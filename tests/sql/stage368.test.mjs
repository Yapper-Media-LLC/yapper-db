// 368: report context fills in messages deleted in the last 2 days, marked deleted (flag report_context_deleted).
// Runs 311 first (deleted_messages, report_message), then 368 on top.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const M311 = mig('311_bug_fixes_1020b.sql');
const MIG = mig('368_report_context_deleted.sql');

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
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.feature_flags f where f.key = k and (f.mode = 'everyone' or (f.mode = 'test' and (auth.uid() = any(f.users) or sid = any(f.servers))))) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(M311);
  await h.db.exec(MIG);
  await h.ok('368 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'report_context_deleted'`)).mode, 'test');

  const amy = await h.signup('amy368@test.dev', 'amy368');
  const bob = await h.signup('bob368@test.dev', 'bob368');
  const eve = await h.signup('eve368@test.dev', 'eve368');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = any($1::uuid[])`, [[amy, bob, eve]]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const sch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  const ch = (await h.one(`insert into channels (kind, created_by, dm_key) values ('dm', $1, gen_random_uuid()::text) returning id`, [amy])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [ch, amy, bob]);
  // One second apart, in the order added: inserts in the same millisecond tied on created_at and came back in any order (flaky on CI).
  let n = 0;
  const add = async (who, text, c = ch) => {
    const id = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [c, who, text])).id;
    await h.q(`update messages set created_at = now() - interval '1 hour' + $2 * interval '1 second' where id = $1`, [id, ++n]);
    return id;
  };
  await add(amy, 'hey');
  const lead1 = await add(bob, 'threat 1');
  const lead2 = await add(bob, 'threat 2');
  const last = await add(bob, 'last one');
  const after = await add(bob, 'after');
  // Bob deletes the build-up and what came after, keeps the last one.
  await h.as(bob);
  await h.q(`delete from messages where id = any($1::uuid[])`, [[lead1, lead2, after]]);

  const ctx = async () => (await h.one(`select evidence from reports where reporter_id = $1 order by created_at desc limit 1`, [amy])).evidence;
  // Flag off for Amy: as before, only what's still up.
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [last]);
  await h.admin();
  h.eq('flag off: deleted ones left out', (await ctx()).map((e) => e.content), ['hey']);

  await h.q(`update feature_flags set users = array[$1]::uuid[] where key = 'report_context_deleted'`, [amy]);
  await h.q(`delete from reports`);
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [last]);
  await h.admin();
  const ev = await ctx();
  h.eq('flag on: build-up and after are back, in order', ev.map((e) => e.content), ['hey', 'threat 1', 'threat 2', 'after']);
  h.eq('marked deleted', ev.map((e) => !!e.deleted), [false, true, true, true]);
  h.eq('kind still set', ev[1].kind, 'dm');
  h.eq('no files on deleted rows', ev[1].attachment, null);

  // Older than 2 days: not used.
  await h.q(`update deleted_messages set deleted_at = now() - interval '3 days' where id = $1`, [lead1]);
  await h.q(`delete from reports`);
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [last]);
  await h.admin();
  h.eq('past 2 days: left out', (await ctx()).map((e) => e.content), ['hey', 'threat 2', 'after']);

  // Still at most 4 after (added later, so these all land after the reported one).
  for (let i = 0; i < 6; i++) await add(amy, `later ${i}`);
  await h.q(`delete from reports`);
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [last]);
  await h.admin();
  h.eq('still at most 4 after, deleted ones count', (await ctx()).map((e) => e.content), ['hey', 'threat 2', 'after', 'later 0', 'later 1', 'later 2']);

  // A message staff (or the system) removed is never shown.
  const removed = await add(bob, 'removed by staff');
  const last2 = await add(bob, 'last two');
  await h.q(`delete from messages where id = $1`, [removed]);
  await h.q(`delete from reports`);
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [last2]);
  await h.admin();
  h.eq('staff removals left out', (await ctx()).some((e) => e.content === 'removed by staff'), false);

  // Server channels: no deleted context (server managers can read those reports).
  await add(amy, 'srv hey', sch);
  const sdel = await add(bob, 'srv threat', sch);
  const slast = await add(bob, 'srv last', sch);
  await h.as(bob);
  await h.q(`delete from messages where id = $1`, [sdel]);
  await h.q(`delete from reports`);
  await h.as(amy);
  await h.q(`select report_message($1, 'harassment', '')`, [slast]);
  await h.admin();
  h.eq('server chat: deleted left out', (await ctx()).map((e) => e.content), ['srv hey']);

  // Someone outside the chat still can't report it.
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'report_context_deleted'`, [amy, eve]);
  await h.as(eve);
  await h.fails('outsider cannot report', `select report_message($1, 'harassment', '')`, [last]);
}
