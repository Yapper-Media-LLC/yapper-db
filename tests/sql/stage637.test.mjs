// 637: ban appeal decisions in the mod log. Same stand-ins as stage226 (plus the head-mod bits staff_mod_stats
// needs), then 226, then 637 twice (re-runnable, backfill included).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz,
  head boolean not null default false, created_at timestamptz not null default now());
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null and head);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
end $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create or replace function public.site_unban(uid uuid) returns void language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Moderators only'; end if;
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unban', uid, coalesce(b.reason, ''));
end; $function$;
`;

export default async function (h) {
  const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(mig('226_ban_appeals.sql'));

  const amy = await h.signup('amy@test.dev', 'amy');   // automatic ban, appeal accepted
  const bob = await h.signup('bob@test.dev', 'bob');   // confirmed ban, appeal denied
  const cat = await h.signup('cat@test.dev', 'cat');   // ban already ended, appeal accepted anyway
  const dan = await h.signup('dan@test.dev', 'dan');   // decided on 226 (before this migration): backfill
  const eve = await h.signup('eve@test.dev', 'eve');   // same, denied
  const mod = await h.signup('mod@test.dev', 'mod');
  const adm = await h.signup('adm@test.dev', 'adm');

  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true)`, [mod]);
  await h.q(`update feature_flags set users = array[$1, $2, $3, $4, $5]::uuid[] where key = 'ban_appeals'`, [amy, bob, cat, dan, eve]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'auto: spam')`, [amy]);
  await h.q(`insert into site_bans (user_id, reason, banned_by) values ($1, 'slurs', $2)`, [bob, adm]);
  await h.q(`insert into site_bans (user_id, reason, expires_at) values ($1, 'auto: links', now() + interval '1 day')`, [cat]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'auto: raid')`, [dan]);
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'auto: nsfw')`, [eve]);
  for (const [u, m] of [[amy, 'It was a mistake, I only posted one gif'], [bob, 'I was hacked, that was not me'], [cat, 'Those links were fine'],
    [dan, 'That raid was not me, I was asleep'], [eve, 'That picture was art']]) {
    await h.as(u);
    await h.q(`select submit_ban_appeal($1)`, [m]);
  }

  // Decisions made on the old function (226): accept dan (only an unban row), deny eve (logged as appeal_denied).
  await h.as(mod);
  const before = (await h.one(`select staff_ban_appeals('pending') r`)).r;
  const idOf = (name) => before.find((a) => a.username === name).id;
  await h.q(`select decide_ban_appeal($1, true, null)`, [idOf('dan')]);
  await h.q(`select decide_ban_appeal($1, false, 'Still not ok')`, [idOf('eve')]);
  await h.admin();
  h.eq('226: accepting only logged an unban', (await h.one(`select array_agg(action order by action) a from mod_log where target_id = $1`, [dan])).a, ['unban']);
  h.eq('226: denial logged under the upload appeal action', (await h.one(`select array_agg(action) a from mod_log where target_id = $1`, [eve])).a, ['appeal_denied']);
  // An upload appeal denial from the same mod must not be touched by the backfill.
  await h.q(`insert into mod_log (actor, action, target_id, reason) values ($1, 'appeal_denied', $2, 'Upload review')`, [mod, eve]);

  await h.db.exec(mig('637_ban_appeal_log.sql'));
  await h.ok('637 re-runs cleanly', () => h.db.exec(mig('637_ban_appeal_log.sql')));

  h.eq('backfill: old acceptance now has one appeal row (not two after the re-run)',
    (await h.one(`select count(*)::int n from mod_log where action = 'ban_appeal_approved' and target_id = $1 and actor = $2`, [dan, mod])).n, 1);
  h.eq('backfill: it is dated when the appeal was decided and says what the ban was for',
    (await h.one(`select (l.created_at = a.decided_at) same, l.reason from mod_log l join ban_appeals a on a.user_id = l.target_id where l.action = 'ban_appeal_approved' and l.target_id = $1`, [dan])),
    { same: true, reason: '(ban: auto: raid)' });
  h.eq('backfill: old denial renamed, upload appeal row left alone',
    (await h.one(`select array_agg(action || ':' || reason order by action) a from mod_log where target_id = $1`, [eve])).a,
    ['appeal_denied:Upload review', 'ban_appeal_denied:Still not ok']);

  // New decisions.
  await h.as(mod);
  const list = (await h.one(`select staff_ban_appeals('pending') r`)).r;
  const id = (name) => list.find((a) => a.username === name).id;
  await h.ok('mod accepts amy with a note', () => h.q(`select decide_ban_appeal($1, true, 'ok, welcome back')`, [id('amy')]));
  await h.fails('mod cannot lift a confirmed ban', `select decide_ban_appeal($1, true, null)`, [id('bob')]);
  await h.ok('mod denies bob with a note', () => h.q(`select decide_ban_appeal($1, false, 'We checked the logs, it was you')`, [id('bob')]));

  await h.admin();
  h.eq('amy is unbanned', (await h.one(`select is_site_banned($1) b`, [amy])).b, false);
  h.eq('accepting logs the appeal and the unban, both by the mod',
    (await h.one(`select array_agg(action || ':' || reason order by action) a from mod_log where target_id = $1 and actor = $2`, [amy, mod])).a,
    ['ban_appeal_approved:ok, welcome back (ban: auto: spam)', 'unban:auto: spam']);
  h.eq('the failed lift logged nothing', (await h.one(`select count(*)::int n from mod_log where target_id = $1 and action like 'ban_appeal%'`, [bob])).n, 1);
  h.eq('denying logs the appeal with the note',
    (await h.one(`select array_agg(action || ':' || reason) a from mod_log where target_id = $1`, [bob])).a,
    ['ban_appeal_denied:We checked the logs, it was you (ban: slurs)']);
  h.eq('bob is still banned', (await h.one(`select is_site_banned($1) b`, [bob])).b, true);
  await h.as(bob);
  h.eq('bob sees the denial and note', (await h.one(`select my_ban_appeal() r`)).r.appeal.staff_note, 'We checked the logs, it was you');

  // A ban that already ended: "Accept" still logs the decision, with no unban row.
  await h.admin();
  await h.q(`update site_bans set expires_at = now() - interval '1 minute' where user_id = $1`, [cat]);
  await h.as(adm);
  await h.ok('admin accepts cat (ban already over)', () => h.q(`select decide_ban_appeal($1, true, null)`, [id('cat')]));
  await h.admin();
  h.eq('ended ban: appeal row only, no note means just the ban reason',
    (await h.one(`select array_agg(action || ':' || reason) a from mod_log where target_id = $1`, [cat])).a, ['ban_appeal_approved:(ban: auto: links)']);

  // Mod stats count them as appeals, not other (4 ban appeal rows plus the upload appeal row from above).
  await h.as(mod);
  const st = (await h.one(`select appeals::int, other::int from staff_mod_stats(7) where user_id = $1`, [mod]));
  h.eq('stats: ban appeal decisions count as appeals', st, { appeals: 5, other: 0 });

  await h.as(cat);
  await h.fails('not staff: cannot decide', `select decide_ban_appeal($1, false, null)`, [id('cat')]);
  await h.as(null);
  await h.fails('anon cannot decide', `select decide_ban_appeal($1, false, null)`, [id('cat')]);
}
