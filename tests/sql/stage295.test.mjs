// 295: invite codes made by the database; no staff oracle on server_bans; custom emoji reactions can't be
// duplicated by renaming; username limit message says when.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '295_bug_fixes_1019.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    alter table public.invites add column if not exists vanity boolean not null default false;
    alter table public.emojis add column if not exists animated boolean not null default false;
    create table if not exists public.staff_standin (user_id uuid primary key);
    create or replace function public.is_staff_user(u uuid) returns boolean language sql stable security definer set search_path = public
      as $$ select exists (select 1 from public.staff_standin where user_id = u) $$;
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
      as $$ select public.is_staff_user(auth.uid()) $$;
    create or replace function public.reaction_emoji_ok(e text) returns boolean language sql immutable as $$ select e = '👍' $$;
    create table if not exists public.reaction_roles (message_id uuid, emoji text);
    create table if not exists public.username_changes (id bigserial primary key, user_id uuid not null, at timestamptz not null default now());
    grant insert on public.server_bans to authenticated;
    grant all on public.username_changes to authenticated;
    grant usage, select on all sequences in schema public to authenticated;
  `);
  await h.db.exec(MIG);
  await h.ok('295 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`
    drop trigger if exists invites_random_code on public.invites;
    create trigger invites_random_code before insert on public.invites for each row execute function public.invite_random_code();
    drop trigger if exists server_bans_no_staff on public.server_bans;
    create trigger server_bans_no_staff before insert on public.server_bans for each row execute function public.no_banning_staff();
    drop trigger if exists reactions_emoji_guard on public.reactions;
    create trigger reactions_emoji_guard before insert on public.reactions for each row execute function public.reaction_emoji_guard();
    drop trigger if exists profiles_username_limit on public.profiles;
    create trigger profiles_username_limit before update of username on public.profiles for each row execute function public.username_change_limit();
  `);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  await h.q(`insert into staff_standin values ($1)`, [bob]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  const ch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('c', 'text', $1, $2) returning id`, [sid, amy])).id;

  const inv = await h.one(`insert into invites (code, server_id, created_by) values ('helloooo', $1, $2) returning code`, [sid, amy]);
  h.eq('picked invite code is replaced', inv.code !== 'helloooo' && /^[A-Za-z0-9]{10}$/.test(inv.code), true);
  const van = await h.one(`insert into invites (code, server_id, created_by, vanity) values ('mylink', $1, $2, true) returning code`, [sid, amy]);
  h.eq('custom links keep their code', van.code, 'mylink');

  await h.as(amy);
  await h.fails('app users can’t insert bans straight into the table', `insert into server_bans (server_id, user_id) values ($1, $2)`, [sid, bob]);
  await h.admin();
  await h.fails('staff still can’t be banned by the service side', `insert into server_bans (server_id, user_id) values ($1, $2)`, [sid, bob]);

  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi') returning id`, [ch, amy])).id;
  const em = (await h.one(`insert into emojis (owner_id, name, path, server_id) values ($1::uuid, 'cat', $1::text || '/cat.png', $2) returning id`, [amy, sid])).id;
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [msg, amy, `<:dog:${em}>`]);
  h.eq('custom emoji stored under its real name', (await h.one(`select emoji from reactions where message_id = $1`, [msg])).emoji, `<:cat:${em}>`);
  const msg2 = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'roles') returning id`, [ch, bob])).id;
  await h.q(`insert into reaction_roles (message_id, emoji) values ($1, $2)`, [msg2, `<:oldname:${em}>`]);
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [msg2, amy, `<:oldname:${em}>`]);
  h.eq('reaction role text wins after a rename', (await h.one(`select emoji from reactions where message_id = $1`, [msg2])).emoji, `<:oldname:${em}>`);
  await h.fails('same emoji under another name is a duplicate', `insert into reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [msg, amy, `<a:zzz:${em}>`]);

  await h.q(`insert into username_changes (user_id, at) select $1, now() - (g || ' hours')::interval from generate_series(1, 5) g`, [amy]);
  await h.as(amy);
  let err = '';
  try { await h.q(`update profiles set username = 'amy2' where id = $1`, [amy]); } catch (e) { err = e.message; }
  h.eq('limit message says when', /in the last 24 hours\. You can change it again in \d+ h/.test(err), true);
  await h.admin();
}
