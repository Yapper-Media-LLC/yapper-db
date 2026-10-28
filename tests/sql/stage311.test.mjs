// 311: deleted messages kept for reports (only direct deletes), server tags of taken-down servers.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '311_bug_fixes_1020b.sql'), 'utf8');

const STANDINS = `
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists webhook jsonb;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists tag text;
alter table public.profiles add column if not exists server_tag uuid;
alter table public.profiles add column if not exists tag text;
create or replace function public.report_guard(reporter uuid) returns void language sql as $$ select $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable as $$ select false $$;
create table if not exists public.webhooks (id uuid primary key default gen_random_uuid(), created_by uuid);
alter table public.reports add column if not exists channel_id uuid;
alter table public.reports add column if not exists message_content text;
alter table public.reports add column if not exists message_attachment text;
alter table public.reports add column if not exists details text;
alter table public.reports add column if not exists evidence jsonb;
alter table public.reports add column if not exists server_id uuid;
alter table public.reports add column if not exists webhook_id uuid;
alter table public.reports add column if not exists message_deleted_at timestamptz;
alter table public.reports add column if not exists message_deleted_by text;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('311 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id, tag) values ('S', $1, 'SSS') returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const ch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  const m1 = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'spam spam') returning id`, [ch, bob])).id;
  const m2 = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'other') returning id`, [ch, amy])).id;

  // A direct delete is kept; a cascade (the channel going) isn't.
  await h.q(`delete from messages where id = $1`, [m1]);
  h.eq('a deleted message is kept', await h.one(`select content from deleted_messages where id = $1`, [m1]), { content: 'spam spam' });
  await h.as(amy);
  await h.fails('people cannot read the kept copies', `select * from deleted_messages`);
  await h.admin();

  // Server tags: fine while the server is up, refused after a takedown, and the takedown takes it off.
  await h.as(bob);
  await h.ok('bob wears the tag', () => h.q(`select set_server_tag($1)`, [sid]));
  await h.admin();
  await h.q(`update servers set shut_down_at = now() where id = $1`, [sid]);
  h.eq('takedown took the tag off', await h.one(`select server_tag, tag from profiles where id = $1`, [bob]), { server_tag: null, tag: null });
  await h.as(bob);
  await h.fails('no tag from a taken-down server', `select set_server_tag($1)`, [sid]);
  await h.admin();

  // Bob deletes his own message; Amy can still report it (no row to point at, marked deleted by the author).
  await h.q(`update servers set shut_down_at = null where id = $1`, [sid]);
  const m3 = (await h.one(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, 'scam link', now() - interval '1 minute') returning id`, [ch, bob])).id;
  await h.as(bob);
  await h.q(`delete from messages where id = $1`, [m3]);
  await h.as(amy);
  await h.ok('a deleted message can be reported', () => h.q(`select report_message($1, 'spam', '')`, [m3]));
  await h.fails('a made-up id still cannot', `select report_message(gen_random_uuid(), 'spam', '')`);
  await h.admin();
  h.eq('the report keeps what it said', await h.one(`select message_id, message_content, message_deleted_by, target_id = $2 as bob from reports where message_content = 'scam link' and reporter_id = $1`, [amy, bob]),
    { message_id: null, message_content: 'scam link', message_deleted_by: 'author', bob: true });

  await h.q(`delete from channels where id = $1`, [ch]);
  h.eq('a cascade isn’t copied', await h.one(`select count(*)::int n from deleted_messages where id = $1`, [m2]), { n: 0 });
}
