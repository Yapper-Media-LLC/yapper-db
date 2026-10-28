// 372: replies to me show in the mentions inbox, taken-down servers give no unread badges (staff still see them),
// and my own server joins / leaves are also sent to my user: topic.
// Starts from stage 24 with stand-ins for the live helpers, plus exact copies of the four live functions 372 patches
// by anchor (so a patch that doesn't fit the live text fails here too).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '372_bug_fixes_1021_c.sql'), 'utf8');

const STANDINS = String.raw`
set check_function_bodies = off;
alter table public.servers add column if not exists shut_down_at timestamptz;
-- Test knob: test.staff = '1' makes is_staff() true.
create or replace function public.is_staff() returns boolean language sql stable as $$ select coalesce(current_setting('test.staff', true), '') = '1' $$;
create or replace function public.my_role_pings() returns table(sid uuid, pats text[]) language sql stable as $$ select null::uuid, null::text[] where false $$;
create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $$
  select c.* from public.channels c join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
$$;
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable as $$ select true $$;
create table public.test_bc (topic text, event text, op text);
grant insert, select on public.test_bc to authenticated, anon;
create or replace function public.bc(topic text, event text, op text, tbl text, sch text, n record, o record) returns void
  language plpgsql security definer set search_path = public as $$ begin insert into public.test_bc values (topic, event, op); end $$;
-- The 024 raid guard is not what is tested here.
alter table public.messages disable trigger messages_raid_guard;

-- Exact live definitions (pg_get_functiondef, Oct 21) that 372 patches by anchor.
CREATE OR REPLACE FUNCTION public.my_mentions(lim integer DEFAULT 40)
 RETURNS SETOF messages
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid()) and not public.is_site_banned((select auth.uid()))
    union all
    select v.id, v.server_id, sm.joined_at
    from public.my_visible_server_channels() v
    join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())
  ),
  ment as (
    select m.*
    from chans
    left join pings p on p.sid = chans.sid
    cross join lateral (
      select x.* from public.messages x
      where x.channel_id = chans.channel_id
        and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
        and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
        and x.author_id <> (select auth.uid())
        and (x.content like '%<@' || (select auth.uid())::text || '>%'
             or x.content ~ '(^|[^\w])@everyone([^\w]|$)'
             or (p.pats is not null and strpos(x.content, '<@&') > 0 and x.content like any (p.pats)))
      order by x.created_at desc
      limit least(greatest(coalesce(lim, 40), 1), 100)
    ) m
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ),
  mine as materialized (
    select array(
      select pm.id from public.messages pm
      where pm.author_id = (select auth.uid()) and pm.created_at > now() - interval '30 days'
      order by pm.created_at desc
      limit 500
    ) as ids
  ),
  rep as (
    select x.*
    from public.messages x
    join chans on chans.channel_id = x.channel_id
    where x.reply_to_id = any ((select ids from mine)::uuid[])
      and x.author_id <> (select auth.uid())
      and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  )
  select m.*
  from (
    select * from ment
    union all
    select * from rep r where not exists (select 1 from ment a where a.id = r.id)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$function$;

CREATE OR REPLACE FUNCTION public.unread_counts_for(vis channels[])
 RETURNS TABLE(channel_id uuid, unread integer, muted boolean, mentions integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return query
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as materialized (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from unnest(vis) c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))
             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, 'connect')))
  )
  select
    mine.channel_id,
    coalesce(x.unread, 0),
    coalesce(r.muted, false),
    coalesce(x.mentions, 0)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
  left join pings p on p.sid = mine.sid
  left join lateral (
    select count(*)::int as unread,
           (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
    from (
      select m.content, m.reply_to_id from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > greatest(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
end
$function$;

CREATE OR REPLACE FUNCTION public.unread_counts_v1()
 RETURNS TABLE(channel_id uuid, unread integer, muted boolean, mentions integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as materialized (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from public.my_visible_server_channels() c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))
             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, 'connect')))
  )
  select
    mine.channel_id,
    coalesce(x.unread, 0),
    coalesce(r.muted, false),
    coalesce(x.mentions, 0)
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
  left join pings p on p.sid = mine.sid
  left join lateral (
    select count(*)::int as unread,
           (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
                              or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
    from (
      select m.content, m.reply_to_id from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > greatest(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) f
  ) x on true;
$function$;

CREATE OR REPLACE FUNCTION public.broadcast_member_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid := coalesce(new.server_id, old.server_id); uid uuid := coalesce(new.user_id, old.user_id); n int;
begin
  select count(*) into n from (select 1 from public.server_members where server_id = sid limit 1001) t;
  if n > 1000 then
    perform public.bc('user:' || uid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    perform public.bc('server:' || sid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
  end if;
  return null;
end;
$function$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  // A live function whose text drifted: the migration stops instead of patching blind.
  const LIVE_BMC = STANDINS.slice(STANDINS.indexOf('CREATE OR REPLACE FUNCTION public.broadcast_member_change()'));
  await h.db.exec(LIVE_BMC.replace(`perform public.bc('server:' || sid`, `perform public.bc('server:'||sid`));
  let stopped = '';
  try { await h.db.exec(MIG); } catch (e) { stopped = e.message; }
  h.eq('a drifted anchor stops the migration', /broadcast_member_change\(\) changed: anchor 1 expected once, found 0/.test(stopped), true);
  await h.db.exec(LIVE_BMC);
  await h.db.exec(MIG);
  await h.ok('372 re-runs cleanly', () => h.db.exec(MIG));
  for (const [fn, mark] of [['unread_counts_for(channels[])', 'down as materialized'],
    ['unread_counts_v1()', 'down as materialized'], ['broadcast_member_change()', '372: the person']]) {
    const d = (await h.one(`select pg_get_functiondef('public.${fn}'::regprocedure) d`)).d;
    h.eq(`${fn} patched once`, d.split(mark).length - 1, 1);
  }
  await h.db.exec(`create or replace trigger server_members_broadcast after insert or update or delete on public.server_members
    for each row execute function public.broadcast_member_change()`);

  const a = await h.signup('owner@test.dev', 'owner');
  const b = await h.signup('member@test.dev', 'member');
  await h.admin();
  const msg = async (ch, who, content, reply = null) =>
    (await h.one(`insert into public.messages (channel_id, author_id, content, reply_to_id) values ($1, $2, $3, $4) returning id`, [ch, who, content, reply])).id;
  const s = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [a])).id;
  await h.q(`delete from public.test_bc`);
  await h.q(`insert into public.server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day'), ($1, $3, now() - interval '1 day') on conflict do nothing`, [s, a, b]);
  await h.q(`update public.server_members set joined_at = now() - interval '1 day' where server_id = $1`, [s]);

  // 3. Joins and leaves: the server topic and the person's own topic.
  const topics = async () => (await h.q(`select topic, op from public.test_bc where event = 'member' order by 1, 2`)).map((r) => `${r.topic.split(':')[0]}:${r.op}`);
  h.eq('a join goes to the server and to the person', (await topics()).filter((t) => t.endsWith('INSERT')).sort(), ['server:INSERT', 'server:INSERT', 'user:INSERT', 'user:INSERT'].sort());
  await h.q(`delete from public.test_bc`);
  await h.q(`update public.server_members set nickname = 'nick' where server_id = $1 and user_id = $2`, [s, b]).catch(() => undefined);
  h.eq('a nickname change stays on the server topic', (await topics()).filter((t) => t.startsWith('user:')), []);

  const ch = (await h.one(`insert into public.channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [s, a])).id;
  const mine = await msg(ch, b, 'hello there');
  await msg(ch, a, 'a reply to you', mine);
  await msg(ch, a, `hi <@${b}>`);
  await msg(ch, a, 'just chatting');
  await msg(ch, a, `both <@${b}>`, mine);
  await msg(ch, a, 'a reply to someone else', (await h.one(`select id from public.messages where content = 'just chatting'`)).id);

  // 1. The inbox lists the reply and the @mention, not the plain message; a ping that is also a reply shows once.
  await h.as(b);
  const inbox = (await h.q(`select content from public.my_mentions(40) order by content`)).map((r) => r.content);
  h.eq('a reply to me shows in my_mentions', inbox.includes('a reply to you'), true);
  h.eq('a ping still shows in my_mentions', inbox.includes(`hi <@${b}>`), true);
  h.eq('replies + pings, a ping-reply once, nothing else', inbox, ['a reply to you', `both <@${b}>`, `hi <@${b}>`]);
  h.eq('newest first', (await h.q(`select content from public.my_mentions(40)`)).map((r) => r.content)[0], `both <@${b}>`);
  h.eq('lim still caps the list', (await h.q(`select 1 from public.my_mentions(1)`)).length, 1);
  const counts = await h.one(`select unread, mentions from public.unread_counts_for(array(select c from public.my_visible_server_channels() c)) where channel_id = $1`, [ch]);
  h.eq('the badge counts the same three pings', [counts.unread, counts.mentions], [5, 3]);
  const v1 = await h.one(`select unread, mentions from public.unread_counts_v1() where channel_id = $1`, [ch]);
  h.eq('unread_counts_v1 agrees', [v1.unread, v1.mentions], [5, 3]);

  // 2. Taken down: no badges for members (mark_read can't clear them), staff still see them.
  await h.admin();
  await h.q(`update public.servers set shut_down_at = now() where id = $1`, [s]);
  await h.as(b);
  h.eq('no badges from a taken-down server', (await h.q(`select 1 from public.unread_counts_for(array(select c from public.my_visible_server_channels() c)) where channel_id = $1`, [ch])).length, 0);
  h.eq('nor from unread_counts_v1', (await h.q(`select 1 from public.unread_counts_v1() where channel_id = $1`, [ch])).length, 0);
  h.eq('nor in the inbox', (await h.q(`select 1 from public.my_mentions(40)`)).length, 0);
  await h.db.query(`select set_config('test.staff', '1', false)`);
  h.eq('staff still see the counts', (await h.q(`select 1 from public.unread_counts_for(array(select c from public.my_visible_server_channels() c)) where channel_id = $1`, [ch])).length, 1);
  await h.db.query(`select set_config('test.staff', '', false)`);

  // 3b. A leave reaches the person too.
  await h.admin();
  await h.q(`delete from public.test_bc`);
  await h.q(`delete from public.server_members where server_id = $1 and user_id = $2`, [s, b]);
  h.eq('a leave goes to the server and to the person', await topics(), ['server:DELETE', 'user:DELETE']);
}
