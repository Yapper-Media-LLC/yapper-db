// 215: server watch (flag server_watch). Like stage193 this starts from stage 24 (+ flags 031/041) and adds small
// stand-ins for the live pieces 215 leans on (staff, mod_log, user_warnings, media_scans, server columns), plus the
// live mod_guard copied verbatim (read-only, Oct 18). Then 215 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.servers add column if not exists description text;
alter table public.servers add column if not exists tags text[];
alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.servers add column if not exists member_count int not null default 0;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists takedown_by uuid;
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.reports add column if not exists server_id uuid;
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists ticket_by uuid;
alter table public.roles add column if not exists auto text not null default 'none';
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid, category_id uuid,
  role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text not null,
  target_id uuid references public.profiles(id) on delete set null, message_id uuid, reason text, created_at timestamptz not null default now());
create table if not exists public.user_warnings (id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
  by uuid, reason text not null check (char_length(reason) between 3 and 500), created_at timestamptz not null default now(), seen_at timestamptz,
  removed_at timestamptz);
create table if not exists public.media_scans (bucket text not null, path text not null, user_id uuid, score real, verdict text,
  scanned_at timestamptz not null default now(), forgiven boolean not null default false, primary key (bucket, path));
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 18. */
const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.channel_overrides_live(cid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
       and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    from public.channels c where c.id = cid), false);
$function$;
CREATE OR REPLACE FUNCTION public.mod_guard(action text, target uuid, why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action
    when 'ban' then 40 when 'takedown' then 5 when 'purge' then 20 when 'timeout' then 60 when 'reset' then 20
    when 'unban' then 10 when 'badge' then 10 when 'untimeout' then 30 when 'verify' then 60
    when 'unwarn' then 30 when 'mark_bot' then 20 else 60 end;
  logged := case action
    when 'badge' then array['badge_given', 'badge_removed']
    when 'takedown' then array['server_takedown']
    when 'untimeout' then array['timeout_cleared']
    when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof']
    when 'mark_bot' then array['marked_bot', 'unmarked_bot']
    when 'reset' then array['reset', 'profile_reset']
    else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim;
  end if;
end; $function$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  const mig = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '215_server_watch.sql'), 'utf8');
  await h.db.exec(mig);
  await h.db.exec(mig); // re-runnable
  h.eq('flag row in test mode with Antic + test account', await h.one(`select mode, cardinality(users) n from feature_flags where key = 'server_watch'`), { mode: 'test', n: 2 });
  h.eq('seeded once', (await h.one(`select count(*)::int n from server_watch_terms`)).n, 16);
  h.eq('mod_guard patched once (hides: 10 an hour)', (await h.one(`select (length(d) - length(replace(d, 'server_hide', ''))) / 11 n from pg_get_functiondef('public.mod_guard(text, uuid, text)'::regprocedure) d`)).n, 1);
  h.eq('policies once', (await h.one(`select count(*)::int n from pg_policies where tablename like 'server_watch%' or tablename = 'server_hides'`)).n, 8);

  // People
  const admin = await h.signup('admin@x.test', 'admin1');
  const mod = await h.signup('mod@x.test', 'mod1');
  const mod2 = await h.signup('mod2@x.test', 'mod2'); // staff, but not in the flag's test group
  const owner = await h.signup('owner@x.test', 'owner1');
  const other = await h.signup('other@x.test', 'other1');
  const joiner = await h.signup('joiner@x.test', 'joiner1');
  const reps = [];
  for (let i = 0; i < 5; i++) reps.push(await h.signup(`rep${i}@x.test`, `rep${i}`));
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 days'`); // past the new-account message limits
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, mod2]);
  await h.q(`update feature_flags set users = users || array[$1, $2]::uuid[] where key = 'server_watch'`, [admin, mod]);

  // RLS on the terms and the results
  await h.as(other);
  h.eq('normal user sees no terms', (await h.one(`select count(*)::int n from server_watch_terms`)).n, 0);
  h.eq('normal user sees no watch rows', (await h.one(`select count(*)::int n from server_watch`)).n, 0);
  await h.fails('normal user cannot add terms', `insert into server_watch_terms (term, kind, weight) values ('zzz', 'other', 5)`);
  await h.fails('normal user cannot run the scan', `select server_watch_scan()`);
  await h.fails('normal user cannot list', `select staff_watch_list('new', 50)`);
  await h.as(mod);
  h.eq('mod reads terms', (await h.one(`select count(*)::int n from server_watch_terms`)).n, 16);
  await h.fails('mod cannot add terms', `insert into server_watch_terms (term, kind, weight) values ('zzz', 'other', 5)`);
  await h.q(`update server_watch_terms set weight = 1 where term = 'porn'`);
  await h.as(admin);
  h.eq('mod update changed nothing', (await h.one(`select weight from server_watch_terms where term = 'porn'`)).weight, 10);
  await h.q(`insert into server_watch_terms (term, kind, weight) values ('zz test', 'other', 5)`);
  h.eq('admin added a term', (await h.one(`select count(*)::int n from server_watch_terms`)).n, 17);
  await h.fails('terms are unique (case-insensitive)', `insert into server_watch_terms (term, kind, weight) values ('NSFW', 'sexual', 5)`);
  await h.q(`delete from server_watch_terms where term = 'zz test'`);
  h.eq('admin removed it', (await h.one(`select count(*)::int n from server_watch_terms`)).n, 16);

  // Fixtures
  await h.admin();
  const srv = async (name, own, extra = {}) => (await h.one(
    `insert into servers (name, owner_id, description, discoverable, member_count) values ($1, $2, $3, $4, 3) returning id`,
    [name, own, extra.description ?? null, extra.discoverable ?? false])).id;
  const chan = async (sid, name) => (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', $1, $2, $3) returning id`, [name, sid, owner])).id;
  const say = async (cid, author, content) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [cid, author, content]);

  const A = await srv('R34 club', owner, { discoverable: true });
  const aGen = await chan(A, 'general'); const aNsfw = await chan(A, 'nsfw-pics');
  await h.q(`update channels set private = true where id = $1`, [aNsfw]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [A, owner]);
  await h.q(`insert into invites (code, server_id, created_by) values ('aserver1', $1, $2)`, [A, owner]);
  await say(aGen, owner, 'hi all');
  await say(aNsfw, owner, 'secret nsfw drop tonight');
  const B = await srv('Cozy Gaming', other, { description: 'chill games and com-munity nights' });
  const bGen = await chan(B, 'general'); await chan(B, 'self-promo');
  await say(bGen, other, 'gg everyone, see you at the community night');
  const C = await srv('Study Hall', other);
  const cGen = await chan(C, 'general');
  const D = await srv('friends', owner);
  await chan(D, 'general');
  await h.q(`insert into invites (code, server_id, created_by) values ('comcode', $1, $2)`, [D, owner]);
  await say(cGen, other, 'WANT TO JOIN A SOCIAL COM/FRIEND GROUP?? https://www.yapper.website/invite/comcode');
  const E = await srv('Hangout', other);
  const eGen = await chan(E, 'general');
  await say(eGen, other, 'hello');
  for (const r of reps.slice(0, 3)) {
    await h.q(`insert into reports (reporter_id, target_id, channel_id, server_id, reason) values ($1, $2, $3, $4, 'sexual')`, [r, other, eGen, E]);
  }
  const G = await srv('nsfw hub', mod2); // owned by staff
  await chan(G, 'general');
  const HQ = await srv('Yapper HQ', admin);
  await h.q(`update app_settings set default_server_id = $1`, [HQ]);
  const J = await srv('Quiet corner', other); // only an "18+" role: on the watch list but under the bar
  await chan(J, 'general');
  await h.q(`insert into roles (server_id, name, position) values ($1, '18+', 1)`, [J]);
  const F = await srv('Art place', other);
  const fGen = await chan(F, 'general');
  await say(fGen, joiner, 'look at this');
  await h.q(`insert into media_scans (bucket, path, user_id, score, verdict) values ('attachments', $1, $2, 0.9, 'blocked')`, [`${joiner}/x.png`, joiner]);

  // Scan
  const stats = await h.one(`select server_watch_scan() s`);
  h.eq('first run reads everything', stats.s.full, true);
  const row = async (sid) => h.one(`select score, status, reasons, reports, blocked_images from server_watch where server_id = $1`, [sid]);
  const a = await row(A);
  h.eq('name + channel match scores A', a.score >= 18, true);
  h.eq('A reason: name r34', a.reasons.some((r) => r.where === 'name' && r.term === 'r34'), true);
  h.eq('A reason: private channel counted without its name', a.reasons.some((r) => r.where === 'a private channel' && r.term === 'nsfw' && r.sample === null), true);
  h.eq('no private channel name anywhere in the reasons', JSON.stringify(a.reasons).includes('nsfw-pics'), false);
  h.eq('J on the list but under the bar', (await row(J)).score < 10, true);
  h.eq('private channel text is never copied', await h.one(`select place, sample from server_watch_hits where server_id = $1 and src = 'message'`, [A]), { place: 'message in a private channel', sample: null });
  h.eq('public channel text is kept', (await h.one(`select place, sample from server_watch_hits where server_id = $1 and src = 'message' and term = 'social com'`, [C])).place, 'message in #general');
  h.eq('clean server not flagged ("com-munity" is no match)', (await row(B)) ?? null, null);
  h.eq('recruiting message counted for the server it was posted in', (await h.one(`select count(*)::int n from server_watch_hits where server_id = $1 and src = 'message' and term = 'social com'`, [C])).n, 1);
  const d = await row(D);
  h.eq('invite ad counts for the invited server', d.score >= 10 && d.reasons.some((r) => r.term === 'social com' && r.where === 'ad posted in Study Hall'), true);
  const e = await row(E);
  h.eq('reports signal: 3 reporters about sexual content', [e.reports, e.score], [3, 15]);
  h.eq('reports reason', e.reasons[0].kind === 'signal' && e.reasons[0].where === 'reports', true);
  h.eq('blocked image matched to the server', (await h.one(`select count(*)::int n from server_watch_hits where server_id = $1 and src = 'image'`, [F])).n, 1);
  h.eq('state saved, terms no longer dirty', await h.one(`select terms_changed, run_no::int from server_watch_state`), { terms_changed: false, run_no: 1 });

  // Lists and permissions
  await h.as(mod);
  const list = (await h.one(`select staff_watch_list('new', 50) l`)).l;
  const scores = list.items.map((x) => x.score);
  h.eq('mod sees the flagged list, best first', scores, [...scores].sort((x, y) => y - x));
  h.eq('list has A, D and E, not B', [A, D, E].every((id) => list.items.some((x) => x.id === id)) && !list.items.some((x) => x.id === B), true);
  h.eq('list has owner name', list.items.find((x) => x.id === A).owner_name, 'owner1');
  h.eq('mod reads server_watch directly', (await h.one(`select count(*)::int n from server_watch where score >= 10`)).n >= 3, true);
  h.eq('mod cannot read raw hits', (await h.one(`select count(*)::int n from server_watch_hits`)).n, 0);
  await h.as(admin);
  h.eq('admin reads raw hits', (await h.one(`select count(*)::int n from server_watch_hits`)).n > 0, true);
  await h.as(mod2);
  await h.fails('staff outside the test group: not available', `select staff_watch_list('new', 50)`);
  await h.as(other);
  await h.fails('normal user cannot warn', `select staff_warn_server_owner($1, 'Adult content')`, [A]);
  await h.fails('normal user cannot review', `select staff_watch_review($1, 'ok')`, [A]);
  await h.fails('normal user cannot hide', `select staff_server_limit($1, 'hide')`, [A]);
  await h.fails('normal user cannot peek', `select staff_watch_peek($1)`, [A]);

  // Peek: logged once per channel per 10 minutes; mods only flagged/reported, non-staff servers, public channels
  await h.as(mod);
  const pk = (await h.one(`select staff_watch_peek($1) p`, [A])).p;
  h.eq('peek: server, public channels only, messages from the public channel', [pk.server.name, pk.channels.length, pk.channel_id, pk.messages.length], ['R34 club', 1, aGen, 1]);
  h.eq('peek: private channel only as a count for mods', [pk.private_channels, JSON.stringify(pk).includes('nsfw-pics')], [1, false]);
  await h.q(`select staff_watch_peek($1)`, [A]);
  await h.fails('peek: channel must be in the server', `select staff_watch_peek($1, $2)`, [A, bGen]);
  await h.fails('peek: mods cannot read a private channel', `select staff_watch_peek($1, $2)`, [A, aNsfw]);
  await h.fails('peek: mods only open flagged or reported servers', `select staff_watch_peek($1)`, [B]);
  await h.fails('peek: a watch row under the bar is not enough', `select staff_watch_peek($1)`, [J]);
  await h.fails('peek: mods cannot open a staff member\'s server', `select staff_watch_peek($1)`, [G]);
  await h.as(admin);
  const pa = (await h.one(`select staff_watch_peek($1, $2) p`, [A, aNsfw])).p;
  h.eq('admins can read private channels', [pa.messages.length, pa.channels.length, pa.private_channels], [1, 2, 0]);
  h.eq('admins can open any server', (await h.one(`select staff_watch_peek($1) p`, [B])).p.server.name, 'Cozy Gaming');
  await h.admin();
  h.eq('peek logged once per channel', (await h.one(`select count(*)::int n from mod_log where action = 'server_peek' and actor = $1`, [mod])).n, 1);
  h.eq('admin peeks logged too', (await h.one(`select count(*)::int n from mod_log where action = 'server_peek' and actor = $1`, [admin])).n, 2);

  // Warn the owner
  await h.as(mod);
  await h.fails('warn needs a reason', `select staff_warn_server_owner($1, '')`, [A]);
  await h.q(`select staff_warn_server_owner($1, 'Adult content')`, [A]);
  await h.fails('no second warning for the same server the same day', `select staff_warn_server_owner($1, 'Adult content')`, [A]);
  await h.admin();
  const w = await h.one(`select user_id, server_id, reason from user_warnings where user_id = $1`, [owner]);
  h.eq('owner warning tied to the server', [w.server_id, w.reason], [A, 'Your server "R34 club": Adult content']);
  const lg = await h.one(`select target_id, reason from mod_log where action = 'server_warn'`);
  h.eq('mod_log row', [lg.target_id, lg.reason], [owner, 'Adult content [R34 club]']);
  h.eq('warned server is actioned', (await row(A)).status, 'actioned');
  await h.q(`update user_warnings set removed_at = now() where user_id = $1`, [owner]);
  await h.as(mod);
  await h.q(`select staff_warn_server_owner($1, 'Adult content')`, [A]);
  await h.admin();
  h.eq('a removed warning does not block a new one', (await h.one(`select count(*)::int n from user_warnings where user_id = $1`, [owner])).n, 2);

  // Review: ok, then it only comes back after a clear rise
  await h.as(mod);
  await h.fails('bad status', `select staff_watch_review($1, 'whatever')`, [E]);
  await h.q(`select staff_watch_review($1, 'ok')`, [E]);
  await h.admin();
  h.eq('E is ok, cleared at 15', await h.one(`select status, cleared_score from server_watch where server_id = $1`, [E]), { status: 'ok', cleared_score: 15 });
  await h.q(`select server_watch_scan()`);
  h.eq('same score: stays ok', (await row(E)).status, 'ok');
  for (const r of reps.slice(3)) {
    await h.q(`insert into reports (reporter_id, target_id, channel_id, server_id, reason) values ($1, $2, $3, $4, 'sexual')`, [r, other, eGen, E]);
  }
  await h.q(`select server_watch_scan()`);
  h.eq('clear rise (15 -> 25): back on the list', await h.one(`select status, score from server_watch where server_id = $1`, [E]), { status: 'new', score: 25 });
  h.eq('review logged', (await h.one(`select count(*)::int n from mod_log where action = 'watch_review'`)).n, 1);

  // Hide / unhide
  await h.as(mod);
  await h.fails('hide needs a reason', `select staff_server_limit($1, 'hide', 'bad')`, [A]);
  await h.fails('mods cannot hide a staff member\'s server', `select staff_server_limit($1, 'hide', 'Adult content')`, [G]);
  await h.fails('Yapper HQ cannot be hidden (mods)', `select staff_server_limit($1, 'hide', 'Adult content')`, [HQ]);
  await h.as(admin);
  await h.fails('Yapper HQ cannot be hidden (admins)', `select staff_server_limit($1, 'hide', 'Adult content')`, [HQ]);
  await h.as(mod);
  await h.q(`select staff_server_limit($1, 'hide', 'Adult content')`, [A]);
  await h.admin();
  h.eq('hidden: out of Discover', await h.one(`select s.discoverable, h.hidden_by = $2 by_mod, h.prev_discoverable from servers s join server_hides h on h.server_id = s.id where s.id = $1`, [A, mod]), { discoverable: false, by_mod: true, prev_discoverable: true });
  await h.as(other);
  h.eq('normal user cannot see who hid it', (await h.one(`select count(*)::int n from server_hides`)).n, 0);
  await h.admin();
  await h.q(`update servers set discoverable = true where id = $1`, [A]);
  h.eq('owner cannot put it back in Discover', (await h.one(`select discoverable from servers where id = $1`, [A])).discoverable, false);
  await h.q(`update servers set discoverable = false where id = $1`, [A]);
  h.eq('owner turning Discover off while hidden is remembered', (await h.one(`select prev_discoverable from server_hides where server_id = $1`, [A])).prev_discoverable, false);
  await h.as(joiner);
  await h.fails('no new members while hidden (invite)', `select join_server('aserver1')`);
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [A, reps[0]]);
  h.eq('inserts not by the joiner (signup, maintenance) pass', (await h.one(`select count(*)::int n from server_members where server_id = $1 and user_id = $2`, [A, reps[0]])).n, 1);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [A, owner]);
  await h.as(owner);
  await h.q(`select join_server('aserver1')`);
  await h.admin();
  h.eq('existing member re-join is a no-op', (await h.one(`select count(*)::int n from server_members where server_id = $1`, [A])).n, 2);
  await h.as(mod2);
  await h.fails('another mod (no flag) cannot unhide', `select staff_server_limit($1, 'unhide')`, [A]);
  await h.as(mod);
  await h.q(`select staff_server_limit($1, 'unhide')`, [A]);
  await h.admin();
  h.eq('unhidden: the owner\'s choice (off) is kept', await h.one(`select discoverable, staff_hidden_at is null shown, (select count(*)::int from server_hides) hides from servers where id = $1`, [A]), { discoverable: false, shown: true, hides: 0 });
  await h.as(joiner);
  await h.q(`select join_server('aserver1')`);
  await h.admin();
  h.eq('joins work again', (await h.one(`select count(*)::int n from server_members where server_id = $1`, [A])).n, 3);
  h.eq('hide + unhide logged', (await h.one(`select count(*)::int n from mod_log where action in ('server_hide', 'server_unhide')`)).n, 2);

  // A term change makes the next run read everything again
  await h.q(`insert into server_watch_terms (term, kind, weight) values ('hall', 'other', 10)`);
  h.eq('terms dirty', (await h.one(`select terms_changed from server_watch_state`)).terms_changed, true);
  const s2 = await h.one(`select server_watch_scan() s`);
  h.eq('full re-read', s2.s.full, true);
  h.eq('new term found on the next run', (await row(C)).reasons.some((r) => r.term === 'hall' && r.where === 'name'), true);

  // Public channel check with channel permissions on (same rules as channel_perm_of)
  await h.admin();
  await h.q(`insert into feature_flags (key, label, mode) values ('channel_perms', 'Channel permissions', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  const pc = async (name) => chan(C, name);
  const open1 = await pc('open1'); const evDeny = await pc('evdeny'); const autoDeny = await pc('autodeny'); const roleDeny = await pc('roledeny');
  const priv = await pc('privallow');
  const autoRole = (await h.one(`insert into roles (server_id, name, position, auto) values ($1, 'everyone auto', 2, 'all') returning id`, [C])).id;
  const plainRole = (await h.one(`insert into roles (server_id, name, position) values ($1, 'vip', 3) returning id`, [C])).id;
  await h.q(`update channels set private = true where id = $1`, [priv]);
  await h.q(`insert into channel_overrides (server_id, channel_id, role_id, allow, deny) values
    ($1, $2, null, '{}', '{view_channel}'), ($1, $3, $6, '{}', '{view_channel}'), ($1, $4, $7, '{}', '{view_channel}'),
    ($1, $5, null, '{view_channel}', '{}'), ($1, $8, null, '{send_messages}', '{}')`, [C, evDeny, autoDeny, roleDeny, priv, autoRole, plainRole, open1]);
  const pub = async (cid) => (await h.one(`select server_watch_public_channel($1) p`, [cid])).p;
  h.eq('override that does not touch view: public', await pub(open1), true);
  h.eq('@everyone denied view: not public', await pub(evDeny), false);
  h.eq('automatic role denied view: not public', await pub(autoDeny), false);
  h.eq('a normal role denied view: still public', await pub(roleDeny), true);
  h.eq('private but @everyone allowed view: public', await pub(priv), true);
}
