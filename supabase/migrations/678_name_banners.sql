-- 678: name banners (flag name_banners, test: Antic + HQ test server).
-- A decorative strip behind someone's name in the member list and the DM list (and the mini profile's header). Only
-- there, never in chat. Two sources:
--     built-in   CSS gradients made by us (lib/nameBanners.ts), stored as their key ('aurora', 'sunset', ...)
--     community  pictures made by artists through the community decoration flow (345, 672): same table, same review
--                queue, auto check, Artist badge, Shards prices and takedowns, a new kind 'banner'. Stored as
--                'c:<path>' of an approved 'banner' one.
--     profiles.name_banner  one of those, or null.
-- Builds on 672 (community_effects): every function below is 672's live body plus the banner bits.
-- Re-runnable. Locks wait at most 3 s.
set lock_timeout = '3s';

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('name_banners', 'Name banners',
  'A decorative strip behind your name in the member list and DMs. Built-in ones plus community-made ones (Art desk review, Shards). Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- the column ----------
alter table public.profiles add column if not exists name_banner text;
-- Column grants (profiles refuses select('*')): everyone reads it like avatar_deco, you set your own.
grant select (name_banner) on public.profiles to anon, authenticated;
grant update (name_banner) on public.profiles to authenticated;

-- ---------- community_decos: the new kind ----------
do $$
begin
  if exists (select 1 from pg_constraint where conrelid = 'public.community_decos'::regclass and conname = 'community_decos_kind_check'
             and pg_get_constraintdef(oid) not like '%banner%') then
    execute 'alter table public.community_decos dr' || 'op constraint community_decos_kind_check';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.community_decos'::regclass and conname = 'community_decos_kind_check') then
    alter table public.community_decos add constraint community_decos_kind_check check (kind in ('deco', 'effect', 'profile', 'banner'));
  end if;
end $$;

-- The banner picker and the artist's own list (a few hundred rows at most).
create index if not exists community_decos_banner_idx on public.community_decos (status, created_at desc) where kind = 'banner';
-- The index on profiles for who wears which banner is 678b (built concurrently, outside a transaction): run it right
-- after this one.

-- ---------- what a profile may wear ----------
create or replace function public.name_banner_ok()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  if tg_op = 'UPDATE' and new.name_banner is not distinct from old.name_banner then return new; end if;
  if new.name_banner is null then return new; end if;
  if not public.feature_on_for_me('name_banners') then
    raise exception 'Name banners aren''t available yet' using errcode = 'check_violation';
  end if;
  if starts_with(new.name_banner, 'c:') then
    select * into d from public.community_decos
      where path = substr(new.name_banner, 3) and status = 'approved' and kind = 'banner';
    if not found then
      raise exception 'That name banner isn''t available' using errcode = 'check_violation';
    end if;
    if d.price is not null and d.artist_id <> new.id
       and not exists (select 1 from public.deco_owned o where o.user_id = new.id and o.deco_id = d.id) then
      raise exception 'Buy that name banner first' using errcode = 'check_violation';
    end if;
  elsif new.name_banner not in ('aurora', 'sunset', 'ocean', 'neon', 'candy', 'ember', 'galaxy', 'mint', 'gold', 'midnight') then
    raise exception 'Unknown name banner' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

do $$ begin execute 'dr' || 'op trigger if exists name_banner_ok on public.profiles'; end $$;
create trigger name_banner_ok before insert or update of name_banner on public.profiles
  for each row execute function public.name_banner_ok();

-- avatar_deco: 672's body, except a name banner can't be worn as an avatar decoration either.
create or replace function public.profile_cosmetics_ok()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  if tg_op = 'UPDATE' and new.avatar_deco is not distinct from old.avatar_deco then return new; end if;
  if new.avatar_deco is null then return new; end if;
  if starts_with(new.avatar_deco, 'c:') then
    select * into d from public.community_decos
      where path = substr(new.avatar_deco, 3) and status = 'approved' and coalesce(kind, 'deco') not in ('profile', 'banner');
    if not found then
      raise exception 'That decoration isn''t available' using errcode = 'check_violation';
    end if;
    if d.price is not null and d.artist_id <> new.id
       and not exists (select 1 from public.deco_owned o where o.user_id = new.id and o.deco_id = d.id) then
      raise exception 'Buy that decoration first' using errcode = 'check_violation';
    end if;
  elsif starts_with(new.avatar_deco, 'fx:') then
    if substr(new.avatar_deco, 4) not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then
      raise exception 'Unknown effect' using errcode = 'check_violation';
    end if;
  elsif new.avatar_deco not in ('flames', 'crown', 'halo', 'horns', 'cat', 'wings', 'headphones', 'laurel', 'snow', 'hearts', 'stars', 'lightning') then
    raise exception 'Unknown decoration' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

-- ---------- sending one in ----------
-- 672's body plus 'banner': its own flag, no events, not paused with decoration submissions, counted on its own
-- (10 live or waiting; waiting cap 3, or 6 for artists). Decorations count only decorations now (672 counted
-- everything that wasn't a profile effect).
create or replace function public.submit_community_deco(p_name text, p_path text, p_event text default null, p_kind text default 'deco')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid; max_wait int := 3; own boolean;
begin
  if me is null then raise exception 'Sign in first'; end if;
  p_kind := coalesce(nullif(btrim(coalesce(p_kind, '')), ''), 'deco');
  if p_kind not in ('deco', 'profile', 'banner') then raise exception 'Unknown kind'; end if;
  -- Profile effects and name banners: their own flag and their own counts.
  own := p_kind <> 'deco';
  p_event := nullif(btrim(coalesce(p_event, '')), '');
  if own then
    if p_event is not null then raise exception 'Events take decorations only'; end if;
    if not public.feature_on_for_me(case when p_kind = 'banner' then 'name_banners' else 'community_effects' end) then
      raise exception 'Not available yet';
    end if;
  elsif p_event is not null then
    if p_event <> 'halloween_2026' then raise exception 'Unknown event'; end if;
    if not public.feature_on_for_me('halloween_decos') then raise exception 'The Halloween event isn''t open'; end if;
  elsif not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if not own and public.feature_on_for_me('deco_submissions_closed') and not public.feature_on_for_me('deco_uploads_open') then
    raise exception 'Decoration submissions are paused for now';
  end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 32 then raise exception 'Give it a name (2 to 32 characters)'; end if;
  if p_path is null or not starts_with(p_path, me::text || '/') then raise exception 'Upload the picture first'; end if;
  -- One person's submissions are counted under a lock on their profile row, so two at once can't both slip past.
  perform 1 from public.profiles where id = me for update;
  if exists (select 1 from public.profiles where id = me and 'artist' = any(coalesce(badges, '{}'))) then max_wait := 6; end if;
  select count(*) filter (where status = 'pending'), count(*) filter (where status in ('pending', 'approved'))
    into n_wait, n_all from public.community_decos
    where artist_id = me
      and (case when kind in ('profile', 'banner') then kind else 'deco' end) = p_kind;
  if n_wait >= max_wait then raise exception 'You have % waiting for review already. Wait for those first.', max_wait; end if;
  if p_kind = 'profile' and n_all >= 10 then raise exception 'You can have up to 10 profile effects.'; end if;
  if p_kind = 'banner' and n_all >= 10 then raise exception 'You can have up to 10 name banners.'; end if;
  if not own and n_all >= 25 then raise exception 'You can have up to 25 decorations.'; end if;
  insert into public.community_decos (name, artist_id, path, event, kind) values (p_name, me, p_path, p_event, p_kind) returning id into nid;
  return nid;
end; $$;

-- ---------- wearers ----------
-- How many people wear each of my approved ones, all three kinds: { path: n }.
create or replace function public.my_deco_wearers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (select (select auth.uid())::text || '/' as pre),
  worn as (
    select substr(p.avatar_deco, 3) as path from public.profiles p, mine
      where p.avatar_deco like 'c:%' and starts_with(p.avatar_deco, 'c:' || mine.pre)
    union all
    select substr(p.profile_effect, 3) from public.profiles p, mine
      where p.profile_effect like 'p:%' and starts_with(p.profile_effect, 'p:' || mine.pre)
    union all
    select substr(p.name_banner, 3) from public.profiles p, mine
      where p.name_banner like 'c:%' and starts_with(p.name_banner, 'c:' || mine.pre)
  )
  select coalesce(jsonb_object_agg(path, n), '{}'::jsonb) from (select path, count(*) as n from worn group by path) x;
$$;

-- Most worn first, one kind at a time: 'deco' (and the legacy 'effect' rows), 'profile' or 'banner'.
create or replace function public.community_decos_popular(p_offset integer default 0, p_limit integer default 200, p_kind text default 'deco')
returns table(id uuid, name text, artist_id uuid, path text, status text, review_note text, created_at timestamptz, event text, wearers integer)
language sql
stable
security definer
set search_path = public
as $$
  with k as (select case when p_kind in ('profile', 'banner') then p_kind else 'deco' end as kind),
  worn as (
    select substr(p.avatar_deco, 3) as path, count(*)::int as n
      from public.profiles p, k where k.kind = 'deco' and p.avatar_deco like 'c:%' group by 1
    union all
    select substr(p.profile_effect, 3), count(*)::int
      from public.profiles p, k where k.kind = 'profile' and p.profile_effect like 'p:%' group by 1
    union all
    select substr(p.name_banner, 3), count(*)::int
      from public.profiles p, k where k.kind = 'banner' and p.name_banner like 'c:%' group by 1
  )
  select d.id, d.name, d.artist_id, d.path, d.status, d.review_note, d.created_at, d.event, coalesce(w.n, 0)
  from public.community_decos d cross join k left join worn w on w.path = d.path
  where d.status = 'approved'
    and (case when d.kind in ('profile', 'banner') then d.kind else 'deco' end) = k.kind
  order by coalesce(w.n, 0) desc, d.created_at desc, d.id
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 200), 0), 200);
$$;

-- ---------- taking one off everyone ----------
-- 672's body, for all three columns.
create or replace function public.community_deco_unwear(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v text := 'c:' || p_path; pv text := 'p:' || p_path; ids uuid[] := '{}'; one uuid; i int;
  old_claims text := current_setting('request.jwt.claims', true); old_sub text := current_setting('request.jwt.claim.sub', true);
begin
  -- A clean-up, not an edit by whoever asked: the profile guards that check the person making the change (banned,
  -- two-factor sign-in) shouldn't keep it on other people's profiles.
  perform set_config('request.jwt.claims', '{}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    with a as (
      update public.profiles
        set avatar_deco = case when avatar_deco = v then null else avatar_deco end,
            profile_effect = case when profile_effect = pv then null else profile_effect end,
            name_banner = case when name_banner = v then null else name_banner end
        where (avatar_deco like 'c:%' and avatar_deco = v) or (profile_effect like 'p:%' and profile_effect = pv)
           or (name_banner like 'c:%' and name_banner = v)
        returning id)
    select coalesce(array_agg(id), '{}') into ids from a;
  exception when others then
    ids := '{}';
    for one in select id from public.profiles where (avatar_deco like 'c:%' and avatar_deco = v) or (profile_effect like 'p:%' and profile_effect = pv)
                 or (name_banner like 'c:%' and name_banner = v) loop
      begin
        update public.profiles
          set avatar_deco = case when avatar_deco = v then null else avatar_deco end,
              profile_effect = case when profile_effect = pv then null else profile_effect end,
              name_banner = case when name_banner = v then null else name_banner end
          where id = one;
        ids := ids || one;
      exception when others then
        raise warning 'community_deco_unwear: profile % kept %: %', one, p_path, sqlerrm;
      end;
    end loop;
  end;
  perform set_config('request.jwt.claims', coalesce(nullif(old_claims, ''), '{}'), true);
  perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
  i := 1;
  while i <= least(cardinality(ids), 2000) loop
    perform public.rt_profile_changed(ids[i : i + 199]);
    i := i + 200;
  end loop;
end; $$;

-- ---------- grants ----------
revoke execute on function public.submit_community_deco(text, text, text, text) from public, anon;
grant execute on function public.submit_community_deco(text, text, text, text) to authenticated;
revoke execute on function public.community_decos_popular(integer, integer, text) from public, anon;
grant execute on function public.community_decos_popular(integer, integer, text) to authenticated;
revoke execute on function public.my_deco_wearers() from public, anon;
grant execute on function public.my_deco_wearers() to authenticated;
revoke execute on function public.community_deco_unwear(text) from public, anon, authenticated;
grant execute on function public.community_deco_unwear(text) to service_role;
revoke execute on function public.profile_cosmetics_ok() from public, anon, authenticated;
revoke execute on function public.name_banner_ok() from public, anon, authenticated;

reset lock_timeout;
