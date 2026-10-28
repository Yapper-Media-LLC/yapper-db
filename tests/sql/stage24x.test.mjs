// 160-164 security sweep: bots secrets, reaction emojis, promo RPCs, vanity links, delete account / reauth, gmail_taken.
// PGlite can't replay migrations 025+, so this starts from stage 24 and adds small stand-ins for the live pieces
// these migrations build on, then runs 160-164 (twice, to check they re-run).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const FILES = ['160_bots_secret_grants.sql', '161_reaction_emoji_check.sql', '162_promo_rpc_auth.sql', '163_vanity_hardening.sql', '164_delete_account_confirm.sql'];

const STANDINS = `
create table if not exists public.bots (
  id uuid primary key, owner_id uuid not null, name text not null, tag text, description text default '', category text,
  public boolean not null default false, avatar_path text, presence jsonb, posts int default 0, created_at timestamptz default now(),
  last_used_at timestamptz, last_poll_at timestamptz, last_event_at timestamptz, submitted_at timestamptz, verified_at timestamptz,
  review_note text, token_hash text, token_prefix text, webhook_secret text, webhook_url text);
alter table public.bots enable row level security;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);
grant all on public.bots to anon, authenticated;

create table if not exists public.reaction_roles (message_id uuid, emoji text, role_id uuid, server_id uuid, primary key (message_id, emoji));

create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid());
$$;
create table if not exists public.site_admins (user_id uuid primary key);
create or replace function public.is_site_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = auth.uid());
$$;
create table if not exists public.server_promotions (id uuid default gen_random_uuid(), server_id uuid, kind text, mult int, starts_at timestamptz, ends_at timestamptz);
create or replace function public.discovery_order(q text, x uuid) returns table (id uuid, pos int) language sql stable as $$
  select s.id, (row_number() over (order by s.created_at))::int from public.servers s;
$$;
create or replace function public.discovery_order_m(q text, x uuid, m int) returns table (id uuid, pos int) language sql stable as $$
  select s.id, (row_number() over (order by s.created_at))::int from public.servers s;
$$;
create or replace function public.promo_slots() returns int language sql stable as $$ select 3 $$;
create or replace function public.next_promo_start(sid uuid) returns timestamptz language sql stable as $$ select now() $$;

create or replace function public.lookalike_key(t text) returns text language sql immutable as $$
  select translate(lower(coalesce(t, '')), '013457$@!|', 'oieastsail');
$$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select t ~* 'slurword' $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.invites drop constraint if exists invites_code_check;

alter table auth.users add column if not exists encrypted_password text;
create schema if not exists extensions;
-- Not bcrypt, just enough to tell right from wrong.
create or replace function extensions.crypt(p text, h text) returns text language sql immutable as $$
  select case when h like 'hash:%' then 'hash:' || md5(p) else null end;
$$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
grant usage on schema extensions to anon, authenticated;
create table if not exists auth.mfa_factors (id uuid default gen_random_uuid(), user_id uuid, status text);
create table if not exists public.app_settings (id int primary key default 1, default_server_id uuid);
`;

export default async function (h) {
  await h.db.exec(STANDINS);
  for (const f of FILES) await h.ok(`${f} runs`, () => h.db.exec(mig(f)));
  for (const f of FILES) await h.ok(`${f} re-runs`, () => h.db.exec(mig(f)));

  const a = await h.signup('a@x.com', 'alice');
  const b = await h.signup('b@x.com', 'bob');
  const c = await h.signup('c@x.com', 'carol');

  // ---- 160 bots
  await h.admin();
  await h.q(`insert into public.bots (id, owner_id, name, public, token_hash, token_prefix, webhook_secret, webhook_url)
             values (gen_random_uuid(), $1, 'pub', true, 'h1', 'yb_1', 's1', 'https://a.example/hook'),
                    (gen_random_uuid(), $2, 'mine', false, 'h2', 'yb_2', 's2', 'https://b.example/hook')`, [a, b]);
  await h.as(b);
  await h.fails('others cannot read token_hash', `select token_hash from public.bots`);
  await h.fails('others cannot read webhook_secret', `select webhook_secret from public.bots`);
  await h.fails('others cannot read token_prefix', `select token_prefix from public.bots`);
  await h.fails('webhook_url not on the table', `select webhook_url from public.bots`);
  await h.fails('select * refused', `select * from public.bots`);
  h.eq('public columns still readable', (await h.q(`select name from public.bots order by name`)).map((r) => r.name), ['mine', 'pub']);
  h.eq('my_bot_hooks: only mine', (await h.q(`select webhook_url from public.my_bot_hooks()`)).map((r) => r.webhook_url), ['https://b.example/hook']);
  await h.fails('no direct writes', `update public.bots set name = 'x'`);
  await h.as(null);
  await h.fails('anon reads nothing', `select name from public.bots`);

  // ---- 161 reactions
  await h.admin();
  const std = [...readFileSync(join(here, '..', '..', 'lib', 'emoji.ts'), 'utf8').split('export const TOKEN')[0].matchAll(/\['([^']+)', '[^']*'\]/g)].map((m) => m[1]);
  const extra = ['👍🏽', '👨‍👩‍👧‍👦', '🏳️‍🌈', '🇺🇸', '1️⃣', '#️⃣', '❤️‍🔥', '🫠', '™️', '©️', '⭐', '✅', '🏴󠁧󠁢󠁳󠁣󠁴󠁿', '🧑🏿‍💻'];
  for (const e of [...std, ...extra]) h.eq(`emoji ok: ${e}`, (await h.one(`select public.reaction_emoji_ok($1) ok`, [e])).ok, true);
  for (const e of ['hello', 'https://evil.example/x.png', 'kiddo✅', '🔵he/him', '1', ' ', '\n', ':3', '<script>', '‮', '<:x:1234>', '🔥 🔥'])
    h.eq(`not an emoji: ${JSON.stringify(e)}`, (await h.one(`select public.reaction_emoji_ok($1) ok`, [e])).ok, false);
  const ch = (await h.one(`insert into public.channels (kind, dm_key, created_by) values ('dm', 'test:dm', $1) returning id`, [a])).id;
  await h.db.exec(`alter table public.messages disable trigger user`);
  const msg = (await h.one(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hi') returning id`, [ch, a])).id;
  await h.db.exec(`alter table public.messages enable trigger user`);
  await h.db.exec(`alter table public.emojis disable trigger user`);
  const emo = (await h.one(`insert into public.emojis (owner_id, name, path) values ($1::uuid, 'cat', $1::text || '/cat.png') returning id`, [a])).id;
  await h.db.exec(`alter table public.emojis enable trigger user`);
  await h.q(`insert into public.reactions (message_id, user_id, emoji) values ($1, $2, '🔥')`, [msg, a]);
  await h.q(`insert into public.reactions (message_id, user_id, emoji) values ($1, $2, $3)`, [msg, a, `<:cat:${emo}>`]);
  await h.fails('custom emoji that does not exist', `insert into public.reactions (message_id, user_id, emoji) values ($1, $2, '<:cat:00000000-0000-0000-0000-000000000000>')`, [msg, a]);
  await h.fails('text reaction refused', `insert into public.reactions (message_id, user_id, emoji) values ($1, $2, 'https://evil.example')`, [msg, a]);
  await h.q(`insert into public.reaction_roles (message_id, emoji) values ($1, 'Purple')`, [msg]);
  await h.ok('reaction-role label allowed', () => h.q(`insert into public.reactions (message_id, user_id, emoji) values ($1, $2, 'Purple')`, [msg, b]));

  // ---- 162 promo RPCs
  await h.admin();
  const sa = (await h.one(`insert into public.servers (name, owner_id) values ('A', $1) returning id`, [a])).id;
  await h.as(b);
  await h.fails('non-manager: discovery_rank_tiers', `select public.discovery_rank_tiers($1)`, [sa]);
  await h.fails('non-manager: discovery_rank', `select public.discovery_rank($1)`, [sa]);
  await h.fails('non-manager: promo_availability', `select public.promo_availability($1)`, [sa]);
  await h.as(a);
  h.eq('owner gets tiers', (await h.one(`select public.discovery_rank_tiers($1) ->> 'mult' m`, [sa])).m, '1');
  h.eq('owner gets availability', (await h.one(`select (public.promo_availability($1) ->> 'promo_slots')::int n`, [sa])).n, 3);
  await h.admin();
  await h.q(`insert into public.site_admins values ($1)`, [c]);
  await h.as(c);
  await h.ok('site admin can read', () => h.q(`select public.promo_availability($1)`, [sa]));
  await h.as(null);
  await h.fails('anon cannot call tiers', `select public.discovery_rank_tiers($1)`, [sa]);

  // ---- 163 vanity
  await h.admin();
  for (let i = 0; i < 5; i++) {
    const u = await h.signup(`m${i}@x.com`, `member${i}`);
    await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2)`, [sa, u]);
  }
  await h.as(a);
  for (const bad of ['admln', 'adm1n', 'ad-min', 'adrnin', 'YAPPERS', 'help', 'he1p', 'security', 'root', 'api', 'www', 'cdn', 'app', 'dev', 'staging', 'test', 'bot', 'mail', 'm0d', 'Support', 'admiiin', 'addmin', 'yappper', 'suppport', 'discorrd', 'modd', 'h-e-l-l-p'])
    await h.fails(`vanity refused: ${bad}`, `select public.set_vanity_invite($1, $2)`, [sa, bad]);
  for (const good of ['coolkids', 'chill-zone', 'lofi', 'animeclub', 'solarsystem'])
    h.eq(`vanity ok: ${good}`, (await h.one(`select public.set_vanity_invite($1, $2) c`, [sa, good])).c, good);
  h.eq('same link again is free', (await h.one(`select public.set_vanity_invite($1, 'solarsystem') c`, [sa])).c, 'solarsystem');
  await h.fails('6th change in an hour refused', `select public.set_vanity_invite($1, 'another1')`, [sa]);
  await h.as(b);
  await h.fails('non-manager refused', `select public.set_vanity_invite($1, 'bobsplace')`, [sa]);
  await h.fails('vanity_changes not readable', `select * from public.vanity_changes`);

  // ---- 164 reauth / delete account
  await h.admin();
  await h.q(`update auth.users set encrypted_password = 'hash:' || md5('right-pw')`);
  await h.as(b);
  h.eq('right password passes', (await h.one(`select public.reauth_check('right-pw') r`)).r, null);
  h.eq('wrong password says so', (await h.one(`select public.reauth_check('nope') r`)).r, 'That password isn\'t right');
  h.eq('delete with wrong password refused', (await h.one(`select public.delete_my_account('nope') r`)).r, 'That password isn\'t right');
  await h.fails('old no-arg delete is gone', `select public.delete_my_account()`);
  await h.fails('attempt log not readable', `select * from public.reauth_attempts`);
  for (let i = 0; i < 3; i++) await h.q(`select public.reauth_check('nope')`);
  h.eq('locked after 5 wrong tries', (await h.one(`select public.reauth_check('right-pw') r`)).r, 'Too many wrong passwords. Try again later');
  await h.as(c);
  await h.admin();
  await h.q(`insert into auth.mfa_factors (user_id, status) values ($1, 'verified')`, [c]);
  await h.as(c);
  h.eq('2FA account needs aal2', (await h.one(`select public.reauth_check('right-pw') r`)).r, 'Enter your 2FA code first');
  await h.db.exec(`select set_config('request.jwt.claims', '{"aal":"aal2"}', false)`);
  h.eq('aal2 passes', (await h.one(`select public.reauth_check('right-pw') r`)).r, null);
  await h.db.exec(`select set_config('request.jwt.claims', '', false)`);
  await h.as(a);
  await h.admin();
  // alice owns server A: deleting her cascades it; fine here.
  await h.as(a);
  h.eq('delete with right password', (await h.one(`select public.delete_my_account('right-pw') r`)).r, null);
  await h.admin();
  h.eq('alice is gone', (await h.one(`select count(*)::int n from auth.users where id = $1`, [a])).n, 0);

  // ---- gmail_taken
  await h.signup('test.123@gmail.com', 'gm1');
  h.eq('dots ignored', (await h.one(`select public.gmail_taken('test123@gmail.com') t`)).t, true);
  h.eq('googlemail same inbox', (await h.one(`select public.gmail_taken('t.e.s.t123@googlemail.com') t`)).t, true);
  h.eq('other gmail free', (await h.one(`select public.gmail_taken('test124@gmail.com') t`)).t, false);
  h.eq('not gmail: no check', (await h.one(`select public.gmail_taken('test123@outlook.com') t`)).t, false);
  await h.as(b);
  await h.fails('gmail_taken is service-only', `select public.gmail_taken('x@gmail.com')`);
}
