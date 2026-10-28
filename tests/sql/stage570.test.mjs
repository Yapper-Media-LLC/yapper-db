// 570: a message that is only a KLIPY GIF link skips the Embed Links check in message_perm_guard.
// The live guard needs many later helpers, so a cut-down stand-in carries the exact lines 570 patches.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '570_gif_links_allowed.sql'), 'utf8');

const STANDINS = String.raw`
create or replace function public.t570_server_perm(sid uuid, perm text) returns boolean language sql as $$ select false $$;
create or replace function public.message_perm_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare sid uuid; cp boolean := false;
begin
  select c.server_id into sid from public.channels c where c.id = new.channel_id;
  if sid is null then return new; end if;
  if new.content ~* 'https?://'
     and not (case when cp then public.t570_channel_perm(new.channel_id, 'embed_links') else public.t570_server_perm(sid, 'embed_links') end) then
    raise exception 'You can''t post links here';
  end if;
  return new;
end; $function$;
drop trigger if exists t570_guard on public.messages;
create trigger t570_guard before insert on public.messages for each row execute function public.message_perm_guard();
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`570 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  // The stand-in must carry the live anchor text for the patch to find it.
  await h.db.exec(STANDINS.replace(/t570_channel_perm\(new\.channel_id, 'embed_links'\)/, "channel_perm(new.channel_id, 'embed_links')"));
  await h.db.exec(`create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql as $$ select false $$`);
  await h.ok('570 runs', () => h.db.exec(MIG));
  await h.ok('570 re-runs cleanly', () => h.db.exec(MIG));
  const def = (await h.one(`select pg_get_functiondef('public.message_perm_guard()'::regprocedure) f`)).f;
  h.eq('guard patched once', def.split('gif_only_link').length - 1, 1);

  const yes = ['https://klipy.com/gif/abc', '  https://cdn.klipy.com/x/y.gif?sig=1  ', 'https://klipy.com/x\n', 'HTTPS://KLIPY.COM/a'];
  const no = ['https://klipy.com/gif/abc look', 'https://evil.com/klipy.com/x', 'https://klipy.com.evil.com/x', 'https://klipy.com@evil.com/x', 'https://klipy.com/x\nhttps://evil.com', 'http://klipy.com/x', 'hi https://klipy.com/x', ''];
  for (const c of yes) h.eq(`gif_only_link yes: ${c.trim()}`, (await h.one(`select public.gif_only_link($1) v`, [c])).v, true);
  for (const c of no) h.eq(`gif_only_link no: ${c || '(empty)'}`, (await h.one(`select public.gif_only_link($1) v`, [c])).v, false);

  const me = await h.signup('me@x.com', 'me');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [me])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, me]);
  const C = (await h.one(`insert into channels (server_id, name, kind) values ($1, 'general', 'text') returning id`, [S])).id;
  const INS = `insert into messages (channel_id, author_id, content) values ($1, $2, $3)`;
  await h.ok('a GIF link goes through with links off', () => h.q(INS, [C, me, 'https://klipy.com/gif/abc']));
  await h.fails('a plain link is still refused', INS, [C, me, 'https://example.com']);
  await h.fails('a GIF link with text is still refused', INS, [C, me, 'look https://klipy.com/gif/abc']);
}
