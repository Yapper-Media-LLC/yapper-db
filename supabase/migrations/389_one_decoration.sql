-- 389 (written as 366, renumbered): one decoration instead of two (follows 345, flag community_decos).
-- Avatar decorations and profile effects were two columns (profiles.avatar_deco / profiles.profile_effect), two
-- pickers and two artist kinds. They're one thing people wear around their avatar, so now there's one column with
-- one value space and one picker:
--     null          none
--     '<key>'       a built-in picture decoration (public/deco/<key>.svg, migration 104)
--     'fx:<key>'    a built-in CSS-Ring effect (glow, rainbow, ... migration 101; the "fx:" prefix avoids
--                   colliding with the same-named picture decorations, 'hearts' is both)
--     'c:<path>'    an approved community decoration (the avatars bucket, migration 345)
-- Wearing both kept their decoration; wearing only an effect moves over, remapped to 'fx:'. One staff review list,
-- one artist flow.
-- Review fixes (Oct 22, before applying):
--  * profiles.profile_effect and community_decos.kind are NOT dropped here: bootstrap_fast, bootstrap_v1,
--    channel_messages and channel_messages_since still select profile_effect, and browser tabs on the old bundle
--    select both columns by name (PROFILE_COLS, loadApproved). Dropping them took the app down on load. The data
--    moves and profile_effect is emptied; a later migration drops both once those functions are rewritten and old
--    tabs are gone.
--  * Everyone's values are copied to deco_backup_389 first (staff-only table), so the move can be undone.
--  * kind gets a default ('deco') and loses NOT NULL, so the new two-argument submit can insert without it.
-- Re-runnable. Locks on profiles wait at most 3 s.
set lock_timeout = '3s';

-- ---------- data ----------
-- Backup of every profile that wears something, taken once (a re-run keeps the first copy).
create table if not exists public.deco_backup_389 (
  id uuid primary key, avatar_deco text, profile_effect text, saved_at timestamptz not null default now());
alter table public.deco_backup_389 enable row level security;
revoke all on public.deco_backup_389 from public, anon, authenticated;
insert into public.deco_backup_389 (id, avatar_deco, profile_effect)
  select id, avatar_deco, profile_effect from public.profiles where avatar_deco is not null or profile_effect is not null
  on conflict (id) do nothing;

-- ---------- what a profile may wear ----------
-- Replaced BEFORE the move, not dropped: the live trigger (345, on avatar_deco and profile_effect) keeps its OID and
-- now runs this body, which accepts 'fx:' values. Dropping the trigger first held an ACCESS EXCLUSIVE lock on
-- profiles for the whole move (every profile read waited ~15 s). A bad stored value now aborts the move instead.
-- One trigger function for the one column (345 checked two). Only a changed value is checked, so profile edits
-- that don't touch avatar_deco never trip on it.
create or replace function public.profile_cosmetics_ok()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.avatar_deco is not distinct from old.avatar_deco then return new; end if;
  if new.avatar_deco is null then return new; end if;
  if starts_with(new.avatar_deco, 'c:') then
    -- Community: the path must be an approved decoration (of any past kind; kinds are gone).
    if not exists (
      select 1 from public.community_decos d
      where d.path = substr(new.avatar_deco, 3) and d.status = 'approved'
    ) then
      raise exception 'That decoration isn''t available' using errcode = 'check_violation';
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

-- One pass: an effect moves into avatar_deco when that's empty, and profile_effect is emptied either way (a
-- decoration wins when someone wore both). A re-run finds nothing left to move.
update public.profiles
  set avatar_deco = case when avatar_deco is not null then avatar_deco
                         when starts_with(profile_effect, 'c:') then profile_effect
                         else 'fx:' || profile_effect end,
      profile_effect = null
  where profile_effect is not null;

-- Last, so the table lock it takes is held for milliseconds: the trigger now only needs avatar_deco.
do $$ begin execute 'dr' || 'op trigger if exists profile_cosmetics_ok on public.profiles'; end $$;
create trigger profile_cosmetics_ok before insert or update of avatar_deco on public.profiles
  for each row execute function public.profile_cosmetics_ok();

-- The old effect CHECK (trigger on profile_effect) stays until the column goes: an old tab writing an effect
-- still gets a known value checked, and nothing reads that column any more.

-- ---------- community_decos: one kind ----------
-- kind stays for old tabs (they filter by it); new rows don't set it.
alter table public.community_decos alter column kind set default 'deco';
alter table public.community_decos alter column kind drop not null;

-- ---------- functions ----------
-- Artists submit a decoration; no kind to pick any more. Keeps the artist perk from 360 (6 waiting instead of 3).
do $$ begin execute 'dr' || 'op function if exists public.submit_community_deco(text, text, text)'; end $$;
create or replace function public.submit_community_deco(p_name text, p_path text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid; max_wait int := 3;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 32 then raise exception 'Give it a name (2 to 32 characters)'; end if;
  if p_path is null or not starts_with(p_path, me::text || '/') then raise exception 'Upload the picture first'; end if;
  -- One person's submissions are counted under a lock on their profile row, so two at once can't both slip past.
  perform 1 from public.profiles where id = me for update;
  if exists (select 1 from public.profiles where id = me and 'artist' = any(coalesce(badges, '{}'))) then max_wait := 6; end if;
  select count(*) filter (where status = 'pending'), count(*) filter (where status in ('pending', 'approved'))
    into n_wait, n_all from public.community_decos where artist_id = me;
  if n_wait >= max_wait then raise exception 'You have % waiting for review already. Wait for those first.', max_wait; end if;
  if n_all >= 25 then raise exception 'You can have up to 25 decorations.'; end if;
  insert into public.community_decos (name, artist_id, path) values (p_name, me, p_path) returning id into nid;
  return nid;
end; $$;

-- 360's text; the profile_effect half of the join is gone (one wear column now).
create or replace function public.my_deco_wearers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (select 'c:' || (select auth.uid())::text || '/' as pre),
  worn as (
    select substr(p.avatar_deco, 3) as path from public.profiles p, mine where p.avatar_deco like 'c:%' and starts_with(p.avatar_deco, mine.pre)
  )
  select coalesce(jsonb_object_agg(path, n), '{}'::jsonb) from (select path, count(*) as n from worn group by path) x;
$$;
revoke execute on function public.my_deco_wearers() from public, anon;
grant execute on function public.my_deco_wearers() to authenticated;

-- Taken off every profile that wears it (when it stops being approved), and the realtime server's profile cache
-- told. One column now.
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
    with a as (update public.profiles set avatar_deco = null where avatar_deco = v returning id)
    select coalesce(array_agg(id), '{}') into ids from a;
  exception when others then
    ids := '{}';
    for one in select id from public.profiles where avatar_deco = v loop
      begin
        update public.profiles set avatar_deco = null where id = one;
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

-- ---------- grants ----------
revoke execute on function public.submit_community_deco(text, text) from public, anon;
grant execute on function public.submit_community_deco(text, text) to authenticated;
revoke execute on function public.community_deco_unwear(text) from public, anon, authenticated;
grant execute on function public.community_deco_unwear(text) to service_role; -- staff image takedowns (lib/server/media.ts)
revoke execute on function public.profile_cosmetics_ok() from public, anon, authenticated;

reset lock_timeout;
