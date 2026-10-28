-- 575: Join applications (flag join_applications, test). Like Discord's membership screening: a server can ask people
-- to apply before they get in. With "People must apply to join" on, an invite link shows a short form (a message to
-- the mods and up to 3 questions the owner wrote) instead of joining; mods with Kick Members or Manage Server accept
-- or decline from Server settings, Members. Accepting inserts the member like join_server does (same triggers, so
-- bots' welcome messages, member counts and verification-level timers all run); declining can carry a note, and the
-- person can apply again after 24 h. A manager can make a link that skips the form (invites.skip_apply).
--
-- The gate lives in a BEFORE INSERT trigger on server_members, not in join_server: join_server's live body carries
-- patches from several branches (193, 462) and is not in this repo in full, and the trigger also covers
-- join_public_server (Discover). The accept path and the skip paths mark the transaction (yapper.join_ok) before
-- they insert. The applicant hears about the decision live (bc_notice on user:<id>) and on the next app start
-- (my_join_decisions, rows with seen_at null).
-- Re-runnable.

alter table public.servers add column if not exists join_apply boolean not null default false;
alter table public.servers add column if not exists join_questions text[] not null default '{}';
alter table public.invites add column if not exists skip_apply boolean not null default false;

create table if not exists public.server_join_requests (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  invite_code text,
  message text not null default '',
  answers text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  note text not null default '',
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  -- The applicant saw the decision (the in-app notice).
  seen_at timestamptz,
  created_at timestamptz not null default now(),
  unique (server_id, user_id)
);
create index if not exists server_join_requests_pending_idx on public.server_join_requests (server_id, created_at)
  where status = 'pending';
create index if not exists server_join_requests_unseen_idx on public.server_join_requests (user_id)
  where status <> 'pending' and seen_at is null;
create index if not exists server_join_requests_user_pending_idx on public.server_join_requests (user_id)
  where status = 'pending';

alter table public.server_join_requests enable row level security;
-- Reads only through the RPCs below (they add the profile bits and check the permission); writes only through them.
revoke all on public.server_join_requests from public, anon, authenticated;

-- Is the apply gate on for this server? The setting, and the feature on for it.
create or replace function public.join_apply_on(sid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select join_apply from public.servers where id = sid), false) and public.feature_on('join_applications', sid);
end $$;
revoke execute on function public.join_apply_on(uuid) from public, anon;
grant execute on function public.join_apply_on(uuid) to authenticated;

-- Who handles join requests: Kick Members or Manage Server (the owner and admins have both).
create or replace function public.can_review_joins(sid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return public.server_perm(sid, 'kick_members') or public.server_perm(sid, 'manage_server');
end $$;
revoke execute on function public.can_review_joins(uuid) from public, anon;
grant execute on function public.can_review_joins(uuid) to authenticated;

-- Skip links only come from skip_apply_invite (review: a plain member could insert one through the table, and every
-- member could read a mod's skip link and pass it on). Live texts from 049 (insert) and 022 (select) plus the skip rule.
alter policy "members create invites" on public.invites
  with check (created_by = auth.uid() and public.server_perm(server_id, 'create_invite')
              and not vanity and uses = 0 and code ~ '^[A-Za-z0-9]{8,16}$' and not skip_apply);
alter policy "see invites to your servers" on public.invites
  using (server_id in (select public.my_server_ids())
         and (not skip_apply or created_by = auth.uid() or public.can_review_joins(server_id)));

-- The gate: a person adding themself to a server that asks for applications is refused, unless this transaction was
-- opened by accept / a skip link (yapper.join_ok = the server id). Owners and staff pass; someone else adding a bot or
-- a member (user_id <> auth.uid()) is not a join and passes.
create or replace function public.server_members_join_gate()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is distinct from auth.uid() then return new; end if;
  if current_setting('yapper.join_ok', true) = new.server_id::text then return new; end if;
  if not public.join_apply_on(new.server_id) then return new; end if;
  if exists (select 1 from public.servers where id = new.server_id and owner_id = new.user_id) then return new; end if;
  if public.is_staff() then return new; end if;
  raise exception 'This server asks people to apply first. Open its invite link to apply.';
end $$;
drop trigger if exists server_members_join_gate on public.server_members;
create trigger server_members_join_gate before insert on public.server_members
  for each row execute function public.server_members_join_gate();

-- The setting (Manage Server). Turning it on needs the feature; turning it off always works.
create or replace function public.set_join_apply(sid uuid, p_on boolean, p_questions text[] default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare qs text[] := '{}'; q text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You need Manage Server for that'; end if;
  if p_on and not public.feature_on('join_applications', sid) then raise exception 'Join applications aren''t available here yet'; end if;
  foreach q in array coalesce(p_questions, '{}') loop
    q := btrim(coalesce(q, ''));
    if q = '' then continue; end if;
    if length(q) > 200 then raise exception 'Keep each question under 200 characters'; end if;
    qs := qs || q;
  end loop;
  if cardinality(qs) > 3 then raise exception 'Up to 3 questions'; end if;
  update public.servers set join_apply = coalesce(p_on, false), join_questions = qs where id = sid;
end $$;
revoke execute on function public.set_join_apply(uuid, boolean, text[]) from public, anon;
grant execute on function public.set_join_apply(uuid, boolean, text[]) to authenticated;

-- What the invite page needs on top of get_invite: does this link ask for an application, the questions, and where
-- my application stands. Null request = none.
create or replace function public.invite_apply_info(invite_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare i public.invites; r public.server_join_requests; apply boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into i from public.invites where lower(code) = lower(invite_code);
  if i.code is null then return null; end if;
  apply := public.join_apply_on(i.server_id) and not i.skip_apply and not public.is_staff()
    and not exists (select 1 from public.servers where id = i.server_id and owner_id = auth.uid());
  select * into r from public.server_join_requests where server_id = i.server_id and user_id = auth.uid();
  return jsonb_build_object(
    'apply', apply,
    'questions', coalesce((select join_questions from public.servers where id = i.server_id), '{}'),
    'request', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'status', r.status, 'note', r.note, 'created_at', r.created_at, 'decided_at', r.decided_at,
      'retry_at', case when r.status = 'declined' then r.decided_at + interval '24 hours' end) end);
end $$;
revoke execute on function public.invite_apply_info(text) from public, anon;
grant execute on function public.invite_apply_info(text) to authenticated;

-- Open an invite: joins straight away where no application is needed (join_server does the work), otherwise files
-- the application. Returns {joined, server_id, status}.
create or replace function public.apply_to_server(invite_code text, p_message text default '', p_answers text[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.invites; r public.server_join_requests; msg text; ans text[] := '{}'; a text; nq int; staff boolean := public.is_staff();
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  select * into i from public.invites where lower(code) = lower(invite_code);
  if i.code is null then raise exception 'This invite is invalid or has expired'; end if;
  if public.is_server_member(i.server_id) then return jsonb_build_object('joined', true, 'server_id', i.server_id); end if;
  if not public.join_apply_on(i.server_id) or i.skip_apply or staff
     or exists (select 1 from public.servers where id = i.server_id and owner_id = auth.uid()) then
    perform set_config('yapper.join_ok', i.server_id::text, true);
    return jsonb_build_object('joined', true, 'server_id', public.join_server(invite_code));
  end if;
  -- The same refusals join_server gives, so nobody applies to a server they can't get into.
  if public.server_locked(i.server_id) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
  if exists (select 1 from public.server_bans where server_id = i.server_id and user_id = auth.uid()) then
    raise exception 'You''re banned from this server';
  end if;
  msg := left(btrim(coalesce(p_message, '')), 500);
  nq := cardinality(coalesce((select join_questions from public.servers where id = i.server_id), '{}'));
  foreach a in array coalesce(p_answers, '{}') loop ans := ans || left(btrim(coalesce(a, '')), 300); end loop;
  ans := ans[1:nq];
  select * into r from public.server_join_requests where server_id = i.server_id and user_id = auth.uid();
  if r.id is not null then
    if r.status = 'pending' then return jsonb_build_object('joined', false, 'server_id', i.server_id, 'status', 'pending'); end if;
    if r.status = 'declined' and r.decided_at > now() - interval '24 hours' then
      raise exception 'This server said no for now. You can apply again in about % h.', greatest(1, ceil(extract(epoch from (r.decided_at + interval '24 hours' - now())) / 3600))::int;
    end if;
    -- Taking it back and applying again in a loop pinged the mods each time.
    if r.status = 'withdrawn' and r.decided_at > now() - interval '1 minute' then raise exception 'Give it a minute before applying again'; end if;
    update public.server_join_requests
      set status = 'pending', message = msg, answers = ans, invite_code = i.code, note = '', decided_by = null, decided_at = null,
          seen_at = null, created_at = now()
      where id = r.id;
  else
    if (select count(*) from public.server_join_requests where user_id = auth.uid() and status = 'pending') >= 20 then
      raise exception 'You have too many applications waiting';
    end if;
    insert into public.server_join_requests (server_id, user_id, invite_code, message, answers)
      values (i.server_id, auth.uid(), i.code, msg, ans);
  end if;
  -- Mods' open tabs refresh their list.
  perform public.bc_notice('server:' || i.server_id, 'join_request', jsonb_build_object('server_id', i.server_id, 'status', 'pending'));
  return jsonb_build_object('joined', false, 'server_id', i.server_id, 'status', 'pending');
end $$;
revoke execute on function public.apply_to_server(text, text, text[]) from public, anon;
grant execute on function public.apply_to_server(text, text, text[]) to authenticated;

-- Take back a waiting application (the applicant). The row stays (seen, so it is never a notice) to slow a reapply loop.
create or replace function public.withdraw_join_request(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.server_join_requests set status = 'withdrawn', decided_at = now(), seen_at = now()
    where server_id = sid and user_id = auth.uid() and status = 'pending';
end $$;
revoke execute on function public.withdraw_join_request(uuid) from public, anon;
grant execute on function public.withdraw_join_request(uuid) to authenticated;

-- The waiting list for the mods (oldest first).
create or replace function public.join_requests(sid uuid)
returns table (id uuid, user_id uuid, message text, answers text[], created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.can_review_joins(sid) then raise exception 'You need Kick Members for that'; end if;
  return query select r.id, r.user_id, r.message, r.answers, r.created_at
    from public.server_join_requests r where r.server_id = sid and r.status = 'pending' order by r.created_at limit 200;
end $$;
revoke execute on function public.join_requests(uuid) from public, anon;
grant execute on function public.join_requests(uuid) to authenticated;

-- Accept or decline. Accepting runs the same refusals as join_server, then inserts the member (every server_members
-- trigger runs: first join, member count, bots' welcome, Plus role) and counts the invite use. The applicant gets a
-- live notice and sees the decision on the next start until they dismiss it.
create or replace function public.decide_join_request(rid uuid, p_accept boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare r public.server_join_requests; n text; sname text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  -- Locked: two mods deciding at once would both pass the pending check and the second overwrite the first.
  select * into r from public.server_join_requests where id = rid for update;
  if r.id is null then raise exception 'That application is gone'; end if;
  if not public.can_review_joins(r.server_id) then raise exception 'You need Kick Members for that'; end if;
  if r.status <> 'pending' then raise exception 'Someone already decided that one'; end if;
  n := case when p_accept then '' else left(btrim(coalesce(p_note, '')), 300) end;
  if p_accept then
    -- members_not_banned checks auth.uid() (the mod here), so check the applicant ourselves.
    if public.is_site_banned(r.user_id) then raise exception 'That account is banned from Yapper'; end if;
    if public.server_locked(r.server_id) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
    if exists (select 1 from public.server_bans where server_id = r.server_id and user_id = r.user_id) then
      raise exception 'They''re banned from this server. Unban them first.';
    end if;
    if (select count(*) from public.server_members where user_id = r.user_id) >= 100 then
      raise exception 'They''re in too many servers';
    end if;
    perform set_config('yapper.join_ok', r.server_id::text, true);
    insert into public.server_members (server_id, user_id) values (r.server_id, r.user_id) on conflict do nothing;
    if found and r.invite_code is not null then
      update public.invites set uses = uses + 1 where lower(code) = lower(r.invite_code);
    end if;
  end if;
  update public.server_join_requests
    set status = case when p_accept then 'accepted' else 'declined' end, note = n, decided_by = auth.uid(), decided_at = now(), seen_at = null
    where id = rid;
  select name into sname from public.servers where id = r.server_id;
  perform public.bc_notice('user:' || r.user_id, 'join_request', jsonb_build_object(
    'id', rid, 'server_id', r.server_id, 'name', sname, 'status', case when p_accept then 'accepted' else 'declined' end, 'note', n));
  perform public.bc_notice('server:' || r.server_id, 'join_request', jsonb_build_object('server_id', r.server_id, 'status', 'decided'));
end $$;
revoke execute on function public.decide_join_request(uuid, boolean, text) from public, anon;
grant execute on function public.decide_join_request(uuid, boolean, text) to authenticated;

-- Decisions I haven't seen yet (app start). One partial-index read per start.
create or replace function public.my_join_decisions()
returns table (id uuid, server_id uuid, name text, status text, note text, decided_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query select r.id, r.server_id, s.name, r.status, r.note, r.decided_at
    from public.server_join_requests r join public.servers s on s.id = r.server_id
    where r.user_id = auth.uid() and r.status in ('accepted', 'declined') and r.seen_at is null
    order by r.decided_at limit 20;
end $$;
revoke execute on function public.my_join_decisions() from public, anon;
grant execute on function public.my_join_decisions() to authenticated;

create or replace function public.ack_join_decision(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.server_join_requests set seen_at = now() where id = rid and user_id = auth.uid() and seen_at is null;
end $$;
revoke execute on function public.ack_join_decision(uuid) from public, anon;
grant execute on function public.ack_join_decision(uuid) to authenticated;

-- A link that skips the form (one per manager per server, made on demand). Kick Members or Manage Server.
create or replace function public.skip_apply_invite(sid uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.can_review_joins(sid) then raise exception 'You need Kick Members for that'; end if;
  if not public.feature_on('join_applications', sid) then raise exception 'Join applications aren''t available here yet'; end if;
  if exists (select 1 from public.server_bans where server_id = sid and user_id = auth.uid()) then raise exception 'You can''t do that'; end if;
  select code into c from public.invites where server_id = sid and created_by = auth.uid() and skip_apply order by created_at desc limit 1;
  if c is not null then return c; end if;
  for i in 1..5 loop
    -- 295's trigger replaces this code on the live database; here it only fills the column.
    c := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    begin
      insert into public.invites (code, server_id, created_by, skip_apply) values (c, sid, auth.uid(), true) returning code into c;
      return c;
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'Could not make a link, try again';
end $$;
revoke execute on function public.skip_apply_invite(uuid) from public, anon;
grant execute on function public.skip_apply_invite(uuid) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('join_applications', 'Join applications',
        'Servers can ask people to apply before they get in: an invite link shows a short form, mods accept or decline from Server settings, Members.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
