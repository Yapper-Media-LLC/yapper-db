set lock_timeout = '3s';
-- 281: what the Terms now promise moderators can do (flag legal_round2 for the buttons; legal list items 9 and 10).
--  1. Copyright strikes (Terms 11.2, DMCA repeat-infringer policy): staff record a valid copyright notice against an
--     account (and the server it was in). 3 in 12 months normally means the account is terminated; the Mod Center
--     shows the count and flags 3, a person still decides.
--  2. Freeze, keep evidence (Terms 12.3): admins lock an account for an investigation without deleting anything.
--     A frozen account can't delete itself, and banning it doesn't queue its uploads for deletion. Optionally it's
--     locked out at once (a ban with no expiry; lifting the freeze doesn't unban).
-- Re-runnable.

create table if not exists public.copyright_strikes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  server_id uuid references public.servers (id) on delete set null,
  notice text not null check (length(notice) between 3 and 500),
  by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid references public.profiles (id) on delete set null
);
create index if not exists copyright_strikes_user_idx on public.copyright_strikes (user_id, created_at desc);
alter table public.copyright_strikes enable row level security;
revoke all on public.copyright_strikes from anon, authenticated;

create table if not exists public.account_freezes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  reason text not null check (length(reason) between 3 and 500),
  by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.account_freezes enable row level security;
revoke all on public.account_freezes from anon, authenticated;

-- Uploads that were waiting to be deleted when the account was frozen; put back on unfreeze.
create table if not exists public.freeze_held_purges (
  user_id uuid not null references public.profiles (id) on delete cascade,
  bucket text not null,
  path text not null,
  queued_at timestamptz,
  primary key (bucket, path)
);
alter table public.freeze_held_purges enable row level security;
revoke all on public.freeze_held_purges from anon, authenticated;

create or replace function public.is_frozen(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select exists (select 1 from public.account_freezes where user_id = uid) $$;
revoke all on function public.is_frozen(uuid) from public, anon, authenticated;

-- Strikes on one account (staff).
create or replace function public.staff_copyright_strikes(uid uuid)
returns table (id uuid, server_id uuid, server_name text, notice text, by uuid, created_at timestamptz, removed_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
    select c.id, c.server_id, s.name, c.notice, c.by, c.created_at, c.removed_at
    from public.copyright_strikes c left join public.servers s on s.id = c.server_id
    where c.user_id = uid
    order by c.created_at desc
    limit 50;
end $$;
revoke all on function public.staff_copyright_strikes(uuid) from public, anon;
grant execute on function public.staff_copyright_strikes(uuid) to authenticated;

-- Add one; returns how many count now (not removed, last 12 months).
create or replace function public.staff_add_copyright_strike(uid uuid, sid uuid, p_notice text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if length(btrim(coalesce(p_notice, ''))) < 3 then raise exception 'Say which notice (who sent it, what work, the date)'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'User not found'; end if;
  if sid is not null and not exists (select 1 from public.servers where id = sid) then sid := null; end if;
  insert into public.copyright_strikes (user_id, server_id, notice, by) values (uid, sid, left(btrim(p_notice), 500), auth.uid());
  select count(*) into n from public.copyright_strikes where user_id = uid and removed_at is null and created_at > now() - interval '12 months';
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'copyright_strike', uid, left(n || '/3 ' || btrim(p_notice), 120));
  return n;
end $$;
revoke all on function public.staff_add_copyright_strike(uuid, uuid, text) from public, anon;
grant execute on function public.staff_add_copyright_strike(uuid, uuid, text) to authenticated;

-- Take one back (counter-notice won, or a mistake).
create or replace function public.staff_remove_copyright_strike(cid uuid, why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare who uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.copyright_strikes set removed_at = now(), removed_by = auth.uid()
   where id = cid and removed_at is null returning user_id into who;
  if who is null then raise exception 'Strike not found'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'copyright_strike_removed', who, left(coalesce(why, ''), 120));
end $$;
revoke all on function public.staff_remove_copyright_strike(uuid, text) from public, anon;
grant execute on function public.staff_remove_copyright_strike(uuid, text) to authenticated;

-- Freeze (admins only). lock = also lock them out now (a ban with no expiry).
create or replace function public.admin_freeze_account(uid uuid, p_reason text, lock boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give a reason (staff only see it)'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Not on an admin'; end if;
  insert into public.account_freezes (user_id, reason, by) values (uid, left(btrim(p_reason), 500), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, by = excluded.by;
  -- Uploads already waiting to be deleted (an earlier ban) stay: held aside, put back on unfreeze.
  execute 'with held as (dele' || 'te from public.media_purge where done_at is null and split_part(path, ''/'', 1) = $1 returning bucket, path, queued_at) '
       || 'insert into public.freeze_held_purges (user_id, bucket, path, queued_at) select $2, bucket, path, queued_at from held on conflict do nothing'
    using uid::text, uid;
  if lock and not exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) then
    insert into public.site_bans (user_id, reason, banned_by) values (uid, 'Account locked while we look into something. Email hello@yapper.website', auth.uid())
    on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, expires_at = null, created_at = now();
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'freeze', uid, left(btrim(p_reason), 120));
end $$;
revoke all on function public.admin_freeze_account(uuid, text, boolean) from public, anon;
grant execute on function public.admin_freeze_account(uuid, text, boolean) to authenticated;

create or replace function public.admin_unfreeze_account(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  execute 'dele' || 'te from public.account_freezes where user_id = $1' using uid;
  execute 'with back as (dele' || 'te from public.freeze_held_purges where user_id = $1 returning bucket, path, queued_at) '
       || 'insert into public.media_purge (bucket, path, queued_at) select bucket, path, coalesce(queued_at, now()) from back on conflict do nothing'
    using uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unfreeze', uid, '');
end $$;
revoke all on function public.admin_unfreeze_account(uuid) from public, anon;
grant execute on function public.admin_unfreeze_account(uuid) to authenticated;

-- Staff: is this account frozen, and why.
create or replace function public.staff_freeze_info(uid uuid)
returns table (reason text, by uuid, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query select f.reason, f.by, f.created_at from public.account_freezes f where f.user_id = uid;
end $$;
revoke all on function public.staff_freeze_info(uuid) from public, anon;
grant execute on function public.staff_freeze_info(uuid) to authenticated;

-- A ban on a frozen account keeps its uploads (live definition, Oct 19, plus the check).
create or replace function public.queue_banned_media()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_frozen(new.user_id) then return new; end if;
  insert into public.media_purge (bucket, path)
  select bucket_id, name from storage.objects
  where (storage.foldername(name))[1] = new.user_id::text
  on conflict do nothing;
  return new;
end;
$$;

-- A frozen account can't delete itself (both live versions, patched in place before their first check).
do $$
declare f text; d text; anchor text := E'  if exists (\n    select 1 from public.app_settings a';
begin
  foreach f in array array['public.delete_my_account()', 'public.delete_my_account(text)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('is_frozen' in d) > 0 then continue; end if;
    if position(anchor in d) = 0 then raise exception '281: % anchor not found', f; end if;
    d := replace(d, anchor, E'  if public.is_frozen(uid) then raise exception ''Your account is locked while we look into something, so it can''''t be deleted right now. Email hello@yapper.website''; end if;\n' || anchor);
    execute d;
  end loop;
end $$;

-- Nothing wipes a frozen account's messages: site_ban(.., wipe) and mod_purge_messages refuse (patched in place).
do $$
declare d text; a1 text := E'  if wipe then\n'; a2 text := E'  perform public.mod_guard(''purge'', uid, r);\n';
begin
  d := pg_get_functiondef('public.site_ban(uuid, text, boolean)'::regprocedure);
  if position('is_frozen' in d) = 0 then
    if position(a1 in d) = 0 then raise exception '281: site_ban anchor not found'; end if;
    d := replace(d, a1, E'  if wipe and public.is_frozen(uid) then raise exception ''This account is frozen to keep evidence: ban it without deleting messages''; end if;\n' || a1);
    execute d;
  end if;
  d := pg_get_functiondef('public.mod_purge_messages(uuid, integer, text)'::regprocedure);
  if position('is_frozen' in d) = 0 then
    if position(a2 in d) = 0 then raise exception '281: mod_purge_messages anchor not found'; end if;
    d := replace(d, a2, E'  if public.is_frozen(uid) then raise exception ''This account is frozen to keep evidence, so its messages can''''t be cleaned up''; end if;\n' || a2);
    execute d;
  end if;
end $$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('legal_round2', 'Legal fixes 2 (Oct 19)', 'Withdrawal waiver checkbox at Stripe checkout, Boosts/Promotions need a 7 day old account with a confirmed email, copyright strikes and Freeze in the user file.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
