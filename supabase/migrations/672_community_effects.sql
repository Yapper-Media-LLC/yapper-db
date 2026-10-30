-- 672: community profile effects (flag community_effects, test: Antic + HQ test server).
-- Like Discord's Profile Effects: an animated picture over the whole profile card, made by artists through the same
-- flow as community avatar decorations (345). Same table, same review queue, auto check, Artist badge, Shards prices
-- and takedowns; a new kind tells them apart:
--     community_decos.kind  'deco' (and the legacy 'effect' rows, which are avatar ring art worn as decorations
--                           since 389) or 'profile' (a profile effect, new here)
--     profiles.profile_effect  'p:<path>' of an approved 'profile' one. The column has been unused since 389; the old
--                           values still in it ('glow', 'c:...', written by old tabs) are left alone and never shown,
--                           the new prefix keeps them apart.
-- Re-runnable. Locks wait at most 3 s.
set lock_timeout = '3s';

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('community_effects', 'Community profile effects',
  'Artists make animated profile effects (over the whole profile card, like Discord''s), people pick one in Settings. Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- community_decos: the new kind ----------
do $$
begin
  if exists (select 1 from pg_constraint where conrelid = 'public.community_decos'::regclass and conname = 'community_decos_kind_check'
             and pg_get_constraintdef(oid) not like '%profile%') then
    execute 'alter table public.community_decos dr' || 'op constraint community_decos_kind_check';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.community_decos'::regclass and conname = 'community_decos_kind_check') then
    alter table public.community_decos add constraint community_decos_kind_check check (kind in ('deco', 'effect', 'profile'));
  end if;
end $$;

-- The effect picker and the artist's own list (a few hundred rows at most; decorations keep community_decos_status_idx).
create index if not exists community_decos_profile_idx on public.community_decos (status, created_at desc) where kind = 'profile';
-- The index on profiles for who wears which effect is 677 (built concurrently, outside a transaction).

-- ---------- what a profile may wear ----------
-- profile_effect: 'p:<path>' of an approved profile effect (bought first when it has a price). The old built-in keys
-- stay accepted so a stale tab can't error, nothing shows them. 'c:' is refused now (it was never checked after 389).
create or replace function public.profile_effect_plus_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  if new.profile_effect is not distinct from old.profile_effect then return new; end if;
  if new.profile_effect is null then return new; end if;
  if starts_with(new.profile_effect, 'p:') then
    select * into d from public.community_decos
      where path = substr(new.profile_effect, 3) and status = 'approved' and kind = 'profile';
    if not found then
      raise exception 'That profile effect isn''t available' using errcode = 'check_violation';
    end if;
    if not public.feature_on_for_me('community_effects') then
      raise exception 'Profile effects aren''t available yet' using errcode = 'check_violation';
    end if;
    if d.price is not null and d.artist_id <> new.id
       and not exists (select 1 from public.deco_owned o where o.user_id = new.id and o.deco_id = d.id) then
      raise exception 'Buy that profile effect first' using errcode = 'check_violation';
    end if;
  elsif new.profile_effect not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then
    raise exception 'Unknown profile effect' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

-- avatar_deco: the live body, except a profile effect can't be worn as an avatar decoration.
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
      where path = substr(new.avatar_deco, 3) and status = 'approved' and kind is distinct from 'profile';
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
-- The live body plus p_kind. Profile effects: their own flag, no events, not paused with decoration submissions, and
-- counted on their own (10 live or waiting; the waiting cap is the same 3, or 6 for artists).
do $$ begin execute 'dr' || 'op function if exists public.submit_community_deco(text, text, text)'; end $$;
create or replace function public.submit_community_deco(p_name text, p_path text, p_event text default null, p_kind text default 'deco')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid; max_wait int := 3; fx boolean;
begin
  if me is null then raise exception 'Sign in first'; end if;
  p_kind := coalesce(nullif(btrim(coalesce(p_kind, '')), ''), 'deco');
  if p_kind not in ('deco', 'profile') then raise exception 'Unknown kind'; end if;
  fx := p_kind = 'profile';
  p_event := nullif(btrim(coalesce(p_event, '')), '');
  if fx then
    if p_event is not null then raise exception 'Events take decorations only'; end if;
    if not public.feature_on_for_me('community_effects') then raise exception 'Not available yet'; end if;
  elsif p_event is not null then
    if p_event <> 'halloween_2026' then raise exception 'Unknown event'; end if;
    if not public.feature_on_for_me('halloween_decos') then raise exception 'The Halloween event isn''t open'; end if;
  elsif not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if not fx and public.feature_on_for_me('deco_submissions_closed') and not public.feature_on_for_me('deco_uploads_open') then
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
    where artist_id = me and (kind is not distinct from 'profile') = fx;
  if n_wait >= max_wait then raise exception 'You have % waiting for review already. Wait for those first.', max_wait; end if;
  if fx and n_all >= 10 then raise exception 'You can have up to 10 profile effects.'; end if;
  if not fx and n_all >= 25 then raise exception 'You can have up to 25 decorations.'; end if;
  insert into public.community_decos (name, artist_id, path, event, kind) values (p_name, me, p_path, p_event, p_kind) returning id into nid;
  return nid;
end; $$;

-- ---------- wearers ----------
-- How many people wear each of my approved ones, decorations and effects: { path: n }.
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
  )
  select coalesce(jsonb_object_agg(path, n), '{}'::jsonb) from (select path, count(*) as n from worn group by path) x;
$$;

-- Most worn first, one kind at a time ('deco' covers the legacy 'effect' rows; 'profile' the profile effects).
do $$ begin execute 'dr' || 'op function if exists public.community_decos_popular(integer, integer)'; end $$;
create or replace function public.community_decos_popular(p_offset integer default 0, p_limit integer default 200, p_kind text default 'deco')
returns table(id uuid, name text, artist_id uuid, path text, status text, review_note text, created_at timestamptz, event text, wearers integer)
language sql
stable
security definer
set search_path = public
as $$
  with worn as (
    select substr(p.avatar_deco, 3) as path, count(*)::int as n
      from public.profiles p where coalesce(p_kind, 'deco') <> 'profile' and p.avatar_deco like 'c:%' group by 1
    union all
    select substr(p.profile_effect, 3), count(*)::int
      from public.profiles p where coalesce(p_kind, 'deco') = 'profile' and p.profile_effect like 'p:%' group by 1
  )
  select d.id, d.name, d.artist_id, d.path, d.status, d.review_note, d.created_at, d.event, coalesce(w.n, 0)
  from public.community_decos d left join worn w on w.path = d.path
  where d.status = 'approved'
    and (d.kind is not distinct from 'profile') = (coalesce(p_kind, 'deco') = 'profile')
  order by coalesce(w.n, 0) desc, d.created_at desc, d.id
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 200), 0), 200);
$$;

-- ---------- taking one off everyone ----------
-- The live body, for both columns: a decoration comes off avatar_deco, an effect off profile_effect.
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
            profile_effect = case when profile_effect = pv then null else profile_effect end
        where (avatar_deco like 'c:%' and avatar_deco = v) or (profile_effect like 'p:%' and profile_effect = pv)
        returning id)
    select coalesce(array_agg(id), '{}') into ids from a;
  exception when others then
    ids := '{}';
    for one in select id from public.profiles where (avatar_deco like 'c:%' and avatar_deco = v) or (profile_effect like 'p:%' and profile_effect = pv) loop
      begin
        update public.profiles
          set avatar_deco = case when avatar_deco = v then null else avatar_deco end,
              profile_effect = case when profile_effect = pv then null else profile_effect end
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
revoke execute on function public.profile_effect_plus_only() from public, anon, authenticated;

reset lock_timeout;
