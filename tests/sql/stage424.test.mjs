// 424: "No GIFs" channel setting. GIF attachments and GIF links are refused in a no_gifs channel for people without
// Manage Messages; pictures and plain text pass; managers and bots pass; off the switch everything passes.
// Base 24 + flags, stand-ins for channel_allows (142) and audit_channels (232), then 424 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
-- Columns the audit trigger (232) lists, from migrations past base 24.
alter table public.channels add column if not exists read_only boolean not null default false;
alter table public.channels add column if not exists slowmode int not null default 0;
alter table public.channels add column if not exists no_images boolean not null default false;
alter table public.channels add column if not exists category_id uuid;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select public.server_perm(c.server_id, perm) from public.channels c where c.id = cid and c.server_id is not null), true);
$$;
alter table public.channels add column if not exists ticket_by uuid;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('424_no_gifs.sql');
  await h.ok('424 applies', () => h.db.exec(MIG));
  await h.ok('424 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('audit_channels diffs no_gifs', (await h.one(`select pg_get_functiondef('public.audit_channels()'::regprocedure) like '%''no_gifs''%' as ok`)).ok, true);

  const owner = await h.signup('o@test.dev', 'owner');
  const member = await h.signup('m@test.dev', 'member');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, owner, member]);
  const cid = (await h.one(`insert into channels (server_id, name, kind, created_by, no_gifs) values ($1, 'chat', 'text', $2, true) returning id`, [sid, owner])).id;
  const open = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'memes', 'text', $2) returning id`, [sid, owner])).id;
  // New-account slowmode: one message per author every 3 s, so the member's attempts are spaced out.
  const wait = () => new Promise((r) => setTimeout(r, 3200));
  const send = (who, ch, content, path = null) => h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, $3, $4)`, [ch, who, content, path]);

  await h.as(member);
  await h.fails('gif attachment refused', `insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, '', $3)`, [cid, member, `${member}/r2-1.gif`]);
  await h.fails('gif link refused', `insert into messages (channel_id, author_id, content) values ($1, $2, 'look https://example.com/funny.gif')`, [cid, member]);
  await h.fails('tenor link refused', `insert into messages (channel_id, author_id, content) values ($1, $2, 'https://tenor.com/view/abc-123')`, [cid, member]);
  await h.fails('klipy link refused', `insert into messages (channel_id, author_id, content) values ($1, $2, 'https://klipy.com/gifs/x')`, [cid, member]);
  await h.ok('a picture is fine', () => send(member, cid, 'pic', `${member}/r2-2.png`));
  await wait();
  await h.ok('plain text is fine', () => send(member, cid, 'just words, gift and giffy are not gifs'));
  await wait();
  await h.ok('a .gif-ish word without a link is fine', () => send(member, cid, 'my file.gif is at home'));
  await wait();
  await h.ok('other channel takes gifs', () => send(member, open, '', `${member}/r2-3.gif`));
  await h.as(owner);
  await h.ok('manager posts a gif in the no-gifs channel', () => send(owner, cid, '', `${owner}/r2-4.gif`));
  // Bots pass (the same transaction-local setting the bot RPCs use).
  await h.admin();
  await h.q(`select set_config('yapper.bot', '1', false)`);
  await wait();
  await h.ok('a bot posts a gif in the no-gifs channel', () => send(owner, cid, '', `${owner}/r2-5.gif`));
  await h.q(`select set_config('yapper.bot', '', false)`);
  // Editing a plain message to add a gif link is refused too (the trigger runs on update of content).
  await h.as(member);
  await wait();
  await send(member, cid, 'plain for the edit test');
  let editMsg = '';
  try { await h.q(`update messages set content = 'https://tenor.com/view/x' where author_id = $1 and content = 'plain for the edit test'`, [member]); } catch (e) { editMsg = e.message; }
  h.eq('edit that adds a gif link is refused with the right words', /GIFs are off/.test(editMsg), true);
  await h.admin();
  await h.q(`update channels set no_gifs = false where id = $1`, [cid]);
  await h.as(member);
  await wait();
  await h.ok('switch off: gifs pass again', () => send(member, cid, 'https://tenor.com/view/abc-123'));
}
