-- ============================================================
-- Yapper · Reports and Yapper-wide bans
-- Anyone can report a user or a message. Reports go to Yapper's admins
-- (site_admins), who review them in the Admin panel and can dismiss them,
-- delete the message, or ban the person from all of Yapper.
-- A banned account can still log in (to see why), but can't post, react,
-- join, create or change anything.
-- ============================================================

create table public.site_admins (
  user_id uuid primary key references public.profiles (id) on delete cascade
);
alter table public.site_admins enable row level security;

create or replace function public.is_site_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_admins where user_id = auth.uid());
$$;

create policy "admins can see the admin list"
  on public.site_admins for select to authenticated using (public.is_site_admin() or user_id = auth.uid());

-- ---------- Bans ----------
create table public.site_bans (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  reason text not null default '' check (char_length(reason) <= 500),
  banned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.site_bans enable row level security;
create policy "you can see your own ban; admins see all"
  on public.site_bans for select to authenticated using (user_id = auth.uid() or public.is_site_admin());

create or replace function public.is_site_banned(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_bans where user_id = uid);
$$;

create or replace function public.not_site_banned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and public.is_site_banned(auth.uid()) then
    raise exception 'Your account is banned from Yapper' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger messages_not_banned before insert or update on public.messages
  for each row execute function public.not_site_banned();
create trigger reactions_not_banned before insert on public.reactions
  for each row execute function public.not_site_banned();
create trigger servers_not_banned before insert or update on public.servers
  for each row execute function public.not_site_banned();
create trigger channels_not_banned before insert or update on public.channels
  for each row execute function public.not_site_banned();
create trigger members_not_banned before insert on public.server_members
  for each row execute function public.not_site_banned();
create trigger friendships_not_banned before insert on public.friendships
  for each row execute function public.not_site_banned();
create trigger invites_not_banned before insert on public.invites
  for each row execute function public.not_site_banned();
create trigger emojis_not_banned before insert or update on public.emojis
  for each row execute function public.not_site_banned();
create trigger profiles_not_banned before update on public.profiles
  for each row execute function public.not_site_banned();

-- ---------- Reports ----------
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles (id) on delete set null,
  target_id uuid references public.profiles (id) on delete cascade,
  message_id uuid references public.messages (id) on delete set null,
  channel_id uuid references public.channels (id) on delete set null,
  -- What the message said when it was reported, kept as evidence.
  message_content text,
  message_attachment text,
  reason text not null check (reason in ('harassment', 'hate', 'sexual', 'minor_safety', 'violence', 'spam', 'self_harm', 'illegal', 'other')),
  details text not null default '' check (char_length(details) <= 1000),
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index reports_status_idx on public.reports (status, created_at desc);
create index reports_reporter_idx on public.reports (reporter_id, created_at desc);
alter table public.reports enable row level security;
create policy "admins read reports" on public.reports for select to authenticated using (public.is_site_admin());
alter publication supabase_realtime add table public.reports;

create or replace function public.report_guard(reporter uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if reporter is null then raise exception 'You need to be logged in'; end if;
  if (select count(*) from public.reports where reporter_id = reporter and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'You''ve sent a lot of reports. Try again later.';
  end if;
end;
$$;

-- Report a message you can see. The text is copied so deleting it doesn't hide the evidence.
create or replace function public.report_message(mid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.messages;
  rid uuid;
begin
  perform public.report_guard(auth.uid());
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  if m.author_id = auth.uid() then raise exception 'You can''t report your own message'; end if;
  insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details)
  values (auth.uid(), m.author_id, m.id, m.channel_id, m.content, m.attachment_path, why, left(coalesce(more, ''), 1000))
  returning id into rid;
  return rid;
end;
$$;

create or replace function public.report_user(uid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
begin
  perform public.report_guard(auth.uid());
  if uid = auth.uid() then raise exception 'You can''t report yourself'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'User not found'; end if;
  insert into public.reports (reporter_id, target_id, reason, details)
  values (auth.uid(), uid, why, left(coalesce(more, ''), 1000))
  returning id into rid;
  return rid;
end;
$$;

-- ---------- Admin actions ----------
create or replace function public.resolve_report(rid uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if new_status not in ('open', 'actioned', 'dismissed') then raise exception 'Bad status'; end if;
  update public.reports
     set status = new_status,
         resolved_by = case when new_status = 'open' then null else auth.uid() end,
         resolved_at = case when new_status = 'open' then null else now() end
   where id = rid;
end;
$$;

create or replace function public.admin_delete_message(mid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  delete from public.messages where id = mid;
end;
$$;

-- Ban someone from all of Yapper; optionally delete everything they've written.
create or replace function public.site_ban(uid uuid, why text default '', wipe boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  if wipe then
    delete from public.messages where author_id = uid;
  end if;
  -- Close their open reports as handled.
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end;
$$;

create or replace function public.site_unban(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  delete from public.site_bans where user_id = uid;
end;
$$;

revoke all on function public.report_message(uuid, text, text), public.report_user(uuid, text, text),
  public.resolve_report(uuid, text), public.admin_delete_message(uuid), public.site_ban(uuid, text, boolean),
  public.site_unban(uuid), public.report_guard(uuid) from public, anon;
grant execute on function public.report_message(uuid, text, text), public.report_user(uuid, text, text),
  public.resolve_report(uuid, text), public.admin_delete_message(uuid), public.site_ban(uuid, text, boolean),
  public.site_unban(uuid) to authenticated;
