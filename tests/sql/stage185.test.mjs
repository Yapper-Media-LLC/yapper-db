// 185: verified bots. The verified_bot badge follows verify / unverify / withdraw / delete, the backfill, nobody can
// give it to themselves, public_bots() shows only verified public bots with safe columns (anon too) and nothing while
// the flag is off for the caller, support_invite validation and its FK to invites (renames follow, deletes clear),
// bot_add_targets().
// PGlite can't replay every migration, so: 001..024, flags (031, 041), stand-ins for the live bot pieces (the bots
// table with its live columns, 117's submit trigger, 160's grants) and the live definitions 185 leans on, copied
// verbatim from the live database (read-only, Oct 17), then 185 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists verified_as text;
alter table public.profiles add column if not exists plus_until timestamptz;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.profiles add column if not exists voice_muted_until timestamptz;
alter table public.profiles add column if not exists stripe_customer text;
alter table public.profiles add column if not exists server_tag uuid;
alter table public.profiles add column if not exists tag text;
alter table public.profiles add column if not exists discriminator text;
revoke update (id, created_at, badges, plus_until, verified_as, muted_until, muted_reason, voice_muted_until, stripe_customer)
  on public.profiles from authenticated, anon;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz, suspended_reason text);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
end $$;

-- bots with its live columns (103 + 109 + 117 + 121 + 127 + 133).
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null, description text not null default '', token_hash text, token_prefix text,
  webhook_url text, webhook_secret text, public boolean not null default false,
  created_at timestamptz not null default now(), last_used_at timestamptz, posts bigint not null default 0,
  last_poll_at timestamptz, last_event_at timestamptz, submitted_at timestamptz, verified_at timestamptz,
  review_note text, presence jsonb, category text default 'other', avatar_path text, tag text
);
alter table public.bots enable row level security;
create policy "bots visible" on public.bots for select to authenticated using (owner_id = auth.uid() or public);
create table if not exists public.bot_servers (
  bot_id uuid not null references public.bots(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  added_by uuid, added_at timestamptz not null default now(),
  primary key (bot_id, server_id)
);
alter table public.bot_servers enable row level security;
-- 160
revoke all on public.bots from anon, authenticated;
grant select (id, owner_id, name, tag, description, category, public, avatar_path, presence, posts,
              created_at, last_used_at, last_poll_at, last_event_at, submitted_at, verified_at, review_note)
  on public.bots to authenticated;
-- 117
create or replace function public.bot_public_submit() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.public and not coalesce(old.public, false) then
    new.submitted_at := now();
    new.verified_at := null;
    new.review_note := null;
  elsif not new.public then
    new.verified_at := null;
  end if;
  return new;
end $$;
create or replace trigger bots_public_submit before update of public on public.bots for each row execute function public.bot_public_submit();
-- 047: vanity-style invite codes.
alter table public.invites drop constraint if exists invites_code_check;
alter table public.invites add constraint invites_code_check check (code ~ '^[A-Za-z0-9_-]{3,32}$');
alter table public.invites add column if not exists vanity boolean not null default false;
insert into public.feature_flags (key, label, description, mode) values ('bot_api', 'Bot API', 'Bots', 'everyone') on conflict (key) do update set mode = 'everyone';
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.admin_set_badge(uid uuid, badge text, on_off boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff') then raise exception 'Unknown badge'; end if;
  perform public.mod_guard('badge', uid, null);
  update public.profiles set badges = case when on_off then array(select distinct unnest(badges || badge)) else array_remove(badges, badge) end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

CREATE OR REPLACE FUNCTION public.admin_verify_bot(bid uuid, ok boolean, note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if ok then
    update public.bots set verified_at = now(), review_note = null where id = bid;
  else
    update public.bots set public = false, verified_at = null, review_note = left(coalesce(note, 'Not approved'), 300) where id = bid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid,
            left(coalesce(nullif(btrim(note), ''), case when ok then 'Approved' else 'Not approved' end) || ' [' || coalesce((select name from public.bots where id = bid), 'bot') || ']', 500));
end $function$;

CREATE OR REPLACE FUNCTION public.bot_add_to_server(bid uuid, sid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  if not exists (select 1 from public.bots b where b.id = bid and (b.owner_id = auth.uid() or (b.public and b.verified_at is not null))) then
    raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $function$;

CREATE OR REPLACE FUNCTION public.feature_on_for_me(k text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$function$;

CREATE OR REPLACE FUNCTION public.feature_on(k text, sid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false);
$function$;

CREATE OR REPLACE FUNCTION public.protect_profile_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if current_user = 'authenticated' and not public.is_site_admin() then
    new.id := old.id; new.created_at := old.created_at; new.verified_as := old.verified_as; new.plus_until := old.plus_until;
    new.muted_until := old.muted_until; new.muted_reason := old.muted_reason; new.voice_muted_until := old.voice_muted_until;
    new.stripe_customer := old.stripe_customer; new.badges := old.badges;
    new.server_tag := old.server_tag; new.tag := old.tag; new.discriminator := old.discriminator;
  end if;
  return new;
end; $function$;
drop trigger if exists profiles_0_protect on public.profiles;
create trigger profiles_0_protect before update on public.profiles for each row execute function public.protect_profile_columns();
`;

export default async function (h) {
  const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '185_bot_verified.sql'), 'utf8');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);

  const adm = await h.signup('adm@test.dev', 'adm');
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const old = await h.signup('old@test.dev', 'oldbot');     // verified before 185: backfill
  const stray = await h.signup('stray@test.dev', 'straybot'); // has the badge but isn't verified: backfill removes it
  const ab = await h.signup('ab@test.dev', 'amybot');
  const priv = await h.signup('priv@test.dev', 'privbot');
  const pend = await h.signup('pend@test.dev', 'pendbot');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`update profiles set badges = '{bot}' where id in ($1, $2, $3, $4, $5)`, [old, stray, ab, priv, pend]);
  await h.q(`update profiles set badges = '{bot,verified_bot}' where id = $1`, [stray]);
  await h.q(`insert into bots (id, owner_id, name, description, public, verified_at, token_hash, webhook_secret, webhook_url)
             values ($1, $2, 'oldbot', 'Old and trusted, does many things', true, now() - interval '30 days', 'hash1', 'sec1', 'https://x.test/hook')`, [old, amy]);
  await h.q(`insert into bots (id, owner_id, name, description, public) values ($1, $2, 'straybot', 'not verified', false)`, [stray, bob]);

  await h.db.exec(MIGRATION);
  await h.ok('185 re-runs cleanly', () => h.db.exec(MIGRATION));
  const badges = async (id) => { await h.admin(); return (await h.one(`select badges from profiles where id = $1`, [id])).badges; };

  // ---- backfill ----
  h.eq('backfill: verified public bot gets it (after bot)', await badges(old), ['bot', 'verified_bot']);
  h.eq('backfill: unverified bot loses a stray one', await badges(stray), ['bot']);
  h.eq('flag row in test mode, no servers', await h.one(`select mode, servers from feature_flags where key = 'bot_verified'`), { mode: 'test', servers: [] });

  // ---- trigger: verify, unverify (sent back), withdraw, re-submit, delete ----
  await h.q(`insert into bots (id, owner_id, name, description, category, tag) values ($1, $2, 'amybot', 'Moderation helper with logs', 'moderation', '1234')`, [ab, amy]);
  h.eq('new private bot: no badge', await badges(ab), ['bot']);
  await h.q(`update bots set public = true where id = $1`, [ab]); // owner publishes (PATCH /api/bots, service role)
  h.eq('submitted, not verified yet: no badge', await badges(ab), ['bot']);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [ab]);
  h.eq('verified: badge added', await badges(ab), ['bot', 'verified_bot']);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [ab]);
  h.eq('verified twice: still one badge', await badges(ab), ['bot', 'verified_bot']);
  await h.q(`update bots set posts = posts + 1, last_used_at = now() where id = $1`, [ab]);
  h.eq('other updates leave it alone', await badges(ab), ['bot', 'verified_bot']);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, false, 'Needs a better description')`, [ab]);
  h.eq('sent back: badge removed', await badges(ab), ['bot']);
  await h.q(`update bots set public = true where id = $1`, [ab]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [ab]);
  h.eq('verified again', await badges(ab), ['bot', 'verified_bot']);
  await h.q(`update bots set public = false where id = $1`, [ab]); // owner withdraws
  h.eq('withdrawn: badge removed', await badges(ab), ['bot']);
  h.eq('withdrawn: verified_at cleared by 117', (await h.one(`select verified_at from bots where id = $1`, [ab])).verified_at, null);
  await h.q(`update bots set public = true where id = $1`, [ab]);
  await h.as(adm);
  await h.q(`select admin_verify_bot($1, true)`, [ab]);
  h.eq('re-verified after withdraw', await badges(ab), ['bot', 'verified_bot']);
  // Private and pending bots for the directory checks.
  await h.q(`insert into bots (id, owner_id, name, description) values ($1, $2, 'privbot', 'private one, secret stuff')`, [priv, bob]);
  await h.q(`insert into bots (id, owner_id, name, description, public, submitted_at) values ($1, $2, 'pendbot', 'waiting for review', true, now())`, [pend, bob]);
  h.eq('private / pending bots: no badge', [await badges(priv), await badges(pend)], [['bot'], ['bot']]);
  // Deleting the bots row (profile kept) takes the badge away.
  const gone = await h.signup('gone@test.dev', 'gonebot');
  await h.admin();
  await h.q(`insert into bots (id, owner_id, name, public, verified_at) values ($1, $2, 'gonebot', true, now())`, [gone, bob]);
  h.eq('inserted as verified: badge', await badges(gone), ['verified_bot']);
  await h.q(`delete from bots where id = $1`, [gone]);
  h.eq('bot row deleted: badge gone', await badges(gone), []);

  // ---- nobody gives it by hand ----
  await h.as(bob);
  try { await h.q(`update profiles set badges = array['verified_bot'] where id = $1`, [bob]); } catch { /* column grant refused: fine */ }
  h.eq('user can not add verified_bot to themselves', await badges(bob), []);
  await h.as(amy);
  try { await h.q(`update profiles set badges = badges || 'verified_bot'::text where id = $1`, [priv]); } catch { /* fine */ }
  h.eq('or to someone else\'s bot', await badges(priv), ['bot']);
  await h.as(adm);
  await h.fails('admin_set_badge refuses verified_bot', `select admin_set_badge($1, 'verified_bot', true)`, [bob]);
  await h.as(bob);
  await h.fails('the trigger function is not callable', `select bot_verified_badge()`);

  // ---- support_invite ----
  await h.as(adm);
  const help = (await h.one(`select create_server('Help', null) id`)).id;
  await h.admin();
  await h.q(`insert into invites (code, server_id, created_by) values ('amy-Support_1', $1, $2), ('amysupport', $1, $2)`, [help, adm]);
  await h.ok('valid invite code saves', () => h.q(`update bots set support_invite = 'amy-Support_1' where id = $1`, [ab]));
  for (const bad of ['ab', 'has space', 'https://www.yapper.website/invite/x', 'a'.repeat(33), 'semi;colon', 'émoji']) {
    await h.fails(`bad invite refused: ${bad.slice(0, 20)}`, `update bots set support_invite = $2 where id = $1`, [ab, bad]);
  }
  await h.fails('a well-formed code with no invite is refused (FK)', `update bots set support_invite = 'nosuchcode' where id = $1`, [ab]);
  await h.ok('cleared with null', () => h.q(`update bots set support_invite = null where id = $1`, [ab]));
  // FK: a renamed (vanity) invite carries over, a deleted one clears it.
  await h.q(`update bots set support_invite = 'amy-Support_1' where id = $1`, [ab]);
  await h.q(`update invites set code = 'amyhelp' where code = 'amy-Support_1'`);
  h.eq('invite renamed: support_invite follows', (await h.one(`select support_invite from bots where id = $1`, [ab])).support_invite, 'amyhelp');
  await h.q(`delete from invites where code = 'amyhelp'`);
  h.eq('invite deleted: support_invite cleared', (await h.one(`select support_invite from bots where id = $1`, [ab])).support_invite, null);
  // A vanity link removed and made again (delete + insert) doesn't come back on its own: the owner sets it again.
  await h.q(`insert into invites (code, server_id, created_by) values ('amyhelp', $1, $2)`, [help, adm]);
  h.eq('re-created invite: still cleared', (await h.one(`select support_invite from bots where id = $1`, [ab])).support_invite, null);
  await h.q(`update bots set support_invite = 'amysupport' where id = $1`, [ab]);
  await h.as(bob);
  h.eq('signed-in users can read support_invite of a public bot', (await h.one(`select support_invite from bots where id = $1`, [ab])).support_invite, 'amysupport');
  await h.fails('still no secrets for signed-in users', `select webhook_secret from bots where id = $1`, [ab]);

  // ---- public_bots ----
  const list = async (who, args = '') => { await h.as(who); return h.q(`select * from public_bots(${args})`); };
  h.eq('flag test, logged out: nothing', (await list(null)).length, 0);
  h.eq('flag test, not a tester: nothing', (await list(bob)).length, 0);
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'bot_verified'`, [amy]);
  const tester = await list(amy);
  h.eq('flag test, tester: verified public bots only', tester.map((r) => r.name).sort(), ['amybot', 'oldbot']);
  h.eq('safe columns only', Object.keys(tester[0]).sort(),
    ['avatar_path', 'category', 'created_at', 'description', 'id', 'name', 'owner_name', 'servers', 'support_invite', 'tag', 'verified_at']);
  const amyRow = tester.find((r) => r.name === 'amybot');
  h.eq('row content', [amyRow.tag, amyRow.category, amyRow.support_invite, amyRow.owner_name, Number(amyRow.servers)], ['1234', 'moderation', 'amysupport', 'amy', 0]);
  h.eq('no secret values anywhere', JSON.stringify(tester).includes('hash1') || JSON.stringify(tester).includes('sec1') || JSON.stringify(tester).includes('x.test'), false);
  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'bot_verified'`);
  h.eq('flag off: nothing even for a tester', (await list(amy)).length, 0);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'bot_verified'`);
  const anon = await list(null);
  h.eq('flag everyone: anon can call it', anon.map((r) => r.name).sort(), ['amybot', 'oldbot']);
  h.eq('anon still can not read the bots table', await (async () => { await h.as(null); try { await h.q(`select id from bots`); return 'read'; } catch { return 'refused'; } })(), 'refused');

  // Server counts and sorting.
  await h.as(amy);
  const s1 = (await h.one(`select create_server('One', null) id`)).id;
  const s2 = (await h.one(`select create_server('Two', null) id`)).id;
  await h.q(`select bot_add_to_server($1, $2)`, [old, s1]);
  await h.q(`select bot_add_to_server($1, $2)`, [old, s2]);
  await h.q(`select bot_add_to_server($1, $2)`, [ab, s1]);
  const pop = await list(null);
  h.eq('popular: most servers first, with counts', pop.map((r) => [r.name, Number(r.servers)]), [['oldbot', 2], ['amybot', 1]]);
  h.eq('new: newest verified first', (await list(null, `sort => 'new'`)).map((r) => r.name), ['amybot', 'oldbot']);
  h.eq('name: A to Z', (await list(null, `sort => 'name'`)).map((r) => r.name), ['amybot', 'oldbot']);
  h.eq('category filter', (await list(null, `cat => 'moderation'`)).map((r) => r.name), ['amybot']);
  h.eq('search by name', (await list(null, `q => 'OLDB'`)).map((r) => r.name), ['oldbot']);
  h.eq('search by description', (await list(null, `q => 'logs'`)).map((r) => r.name), ['amybot']);
  h.eq('search % is literal', (await list(null, `q => '%'`)).length, 0);
  h.eq('search _ is literal', (await list(null, `q => '_'`)).length, 0);
  h.eq('search for a private bot finds nothing', (await list(null, `q => 'privbot'`)).length, 0);
  h.eq('lim and off', [(await list(null, `lim => 1`)).length, (await list(null, `lim => 1, off => 1`)).map((r) => r.name)], [1, ['amybot']]);
  h.eq('lim is capped, never 0 or negative', [(await list(null, `lim => 100000`)).length, (await list(null, `lim => -5`)).length], [2, 1]);

  // ---- bot_add_targets ----
  await h.as(amy);
  h.eq('targets: servers I manage, with added', (await h.q(`select name, added from bot_add_targets($1)`, [ab])).map((r) => [r.name, r.added]), [['One', true], ['Two', false]]);
  await h.as(bob);
  h.eq('targets: none for someone who manages nothing', (await h.q(`select * from bot_add_targets($1)`, [ab])).length, 0);
  await h.as(null);
  await h.fails('targets: anon can not call it', `select * from bot_add_targets($1)`, [ab]);
  await h.as(amy);
  await h.q(`select bot_add_to_server($1, $2)`, [ab, s2]);
  h.eq('adding a verified bot from /bots works', (await h.q(`select added from bot_add_targets($1)`, [ab])).map((r) => r.added), [true, true]);
  await h.fails('a pending bot can not be added', `select bot_add_to_server($1, $2)`, [pend, s1]);
}
