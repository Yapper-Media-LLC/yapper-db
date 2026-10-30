// 654: NSFW check for custom emojis. Base 24 has emojis with server_id; stand-ins for the later bits (media_scans,
// media_purge, is_staff, bc, feature_on, 625's staff_emoji_remove). Covers: the insert gate (unsure is kept in
// emoji_checks and not inserted, clean is recorded and inserted, no scan answer and flag off leave things alone, the
// same waiting picture isn't queued twice, path updates are refused), the column grant (only name is updatable), the
// staff queue/stats/decide (approve inserts the row back with its id, remove purges + logs), the service-side apply
// (nsfw removes + logs + blocks the scan row, unsure moves the row to the queue, error is retried) and the spend sums.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MORE = `
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists member_count integer not null default 0;
alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.profiles add column if not exists display_name text;
create table if not exists public.media_purge (bucket text not null, path text not null, queued_at timestamptz not null default now(),
  done_at timestamptz, error text, primary key (bucket, path));
create table if not exists public.media_scans (bucket text not null, path text not null, user_id uuid, score real not null,
  verdict text not null check (verdict in ('ok', 'blocked')), scanned_at timestamptz not null default now(), details jsonb, primary key (bucket, path));
create or replace function public.media_ok(b text, p text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.media_scans where bucket = b and path = p and verdict = 'ok') $$;
create or replace function public.require_scanned_media() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.path is not null and (tg_op = 'INSERT' or new.path is distinct from old.path) and not public.media_ok('emojis', new.path) then
    raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists emojis_scanned_media on public.emojis;
create trigger emojis_scanned_media before insert or update of path on public.emojis for each row execute function public.require_scanned_media();
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null); $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod(); $$;
create table if not exists public.t654_bc (topic text, event text, op text, rec jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql as $$ begin insert into public.t654_bc values (topic_name, event_name, operation, coalesce(to_jsonb(new), to_jsonb(old))); end $$;
create or replace function public.bc_emoji() returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid := coalesce(new.server_id, old.server_id);
begin
  if sid is not null then perform public.bc('server:' || sid, 'emoji', tg_op, tg_table_name, tg_table_schema, new, old); end if;
  return null;
end $$;
drop trigger if exists emojis_bc on public.emojis;
create trigger emojis_bc after insert or update or delete on public.emojis for each row execute function public.bc_emoji();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(mig('625_emoji_source.sql'));
  await h.db.exec(mig('654_emoji_nsfw_scan.sql'));
  await h.ok('654 re-runs cleanly', () => h.db.exec(mig('654_emoji_nsfw_scan.sql')));
  h.eq('flag stays in test mode', (await h.one(`select mode from feature_flags where key = 'emoji_nsfw_scan'`)).mode, 'test');
  h.eq('flag lists the HQ test server', (await h.one(`select '00000000-0000-4000-8000-00000000b001' = any(servers) ok from feature_flags where key = 'emoji_nsfw_scan'`)).ok, true);

  const mod = await h.signup('mod654@test.dev', 'mod654');
  const owner = await h.signup('owner654@test.dev', 'owner654');
  const member = await h.signup('member654@test.dev', 'member654');
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  const SID = '00000000-0000-4000-8000-00000000b001';
  const OTHER = 'a1509fda-bcf4-48a2-9cac-756bd3fff8f2';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test HQ', $2), ($3, 'Elsewhere', $2)`, [SID, owner, OTHER]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($4, $2), ($4, $3) on conflict do nothing`, [SID, owner, member, OTHER]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'emoji_source'`);

  const E_UNSURE = '11111111-1111-4111-8111-111111111111';
  const E_CLEAN = '22222222-2222-4222-8222-222222222222';
  const E_NOSCAN = '33333333-3333-4333-8333-333333333333';
  const E_OFF = '44444444-4444-4444-8444-444444444444';
  const E_OLD = '55555555-5555-4555-8555-555555555555';
  const E_AGAIN = '66666666-6666-4666-8666-666666666666';
  const pathOf = (id) => `${owner}/r2-${id}-1700000000-abc123.png`;
  const scan = (id, emoji) => h.q(`insert into media_scans (bucket, path, user_id, score, verdict, details) values ('emojis', $1, $2, 0.1, 'ok', $3)`,
    [pathOf(id), owner, emoji ? JSON.stringify({ emoji }) : null]);
  await scan(E_UNSURE, { verdict: 'unsure', rating: 'suggestive', confidence: 0.62, reason: 'lingerie pose', model: 'claude-haiku-5-5', cost: 0.00012 });
  await scan(E_CLEAN, { verdict: 'clean', rating: 'safe', confidence: 0.97, reason: 'cat face', model: 'claude-haiku-5-5', cost: 0.0001 });
  await scan(E_NOSCAN, null);
  await scan(E_OFF, { verdict: 'unsure', rating: 'suggestive', confidence: 0.5, reason: 'x', model: 'm', cost: 0 });
  await scan(E_OLD, null);

  // Inserts as the uploader (the dialog inserts straight into the table and then looks the row up).
  await h.as(owner);
  const add = (id, sid, name, path = pathOf(id)) => h.q(`insert into emojis (id, owner_id, server_id, name, path) values ($1::uuid, $2::uuid, $3::uuid, $4, $5)`, [id, owner, sid, name, path]);
  await add(E_UNSURE, SID, 'maybe');
  await add(E_CLEAN, SID, 'cat');
  await add(E_NOSCAN, SID, 'noscan');
  await add(E_OFF, OTHER, 'elsewhere');
  await add(E_OLD, OTHER, 'older');
  h.eq('unsure: no row (the dialog sees nothing back and says a mod will look)', (await h.q(`select 1 from emojis where id = $1`, [E_UNSURE])).length, 0);
  h.eq('clean: inserted', (await h.q(`select 1 from emojis where id = $1`, [E_CLEAN])).length, 1);
  h.eq('no scan answer: inserted', (await h.q(`select 1 from emojis where id = $1`, [E_NOSCAN])).length, 1);
  h.eq('flag off for that server: inserted even with an unsure answer', (await h.q(`select 1 from emojis where id = $1`, [E_OFF])).length, 1);
  // The same waiting picture again under a new id: swallowed, not queued twice.
  await add(E_AGAIN, SID, 'maybe2', pathOf(E_UNSURE));
  h.eq('same picture again: no row', (await h.q(`select 1 from emojis where id = $1`, [E_AGAIN])).length, 0);
  // The gate drops the row before the insert policy runs, so it checks the policy's rules itself (round-two review).
  await h.as(member);
  await h.fails('a non-manager cannot queue an emoji with an unsure picture', `insert into emojis (id, owner_id, server_id, name, path) values ('99999999-9999-4999-8999-999999999999', $1, $2, 'sneak', $3)`, [member, SID, pathOf(E_UNSURE)]);
  await h.fails("a non-manager cannot queue one under the uploader's name", `insert into emojis (id, owner_id, server_id, name, path) values ('99999999-9999-4999-8999-999999999999', $1, $2, 'sneak', $3)`, [owner, SID, pathOf(E_UNSURE)]);
  await h.as(owner);
  await h.fails('reusing a live emoji id with an unsure picture fails', `insert into emojis (id, owner_id, server_id, name, path) values ($1, $2, $3, 'clobber', $4)`, [E_CLEAN, owner, SID, pathOf(E_UNSURE)]);
  await h.admin();
  await h.q(`insert into media_scans (bucket, path, user_id, score, verdict, details) values ('emojis', $1, $2, 0.1, 'ok', $3)`,
    [`${member}/r2-other.png`, member, JSON.stringify({ emoji: { verdict: 'unsure', rating: 'suggestive', confidence: 0.6, reason: 'y' } })]);
  await h.as(owner);
  await h.fails("someone else's scan cannot be queued as yours", `insert into emojis (id, owner_id, server_id, name, path) values ('99999999-9999-4999-8999-999999999999', $1, $2, 'theirs', $3)`, [owner, SID, `${member}/r2-other.png`]);
  await h.admin();
  h.eq('nothing extra was queued by those attempts', (await h.q(`select 1 from emoji_checks`)).length, 2);
  h.eq("the live emoji's record is untouched", (await h.one(`select verdict, path from emoji_checks where emoji_id = $1`, [E_CLEAN])), { verdict: 'clean', path: pathOf(E_CLEAN) });
  await h.as(owner);
  // Only the name may be changed by the browser.
  await h.q(`update emojis set name = 'kitty' where id = $1`, [E_CLEAN]);
  h.eq('rename works', (await h.one(`select name from emojis where id = $1`, [E_CLEAN])).name, 'kitty');
  await h.fails('path cannot be updated by a manager (column grant)', `update emojis set path = $2 where id = $1`, [E_CLEAN, pathOf(E_NOSCAN)]);
  await h.fails('animated cannot be updated by a manager (column grant)', `update emojis set animated = true where id = $1`, [E_CLEAN]);

  await h.admin();
  h.eq('unsure recorded once, with the whole row', (await h.q(`select name, server_id, owner_id, verdict, rating, reason, animated, emoji_created_at is not null as has_ts from emoji_checks where path = $1`, [pathOf(E_UNSURE)])),
    [{ name: 'maybe', server_id: SID, owner_id: owner, verdict: 'unsure', rating: 'suggestive', reason: 'lingerie pose', animated: false, has_ts: true }]);
  h.eq('unsure cost recorded', Number((await h.one(`select cost_usd from emoji_checks where emoji_id = $1`, [E_UNSURE])).cost_usd), 0.00012);
  h.eq('clean recorded', (await h.one(`select verdict from emoji_checks where emoji_id = $1`, [E_CLEAN])).verdict, 'clean');
  h.eq('no answer: nothing recorded', (await h.q(`select 1 from emoji_checks where emoji_id in ($1, $2, $3)`, [E_NOSCAN, E_OFF, E_OLD])).length, 0);
  h.eq('nothing was broadcast for the unsure one', (await h.q(`select 1 from t654_bc where rec ->> 'id' = $1`, [E_UNSURE])).length, 0);
  h.eq('clean insert was broadcast', (await h.q(`select 1 from t654_bc where rec ->> 'id' = $1 and op = 'INSERT'`, [E_CLEAN])).length, 1);
  // A path update as the service role (nothing does this today) to an unsure picture is refused outright.
  await h.fails('path update to an unsure picture is refused', `update emojis set path = $2 where id = $1`, [E_CLEAN, pathOf(E_UNSURE)]);

  // Nothing of the waiting one is readable by members.
  await h.as(member);
  h.eq('emojis_by_ids knows nothing of it', (await h.q(`select 1 from emojis where id = $1`, [E_UNSURE])).length, 0);
  h.eq('emoji_source: no card', (await h.one(`select emoji_source($1) j`, [E_UNSURE])).j, null);
  await h.fails('member cannot read emoji_checks', `select * from emoji_checks`);
  await h.fails('member cannot read the queue', `select emoji_checks_queue()`);
  await h.fails('member cannot read the stats', `select emoji_checks_stats()`);
  await h.fails('member cannot decide', `select emoji_check_decide((select id from emoji_checks limit 1), true)`);
  await h.fails('member cannot call the service todo', `select * from emoji_checks_todo(5)`);
  await h.fails('member cannot call apply', `select emoji_check_apply($1, 'clean', null, null, null, null, 0)`, [E_OLD]);
  await h.fails('member cannot call the scan note', `select emoji_scan_note('x', 'clean', null, null, null, null)`);
  await h.as(null);
  await h.fails('anon cannot read the queue', `select emoji_checks_queue()`);

  // Staff: the queue, the numbers, and the decision.
  await h.as(mod);
  const queue = (await h.one(`select emoji_checks_queue() j`)).j;
  h.eq('queue has the unsure one only', queue.map((r) => r.emoji_id), [E_UNSURE]);
  h.eq('queue row carries server, uploader and the reason', [queue[0].server.name, queue[0].uploader.username, queue[0].reason, queue[0].rating, queue[0].name], ['Test HQ', 'owner654', 'lingerie pose', 'suggestive', 'maybe']);
  const stats = (await h.one(`select emoji_checks_stats() j`)).j;
  h.eq('stats: 1 waiting, 2 checked, 1 not checked yet (test mode: the test server only)', [stats.queue, stats.checked_day, stats.unchecked], [1, 2, 1]);
  await h.q(`select emoji_check_decide($1, true, 'fine')`, [queue[0].id]);
  await h.fails('deciding twice fails', `select emoji_check_decide($1, true)`, [queue[0].id]);
  await h.admin();
  const back = await h.one(`select id, owner_id, server_id, name, path, animated from emojis where id = $1`, [E_UNSURE]);
  h.eq('approved: the row is back as it was sent in', back, { id: E_UNSURE, owner_id: owner, server_id: SID, name: 'maybe', path: pathOf(E_UNSURE), animated: false });
  h.eq('approval written on the check', (await h.one(`select decision, decided_by from emoji_checks where emoji_id = $1`, [E_UNSURE])).decided_by, mod);
  h.eq('approval logged', (await h.one(`select reason from mod_log where action = 'emoji_approved'`)).reason.startsWith(':maybe: (Test HQ, '), true);
  h.eq('approval was broadcast as an insert', (await h.q(`select 1 from t654_bc where rec ->> 'id' = $1 and op = 'INSERT'`, [E_UNSURE])).length, 1);
  h.eq('approval noted on the scan row', (await h.one(`select details -> 'emoji' ->> 'verdict' v from media_scans where path = $1`, [pathOf(E_UNSURE)])).v, 'clean');
  h.eq('check row still says unsure (history)', (await h.one(`select verdict from emoji_checks where emoji_id = $1`, [E_UNSURE])).verdict, 'unsure');
  await h.as(member);
  h.eq('member sees it now', (await h.q(`select 1 from emojis where id = $1`, [E_UNSURE])).length, 1);

  // Service side: the older-emojis pass. In test mode only the test server's emojis are walked.
  await h.admin();
  h.eq('todo in test mode: the test server only', (await h.q(`select id from emoji_checks_todo(10)`)).map((r) => r.id), [E_NOSCAN]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'emoji_nsfw_scan'`);
  const todo = await h.q(`select id from emoji_checks_todo(10)`);
  h.eq('todo: the unchecked ones, newest first', todo.map((r) => r.id), [E_OLD, E_OFF, E_NOSCAN]);
  h.eq('remaining counts them', Number((await h.one(`select emoji_checks_remaining() n`)).n), 3);
  h.eq('apply: clean', (await h.one(`select emoji_check_apply($1, 'clean', 'safe', 0.9, 'dog', 'claude-haiku-5-5', 0.0001) v`, [E_NOSCAN])).v, 'clean');
  h.eq('clean noted on the scan row', (await h.one(`select details -> 'emoji' ->> 'verdict' v from media_scans where path = $1`, [pathOf(E_NOSCAN)])).v, 'clean');
  h.eq('apply: unsure moves it to the queue', (await h.one(`select emoji_check_apply($1, 'unsure', 'suggestive', 0.6, 'bikini', 'claude-haiku-5-5', 0.0001) v`, [E_OFF])).v, 'unsure');
  h.eq('unsure older emoji: row gone', (await h.q(`select 1 from emojis where id = $1`, [E_OFF])).length, 0);
  h.eq('unsure older emoji: picture not purged', (await h.q(`select 1 from media_purge where path = $1`, [pathOf(E_OFF)])).length, 0);
  h.eq('its removal was broadcast', (await h.q(`select 1 from t654_bc where rec ->> 'id' = $1 and op = 'DELETE'`, [E_OFF])).length, 1);
  h.eq('unsure noted on the scan row', (await h.one(`select details -> 'emoji' ->> 'verdict' v from media_scans where path = $1`, [pathOf(E_OFF)])).v, 'unsure');
  // The owner tries to add the same picture again: the gate keeps it out, no second queue row.
  await h.as(owner);
  await add('77777777-7777-4777-8777-777777777777', OTHER, 'again', pathOf(E_OFF));
  await h.admin();
  h.eq('re-adding a waiting picture: no row', (await h.q(`select 1 from emojis where path = $1`, [pathOf(E_OFF)])).length, 0);
  h.eq('re-adding a waiting picture: still one queue row', (await h.q(`select 1 from emoji_checks where path = $1`, [pathOf(E_OFF)])).length, 1);
  h.eq('apply: error', (await h.one(`select emoji_check_apply($1, 'error', null, null, 'Timed out', null, 0) v`, [E_OLD])).v, 'error');
  h.eq('a fresh error is not retried yet', (await h.q(`select id from emoji_checks_todo(10)`)).length, 0);
  await h.q(`update emoji_checks set checked_at = now() - interval '2 hours' where emoji_id = $1`, [E_OLD]);
  h.eq('an hour later it is', (await h.q(`select id from emoji_checks_todo(10)`)).map((r) => r.id), [E_OLD]);
  h.eq('apply: nsfw', (await h.one(`select emoji_check_apply($1, 'nsfw', 'explicit', 0.95, 'nudity', 'claude-haiku-5-5', 0.0001) v`, [E_OLD])).v, 'nsfw');
  h.eq('nsfw: row gone', (await h.q(`select 1 from emojis where id = $1`, [E_OLD])).length, 0);
  h.eq('nsfw: picture queued for the purge', (await h.q(`select 1 from media_purge where bucket = 'emojis' and path = $1`, [pathOf(E_OLD)])).length, 1);
  h.eq('nsfw: scan row blocked', (await h.one(`select verdict from media_scans where path = $1`, [pathOf(E_OLD)])).verdict, 'blocked');
  await h.q(`update media_scans set score = 0.95, verdict = 'ok' where path = $1`, [pathOf(E_NOSCAN)]);
  await h.q(`select emoji_scan_note($1, 'nsfw', 'explicit', 0.9, 'x', 'm')`, [pathOf(E_NOSCAN)]);
  h.eq('a refusal note keeps the score under the strike line', Number((await h.one(`select score from media_scans where path = $1`, [pathOf(E_NOSCAN)])).score) < 0.9, true);
  await h.q(`update media_scans set score = 0.1, verdict = 'ok' where path = $1`, [pathOf(E_NOSCAN)]);
  await h.as(owner);
  await h.fails('nsfw: the picture cannot be added again', `insert into emojis (id, owner_id, server_id, name, path) values ('88888888-8888-4888-8888-888888888888', $1, $2, 'back', $3)`, [owner, OTHER, pathOf(E_OLD)]);
  await h.admin();
  const auto = await h.one(`select * from mod_log where action = 'emoji_auto_removed'`);
  h.eq('nsfw: logged against the uploader with the server', [auto.target_id, auto.actor, auto.reason.startsWith(':older: (Elsewhere, ')], [owner, null, true]);
  h.eq('nsfw: reason carries the check', auto.reason.includes('Auto check: nudity'), true);
  const chk = await h.one(`select verdict, decision, attempts from emoji_checks where emoji_id = $1`, [E_OLD]);
  h.eq('nsfw: check row kept after the removal, second attempt', [chk.verdict, chk.decision, chk.attempts], ['nsfw', 'removed', 2]);
  h.eq('apply on a gone emoji', (await h.one(`select emoji_check_apply($1, 'clean', null, null, null, null, 0) v`, [E_OLD])).v, 'gone');
  await h.fails('apply refuses a bad verdict', `select emoji_check_apply($1, 'meh', null, null, null, null, 0)`, [E_CLEAN]);
  const spend = (await h.one(`select emoji_check_spend() j`)).j;
  h.eq('spend: new emojis today', Number(spend.day), 0.00022);
  h.eq('spend: older pass today', Number(spend.backfill_day), 0.0003);
  h.eq('remaining is 0 now', Number((await h.one(`select emoji_checks_remaining() n`)).n), 0);

  // Staff remove from the queue: the waiting one has no emoji row, so purge + log directly.
  await h.as(mod);
  const q2 = (await h.one(`select emoji_checks_queue() j`)).j;
  h.eq('queue now holds the older unsure one', q2.map((r) => r.emoji_id), [E_OFF]);
  await h.q(`select emoji_check_decide($1, false, 'too much')`, [q2[0].id]);
  await h.admin();
  h.eq('removed from the queue: picture purged', (await h.q(`select 1 from media_purge where path = $1`, [pathOf(E_OFF)])).length, 1);
  h.eq('removed from the queue: logged as emoji_removed', (await h.one(`select reason from mod_log where action = 'emoji_removed'`)).reason.endsWith(' too much'), true);
  h.eq('removed from the queue: decision written', (await h.one(`select decision from emoji_checks where emoji_id = $1`, [E_OFF])).decision, 'removed');
  h.eq('removed from the queue: scan row blocked', (await h.one(`select verdict from media_scans where path = $1`, [pathOf(E_OFF)])).verdict, 'blocked');
  // A refused upload's record (emoji_id null) can't be "approved".
  await h.q(`insert into emoji_checks (emoji_id, owner_id, path, verdict, decision) values (null, $1, 'x/y.png', 'nsfw', 'removed')`, [owner]);
  await h.as(mod);
  h.eq('queue empty', (await h.one(`select emoji_checks_queue() j`)).j, []);
  await h.fails('a refusal record cannot be decided', `select emoji_check_decide((select id from emoji_checks where emoji_id is null), true)`);

  // Approving: a banned uploader's emoji stays out; a name taken meanwhile gets a readable message; then it goes in.
  await h.admin();
  const E_LATE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  await scan(E_LATE, { verdict: 'unsure', rating: 'suggestive', confidence: 0.55, reason: 'pose', model: 'm', cost: 0.0001 });
  await h.as(owner);
  await add(E_LATE, SID, 'late');
  await h.admin();
  h.eq('late one is waiting', (await h.q(`select 1 from emojis where id = $1`, [E_LATE])).length, 0);
  const late = await h.one(`select id from emoji_checks where emoji_id = $1`, [E_LATE]);
  await h.q(`insert into site_bans (user_id) values ($1)`, [owner]);
  await h.as(mod);
  await h.fails("a banned uploader's emoji cannot be approved", `select emoji_check_decide($1, true)`, [late.id]);
  await h.admin();
  await h.q(`delete from site_bans where user_id = $1`, [owner]);
  await scan('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', null);
  await h.as(owner);
  await add('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', SID, 'late');
  await h.as(mod);
  let msg = '';
  try { await h.q(`select emoji_check_decide($1, true)`, [late.id]); } catch (e) { msg = e.message; }
  h.eq('name taken meanwhile: readable message', msg.includes('already has an emoji called :late:'), true);
  await h.admin();
  h.eq('still undecided after the failed approve', (await h.one(`select decision from emoji_checks where id = $1`, [late.id])).decision, null);
  await h.q(`update emojis set name = 'late_other' where name = 'late'`);
  await h.as(mod);
  await h.q(`select emoji_check_decide($1, true)`, [late.id]);
  await h.admin();
  h.eq('approved after the rename', (await h.one(`select name from emojis where id = $1`, [E_LATE])).name, 'late');
}
