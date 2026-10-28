// 533: server lobby (flag server_lobby). Members read it, only managers write it through set_server_lobby, and the
// RPC cleans what it's given (trim, filter, FAQ shape, featured channels from this server only, limits).
// Starts from stage 24 with stand-ins for server_perm (as in 504/517), the text filters, audit_add and channels.ticket_by.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('533_server_lobby.sql');

const STANDINS = String.raw`
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.channels add column if not exists ticket_by uuid;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.has_slur(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badword%' $$;
create or replace function public.has_sexual_spam(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%spamword%' $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select coalesce(t, '') ilike '%badsite.com%' $$;
create table if not exists public.audit_seen (sid uuid, act text, actor uuid, extra jsonb);
create or replace function public.audit_add(sid uuid, act text, kind text, tid uuid, tname text, extra jsonb default '{}'::jsonb)
 returns void language sql security definer set search_path = public as $$ insert into public.audit_seen values (sid, act, auth.uid(), extra) $$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`533 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('533 runs', () => h.db.exec(MIG));
  await h.ok('533 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag server_lobby in test', (await h.one(`select mode from feature_flags where key = 'server_lobby'`))?.mode, 'test');

  const owner = await h.signup('o@x.com', 'owner');
  const mgr = await h.signup('m@x.com', 'manager');
  const member = await h.signup('p@x.com', 'plain');
  const outsider = await h.signup('x@x.com', 'outsider');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const other = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  for (const u of [owner, mgr, member]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [S, u]);
  const mgrRole = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Mods', 1, '{"manage_server": true}'::jsonb) returning id`, [S])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [S, mgr, mgrRole]);
  const chan = async (sid, name) => (await h.one(`insert into channels (server_id, name, kind) values ($1, $2, 'text') returning id`, [sid, name])).id;
  const general = await chan(S, 'general');
  const clips = await chan(S, 'clips');
  const elsewhere = await chan(other, 'theirs');
  const ticket = await chan(S, 'ticket-1');
  await h.q(`update channels set ticket_by = $1 where id = $2`, [member, ticket]);
  const seven = [];
  for (let i = 0; i < 7; i++) seven.push(await chan(S, `c${i}`));

  const call = `select public.set_server_lobby($1, $2, $3::jsonb, $4::uuid[], true)`;
  const save = async (by, about, faq, featured) => { await h.as(by); return h.q(call, [S, about, JSON.stringify(faq), featured]); };
  const lobby = async () => { await h.admin(); return h.one(`select about, faq, featured, show_staff from server_lobby where server_id = $1`, [S]); };

  // The flag gate: refused until the server is in the test list.
  await h.as(owner);
  await h.fails('refused while the flag is off for the server', call, [S, 'hi', '[]', []]);
  await h.admin();
  await h.q(`update feature_flags set servers = array_append(servers, $1) where key = 'server_lobby'`, [S]);

  // Who can write.
  await h.ok('owner saves', () => save(owner, '  Welcome in  ', [{ q: ' How do I get roles? ', a: ' Ask a mod ', extra: 'x' }, { q: '', a: '' }], [clips, general, clips]));
  let row = await lobby();
  h.eq('about trimmed', row.about, 'Welcome in');
  h.eq('faq trimmed, extra keys and blank rows dropped', row.faq, [{ a: 'Ask a mod', q: 'How do I get roles?' }]);
  h.eq('featured in order, duplicate dropped', row.featured, [clips, general]);
  h.eq('show_staff saved', row.show_staff, true);
  await h.ok('manager (Manage Server role) saves', () => save(mgr, 'Hi from the mods', [], [general]));
  h.eq('manager save landed', (await lobby()).about, 'Hi from the mods');
  await h.as(member);
  await h.fails('plain member refused', call, [S, 'mine now', '[]', []]);
  await h.as(outsider);
  await h.fails('outsider refused', call, [S, 'mine now', '[]', []]);
  await h.as(null);
  await h.fails('logged out refused', call, [S, 'mine now', '[]', []]);

  // Who can read.
  await h.as(member);
  h.eq('member reads it', (await h.q(`select about from server_lobby where server_id = $1`, [S])).length, 1);
  await h.as(outsider);
  h.eq('outsider reads nothing', (await h.q(`select about from server_lobby where server_id = $1`, [S])).length, 0);

  // Refusals.
  await h.as(owner);
  await h.fails('channel from another server refused', call, [S, '', '[]', [elsewhere]]);
  await h.fails('ticket channel refused', call, [S, '', '[]', [ticket]]);
  await h.fails('more than 6 channels refused', call, [S, '', '[]', seven]);
  await h.ok('6 channels fine', () => h.q(call, [S, '', '[]', seven.slice(0, 6)]));
  await h.as(owner);
  await h.fails('faq not a list refused', call, [S, '', '{"q":"a"}', []]);
  await h.fails('faq item not an object refused', call, [S, '', '["hi"]', []]);
  await h.fails('question without answer refused', call, [S, '', '[{"q":"Q","a":""}]', []]);
  await h.fails('11 questions refused', call, [S, '', JSON.stringify(Array.from({ length: 11 }, (_, i) => ({ q: `Q${i}`, a: 'A' }))), []]);
  await h.fails('long question refused', call, [S, '', JSON.stringify([{ q: 'x'.repeat(201), a: 'A' }]), []]);
  await h.fails('about over 2000 refused', call, [S, 'x'.repeat(2001), '[]', []]);
  await h.fails('filtered about refused', call, [S, 'this has badword in it', '[]', []]);
  await h.fails('filtered faq refused', call, [S, '', '[{"q":"badword?","a":"no"}]', []]);
  await h.fails('spam in an answer refused', call, [S, '', '[{"q":"hi","a":"spamword"}]', []]);
  await h.fails('blocked link refused', call, [S, 'see badsite.com/x', '[]', []]);
  await h.fails('21 faq items refused before any checks', call, [S, '', JSON.stringify(Array.from({ length: 21 }, () => ({ q: '', a: '' }))), []]);
  await h.fails('13 channel ids refused before any checks', call, [S, '', '[]', Array.from({ length: 13 }, () => general)]);
  await h.ok('ordinary rule text passes (the name filter used to refuse it)', () => h.q(call, [S, 'No porn, no NSFW. Our therapist channel is for support.', '[{"q":"Is NSFW allowed?","a":"No."}]', []]));

  // Every save is in the audit log, by whoever saved.
  await h.admin();
  const seen = await h.q(`select act, actor from audit_seen where sid = $1`, [S]);
  h.eq('saves logged', seen.every((x) => x.act === 'server_update_lobby') && seen.length >= 3, true);
  h.eq('manager save logged as the manager', seen.some((x) => x.actor === mgr), true);
  await h.as(owner);

  // Direct writes are closed, even for the owner.
  await h.fails('owner cannot update the table directly', `update server_lobby set about = 'sneaky' where server_id = $1`, [S]);
  await h.fails('owner cannot insert directly', `insert into server_lobby (server_id, about) values ($1, 'x')`, [other]);
  await h.as(member);
  await h.fails('member cannot remove it directly', `delete from server_lobby where server_id = $1`, [S]);
  h.eq('still the last good save', (await lobby()).about.startsWith('No porn'), true);

  // Gone with the server.
  await h.admin();
  await h.q(`delete from servers where id = $1`, [S]);
  h.eq('lobby goes with its server', (await h.q(`select 1 from server_lobby where server_id = $1`, [S])).length, 0);
}
