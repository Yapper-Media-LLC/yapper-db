// 546: forwards stop counting as mentions in my_mentions and unread_counts_for.
// The live bodies depend on a lot of later helpers, so the stand-ins here are cut down but carry the exact lines 546
// patches (copied from the live text), and the checks run them on real rows.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '546_forwards_not_mentions.sql'), 'utf8');

const STANDINS = String.raw`
create or replace function public.my_mentions(lim integer default 40)
 returns setof public.messages language sql stable security definer set search_path to 'public' as $function$
  select x.* from public.messages x
  where true
        and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
        and x.author_id <> (select auth.uid())
        and x.content like '%<@' || (select auth.uid())::text || '>%'
  order by x.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$function$;
create or replace function public.unread_counts_for(vis public.channels[])
 returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
 language plpgsql stable security definer set search_path to 'public' as $function$
#variable_conflict use_column
begin
  return query
  select c.id,
    (select count(*)::int from public.messages m where m.channel_id = c.id and m.author_id <> auth.uid()),
    false,
    (select (count(*) filter (where f.content like '%<@' || auth.uid()::text || '>%'
                              or (f.reply_to_id is not null
                                  and exists (select 1 from public.messages pm where pm.id = f.reply_to_id and pm.author_id = (select auth.uid())))))::int as mentions
     from (select m.content, m.reply_to_id from public.messages m where m.channel_id = c.id and m.author_id <> auth.uid()) f)
  from unnest(vis) c;
end
$function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`546 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('546 runs', () => h.db.exec(MIG));
  await h.ok('546 re-runs cleanly', () => h.db.exec(MIG));
  const defs = await h.one(`select pg_get_functiondef('public.my_mentions(integer)'::regprocedure) a,
    pg_get_functiondef('public.unread_counts_for(public.channels[])'::regprocedure) b`);
  h.eq('my_mentions patched once', defs.a.split('chr(8618)').length - 1, 1);
  h.eq('unread_counts_for patched once', defs.b.split('chr(8618)').length - 1, 1);

  const me = await h.signup('me@x.com', 'me');
  const them = await h.signup('them@x.com', 'them');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [them])).id;
  for (const u of [me, them]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  const C = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [S])).id;
  // Fixture rows only: the per-account message rate trigger would refuse five in a row.
  await h.q(`set session_replication_role = replica`);
  const say = async (content, reply = null) => (await h.one(
    `insert into messages (channel_id, author_id, content, reply_to_id) values ($1, $2, $3, $4) returning id`, [C, them, content, reply])).id;
  const mine = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hello') returning id`, [C, me])).id;
  await say(`hey <@${me}>`);
  await say(`↪ Forwarded\nhey <@${me}> from somewhere else`);
  await say(`↪ Forwarded\nnot a ping`);
  await say('a reply', mine);
  await say(`I typed ↪ Forwarded by hand <@${me}>`); // the mark not at the start: still a ping

  await h.q(`set session_replication_role = origin`);

  await h.as(me);
  const inbox = (await h.q(`select content from my_mentions(40)`)).map((r) => r.content);
  h.eq('inbox keeps the real ping', inbox.includes(`hey <@${me}>`), true);
  h.eq('inbox drops the forwarded ping', inbox.some((c) => c.startsWith('↪ Forwarded\n')), false);
  h.eq('inbox keeps a mark typed mid-text', inbox.some((c) => c.startsWith('I typed')), true);
  const row = await h.one(`select u.unread, u.mentions from unread_counts_for(array(select c from channels c where c.id = $1)) u`, [C]);
  h.eq('unread counts every message', row.unread, 5);
  h.eq('badge counts ping, reply and mid-text mark, not the forwards', row.mentions, 3);
}
