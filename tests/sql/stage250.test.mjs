// 250: deleting a message leaves replies pointing at it. 001..024 (messages with the reply key from 009).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '250_replies_keep_deleted_link.sql'), 'utf8');
  // post_marks as 100/173 made it (the slowmode mark the new function reads).
  await h.db.exec(`create table if not exists public.post_marks (channel_id uuid not null, author_id uuid not null, kind text not null,
    at timestamptz not null default now(), album_n int not null default 0, primary key (channel_id, author_id, kind));
    alter table public.post_marks enable row level security;`);
  await h.db.exec(MIG);
  await h.ok('250 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('reply key is gone', (await h.one(`select count(*)::int n from pg_constraint where conname = 'messages_reply_to_id_fkey'`)).n, 0);

  const amy = await h.signup('amy@test.dev', 'amy');
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, amy]);
  const cid = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  await h.q(`alter table messages disable trigger user`);
  const orig = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'first') returning id`, [cid, amy])).id;
  const reply = (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1, $2, 'reply', $3) returning id`, [cid, amy, orig])).id;
  await h.q(`alter table messages enable trigger user`);
  await h.as(amy);
  await h.q(`delete from messages where id = $1`, [orig]);
  await h.admin();
  h.eq('reply still points at the deleted message', (await h.one(`select reply_to_id from messages where id = $1`, [reply])).reply_to_id, orig);

  // my_slowmode_mark: your own mark only, and nothing for anon.
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.q(`insert into post_marks (channel_id, author_id, kind, at) values ($1, $2, 'msg', '2026-10-18 10:00Z'), ($1, $3, 'msg', '2026-10-18 11:00Z')
    on conflict (channel_id, author_id, kind) do update set at = excluded.at`, [cid, amy, bob]);
  await h.as(amy);
  h.eq('my mark, not someone else\'s', new Date((await h.one(`select my_slowmode_mark($1) t`, [cid])).t).toISOString(), '2026-10-18T10:00:00.000Z');
  await h.as(null);
  await h.fails('anon can\'t call it', `select my_slowmode_mark($1)`, [cid]);
  await h.admin();
}
