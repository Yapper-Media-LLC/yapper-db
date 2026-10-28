// 282 private server lookups (applied live as 277_private_server_lookups). PGlite can't replay migrations 025+, so this starts from stage 24 and adds stand-ins for the
// columns / tables the live functions read (member_count, discoverable, profiles.server_tag, presence, the ban bookkeeping).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const base = 24;

const STANDINS = `
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.servers add column if not exists description text;
alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.servers add column if not exists tag text;
alter table public.server_members add column if not exists nickname text;
alter table public.profiles add column if not exists server_tag uuid;
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.member_roles add column if not exists manual boolean not null default false;
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.reports add column if not exists message_deleted_by text;
create table if not exists public.presence (user_id uuid, last_seen timestamptz);
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text);
create table if not exists public.media_purge (path text, bucket text, done_at timestamptz);
create table if not exists public.media_scans (user_id uuid, verdict text, forgiven boolean not null default false);
create or replace function public.is_site_mod() returns boolean language sql stable as $$ select false $$;
create or replace function public.mod_guard(a text, b uuid, c text) returns void language plpgsql as $$ begin end $$;
-- The live is_site_banned (callable by signed-in users until 277), a bug_reports table with the live "file a bug"
-- policy that calls it, and a security definer function that uses it, like the ~20 live ones.
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
revoke all on function public.is_site_banned(uuid) from public, anon;
grant execute on function public.is_site_banned(uuid) to authenticated, service_role;
create table if not exists public.bug_reports (id uuid primary key default gen_random_uuid(), user_id uuid not null, title text);
alter table public.bug_reports enable row level security;
grant select, insert on public.bug_reports to authenticated;
create policy "file a bug" on public.bug_reports for insert to authenticated with check (user_id = auth.uid() and not public.is_site_banned(auth.uid()));
create or replace function public.ban_probe(uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$ select public.is_site_banned(uid) $$;
revoke all on function public.ban_probe(uuid) from public, anon;
grant execute on function public.ban_probe(uuid) to authenticated;
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '282_private_server_lookups.sql'), 'utf8'));
  await h.ok('277 re-runs cleanly', () => h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '282_private_server_lookups.sql'), 'utf8')));

  const a = await h.signup('a277@example.com', 'a277'); // owns the private server
  const b = await h.signup('b277@example.com', 'b277'); // in a server of their own, not in the private one
  const c = await h.signup('c277@example.com', 'c277'); // member of the private server
  await h.admin();
  const mk = async (name, owner, members, extra = '') => {
    const s = (await h.one(`insert into servers (name, owner_id, member_count, tag, description) values ($1, $2, $3, $4, $5) returning id`, [name, owner, members.length, name.slice(0, 3).toUpperCase(), `about ${name}`])).id;
    for (const m of members) await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [s, m]);
    if (extra) await h.q(extra, [s]);
    return s;
  };
  const priv = await mk('private277', a, [a, c]);
  const mine = await mk('mine277', b, [b]);
  const pub = await mk('public277', a, [a], `update servers set discoverable = true where id = $1`);

  const slice = async (who, sids) => { await h.as(who); const r = await h.q(`select server_id, user_id from server_members_slice($1::uuid[])`, [sids]); await h.admin(); return r; };
  const counts = async (who, sids) => { await h.as(who); const r = await h.q(`select server_id, n::int n from server_member_counts($1::uuid[])`, [sids]); await h.admin(); return r; };
  const people = (rows, sid) => rows.filter((r) => r.server_id === sid).map((r) => r.user_id).sort();

  // Member lists and counts: only for servers you are in.
  h.eq('a non-member gets nothing for a private server', await slice(b, [priv]), []);
  h.eq('asking for your own server and a private one gives only your own', people(await slice(b, [mine, priv]), mine), [b]);
  h.eq('...and no row for the private one', (await slice(b, [mine, priv])).some((r) => r.server_id === priv), false);
  h.eq('a member sees the whole list', people(await slice(a, [priv, pub]), priv), [a, c].sort());
  h.eq('a member sees every server they are in', (await slice(a, [priv, pub, mine])).map((r) => r.server_id).sort(), [priv, priv, pub].sort());
  h.eq('an empty list is fine', await slice(a, []), []);
  h.eq('a server that does not exist is fine', await slice(a, ['00000000-0000-4000-8000-000000000000']), []);
  h.eq('signed-out callers get nothing', await slice(null, [priv]).catch(() => []), []);
  h.eq('a non-member gets no count for a private server', await counts(b, [priv]), []);
  h.eq('a non-member only gets the counts of their own servers', await counts(b, [priv, mine]), [{ server_id: mine, n: 1 }]);
  h.eq('a member gets the count', await counts(c, [priv]), [{ server_id: priv, n: 2 }]);

  // The big-server path (more than 3000 members) filters the same way.
  await h.q(`update servers set member_count = 3001 where id = $1`, [priv]);
  h.eq('big server: a non-member gets nothing', await slice(b, [priv]), []);
  h.eq('big server: a member still gets their own row', people(await slice(c, [priv]), priv).includes(c), true);
  await h.q(`update servers set member_count = 2 where id = $1`, [priv]);

  // Tag cards: a member, a public server, or a server somebody wears the tag of. Not a private server found by its id.
  const card = async (who, sid) => { await h.as(who); const r = (await h.one(`select tag_server($1) t`, [sid])).t; await h.admin(); return r; };
  h.eq('a non-member can not look up a private server by id', await card(b, priv), null);
  h.eq('a server that does not exist gives nothing', await card(b, '00000000-0000-4000-8000-000000000000'), null);
  h.eq('a public server gives its card', (await card(b, pub))?.name, 'public277');
  h.eq('a public server says you are not in it', (await card(b, pub))?.joined, false);
  h.eq('a member gets the card of their private server', [(await card(c, priv))?.name, (await card(c, priv))?.joined, (await card(c, priv))?.member_count], ['private277', true, 2]);
  await h.q(`update servers set member_count = 7 where id = $1`, [priv]);
  h.eq('the card reads the stored member count instead of counting rows', (await card(c, priv))?.member_count, 7);
  await h.q(`update servers set member_count = 2 where id = $1`, [priv]);
  await h.q(`update profiles set server_tag = $1 where id = $2`, [priv, c]);
  h.eq('once somebody wears its tag the card answers (the tag opens it)', (await card(b, priv))?.name, 'private277');
  h.eq('...and is marked private', (await card(b, priv))?.discoverable, false);
  await h.q(`update profiles set server_tag = null where id = $1`, [c]);
  h.eq('...and stops when the tag is gone', await card(b, priv), null);

  // site_unban: non-staff get the same refusal whether or not the user is banned.
  await h.q(`insert into site_admins (user_id) values ($1)`, [a]);
  await h.q(`insert into site_bans (user_id, reason, banned_by) values ($1, 'test', $2)`, [c, a]);
  const msg = async (who, uid) => {
    await h.as(who);
    try { await h.q(`select site_unban($1)`, [uid]); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  h.eq('a plain account is refused for a banned user', await msg(b, c), 'Moderators only');
  h.eq('...and for a user who is not banned', await msg(b, a), 'Moderators only');
  h.eq('...and for an id that belongs to nobody', await msg(b, '00000000-0000-4000-8000-000000000000'), 'Moderators only');
  h.eq('the ban is still there', (await h.one(`select expires_at from site_bans where user_id = $1`, [c])).expires_at, null);
  h.eq('an admin can lift a ban', await msg(a, c), 'ok');
  h.eq('...and it ends now', (await h.one(`select expires_at is not null lifted from site_bans where user_id = $1`, [c])).lifted, true);
  h.eq('...and is logged', (await h.one(`select count(*)::int n from mod_log where action = 'unban' and target_id = $1`, [c])).n, 1);
  h.eq('an admin lifting nobody is fine', await msg(a, '00000000-0000-4000-8000-000000000000'), 'ok');

  // is_site_banned(uid) is not an oracle any more, and the policy and the definer functions that use it still work.
  const canRun = async (role, fn) => (await h.one(`select has_function_privilege($1, $2, 'execute') r`, [role, fn])).r;
  h.eq('signed-in users can not call is_site_banned', await canRun('authenticated', 'public.is_site_banned(uuid)'), false);
  h.eq('...nor anon', await canRun('anon', 'public.is_site_banned(uuid)'), false);
  h.eq('...the service role and postgres still can', [await canRun('service_role', 'public.is_site_banned(uuid)'), await canRun('postgres', 'public.is_site_banned(uuid)')], [true, true]);
  await h.q(`update site_bans set expires_at = null where user_id = $1`, [c]); // c is banned again (the unban above ended it)
  const pol = await h.one(`select cmd, array_to_string(roles, ',') roles from pg_policies where tablename = 'bug_reports' and policyname = 'file a bug'`);
  h.eq('the "file a bug" policy is still an INSERT policy for signed-in users', [pol.cmd, pol.roles], ['INSERT', 'authenticated']);
  h.eq('no policy calls is_site_banned any more', (await h.one(`select count(*)::int n from pg_policies where coalesce(qual, '') || ' ' || coalesce(with_check, '') ~ '\\mis_site_banned\\M'`)).n, 0);
  await h.as(b);
  await h.fails('a plain account asking about a banned user gets an error, not an answer', `select is_site_banned($1)`, [c]);
  await h.fails('...and about a user who is not banned', `select is_site_banned($1)`, [a]);
  h.eq('a security definer function that uses it still answers', (await h.one(`select ban_probe($1) r`, [c])).r, true);
  h.eq('...for a user who is not banned', (await h.one(`select ban_probe($1) r`, [b])).r, false);
  h.eq('am_i_site_banned: not banned', (await h.one(`select am_i_site_banned() r`)).r, false);
  await h.ok('filing a bug still works for an account that is not banned', () => h.q(`insert into bug_reports (user_id, title) values ($1, 'hi')`, [b]));
  await h.as(c);
  h.eq('am_i_site_banned: banned', (await h.one(`select am_i_site_banned() r`)).r, true);
  await h.fails('a banned account can not file a bug', `insert into bug_reports (user_id, title) values ($1, 'hi')`, [c]);
  await h.as(b);
  await h.fails('nobody files a bug as somebody else', `insert into bug_reports (user_id, title) values ($1, 'hi')`, [a]);
  await h.as(null);
  await h.fails('signed-out callers can not ask am_i_site_banned', `select am_i_site_banned()`);
  await h.admin();
  h.eq('am_i_site_banned runs for signed-in users and the service, not anon', [await canRun('authenticated', 'public.am_i_site_banned()'), await canRun('service_role', 'public.am_i_site_banned()'), await canRun('anon', 'public.am_i_site_banned()')], [true, true, false]);
}
