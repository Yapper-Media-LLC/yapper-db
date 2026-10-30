-- 663: Server reports (flag server_reports, test: Antic + the HQ test server). Anyone but the owner can report a whole
-- server to Yapin' staff from the server menus, invite cards, Discover and the tag card. Antic: "Report a server straight
-- to the Yapin' team" (roadmap).
-- Stored in reports, as a row with reported_server_id set and no target, message or server_id:
--   * server_id stays null on purpose: "server mods read their reports" (027), resolve_report and Server Settings > Reports
--     key on server_id, so the reported server's own owner and mods never see who reported them.
--   * target_id stays null, so a server report never counts toward the owner's triage ban (276) or auto timeout/ban (115).
--   * reported_server_name keeps the name at report time, for when the server is gone (the FK sets the id null).
-- Staff see these in the Mod Center queue as one case per server (claim_reports below groups them the same way) and act
-- with the tools that already exist (staff_warn_server_owner, staff_server_limit, staff_takedown_server), each of which
-- writes mod_log; staff_close_server_reports closes the case and logs that too. Re-runnable.
set lock_timeout = '4s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('server_reports', 'Server reports', 'Report a whole server to Yapin'' staff (server menus, invites, Discover). Staff handle them in the Mod Center queue: warn the owner, hide from Discover, shut down.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.reports add column if not exists reported_server_id uuid references public.servers (id) on delete set null;
alter table public.reports add column if not exists reported_server_name text;
-- Covers the FK (server deletes), the per-server case lookups and the "already reported this server today" check.
-- Partial: only server reports have it. reports had ~9k rows on Oct 28, so a plain create index is milliseconds.
create index if not exists reports_reported_server_idx on public.reports (reported_server_id, created_at desc)
  where reported_server_id is not null;

-- ---------- report a server ----------
-- Refused: logged out or 20 reports in the last hour (report_guard), flag off, own server, site-banned, account younger
-- than a day, this server already reported by me in the last 24 hours, or 5 server reports by me in the last 24 hours.
create or replace function public.report_server(sid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); own uuid; nm text; born timestamptz; d text; rid uuid;
begin
  perform public.report_guard(uid);
  if not public.feature_on('server_reports', sid) then raise exception 'Not available yet'; end if;
  select owner_id, name into own, nm from public.servers where id = sid;
  if nm is null then raise exception 'Server not found'; end if;
  if own = uid then raise exception 'You can''t report your own server'; end if;
  if public.is_site_banned(uid) then raise exception 'You can''t send reports right now'; end if;
  select created_at into born from public.profiles where id = uid;
  if born is null or born > now() - interval '1 day' then
    raise exception 'Your account is too new to report servers. Try again tomorrow.';
  end if;
  if why is null or why not in ('harassment', 'hate', 'sexual', 'minor_safety', 'violence', 'spam', 'self_harm', 'illegal', 'other') then
    raise exception 'Pick what''s wrong';
  end if;
  -- Two quick clicks from the same person: the second waits here and then sees the first report.
  perform pg_advisory_xact_lock(hashtext('report_server:' || uid::text));
  if exists (select 1 from public.reports where reporter_id = uid and reported_server_id = sid and created_at > now() - interval '24 hours') then
    raise exception 'You already reported this server today. Staff will take a look.';
  end if;
  if (select count(*) from public.reports where reporter_id = uid and reported_server_id is not null and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'That''s a lot of server reports today. Try again tomorrow.';
  end if;
  -- voice_report_log (291) picks up rows whose details start with [voice]; a server report never should.
  d := left(regexp_replace(btrim(coalesce(more, '')), '^(\s*\[voice\]\s*)+', '', 'i'), 1000);
  insert into public.reports (reporter_id, reason, details, reported_server_id, reported_server_name)
  values (uid, why, d, sid, left(nm, 100))
  returning id into rid;
  return rid;
end $$;

-- ---------- staff: what the Mod Center card shows ----------
-- The server, its owner, whether it is listed in Discover / hidden / shut down, other open reports from inside it,
-- earlier server reports, and the last few server watch hits (auto-mod words, kept 3 days). Null when the server is gone.
-- Mods only for servers that were reported, and without the raw hit samples (admins only, like server_watch_hits in 215).
create or replace function public.staff_server_report_info(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare s record; res jsonb; adm boolean;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('server_reports') then raise exception 'Not available yet'; end if;
  adm := public.is_site_admin();
  if not adm and not exists (select 1 from public.reports where reported_server_id = sid) then
    raise exception 'That server wasn''t reported';
  end if;
  select id, name, icon_path, owner_id, member_count, created_at, discoverable, name_ok, locked_until, staff_hidden_at,
         shut_down_at, shut_down_reason, tag
    into s from public.servers where id = sid;
  if s.id is null then return null; end if;
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'icon_path', s.icon_path, 'tag', s.tag, 'member_count', s.member_count, 'created_at', s.created_at,
    'discoverable', s.discoverable,
    'listed', coalesce(s.discoverable and s.name_ok and (s.locked_until is null or s.locked_until < now()), false),
    'hidden_at', s.staff_hidden_at, 'shut_down_at', s.shut_down_at, 'shut_down_reason', s.shut_down_reason,
    'owner', (select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name, 'created_at', p.created_at,
                                        'banned', public.is_site_banned(p.id), 'staff', public.is_staff_user(p.id))
                from public.profiles p where p.id = s.owner_id),
    -- Message, voice and user reports filed from inside the server that are still open (reports_server_idx).
    'open_inside', (select count(*) from public.reports r where r.server_id = sid and r.status = 'open'),
    'recent_inside', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select r.id, r.reason, r.target_id, r.created_at, (select username from public.profiles where id = r.target_id) as target_name
          from public.reports r where r.server_id = sid and r.status = 'open' order by r.created_at desc limit 5) x), '[]'::jsonb),
    -- Earlier server reports about it that staff already handled, and how many of those led to action.
    'past_reports', (select count(*) from public.reports r where r.reported_server_id = sid and r.status <> 'open'),
    'past_actioned', (select count(*) from public.reports r where r.reported_server_id = sid and r.status = 'actioned'),
    'watch', (select jsonb_build_object('score', w.score, 'status', w.status) from public.server_watch w where w.server_id = sid),
    'hits', coalesce((select jsonb_agg(x order by x.at desc) from (
        select h.src, h.kind, h.term, case when adm then left(h.sample, 140) end as sample, h.at
          from public.server_watch_hits h where h.server_id = sid order by h.at desc limit 5) x), '[]'::jsonb)
  ) into res;
  return res;
end $$;

-- ---------- staff: close a server's open reports ----------
-- 'dismissed' (nothing wrong) or 'actioned' (handled, usually right after warn / hide / shut down). Respects report
-- claims: someone else's live claim refuses mods (admins pass). Mods can't close reports about their own or another
-- staff member's server (like mod_guard on the other server tools). Logged in mod_log against the owner. Returns rows closed.
create or replace function public.staff_close_server_reports(sid uuid, new_status text, why text default '')
returns int
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); own uuid; nm text; holder uuid; n int; r text := left(btrim(coalesce(why, '')), 300);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('server_reports') then raise exception 'Not available yet'; end if;
  if new_status is null or new_status not in ('dismissed', 'actioned') then raise exception 'Bad status'; end if;
  select owner_id, name into own, nm from public.servers where id = sid;
  if not public.is_site_admin() and own is not null and (own = uid or public.is_staff_user(own)) then
    raise exception 'That server belongs to staff. Ask an admin.';
  end if;
  perform 1 from public.reports where reported_server_id = sid and status = 'open' for update;
  select claimed_by into holder from public.reports
   where reported_server_id = sid and status = 'open'
     and claimed_by is not null and claimed_by <> uid and claimed_at > now() - public.report_claim_window()
   order by claimed_at desc limit 1;
  if holder is not null and not public.is_site_admin() then
    raise exception 'Claimed by %. You can take over after 30 minutes without action.',
      coalesce((select username from public.profiles where id = holder), 'someone');
  end if;
  update public.reports set status = new_status, resolved_by = uid, resolved_at = now()
   where reported_server_id = sid and status = 'open';
  get diagnostics n = row_count;
  if n = 0 then return 0; end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (uid, case when new_status = 'dismissed' then 'server_report_dismissed' else 'server_report_closed' end, own,
          left(coalesce(nullif(r, ''), n || ' report' || case when n = 1 then '' else 's' end) || ' [' || coalesce(nm, 'deleted server') || ']', 500));
  return n;
end $$;

revoke all on function public.report_server(uuid, text, text) from public, anon;
revoke all on function public.staff_server_report_info(uuid) from public, anon;
revoke all on function public.staff_close_server_reports(uuid, text, text) from public, anon;
grant execute on function public.report_server(uuid, text, text) to authenticated;
grant execute on function public.staff_server_report_info(uuid) to authenticated;
grant execute on function public.staff_close_server_reports(uuid, text, text) to authenticated;

-- ---------- report claims (643): all reports about one server are one case ----------
-- Same as 643, except the case key: the reported person, else the reported server, else the report itself. Without this
-- a server with 3 open reports would use up 3 of a mod's 5 claims.
create or replace function public.claim_reports(rids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); adm boolean; holder uuid; holder_tgt uuid; held int; n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('report_claims') then raise exception 'Not available'; end if;
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  adm := public.is_site_admin();
  -- Two mods pressing Claim at the same moment: the second waits for the first and then sees their claim.
  perform 1 from public.reports where id = any(rids) and status = 'open' for update;
  select claimed_by, target_id into holder, holder_tgt from public.reports
   where id = any(rids) and status = 'open'
     and claimed_by is not null and claimed_by <> uid and claimed_at > now() - public.report_claim_window()
   order by claimed_at desc limit 1;
  if holder is not null and not adm then
    raise exception 'Claimed by %. You can take over after 30 minutes without action.',
      coalesce((select username from public.profiles where id = holder), 'someone');
  end if;
  -- At most 5 cases at once (a case = the reported person, else the reported server, else the report itself).
  -- Reports of a case I already hold don't count again, so new reports on it can be claimed.
  select count(distinct coalesce(target_id::text, 's:' || reported_server_id::text, id::text)) into held from public.reports
   where claimed_by = uid and status = 'open' and claimed_at > now() - public.report_claim_window()
     and coalesce(target_id::text, 's:' || reported_server_id::text, id::text) not in (
       select coalesce(r.target_id::text, 's:' || r.reported_server_id::text, r.id::text) from public.reports r where r.id = any(rids));
  if held >= 5 then raise exception 'You already hold 5 claims. Finish or release one first.'; end if;
  update public.reports set claimed_by = uid, claimed_at = now() where id = any(rids) and status = 'open';
  get diagnostics n = row_count;
  if holder is not null then
    insert into public.mod_log (actor, action, target_id, reason)
    values (uid, 'report_claim_taken', holder_tgt, 'Took over the case from ' || coalesce((select username from public.profiles where id = holder), 'someone'));
  end if;
  return n;
end $$;

reset lock_timeout;
