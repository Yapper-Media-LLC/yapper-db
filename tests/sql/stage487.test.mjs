// 487: new-member wait fixes. Reactions get the account-age waits messages have (HQ's and a server's new account
// rule, chat mode), and a rejoin restarts the "member for 5 minutes" wait..
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '487_member_wait_fixes.sql'), 'utf8');
export const base = 24;
export const extra = ['105_first_joins.sql'];

// Stand-ins for what 193 / 333 / later migrations add live (PGlite stops at 025).
const STUBS = `
alter table auth.users add column if not exists email_confirmed_at timestamptz;
alter table public.servers add column if not exists verification_level smallint not null default 0;
alter table public.servers add column if not exists raid_until timestamptz;
alter table public.servers add column if not exists raid_reset_at timestamptz;
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.servers add column if not exists new_account_minutes int;
alter table public.servers add column if not exists new_account_mode text not null default 'join';
create table if not exists public.raid_hits (server_id uuid, user_id uuid, at timestamptz default now(), primary key (server_id, user_id));
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql as $$ select true $$;
create or replace function public.raid_exempt(sid uuid, uid uuid) returns boolean language sql as $$ select false $$;
create or replace function public.raid_threshold(members int) returns int language sql as $$ select 8 $$;
create or replace function public.raid_fire(sid uuid) returns void language sql as $$ select $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql as $$ select false $$;
create or replace function public.server_perm_user(sid uuid, uid uuid, p text) returns boolean language sql as $$ select false $$;
create or replace function public.short_wait(until timestamptz) returns text language sql stable as $$
  select greatest(1, ceil(extract(epoch from (until - now()))))::int || ' seconds' $$;
create or replace function public.new_account_label(mins int) returns text language sql immutable as $$ select mins || ' minutes' $$;
create or replace function public.wait_label(until timestamptz) returns text language sql stable as $$
  select greatest(1, ceil(extract(epoch from (until - now())) / 60))::int || ' min' $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STUBS);
  await h.ok('487 runs', () => h.db.exec(MIG));
  await h.ok('487 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create trigger reactions_verification_guard before insert on public.reactions
    for each row execute function public.reaction_verification_guard()`);

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.admin();
  // HQ's wait is tested on its own server; keep it off the others.
  await h.q(`update app_settings set default_server_id = null`);
  const mk = async (name) => {
    const sid = (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, a])).id;
    const cid = (await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', 'c', $1, $2, 0) returning id`, [sid, a])).id;
    await h.db.exec(`set session_replication_role = replica`);
    const mid = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi') returning id`, [cid, a])).id;
    await h.db.exec(`set session_replication_role = origin`);
    return { sid, mid };
  };
  const asUid = async (uid) => { await h.admin(); await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [uid]); };
  const react = (uid, mid, e = '👍') => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [mid, uid, e]);
  const err = (p) => p.then(() => 'ok', (e) => e.message);
  const join_ = (sid, uid) => h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, uid]);
  const leave = (sid, uid) => h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, uid]);

  // ---------- 1. new account rule (chat mode) now covers reactions ----------
  const s1 = await mk('S1');
  await join_(s1.sid, b);
  await h.q(`update servers set new_account_minutes = 60, new_account_mode = 'chat' where id = $1`, [s1.sid]);
  await asUid(b);
  h.eq('new account rule refuses a reaction', (await err(react(b, s1.mid))).startsWith('New accounts can\'t react here until they\'re 60 minutes old'), true);
  await h.admin();
  await h.q(`update servers set new_account_mode = 'join' where id = $1`, [s1.sid]);
  await asUid(b);
  await h.ok('join mode: reacting is fine once in', () => react(b, s1.mid));
  await h.admin();
  await h.q(`update servers set new_account_mode = 'chat' where id = $1`, [s1.sid]);
  await h.q(`update profiles set created_at = now() - interval '2 hours' where id = $1`, [b]);
  await asUid(b);
  await h.ok('old enough: reacting is fine', () => react(b, s1.mid, '🔥'));
  await h.admin();
  await h.q(`update profiles set created_at = now() where id = $1`, [b]);
  await asUid(b);
  await h.db.exec(`select set_config('yapper.bot', '1', false)`);
  await h.ok('yapper.bot skips it', () => react(b, s1.mid, '😎'));
  await h.db.exec(`select set_config('yapper.bot', '', false)`);
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [a]);
  await asUid(a);
  await h.ok('an old account is never asked', () => react(a, s1.mid));

  // ---------- 1b. HQ's wait covers reactions ----------
  const hq = await mk('HQ');
  await join_(hq.sid, b);
  await h.q(`update app_settings set default_server_id = $1, new_account_wait = interval '10 minutes'`, [hq.sid]);
  await asUid(b);
  h.eq('HQ wait refuses a reaction', (await err(react(b, hq.mid))).startsWith('Welcome! New accounts can react here'), true);
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '11 minutes' where id = $1`, [b]);
  await asUid(b);
  await h.ok('after the HQ wait: fine', () => react(b, hq.mid));
  await h.admin();
  await h.q(`update app_settings set default_server_id = null`);

  // ---------- 2. rejoin restarts the member wait ----------
  const s2 = await mk('S2');
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [b]);
  await h.q(`update servers set verification_level = 2 where id = $1`, [s2.sid]);
  await join_(s2.sid, b);
  // Joined 20 minutes ago: past the wait.
  await h.q(`update server_members set joined_at = now() - interval '20 minutes' where server_id = $1 and user_id = $2`, [s2.sid, b]);
  await h.q(`update server_first_joins set first_joined_at = now() - interval '20 minutes', last_joined_at = now() - interval '20 minutes' where server_id = $1 and user_id = $2`, [s2.sid, b]);
  await asUid(b);
  await h.ok('member for 20 min: can react', () => react(b, s2.mid));
  await h.admin();
  await leave(s2.sid, b);
  await join_(s2.sid, b);
  const row = await h.one(`select (joined_at < now() - interval '19 minutes') kept_first from server_members where server_id = $1 and user_id = $2`, [s2.sid, b]);
  h.eq('joined_at still holds the first join (105)', row.kept_first, true);
  const f = await h.one(`select (last_joined_at > now() - interval '1 minute') fresh from server_first_joins where server_id = $1 and user_id = $2`, [s2.sid, b]);
  h.eq('last_joined_at is the rejoin', f.fresh, true);
  await asUid(b);
  h.eq('rejoined: the 5 minute wait starts over', (await err(react(b, s2.mid, '🔥'))).startsWith('This server needs you to be a member for 5 minutes'), true);
  const gate = await h.one(`select public.server_gate($1, $2, false) why`, [s2.sid, b]);
  h.eq('server_gate (messages too) says wait', (gate.why ?? '').startsWith('This server needs you to be a member for 5 minutes'), true);
  await h.admin();
  await h.q(`update server_first_joins set last_joined_at = now() - interval '6 minutes' where server_id = $1 and user_id = $2`, [s2.sid, b]);
  await asUid(b);
  await h.ok('6 minutes after the rejoin: fine', () => react(b, s2.mid, '🔥'));
  // Clicking an invite to a server you're already in is a no-op insert: the wait must not restart.
  await h.admin();
  await join_(s2.sid, b);
  const still = await h.one(`select (last_joined_at < now() - interval '5 minutes') old from server_first_joins where server_id = $1 and user_id = $2`, [s2.sid, b]);
  h.eq('repeat join of a member: last_joined_at unchanged', still.old, true);

  // A first-ever join sets both times.
  await h.admin();
  const c = await h.signup('c@test.dev', 'carol');
  await join_(s2.sid, c);
  const fc = await h.one(`select first_joined_at = last_joined_at same from server_first_joins where server_id = $1 and user_id = $2`, [s2.sid, c]);
  h.eq('first join: first = last', fc.same, true);
}
