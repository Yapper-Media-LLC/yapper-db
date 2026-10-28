-- 460: security audit fixes (Oct 24 report, findings S5 and S6). Re-runnable. DDL: apply in quiet hours, before the web
-- deploy that goes with it (lib/server/media.ts writes media_scans.etag; the bot API calls bot_channel_history_ok).
--
-- 1. media_scans.etag: the R2 ETag of the bytes a verdict is about. Verdicts are remembered per path; this ties an "ok"
--    to the content that was judged (lib/server/media.ts scanStored / promoteUpload).
-- 2. Read Message History: channel_history_ok() answered true whenever a server had no channel overrides, so the
--    server-wide setting (everyone_perms.read_history, a role without it) was never enforced, and the messages RLS read
--    policy and search v1 never asked at all. Now: channel_allows(cid, 'read_history') (channel overrides where live,
--    the server-wide answer otherwise), asked by the RLS read policy (own messages always show: insert ... returning
--    needs it), by search_messages v1 and by my_mentions, like the history RPCs (142, 229, 240, 261, 409) already do.
-- 3. bot_channel_history_ok(bid, cid): the same rule for the bot API's message history (app/api/bot/v1, GET messages).

alter table public.media_scans add column if not exists etag text;

-- ---------- 2. Read Message History ----------

create or replace function public.channel_history_ok(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select case when c.server_id is null then true
                               when c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id) then false
                               when c.kind = 'voice' and public.channel_overrides_live(c.id) and not public.channel_perm(c.id, 'connect') then false
                               -- Overrides where they are live, else the server-wide permission (owner / Administrator
                               -- always, a role that grants it, or every member unless everyone_perms says no).
                               else public.channel_allows(c.id, 'read_history') end
                   from public.channels c where c.id = cid), true);
$$;
revoke execute on function public.channel_history_ok(uuid) from public, anon;
grant execute on function public.channel_history_ok(uuid) to authenticated;

-- Direct reads of messages (pins, a jumped-to message, a reply's target): same rule as the history RPCs. Your own
-- messages always show, so insert ... returning and your own edits keep working where history is off. Postgres also
-- applies this policy to UPDATE / DELETE ... RETURNING, so moderators (Manage Messages) keep it too, or they could no
-- longer delete what they see arrive live.
alter policy "read messages in channels you can access" on public.messages
  using (public.can_access_channel(channel_id)
         and (author_id = (select auth.uid()) or public.channel_history_ok(channel_id) or public.channel_allows(channel_id, 'manage_messages')));

-- Search v1 (031): still callable by the app as a fallback; it checked channel access only.
create or replace function public.search_messages(q text, sid uuid default null, cid uuid default null)
returns setof public.messages language sql stable security definer set search_path = public as $$
  select m.* from public.messages m
  join public.channels c on c.id = m.channel_id
  where (cid is null or m.channel_id = cid)
    and (sid is null or c.server_id = sid)
    and public.can_access_channel(m.channel_id)
    and public.channel_history_ok(m.channel_id)
    and (public.feature_on('search', c.server_id) or public.feature_on_for_me('search'))
    and to_tsvector('simple', coalesce(m.content, '')) @@ websearch_to_tsquery('simple', q)
  order by m.created_at desc
  limit 50;
$$;
revoke all on function public.search_messages(text, uuid, uuid) from public, anon;
grant execute on function public.search_messages(text, uuid, uuid) to authenticated;

-- Mentions (378): a channel whose history is off contributes nothing. Patched in place like 144/145 did, so the rest of
-- the live body (which this file doesn't own) stays as it is. Skipped where the function isn't there (test databases);
-- a live body that differs from 378 fails the migration (fix the anchor, don't ship a half-applied rule).
do $$ declare d text; begin
  if to_regprocedure('public.my_mentions(integer)') is null then return; end if;
  d := pg_get_functiondef('public.my_mentions(integer)'::regprocedure);
  if position('channel_history_ok' in d) > 0 then return; end if;
  d := replace(d,
    E'    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())\n',
    E'    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())\n'
    || E'      and public.channel_history_ok(v.id)\n');
  if position('channel_history_ok' in d) = 0 then
    raise exception '460: my_mentions patch did not apply (live body differs from 378)';
  end if;
  execute d;
end $$;

-- ---------- 3. Bots ----------

/** A bot's server-wide permission: server_perm (044) for a bot account (bots are never owners; the legacy manage_server /
 *  manage_messages role columns are not consulted, so use this for ordinary perms like read_history only). */
create or replace function public.bot_server_perm(bid uuid, sid uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select sid is not null and bid is not null and (
    exists (
      select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
      where mr.server_id = sid and mr.user_id = bid
        and (coalesce((r.perms->>'administrator')::boolean, false) or coalesce((r.perms->>perm)::boolean, false))
    )
    or (public.basic_perm(perm)
        and exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = sid)
        and coalesce(((select everyone_perms from public.servers where id = sid)->>perm)::boolean, true))
  );
$$;
revoke all on function public.bot_server_perm(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.bot_server_perm(uuid, uuid, text) to service_role;

/** channel_history_ok for a bot (service role only; the bot API asks before listing a channel's messages). */
create or replace function public.bot_channel_history_ok(bid uuid, cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select case when c.server_id is null then true
                               when c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id) then false
                               when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                                            and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                                    and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
                                 then public.channel_perm_of(bid, c.id, 'read_history', public.bot_server_perm(bid, c.server_id, 'read_history'))
                               else public.bot_server_perm(bid, c.server_id, 'read_history') end
                   from public.channels c where c.id = cid), false);
$$;
revoke all on function public.bot_channel_history_ok(uuid, uuid) from public, anon, authenticated;
grant execute on function public.bot_channel_history_ok(uuid, uuid) to service_role;
