// 575: join applications. Starts from stage 24 (servers, invites, server_members, bans, the 014 join_server) plus the
// flags tables (031/041) and stand-ins for the later helpers these functions use (staff, server_perm with role perms,
// server_locked, bc_notice).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '575_join_applications.sql'), 'utf8');

const STANDINS = `
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.t575_perms (server_id uuid, user_id uuid, perm text);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid());
$$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.t575_perms p where p.server_id = sid and p.user_id = auth.uid() and p.perm = $2);
$$;
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.servers add column if not exists locked_until timestamptz;
create or replace function public.server_locked(sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select locked_until > now() from public.servers where id = sid), false);
$$;
create table if not exists public.t575_notices (topic text, event text, payload jsonb);
create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
  insert into public.t575_notices values (topic_name, event_name, payload);
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('575 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create or replace function public.t575_req(uid uuid) returns jsonb language sql security definer set search_path = public as $$
    select to_jsonb(r) from public.server_join_requests r where r.user_id = uid order by r.created_at desc limit 1; $$;`);

  const owner = await h.signup('owner@test.dev', 'owner');
  const mod = await h.signup('mod@test.dev', 'mod');
  const plain = await h.signup('plain@test.dev', 'plain');
  const ann = await h.signup('ann@test.dev', 'ann');
  const bob = await h.signup('bob@test.dev', 'bob');
  const staff = await h.signup('staff@test.dev', 'staff');
  await h.as(owner);
  const A = (await h.one(`select create_server('Gated', null) id`)).id;
  const B = (await h.one(`select create_server('Open', null) id`)).id;
  await h.admin();
  await h.q(`insert into invites (code, server_id, created_by) values ('gatedlink', $1, $2), ('openlink', $3, $2)`, [A, owner, B]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [A, mod, plain]);
  await h.q(`insert into t575_perms values ($1, $2, 'kick_members')`, [A, mod]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  const members = async (sid) => (await h.one(`select count(*)::int n from server_members where server_id = $1`, [sid])).n;
  const isMember = async (sid, uid) => (await h.one(`select count(*)::int n from server_members where server_id = $1 and user_id = $2`, [sid, uid])).n === 1;
  const notices = async () => h.q(`select topic, event, payload from t575_notices order by ctid`);
  const info = async (code) => (await h.one(`select invite_apply_info($1) j`, [code])).j;
  const req = async (uid) => (await h.one(`select t575_req($1) j`, [uid])).j;
  const pick = (o, ks) => Object.fromEntries(ks.map((k) => [k, o[k]]));
  const apply = async (code, msg = '', ans = []) => (await h.one(`select apply_to_server($1, $2, $3) j`, [code, msg, ans])).j;

  // Flag off: the setting can't be turned on, and the gate does nothing even where join_apply is set.
  h.eq('flag row (test)', (await h.one(`select mode from feature_flags where key = 'join_applications'`)).mode, 'test');
  await h.as(owner);
  await h.fails('setting needs the flag', `select set_join_apply($1, true, '{}')`, [A]);
  await h.admin();
  await h.q(`update servers set join_apply = true where id = $1`, [A]);
  await h.as(ann);
  h.eq('flag off: invite joins straight away', (await apply('gatedlink')).joined, true);
  h.eq('flag off: ann is in', await isMember(A, ann), true);
  await h.admin();
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [A, ann]);
  await h.q(`update servers set join_apply = false where id = $1`, [A]);
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'join_applications'`, [A]);

  // The setting.
  await h.as(mod);
  await h.fails('setting needs Manage Server', `select set_join_apply($1, true, '{}')`, [A]);
  await h.as(owner);
  await h.fails('up to 3 questions', `select set_join_apply($1, true, array['a','b','c','d'])`, [A]);
  await h.fails('questions under 200 chars', `select set_join_apply($1, true, array[repeat('x', 201)])`, [A]);
  await h.q(`select set_join_apply($1, true, array[' Why here? ', '', 'Age?'])`, [A]);
  h.eq('setting saved, questions trimmed and blanks dropped',
    await h.one(`select join_apply, join_questions from servers where id = $1`, [A]), { join_apply: true, join_questions: ['Why here?', 'Age?'] });

  // The gate on a direct join.
  await h.as(ann);
  await h.fails('join_server refused while the gate is on', `select join_server('gatedlink')`);
  await h.fails('a direct insert is refused too', `insert into server_members (server_id, user_id) values ($1, $2)`, [A, ann]);
  h.eq('open server unaffected', (await apply('openlink')).joined, true);
  h.eq('invite page: apply needed', (await info('gatedlink')).apply, true);
  h.eq('invite page: questions', (await info('gatedlink')).questions, ['Why here?', 'Age?']);
  h.eq('invite page: no request yet', (await info('gatedlink')).request, null);
  h.eq('invite page: open server needs nothing', (await info('openlink')).apply, false);
  h.eq('invite page: bad code', await info('nope'), null);

  // Apply.
  const r1 = await apply('gatedlink', '  hi mods  ', ['because', 'old enough', 'extra answer dropped']);
  h.eq('application filed', [r1.joined, r1.status], [false, 'pending']);
  h.eq('still not a member', await isMember(A, ann), false);
  h.eq('message trimmed, answers capped to the questions',
    pick(await req(ann), ['message', 'answers', 'invite_code']),
    { message: 'hi mods', answers: ['because', 'old enough'], invite_code: 'gatedlink' });
  h.eq('applying again while waiting just says pending', (await apply('gatedlink', 'again')).status, 'pending');
  h.eq('one row per person and server', (await req(ann)).status, 'pending');
  h.eq('invite page: pending', (await info('gatedlink')).request.status, 'pending');
  h.eq('mods were told', (await notices()).map((n) => n.event), ['join_request']);
  await h.fails('no direct reads of the table', `select * from server_join_requests`);
  
  // Who can see and decide.
  await h.as(plain);
  await h.fails('a plain member can not list requests', `select * from join_requests($1)`, [A]);
  await h.as(mod);
  const list = await h.q(`select * from join_requests($1)`, [A]);
  h.eq('mod sees the request', [list.length, list[0].user_id, list[0].message], [1, ann, 'hi mods']);
  await h.as(plain);
  await h.fails('a plain member can not decide', `select decide_join_request($1, true, '')`, [list[0].id]);

  // Decline with a note, then 24 h.
  await h.as(mod);
  await h.q(`select decide_join_request($1, false, '  Not yet, sorry  ')`, [list[0].id]);
  h.eq('declined with the note', pick(await req(ann), ['status', 'note', 'decided_by']),
    { status: 'declined', note: 'Not yet, sorry', decided_by: mod });
  await h.fails('decided twice', `select decide_join_request($1, true, '')`, [list[0].id]);
  await h.as(ann);
  await h.fails('declined: apply again too soon', `select apply_to_server('gatedlink', 'please', '{}')`);
  h.eq('invite page: declined with retry time', (await info('gatedlink')).request.status, 'declined');
  h.eq('ann hears about it', (await h.q(`select * from my_join_decisions()`)).map((d) => [d.status, d.note, d.name]), [['declined', 'Not yet, sorry', 'Gated']]);
  const dec = (await h.q(`select * from my_join_decisions()`))[0];
  await h.as(bob);
  await h.q(`select ack_join_decision($1)`, [dec.id]);
  await h.as(ann);
  h.eq('only the applicant can dismiss it', (await h.q(`select * from my_join_decisions()`)).length, 1);
  await h.q(`select ack_join_decision($1)`, [dec.id]);
  h.eq('dismissed', (await h.q(`select * from my_join_decisions()`)).length, 0);
  await h.admin();
  await h.q(`update server_join_requests set decided_at = now() - interval '25 hours' where id = $1`, [list[0].id]);
  await h.as(ann);
  h.eq('after 24 h: apply again', (await apply('gatedlink', 'second try')).status, 'pending');
  h.eq('same row, reset', pick(await req(ann), ['status', 'note', 'message']),
    { status: 'pending', note: '', message: 'second try' });

  // Accept: member inserted, invite counted, notice sent.
  await h.as(mod);
  await h.q(`select decide_join_request($1, true, 'ignored on accept')`, [list[0].id]);
  h.eq('accepted: ann is in', await isMember(A, ann), true);
  h.eq('accepted: no note kept', (await req(ann)).note, '');
  h.eq('invite use counted (1 from the flag-off join)', (await h.one(`select uses from invites where code = 'gatedlink'`)).uses, 2);
  const last = (await notices()).filter((n) => n.topic === `user:${ann}`).pop();
  h.eq('ann told live', [last.event, last.payload.status, last.payload.name], ['join_request', 'accepted', 'Gated']);
  await h.as(ann);
  h.eq('invite page: already in', (await apply('gatedlink')).joined, true);
  h.eq('nothing waiting (left the list)', (await h.q(`select * from join_requests($1)`).catch(() => [])).length, 0);
  h.eq('decision seen later', (await h.q(`select * from my_join_decisions()`)).map((d) => d.status), ['accepted']);

  // Left after accept: must apply again.
  await h.admin();
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [A, ann]);
  await h.as(ann);
  await h.fails('rejoin by link needs a new application', `select join_server('gatedlink')`);
  h.eq('can apply again after leaving', (await apply('gatedlink', 'back')).status, 'pending');
  await h.q(`select withdraw_join_request($1)`, [A]);
  h.eq('withdrawn (row kept, seen)', pick(await req(ann), ['status']), { status: 'withdrawn' });
  h.eq('withdrawn is not a notice', (await h.q(`select * from my_join_decisions()`)).length, 0);
  await h.fails('reapply right after a withdraw waits a minute', `select apply_to_server('gatedlink', 'back again', '{}')`);
  await h.admin();
  await h.q(`update server_join_requests set decided_at = now() - interval '2 minutes' where user_id = $1`, [ann]);
  await h.as(ann);
  h.eq('a minute later: fine', (await apply('gatedlink', 'back again')).status, 'pending');
  await h.q(`select withdraw_join_request($1)`, [A]);

  // Refusals before applying: bans and locks.
  await h.admin();
  await h.q(`insert into server_bans (server_id, user_id) values ($1, $2)`, [A, bob]);
  await h.as(bob);
  await h.fails('banned can not apply', `select apply_to_server('gatedlink', 'hi', '{}')`);
  await h.admin();
  await h.q(`delete from server_bans where server_id = $1 and user_id = $2`, [A, bob]);
  await h.as(bob);
  h.eq('bob applies', (await apply('gatedlink', 'hi')).status, 'pending');
  await h.admin();
  await h.q(`insert into server_bans (server_id, user_id) values ($1, $2)`, [A, bob]);
  const bobReq = (await h.one(`select id from server_join_requests where user_id = $1`, [bob])).id;
  await h.as(mod);
  await h.fails('accept refused while banned', `select decide_join_request($1, true, '')`, [bobReq]);
  await h.admin();
  await h.q(`delete from server_bans where server_id = $1 and user_id = $2`, [A, bob]);
  await h.q(`update servers set locked_until = now() + interval '10 minutes' where id = $1`, [A]);
  await h.as(mod);
  await h.fails('accept refused while locked', `select decide_join_request($1, true, '')`, [bobReq]);
  await h.admin();
  await h.q(`update servers set locked_until = null where id = $1`, [A]);
  await h.as(owner);
  await h.q(`select decide_join_request($1, true, '')`, [bobReq]);
  h.eq('owner accepts too', await isMember(A, bob), true);
  // Site-banned accounts: can not apply, can not be accepted.
  const eve = await h.signup('eve@test.dev', 'eve');
  await h.as(eve);
  h.eq('eve applies', (await apply('gatedlink', 'hi')).status, 'pending');
  await h.admin();
  await h.q(`insert into site_bans (user_id) values ($1)`, [eve]);
  const eveReq = (await h.one(`select id from server_join_requests where user_id = $1`, [eve])).id;
  await h.as(mod);
  await h.fails('accept refused for a site-banned account', `select decide_join_request($1, true, '')`, [eveReq]);
  await h.q(`select decide_join_request($1, false, '')`, [eveReq]);
  await h.as(eve);
  await h.fails('site-banned can not apply', `select apply_to_server('openlink', 'hi', '{}')`);

  // Who skips the form: staff, the owner, and skip links.
  await h.as(staff);
  h.eq('staff: no form', (await info('gatedlink')).apply, false);
  h.eq('staff joins straight away', (await apply('gatedlink')).joined, true);
  await h.as(plain);
  await h.fails('a plain member can not make a skip link', `select skip_apply_invite($1)`, [A]);
  await h.as(mod);
  const skip = (await h.one(`select skip_apply_invite($1) c`, [A])).c;
  h.eq('skip link made once', (await h.one(`select skip_apply_invite($1) c`, [A])).c, skip);
  h.eq('skip link flagged', (await h.one(`select skip_apply, created_by from invites where code = $1`, [skip])), { skip_apply: true, created_by: mod });
  await h.as(plain);
  await h.fails('a plain member can not insert a skip link through the table', `insert into invites (code, server_id, created_by, skip_apply) values ('plebskip1', $1, $2, true)`, [A, plain]);
  h.eq('a plain member can not see the skip link', (await h.one(`select count(*)::int n from invites where code = $1`, [skip])).n, 0);
  h.eq('a plain member still sees normal links', (await h.one(`select count(*)::int n from invites where code = 'gatedlink'`)).n, 1);
  await h.as(mod);
  h.eq('the maker sees it', (await h.one(`select count(*)::int n from invites where code = $1`, [skip])).n, 1);
  const carl = await h.signup('carl@test.dev', 'carl');
  await h.as(carl);
  h.eq('skip link: no form', (await info(skip)).apply, false);
  h.eq('skip link joins straight away', (await apply(skip)).joined, true);
  h.eq('carl is in', await isMember(A, carl), true);
  await h.admin();
  h.eq('skip link use counted', (await h.one(`select uses from invites where code = $1`, [skip])).uses, 1);

  // Turning it off opens the door again.
  await h.as(owner);
  await h.q(`select set_join_apply($1, false, '{}')`, [A]);
  const dan = await h.signup('dan@test.dev', 'dan');
  await h.as(dan);
  h.eq('setting off: plain join works', (await h.one(`select join_server('gatedlink') id`)).id, A);
  h.eq('member count sane', await members(A), 7);
}
