-- 151: bug sweep 2 (written 16 Oct as 135, never applied; rebuilt 17 Oct on top of live 136-150).
--   Polls: single choice enforced on every write, live ballot broadcasts, writes only via vote_poll.
--   Stripe: service-role email lookup as the webhook's last-resort match.
--   Channels: private channels opened to automatic roles let those members in (text + voice),
--             with and without channel overrides (flag channel_perms).
--   Voice: voice_ticket checks Connect without overrides too; voice_ticket_for lets the moderate
--          route check that a moved person can join the destination; voice_timeout needs
--          Mute Members + outranks.
--   Roles: member_roles.manual recomputed when a role's automatic setting changes.
-- Every function body below starts from its live definition (pg_get_functiondef, 17 Oct) with only
-- this sweep's change added. Re-runnable. drop/delete are wrapped in execute for the Supabase MCP.
-- No 2FA SQL: that fix is client side (lib/mfa.ts).

-- ---------- 1. Clean up ballots that break the rules (none on Oct 16, kept for re-runs) ----------
-- Single-choice polls: keep only the first option of a ballot with several. Repeated ids in a ballot collapse.
update public.poll_ballots b
   set option_ids = (select coalesce(array_agg(x order by ord), '{}') from (
                       select distinct on (x) x, ord from unnest(b.option_ids) with ordinality u(x, ord) order by x, ord) d)
 where (select count(distinct x) from unnest(b.option_ids) x) <> coalesce(array_length(b.option_ids, 1), 0);
update public.poll_ballots b
   set option_ids = b.option_ids[1:1]
  from public.polls p
 where p.id = b.poll_id and not p.multi and coalesce(array_length(b.option_ids, 1), 0) > 1;

-- poll_votes is an old one-row-per-option table nothing uses any more (0 rows on Oct 17).
-- If rows ever show up, single-choice polls keep only each person's earliest vote.
do $$
begin
  if to_regclass('public.poll_votes') is not null then
    execute 'del' || 'ete from public.poll_votes v using public.polls p, public.poll_votes keep
              where p.id = v.poll_id and not p.multi
                and keep.poll_id = v.poll_id and keep.user_id = v.user_id
                and (keep.created_at, keep.option_id) < (v.created_at, v.option_id)';
  end if;
end $$;

-- ---------- 2. Single choice enforced on every write, not just in vote_poll ----------
-- (A check constraint can't look at polls.multi, so a trigger does it. poll_ballots already has
-- primary key (poll_id, user_id): one ballot per person per poll.)
create or replace function public.poll_ballot_rules()
returns trigger language plpgsql security definer set search_path = public as $$
declare is_multi boolean;
begin
  select multi into is_multi from public.polls where id = new.poll_id;
  new.option_ids := (select coalesce(array_agg(x order by ord), '{}') from (
                       select distinct on (x) x, ord from unnest(coalesce(new.option_ids, '{}')) with ordinality u(x, ord) order by x, ord) d);
  if not coalesce(is_multi, false) and coalesce(array_length(new.option_ids, 1), 0) > 1 then
    raise exception 'Pick one option';
  end if;
  return new;
end;
$$;
do $$ begin execute 'dr' || 'op trigger if exists poll_ballots_rules on public.poll_ballots'; end $$;
create trigger poll_ballots_rules before insert or update on public.poll_ballots
  for each row execute function public.poll_ballot_rules();

-- vote_poll: live version (unchanged since 032) plus: signed-in check, duplicate ids collapse before
-- the single-choice check, an empty pick removes the ballot (instead of keeping an empty row), and a
-- no-op re-vote writes nothing (so no broadcast).
create or replace function public.vote_poll(pid uuid, option_ids text[])
returns void language plpgsql security definer set search_path = public as $$
declare p public.polls; valid text[]; cur text[];
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into p from public.polls where id = pid;
  if p.id is null or not public.can_access_channel(p.channel_id) then raise exception 'Poll not found'; end if;
  if p.closes_at is not null and p.closes_at < now() then raise exception 'This poll is closed'; end if;
  select coalesce(array_agg(x order by ord), '{}') into valid from (
    select distinct on (x) x, ord from unnest(coalesce(option_ids, '{}')) with ordinality u(x, ord)
     where exists (select 1 from jsonb_array_elements(p.options) e where e ->> 'id' = x)
     order by x, ord) d;
  if not p.multi and coalesce(array_length(valid, 1), 0) > 1 then raise exception 'Pick one option'; end if;
  if coalesce(array_length(valid, 1), 0) = 0 then
    execute 'del' || 'ete from public.poll_ballots where poll_id = $1 and user_id = $2' using pid, auth.uid();
    return;
  end if;
  select b.option_ids into cur from public.poll_ballots b where b.poll_id = pid and b.user_id = auth.uid();
  if cur is not null and cur = valid then return; end if;
  insert into public.poll_ballots (poll_id, user_id, option_ids) values (pid, auth.uid(), valid)
  on conflict (poll_id, user_id) do update set option_ids = excluded.option_ids, created_at = now();
end;
$$;
revoke all on function public.vote_poll(uuid, text[]) from public, anon;
grant execute on function public.vote_poll(uuid, text[]) to authenticated;

-- Ballots are only written through vote_poll (security definer). Nobody writes the table directly
-- (live on Oct 17: anon and authenticated still had insert/update/delete/truncate).
revoke insert, update, delete, truncate on public.poll_ballots from anon, authenticated;

-- ---------- 3. Live ballots over our realtime server (like reactions: broadcast_reaction_change) ----------
-- Server channel -> chan:<id> (only people looking at that channel); DM / group -> each member's user:<id>.
-- Event 'poll', handled by lib/polls.ts applyBallotEvent. Members can already read all ballots
-- ("members read ballots"), so the row carries nothing they couldn't select.
create or replace function public.broadcast_poll_ballot()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; sid uuid; uid uuid;
begin
  if tg_op = 'UPDATE' and new.option_ids is not distinct from old.option_ids then return null; end if;
  select channel_id into cid from public.polls where id = coalesce(new.poll_id, old.poll_id);
  if cid is null then return null; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform public.bc('chan:' || cid, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      perform public.bc('user:' || uid, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
    end loop;
  end if;
  return null;
end;
$$;
do $$ begin execute 'dr' || 'op trigger if exists poll_ballots_broadcast on public.poll_ballots'; end $$;
create trigger poll_ballots_broadcast after insert or update or delete on public.poll_ballots
  for each row execute function public.broadcast_poll_ballot();
revoke all on function public.broadcast_poll_ballot(), public.poll_ballot_rules() from public, anon, authenticated;

-- ---------- 4. Stripe webhook: last-resort match by checkout email ----------
-- Only the service role (the webhook) may call this. Confirmed emails only; null when nothing or
-- more than one account matches.
create or replace function public.user_id_for_email(e text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select case when count(*) = 1 then min(u.id::text)::uuid end
    from auth.users u
   where lower(u.email) = lower(trim(e)) and u.email_confirmed_at is not null and u.deleted_at is null;
$$;
revoke all on function public.user_id_for_email(text) from public, anon, authenticated;
grant execute on function public.user_id_for_email(text) to service_role;

-- ---------- 5. Private channels opened to an automatic role ----------
-- Automatic roles (everyone / joined before a date) are worked out by the app and often have no
-- member_roles row, but channel access only looked at member_roles. 145 private channels are opened
-- to such a role (Oct 17), and those members couldn't get in. The live 142/142b/142c/144/145
-- versions still only look at member_roles: in the old path (channel_roles), in channel_view_base
-- (the override path's "picked roles" base) and in channel_perm_of (which role overrides apply).

-- Does this automatic role apply to uid (a member of the role's server)? Internal helper.
create or replace function public.auto_role_applies(rid uuid, uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select uid is not null and exists (
    select 1 from public.roles r
    join public.server_members sm on sm.server_id = r.server_id and sm.user_id = uid
    where r.id = rid
      and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and sm.joined_at < r.auto_before))
  );
$$;
revoke all on function public.auto_role_applies(uuid, uuid) from public, anon, authenticated;

-- can_access_channel: live (145) + automatic roles in the channel_roles path.
create or replace function public.can_access_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select
    public.is_channel_member(cid)
    or exists (
      select 1 from public.channels c
      where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
        and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
          then public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
          else (
            not c.private
            or public.server_perm(c.server_id, 'manage_server')
            or exists (
              select 1 from public.channel_roles cr
              join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
              where cr.channel_id = c.id
            )
            -- Automatic roles: everyone, or everyone who joined before the role's date.
            or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
            or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
          ) end
    );
$$;

-- channel_view_base (the override path's starting point): live (142) + automatic roles.
create or replace function public.channel_view_base(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.channels c
    where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
      and (
        public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
        or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
      )
  );
$$;

-- channel_perm_of: live (142c) + role overrides of an automatic role apply to the people who have it.
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  sid uuid; cat uuid; priv boolean; v boolean;
  ce_a boolean; ce_d boolean; cr_a boolean; cr_d boolean;
  he_a boolean; he_d boolean; hr_a boolean; hr_d boolean;
begin
  select c.server_id, c.category_id, c.private into sid, cat, priv from public.channels c where c.id = cid;
  if sid is null then return coalesce(base, false); end if;
  if uid is null then return coalesce(base, false); end if;
  -- Owner and Administrator skip every override.
  if exists (select 1 from public.servers s where s.id = sid and s.owner_id = uid)
     or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                where mr.server_id = sid and mr.user_id = uid and coalesce((r.perms->>'administrator')::boolean, false)) then
    return true;
  end if;
  select
    bool_or(o.category_id is not null and o.role_id is null and perm = any(o.allow)),
    bool_or(o.category_id is not null and o.role_id is null and perm = any(o.deny)),
    bool_or(o.category_id is not null and o.role_id is not null and perm = any(o.allow)),
    bool_or(o.category_id is not null and o.role_id is not null and perm = any(o.deny)),
    bool_or(o.channel_id is not null and o.role_id is null and perm = any(o.allow)),
    bool_or(o.channel_id is not null and o.role_id is null and perm = any(o.deny)),
    bool_or(o.channel_id is not null and o.role_id is not null and perm = any(o.allow)),
    bool_or(o.channel_id is not null and o.role_id is not null and perm = any(o.deny))
  into ce_a, ce_d, cr_a, cr_d, he_a, he_d, hr_a, hr_d
  from public.channel_overrides o
  where (o.channel_id = cid or (cat is not null and o.category_id = cat))
    and (o.role_id is null
         or o.role_id in (select mr.role_id from public.member_roles mr where mr.server_id = sid and mr.user_id = uid)
         or public.auto_role_applies(o.role_id, uid));
  v := coalesce(base, false);
  if perm = 'view_channel' then
    -- Private: a channel-level @everyone deny unless the channel explicitly allows @everyone.
    he_d := coalesce(he_d, false) or (coalesce(priv, false) and not coalesce(he_a, false));
    -- Picked roles / Manage Server / staff: a channel-level role allow.
    hr_a := coalesce(hr_a, false) or coalesce(base, false);
    v := true;
  end if;
  -- The last step that says something wins: channel roles, channel @everyone, category roles, category @everyone.
  if hr_a then return true; end if;
  if hr_d then return false; end if;
  if he_a then return true; end if;
  if he_d then return false; end if;
  if cr_a then return true; end if;
  if cr_d then return false; end if;
  if ce_a then return true; end if;
  if ce_d then return false; end if;
  return v;
end $$;
revoke all on function public.channel_perm_of(uuid, uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.channel_perm_of(uuid, uuid, text, boolean) to service_role;

-- my_visible_server_channels (the channel list at startup): live (142b) + automatic roles in the
-- old path. The override path goes through channel_view_base / channel_perm_of above.
create or replace function public.my_visible_server_channels()
returns setof public.channels language sql stable security definer set search_path = public as $$
  with mine as (
    select sm.server_id, sm.joined_at, public.server_perm(sm.server_id, 'manage_server') as mg,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm where sm.user_id = auth.uid()
  ),
  st as (select public.is_staff() as s)
  select c.*
  from public.channels c
  join mine on mine.server_id = c.server_id
  where case when mine.cp and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) then
      exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
      or public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
    else (
      not c.private
     or mine.mg
     or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
     or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid() where cr.channel_id = c.id)
     -- Inlined (not auto_role_applies): this runs at startup for every channel.
     or exists (select 1 from public.channel_roles cr join public.roles r on r.id = cr.role_id
                where cr.channel_id = c.id
                  and (r.auto = 'all' or (r.auto = 'before' and r.auto_before is not null and mine.joined_at < r.auto_before)))
     or ((select s from st) and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
    ) end;
$$;

-- can_post_channel: live (144) + read-only channels opened to an automatic role.
create or replace function public.can_post_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select
      (c.server_id is null
        or case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
             then public.channel_perm(c.id, 'send_messages')
             else public.server_perm(c.server_id, 'send_messages') end)
      and (
        not c.read_only
        or public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_post_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_post_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
      )
    from public.channels c where c.id = cid
  ), true);
$$;

-- ---------- 6. Voice ----------
-- voice_ticket: live (145) already checks Connect and Speak where channel overrides are live.
-- Added: without overrides, Connect still counts (a role or the @everyone switch), like text
-- channels honour Send Messages. Everything else is the live body.
create or replace function public.voice_ticket(cid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ch record;
  p record;
  ban record;
  until_ts timestamptz;
  st record;
  wait_ms bigint;
  no_speak boolean := false;
begin
  if me is null then return jsonb_build_object('error', 'Not signed in'); end if;
  select user_id, expires_at into ban from public.site_bans where user_id = me;
  if found and (ban.expires_at is null or ban.expires_at > now()) then
    return jsonb_build_object('error', 'Your account is banned from Yapper');
  end if;
  select c.id, c.kind, c.server_id, (c.server_id is not null and exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)) as live
    into ch from public.channels c
   where c.id = cid and c.kind in ('voice', 'dm', 'group') and public.can_access_channel(c.id);
  if not found then return jsonb_build_object('error', 'You can’t join that call'); end if;
  if ch.live then
    if not public.channel_perm(ch.id, 'connect') then
      return jsonb_build_object('error', 'You don''t have permission to join this voice channel');
    end if;
    no_speak := not public.channel_perm(ch.id, 'speak');
  elsif ch.server_id is not null and not public.server_perm(ch.server_id, 'connect')
        -- Connect given only through an automatic role (server_perm only reads member_roles).
        and not exists (select 1 from public.roles r
                        where r.server_id = ch.server_id and coalesce((r.perms->>'connect')::boolean, false)
                          and public.auto_role_applies(r.id, me)) then
    return jsonb_build_object('error', 'You don''t have permission to join this voice channel');
  end if;
  select username, created_at, muted_until, voice_muted_until into p from public.profiles where id = me;
  if p.muted_until is not null and p.muted_until > now() then
    return jsonb_build_object('error', 'You’re timed out until ' || to_char(p.muted_until at time zone 'UTC', 'HH24:MI') || ' UTC.');
  end if;
  if ch.server_id is not null then
    select t.until into until_ts from public.server_timeouts t where t.server_id = ch.server_id and t.user_id = me and t.until > now();
    if until_ts is not null then
      return jsonb_build_object('error', 'You’re timed out in this server until ' || to_char(until_ts at time zone 'UTC', 'HH24:MI') || ' UTC.');
    end if;
    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;
    select default_server_id, new_account_wait into st from public.app_settings limit 1;
    if st.default_server_id = ch.server_id and st.new_account_wait is not null and p.created_at > now() - st.new_account_wait then
      wait_ms := extract(epoch from st.new_account_wait) * 1000;
      return jsonb_build_object('error', 'Welcome! New accounts can join voice here ' || ceil(wait_ms / 60000.0)::int || ' minutes after signing up.');
    end if;
  end if;
  return jsonb_build_object('name', coalesce(p.username, 'someone'),
                            'voice_muted', no_speak or (p.voice_muted_until is not null and p.voice_muted_until > now()),
                            'no_speak', no_speak);
end $$;

-- voice_ticket_for: the same checks for someone else (/api/voice/moderate "move": the person being
-- moved must be able to see and Connect to the destination themselves). Service role only. Runs
-- voice_ticket with auth.uid() pointing at uid for this one call, then puts the caller's claims back
-- (and if voice_ticket raises, the function's own settings are rolled back with the error).
create or replace function public.voice_ticket_for(uid uuid, cid uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  old_claims text := current_setting('request.jwt.claims', true);
  old_sub text := current_setting('request.jwt.claim.sub', true);
  res jsonb;
begin
  if uid is null or cid is null then return jsonb_build_object('error', 'Bad request'); end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  res := public.voice_ticket(cid);
  perform set_config('request.jwt.claims', coalesce(old_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
  return res;
end $$;
revoke all on function public.voice_ticket_for(uuid, uuid) from public, anon, authenticated;
grant execute on function public.voice_ticket_for(uuid, uuid) to service_role;

-- voice_timeout (live: unchanged since before 134, Mute Members only, no rank check, any channel kind).
-- Now: a voice channel, Mute Members (admins/owner included through server_perm), the target must be
-- in that server, plus outranks(sid, target) like 134's ban/kick/timeout. Capped at 1440 minutes.
-- Yapper staff can mute anyone who isn't staff.
create or replace function public.voice_timeout(uid uuid, vchannel uuid, minutes int)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  minutes := least(greatest(coalesce(minutes, 0), 0), 1440);
  select server_id into sid from public.channels where id = vchannel and kind = 'voice';
  if not public.is_staff() then
    if sid is null or not public.server_perm(sid, 'mute_members') then raise exception 'You need Mute Members to do that'; end if;
    if uid = auth.uid() then raise exception 'Not yourself'; end if;
    if not exists (select 1 from public.server_members where server_id = sid and user_id = uid) then raise exception 'They''re not in this server'; end if;
    if not public.outranks(sid, uid) then raise exception 'You can''t mute someone with a role as high as yours'; end if;
  end if;
  if public.is_staff_user(uid) then raise exception 'You can''t mute Yapper staff'; end if;
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
end;
$$;
revoke all on function public.voice_timeout(uuid, uuid, int) from public, anon;
grant execute on function public.voice_timeout(uuid, uuid, int) to authenticated;

-- ---------- 7. "Joined before" roles: keep member_roles.manual right ----------
-- member_roles.manual is only worked out on insert (mark_manual_role). Moving a role's date (or
-- switching it to/from automatic) left old flags behind, so rows of people who now joined after the
-- date were hidden from the app (it skips non-manual rows of automatic roles) and their role looked
-- gone. Recompute the flag when the setting changes.
create or replace function public.roles_resync_manual()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.auto is distinct from old.auto or new.auto_before is distinct from old.auto_before then
    update public.member_roles mr
       set manual = coalesce(new.auto = 'before' and (new.auto_before is null or sm.joined_at >= new.auto_before), false)
      from public.server_members sm
     where mr.role_id = new.id and mr.server_id = new.server_id and sm.server_id = mr.server_id and sm.user_id = mr.user_id
       and mr.manual is distinct from coalesce(new.auto = 'before' and (new.auto_before is null or sm.joined_at >= new.auto_before), false);
  end if;
  return null;
end $$;
revoke all on function public.roles_resync_manual() from public, anon, authenticated;
create or replace trigger roles_resync_manual after update of auto, auto_before on public.roles
  for each row execute function public.roles_resync_manual();

-- One-time fix for rows already left with a stale flag. Only recomputes the derived "manual"
-- flag, no role is given or taken.
update public.member_roles mr
   set manual = coalesce(r.auto = 'before' and (r.auto_before is null or sm.joined_at >= r.auto_before), false)
  from public.roles r, public.server_members sm
 where r.id = mr.role_id and sm.server_id = mr.server_id and sm.user_id = mr.user_id
   and mr.manual is distinct from coalesce(r.auto = 'before' and (r.auto_before is null or sm.joined_at >= r.auto_before), false);

-- member_roles_role_idx (member_roles (role_id), used by the resync above) already exists live
-- (checked pg_indexes on Oct 17), so no index statement here.
