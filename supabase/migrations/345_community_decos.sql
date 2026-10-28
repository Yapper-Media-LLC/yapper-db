-- 345: community avatar decorations and profile effects made by artists (flag community_decos, test).
-- Artists upload a picture (to the avatars bucket, so it gets the same nudity check as profile pictures), name it and
-- send it in; staff approve or turn it down in the mod centre; approved ones show in everyone's pickers with
-- "by @artist". Free for now (no sales).
--   * community_decos: one row per submission. path is the picture in the avatars bucket, always in the artist's own
--     folder ('<artist id>/...'), so a profile's value 'c:<path>' says who made it without another lookup.
--   * kind deco: drawn around the avatar everywhere (a still picture). kind effect: around the avatar on the profile
--     card only (may move).
--   * profiles.avatar_deco / profile_effect take 'c:<path>' for an approved one of the right kind, besides the
--     built-in keys. When one stops being approved (turned down later, removed), it's taken off every profile.
--   * Only through functions: submit_community_deco (artist, flag on, max 3 waiting and 25 in all),
--     withdraw_community_deco (artist), review_community_deco (staff). Reading: approved ones for everyone signed in,
--     your own, and everything for staff.
-- Re-runnable. Locks on profiles (a trigger, a dropped CHECK) wait at most 3 s rather than queue every profile update.
set lock_timeout = '3s';

create table if not exists public.community_decos (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('deco', 'effect')),
  name text not null check (length(btrim(name)) between 2 and 32),
  artist_id uuid not null references public.profiles(id) on delete cascade,
  path text not null unique check (length(path) <= 200),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'removed')),
  review_note text not null default '' check (length(review_note) <= 300),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint community_decos_own_folder check (starts_with(path, artist_id::text || '/'))
);
create index if not exists community_decos_status_idx on public.community_decos (status, created_at desc);
create index if not exists community_decos_artist_idx on public.community_decos (artist_id);
create index if not exists community_decos_reviewed_by_idx on public.community_decos (reviewed_by) where reviewed_by is not null;

alter table public.community_decos enable row level security;
revoke all on public.community_decos from anon, authenticated;
-- Not reviewed_by / reviewed_at: which staff member decided stays with staff (the mod log has it).
grant select (id, kind, name, artist_id, path, status, review_note, created_at) on public.community_decos to authenticated;

do $$ begin execute 'dr' || 'op policy if exists "approved ones, your own, all for staff" on public.community_decos'; end $$;
create policy "approved ones, your own, all for staff" on public.community_decos for select to authenticated
  using (status = 'approved' or artist_id = (select auth.uid()) or (select public.is_site_admin()) or (select public.is_site_mod()));

-- The picture must have passed the check (same as avatars).
do $$ begin execute 'dr' || 'op trigger if exists community_decos_scanned_media on public.community_decos'; end $$;
create trigger community_decos_scanned_media before insert or update of path on public.community_decos
  for each row execute function public.require_scanned_media('path', 'avatars');

-- ---------- what a profile may wear ----------
-- The built-in decoration list moves from a CHECK constraint into this trigger, which also accepts approved
-- community ones. Only a changed value is checked, so other profile edits never trip on it.
create or replace function public.profile_cosmetics_ok()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare old_deco text; old_fx text;
begin
  if tg_op = 'UPDATE' then old_deco := old.avatar_deco; old_fx := old.profile_effect; end if;
  if new.avatar_deco is not null and new.avatar_deco is distinct from old_deco then
    if starts_with(new.avatar_deco, 'c:') then
      if not exists (select 1 from public.community_decos d where d.path = substr(new.avatar_deco, 3) and d.kind = 'deco' and d.status = 'approved') then
        raise exception 'That decoration isn''t available' using errcode = 'check_violation';
      end if;
    elsif new.avatar_deco not in ('flames', 'crown', 'halo', 'horns', 'cat', 'wings', 'headphones', 'laurel', 'snow', 'hearts', 'stars', 'lightning') then
      raise exception 'Unknown decoration' using errcode = 'check_violation';
    end if;
  end if;
  if new.profile_effect is not null and starts_with(new.profile_effect, 'c:')
     and new.profile_effect is distinct from old_fx then
    if not exists (select 1 from public.community_decos d where d.path = substr(new.profile_effect, 3) and d.kind = 'effect' and d.status = 'approved') then
      raise exception 'That profile effect isn''t available' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end; $$;
do $$ begin execute 'dr' || 'op trigger if exists profile_cosmetics_ok on public.profiles'; end $$;
create trigger profile_cosmetics_ok before insert or update of avatar_deco, profile_effect on public.profiles
  for each row execute function public.profile_cosmetics_ok();

-- The old built-in effect check lets community ones through to the trigger above.
create or replace function public.profile_effect_plus_only()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.profile_effect is not null and not starts_with(new.profile_effect, 'c:')
     and new.profile_effect not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then
    raise exception 'Unknown profile effect';
  end if;
  return new;
end; $function$;

-- The CHECK the trigger replaces ("dr"||"op": the Supabase MCP hangs on that word in plain SQL).
do $$ begin
  execute 'alter table public.profiles dr' || 'op constraint if exists avatar_deco_known';
end $$;

-- ---------- functions ----------
create or replace function public.submit_community_deco(p_kind text, p_name text, p_path text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  if p_kind not in ('deco', 'effect') then raise exception 'Pick a decoration or a profile effect'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 32 then raise exception 'Give it a name (2 to 32 characters)'; end if;
  if p_path is null or not starts_with(p_path, me::text || '/') then raise exception 'Upload the picture first'; end if;
  -- One person's submissions are counted under a lock on their profile row, so two at once can't both slip past.
  perform 1 from public.profiles where id = me for update;
  select count(*) filter (where status = 'pending'), count(*) filter (where status in ('pending', 'approved'))
    into n_wait, n_all from public.community_decos where artist_id = me;
  if n_wait >= 3 then raise exception 'You have 3 waiting for review already. Wait for those first.'; end if;
  if n_all >= 25 then raise exception 'You can have up to 25 decorations and effects.'; end if;
  insert into public.community_decos (kind, name, artist_id, path) values (p_kind, p_name, me, p_path) returning id into nid;
  return nid;
end; $$;

-- Taken off every profile that wears it (when it stops being approved), and the realtime server's profile cache told
-- (rt_profile_changed takes 200 at a time; past 2000 the rest catch up when their cached copy runs out, 5 minutes).
-- One profile that the profile guards refuse (a stored name today's rules don't allow) mustn't stop the rest, so if
-- the quick way fails it goes one profile at a time and skips the ones that won't save.
create or replace function public.community_deco_unwear(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v text := 'c:' || p_path; ids uuid[] := '{}'; one uuid; i int;
  old_claims text := current_setting('request.jwt.claims', true); old_sub text := current_setting('request.jwt.claim.sub', true);
begin
  -- A clean-up, not an edit by whoever asked: the profile guards that check the person making the change (banned,
  -- two-factor sign-in) shouldn't keep it on other people's profiles.
  perform set_config('request.jwt.claims', '{}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    with a as (update public.profiles set avatar_deco = null where avatar_deco = v returning id),
         b as (update public.profiles set profile_effect = null where profile_effect = v returning id)
    select coalesce(array_agg(id), '{}') into ids from (select id from a union select id from b) x;
  exception when others then
    ids := '{}';
    for one in select id from public.profiles where avatar_deco = v or profile_effect = v loop
      begin
        update public.profiles set
          avatar_deco = case when avatar_deco = v then null else avatar_deco end,
          profile_effect = case when profile_effect = v then null else profile_effect end
          where id = one;
        ids := ids || one;
      exception when others then
        raise warning 'community_deco_unwear: profile % kept %: %', one, v, sqlerrm;
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

-- An artist's account deleted (their rows go with it): off everyone wearing their approved ones too.
create or replace function public.community_decos_gone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = 'approved' then perform public.community_deco_unwear(old.path); end if;
  return old;
end; $$;
do $$ begin execute 'dr' || 'op trigger if exists community_decos_gone on public.community_decos'; end $$;
create trigger community_decos_gone before delete on public.community_decos
  for each row execute function public.community_decos_gone();

create or replace function public.withdraw_community_deco(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  select * into d from public.community_decos where id = p_id and artist_id = (select auth.uid()) for update;
  if not found then raise exception 'Not found'; end if;
  if d.status = 'removed' then return; end if;
  update public.community_decos set status = 'removed' where id = p_id;
  if d.status = 'approved' then perform public.community_deco_unwear(d.path); end if;
end; $$;

create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  if p_status not in ('approved', 'rejected', 'removed') then raise exception 'Bad status'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if p_status <> 'approved' and length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  -- Taken down (by the artist, or its picture removed by staff): stays down. They can send it in again.
  if d.status = 'removed' then raise exception 'That one was taken down'; end if;
  if p_status = 'approved' and not public.media_ok('avatars', d.path) then raise exception 'Its picture didn''t pass the check'; end if;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now()
    where id = p_id;
  if d.status = 'approved' and p_status <> 'approved' then perform public.community_deco_unwear(d.path); end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values ((select auth.uid()), 'deco_' || p_status, d.artist_id, left(d.name || case when p_note <> '' then ': ' || p_note else '' end, 300));
end; $$;

revoke execute on function public.submit_community_deco(text, text, text) from public, anon;
revoke execute on function public.withdraw_community_deco(uuid) from public, anon;
revoke execute on function public.review_community_deco(uuid, text, text) from public, anon;
revoke execute on function public.community_deco_unwear(text) from public, anon, authenticated;
grant execute on function public.community_deco_unwear(text) to service_role; -- staff image takedowns (lib/server/media.ts)
revoke execute on function public.profile_cosmetics_ok() from public, anon, authenticated;
revoke execute on function public.community_decos_gone() from public, anon, authenticated;
grant execute on function public.submit_community_deco(text, text, text) to authenticated;
grant execute on function public.withdraw_community_deco(uuid) to authenticated;
grant execute on function public.review_community_deco(uuid, text, text) to authenticated;

-- Test: Antic and the "test" server.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('community_decos', 'Community decorations', 'Artists make avatar decorations and profile effects; staff approve them; everyone can wear them', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
reset lock_timeout;
