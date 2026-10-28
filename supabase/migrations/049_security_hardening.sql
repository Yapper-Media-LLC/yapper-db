-- ============================================================
-- Security hardening (2026-10-14)
-- ============================================================

-- 1. Profile columns people must not set on themselves.
--    The old guards were SECURITY DEFINER, so `current_user` inside them was always the
--    owner and the "is this a normal user?" check never fired. Guards now run as the
--    caller: direct client updates arrive as `authenticated`; our admin RPCs and the
--    server (service_role / postgres) are unaffected.
create or replace function public.protect_profile_columns()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  if current_user = 'authenticated' and not public.is_site_admin() then
    new.id := old.id;
    new.created_at := old.created_at;
    new.verified_as := old.verified_as;
    new.plus_until := old.plus_until;
    new.muted_until := old.muted_until;
    new.muted_reason := old.muted_reason;
    new.voice_muted_until := old.voice_muted_until;
    new.stripe_customer := old.stripe_customer;
  end if;
  return new;
end;
$$;
-- Named to run first, so the name guard below can still drop a badge on rename.
drop trigger if exists profiles_0_protect on public.profiles;
create trigger profiles_0_protect before update on public.profiles for each row execute function public.protect_profile_columns();
-- Same SECURITY DEFINER problem made "badge drops when you rename" never fire.
alter function public.profile_custom_guard() security invoker;

-- 2. Stripe customer ids out of the world-readable profiles table.
create table if not exists public.billing_customers (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  stripe_customer text not null unique,
  created_at timestamptz not null default now()
);
alter table public.billing_customers enable row level security;   -- no policies: server (service role) only
insert into public.billing_customers (user_id, stripe_customer)
  select id, stripe_customer from public.profiles where stripe_customer is not null
  on conflict (user_id) do nothing;
-- (profiles.stripe_customer is emptied below and locked by profiles_0_protect; safe to drop later.)

-- 2b. Failed username logins, for /api/login's password-guessing limit (server only).
create table if not exists public.login_attempts (
  id bigint generated always as identity primary key,
  ip text not null,
  username text not null,
  ok boolean not null,
  at timestamptz not null default now()
);
alter table public.login_attempts enable row level security;
create index if not exists login_attempts_ip_idx on public.login_attempts (ip, at desc);
create index if not exists login_attempts_user_idx on public.login_attempts (lower(username), at desc);

-- 3. Messages: authors can edit text only (pins go through pin_message()).
create or replace function public.message_edit_guard()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  new.id := old.id;
  new.channel_id := old.channel_id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  new.attachment_path := old.attachment_path;
  new.attachment_width := old.attachment_width;
  new.attachment_height := old.attachment_height;
  new.reply_to_id := case when new.reply_to_id is null then null else old.reply_to_id end;
  if current_user = 'authenticated' then
    new.pinned_at := old.pinned_at;
    new.pinned_by := old.pinned_by;
  end if;
  if new.content is distinct from old.content then new.edited_at := now(); else new.edited_at := old.edited_at; end if;
  return new;
end;
$$;

-- 4. Invites: normal invites only (custom links go through set_vanity_invite()).
alter policy "members create invites" on public.invites
  with check (created_by = auth.uid() and public.server_perm(server_id, 'create_invite')
              and not vanity and uses = 0 and code ~ '^[A-Za-z0-9]{8,16}$');

-- 5. Role hierarchy (like Discord): non-owners can only create, edit, delete, give or take
--    roles below their own highest role, and can only hand out permissions they have.
create or replace function public.my_top_role_position(sid uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select max(r.position) from public.member_roles mr join public.roles r on r.id = mr.role_id
                   where mr.server_id = sid and mr.user_id = auth.uid()), -1);
$$;
grant execute on function public.my_top_role_position(uuid) to authenticated;

create or replace function public.role_guard()
returns trigger language plpgsql security invoker set search_path = public as $$
declare sid uuid; top int; pos int; k text;
begin
  if current_user <> 'authenticated' then return coalesce(new, old); end if;
  sid := coalesce(new.server_id, old.server_id);
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) or public.is_site_admin() then
    return coalesce(new, old);
  end if;
  top := public.my_top_role_position(sid);

  if tg_table_name = 'member_roles' then
    select position into pos from public.roles where id = coalesce(new.role_id, old.role_id);
    if pos is null or pos >= top then raise exception 'You can only give or take roles below your highest role'; end if;
    return coalesce(new, old);
  end if;

  -- roles
  if tg_op in ('UPDATE', 'DELETE') and old.position >= top then
    raise exception 'You can only change roles below your highest role';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' and new.position >= top then new.position := top - 1; end if;
  if new.position >= top then raise exception 'Roles have to stay below your highest role'; end if;
  if coalesce((new.perms ->> 'administrator')::boolean, false)
     and (tg_op = 'INSERT' or not coalesce((old.perms ->> 'administrator')::boolean, false)) then
    raise exception 'Only the owner can grant Administrator';
  end if;
  if new.manage_server and (tg_op = 'INSERT' or not old.manage_server) and not public.server_perm(sid, 'administrator') then
    raise exception 'You can''t grant Manage Server';
  end if;
  if new.manage_messages and (tg_op = 'INSERT' or not old.manage_messages) and not public.server_perm(sid, 'manage_messages') then
    raise exception 'You can''t grant Manage Messages';
  end if;
  for k in select key from jsonb_each_text(coalesce(new.perms, '{}'::jsonb)) where value = 'true' loop
    if (tg_op = 'INSERT' or not coalesce((old.perms ->> k)::boolean, false)) and not public.server_perm(sid, k) then
      raise exception 'You can''t give a permission you don''t have (%)', k;
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists roles_guard on public.roles;
create trigger roles_guard before insert or update or delete on public.roles for each row execute function public.role_guard();
drop trigger if exists member_roles_guard on public.member_roles;
create trigger member_roles_guard before insert or delete on public.member_roles for each row execute function public.role_guard();

-- Reordering can move roles above yourself, so it's owner/administrator only.
create or replace function public.reorder_roles(sid uuid, ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare n int; i int;
begin
  if not (exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) or public.server_perm(sid, 'administrator')) then
    raise exception 'Only the owner can rearrange roles';
  end if;
  n := coalesce(array_length(ids, 1), 0);
  for i in 1 .. n loop
    update public.roles set position = n - i where id = ids[i] and server_id = sid;
  end loop;
end;
$$;

-- 6. Re-uploading a different file at a path that already passed the image check
--    (delete + upload again, or overwrite) would skip the check. Paths are single-use:
--    every scanned-bucket path is remembered the first time it's uploaded.
create table if not exists public.storage_paths_used (
  bucket text not null,
  path text not null,
  at timestamptz not null default now(),
  primary key (bucket, path)
);
alter table public.storage_paths_used enable row level security;   -- no policies: internal
insert into public.storage_paths_used (bucket, path)
  select bucket_id, name from storage.objects where bucket_id in ('attachments', 'avatars', 'banners', 'icons', 'emojis')
  on conflict do nothing;
insert into public.storage_paths_used (bucket, path) select bucket, path from public.media_scans on conflict do nothing;

create or replace function public.storage_no_path_reuse()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if new.bucket_id in ('attachments', 'avatars', 'banners', 'icons', 'emojis') then
    insert into public.storage_paths_used (bucket, path) values (new.bucket_id, new.name) on conflict do nothing;
    get diagnostics n = row_count;
    if n = 0 then raise exception 'That file name was already used. Upload it again.'; end if;
  end if;
  return new;
end;
$$;
drop trigger if exists no_path_reuse on storage.objects;
create trigger no_path_reuse before insert on storage.objects for each row execute function public.storage_no_path_reuse();
-- Overwriting an existing file (upsert) also skipped the check: no UPDATE on these buckets.
alter policy "profile images: update own folder" on storage.objects using (false);

-- 7. Functions: nothing for logged-out visitors except what the signup/invite pages need,
--    and internal helpers aren't callable directly (apply_auto_action took a made-up
--    report, so anyone with one other report on a person could get them auto-banned).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' loop
    if has_function_privilege('authenticated', f.sig, 'execute') then
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
    execute format('revoke execute on function %s from public, anon', f.sig);
  end loop;
end $$;
grant execute on function public.get_invite(text), public.username_taken(text) to anon;
revoke execute on function public.are_friends(uuid, uuid), public.is_blocked_between(uuid, uuid), public.server_perm_user(uuid, uuid, text),
  public.is_staff_user(uuid), public.check_addable(uuid[]), public.apply_auto_action(uuid, public.reports), public.triage_rules(public.reports),
  public.report_guard(uuid), public.mod_guard(text, uuid, text) from authenticated;
-- New functions: authenticated + service_role only (anon must be granted explicitly).
alter default privileges for role postgres in schema public revoke execute on functions from public, anon;
alter default privileges for role postgres revoke execute on functions from public;

-- Pin search_path on the remaining helper functions.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proconfig is null
    and p.proname in ('emoji_limit','check_icon_path','channel_guard','slugify_channel','slur_text','has_slur','no_slurs','message_length',
      'link_targets','no_adult_links','bad_name','no_bad_names','has_self_harm_incitement','check_links','brand_name','basic_perm',
      'legacy_manage_server','legacy_manage_messages','roles_sync_legacy','skeleton','clean_name') loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

-- 7b. New messages can't arrive already pinned or "edited".
create or replace function public.message_defaults()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.created_at := now();
  new.edited_at := null;
  new.pinned_at := null;
  new.pinned_by := null;
  if new.reply_to_id is not null and not exists (
    select 1 from public.messages where id = new.reply_to_id and channel_id = new.channel_id
  ) then
    new.reply_to_id := null;
  end if;
  return new;
end;
$$;

-- 8. Undo self-granted badges and Plus from before this fix.
update public.profiles p set verified_as = null
  where verified_as is not null and not exists (select 1 from public.verification_requests r where r.user_id = p.id and r.status = 'approved');
update public.profiles set verified_as = 'Twitch · RightfulOsu' where username = 'Right';
update public.profiles p set plus_until = null
  where plus_until is not null and not exists (select 1 from public.plus_events e where e.user_id = p.id);
-- Customer ids now live in billing_customers; the ones left on profiles were either copied
-- there above or pasted on by people themselves (someone else's id, or junk).
update public.profiles set stripe_customer = null where stripe_customer is not null;
