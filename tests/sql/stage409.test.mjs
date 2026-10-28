// 409: search filters. search_messages_v3 = v2 plus since (after:) and has (link / image / video / file), and a
// kind-only search. Same stand-ins as stage298 (base 24 + flags), then 298 (v2) and 409 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage298.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(`alter table public.servers add column if not exists shut_down_at timestamptz;`);
  // Same stub dance as stage298: my_mentions calls my_visible_server_channels, which 298 itself defines later.
  await h.db.exec("create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable as $f$ select * from public.channels where false $f$;");
  await h.db.exec(mig('298_banned_cant_read.sql'));
  await h.db.exec("create or replace function public.my_visible_server_channels() returns setof public.channels language sql stable security definer set search_path = public as $f$ select * from public.visible_server_channels(null) $f$;");
  const MIG = mig('409_search_filters.sql');
  await h.ok('409 applies', () => h.db.exec(MIG));
  await h.ok('409 re-runs cleanly', () => h.db.exec(MIG));

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'search'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [a])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, a, b]);
  const cid = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'general', 'text', $2) returning id`, [sid, a])).id;
  const c2 = (await h.one(`insert into channels (server_id, name, kind, created_by) values ($1, 'memes', 'text', $2) returning id`, [sid, a])).id;
  // A trigger stamps created_at with now() on insert (and keeps it), so the dates for before:/after: are read back
  // between rows. New-account slowmode: one message per author every 3 s, so the seed waits between rows.
  const ins = async (ch, who, content, path) => {
    await new Promise((r) => setTimeout(r, 3200));
    return h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, $3, $4)`, [ch, who, content, path]);
  };
  const stamp = async () => (await h.one(`select now()::text t`)).t;
  await ins(cid, a, 'hello world https://example.com', null);
  await ins(cid, b, 'hello picture', `${b}/r2-1.png`);
  const t1 = await stamp(); // after 2 rows
  await ins(cid, b, 'hello clip', `${b}/r2-2.mp4`);
  await ins(c2, a, 'hello doc', `${a}/r2-3.pdf`);
  const t2 = await stamp(); // after 4 rows
  await ins(cid, a, 'plain hello', null);

  await h.as(a);
  const n = async (sql, params = []) => (await h.one(`select count(*)::int n from ${sql}`, params)).n;
  h.eq('words only, like v2', await n(`search_messages_v3('hello', $1)`, [sid]), 5);
  h.eq('has:link', await n(`search_messages_v3('hello', $1, null, null, null, null, 'link')`, [sid]), 1);
  h.eq('has:image', await n(`search_messages_v3('hello', $1, null, null, null, null, 'image')`, [sid]), 1);
  h.eq('has:video', await n(`search_messages_v3('hello', $1, null, null, null, null, 'video')`, [sid]), 1);
  h.eq('has:file counts every attachment', await n(`search_messages_v3('hello', $1, null, null, null, null, 'file')`, [sid]), 3);
  h.eq('after: cuts the older ones', await n(`search_messages_v3('hello', $1, null, null, null, $2)`, [sid, t1]), 3);
  h.eq('before: and after: together', await n(`search_messages_v3('hello', $1, null, null, $2, $3)`, [sid, t2, t1]), 2);
  h.eq('in: one channel', await n(`search_messages_v3('hello', null, $1)`, [c2]), 1);
  h.eq('kind only, no words: newest of that kind in the server', await n(`search_messages_v3(null, $1, null, null, null, null, 'file')`, [sid]), 3);
  h.eq('kind only, links', await n(`search_messages_v3(null, $1, null, null, null, null, 'link')`, [sid]), 1);
  h.eq('kind only needs a place to look', await n(`search_messages_v3(null, null, null, null, null, null, 'file')`), 0);
  h.eq('unknown kind finds nothing', await n(`search_messages_v3('hello', $1, null, null, null, null, 'song')`, [sid]), 0);
  h.eq('author plus kind', await n(`search_messages_v3(null, $1, null, $2, null, null, 'file')`, [sid, b]), 2);
  await h.admin();
  await h.q(`update servers set shut_down_at = now() where id = $1`, [sid]);
  await h.as(a);
  h.eq('a taken-down server is closed to its members (331 kept)', await n(`search_messages_v3('hello', $1)`, [sid]), 0);
}
