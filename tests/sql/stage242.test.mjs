// 242: proof on warnings and bans. PGlite can't replay every migration, so: 001..024, flags (031, 041), stand-ins for
// the tables 242 touches (user_warnings, the newer report/ban/profile columns, the proofs bucket and its two live
// storage policies), and the live functions 242 wraps or reads copied verbatim from the live database (read-only,
// pg_get_functiondef, Oct 18): is_site_admin, is_site_mod, is_staff, is_staff_user, mod_guard, require_staff_reauth,
// mod_warn, mod_ban, site_ban, mod_user_case. Then 242 twice (re-runnable).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.profiles add column if not exists voice_muted_until timestamptz;
alter table public.reports add column if not exists evidence jsonb;
alter table public.reports add column if not exists server_id uuid;
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create table if not exists public.app_settings (webhook_user_id uuid);
alter table public.app_settings add column if not exists webhook_user_id uuid;
create table if not exists public.staff_reauth (user_id uuid primary key, ok_at timestamptz);
create table if not exists public.media_scans (user_id uuid, verdict text);
create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  by uuid references public.profiles (id) on delete set null,
  reason text not null check (char_length(reason) between 3 and 500),
  created_at timestamptz not null default now(),
  seen_at timestamptz, removed_at timestamptz, removed_by uuid, server_id uuid
);
alter table public.user_warnings enable row level security;
create or replace function public.staff_mfa_ok() returns boolean language sql stable as $$ select true $$;
insert into storage.buckets (id, name, public) values ('proofs', 'proofs', false) on conflict do nothing;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 18. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.is_site_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.site_admins where user_id = auth.uid()) and public.staff_mfa_ok();
$function$;
CREATE OR REPLACE FUNCTION public.is_site_mod()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) and public.staff_mfa_ok();
$function$;
CREATE OR REPLACE FUNCTION public.is_staff()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.is_site_admin() or public.is_site_mod();
$function$;
CREATE OR REPLACE FUNCTION public.is_staff_user(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$function$;
CREATE OR REPLACE FUNCTION public.require_staff_reauth()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.feature_on('staff_reauth', null) then return; end if;
  if not exists (select 1 from public.staff_reauth where user_id = auth.uid() and ok_at > now() - interval '5 minutes') then
    raise exception 'REAUTH: Enter your password to confirm this.';
  end if;
end $function$;
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
    when 'unwarn' then 30 when 'mark_bot' then 20 when 'server_hide' then 10 else 60 end;
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
CREATE OR REPLACE FUNCTION public.mod_warn(uid uuid, why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if length(trim(coalesce(why, ''))) < 3 then raise exception 'Say what the warning is for'; end if;
  if uid = auth.uid() then raise exception 'Not yourself'; end if;
  perform public.mod_guard('warn', uid, why);
  insert into public.user_warnings (user_id, by, reason) values (uid, auth.uid(), left(trim(why), 500));
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'warn', uid, left(trim(why), 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$function$;
CREATE OR REPLACE FUNCTION public.mod_ban(uid uuid, why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.mod_guard('ban', uid, why);
  insert into public.site_bans (user_id, reason, banned_by, expires_at)
  values (uid, left(why, 500), auth.uid(), case when public.is_site_admin() then null else now() + interval '7 days' end)
  on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now(), expires_at = excluded.expires_at
    -- 157: a lifted (expired) ban is replaced; a running one only by a ban at least as long (null = permanent).
    where site_bans.expires_at <= now() or excluded.expires_at is null
       or (site_bans.expires_at is not null and excluded.expires_at >= site_bans.expires_at);
  if not found then raise exception 'Already banned for longer'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'ban', uid, left(why, 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$function$;
CREATE OR REPLACE FUNCTION public.site_ban(uid uuid, why text DEFAULT ''::text, wipe boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t ban another admin'; end if;
  if uid = (select a.webhook_user_id from public.app_settings a limit 1) then
    raise exception 'That''s the shared webhook account. Ban whoever made the webhook instead.';
  end if;
  insert into public.site_bans (user_id, reason, banned_by) values (uid, left(coalesce(why, ''), 500), auth.uid())
  on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now(), expires_at = excluded.expires_at
    -- 157: a lifted (expired) ban is replaced; a running one only by a ban at least as long (null = permanent).
    where site_bans.expires_at <= now() or excluded.expires_at is null
       or (site_bans.expires_at is not null and excluded.expires_at >= site_bans.expires_at);
  if wipe then
    perform public.require_staff_reauth();
    delete from public.messages where author_id = uid;
  end if;
  -- Close their open reports as handled.
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end;
$function$;
CREATE OR REPLACE FUNCTION public.mod_user_case(uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare out jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select jsonb_build_object(
    'joined', p.created_at,
    'muted_until', p.muted_until,
    'muted_reason', p.muted_reason,
    'voice_muted_until', p.voice_muted_until,
    'ban', (select to_jsonb(b) from public.site_bans b where b.user_id = uid),
    'is_admin', exists (select 1 from public.site_admins where user_id = uid),
    'is_mod', exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null),
    'servers', (select count(*) from public.server_members where user_id = uid),
    'messages_7d', (select count(*) from public.messages where author_id = uid and created_at > now() - interval '7 days'),
    'reports_total', (select count(*) from public.reports where target_id = uid),
    'reports_open', (select count(*) from public.reports where target_id = uid and status = 'open'),
    'reporters', (select count(distinct reporter_id) from public.reports where target_id = uid),
    'reports_made', (select count(*) from public.reports where reporter_id = uid),
    'refused_uploads', (select count(*) from public.media_scans where user_id = uid and verdict = 'blocked'),
    'warnings', coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from public.user_warnings w where w.user_id = uid and w.removed_at is null), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc)
                         from (select * from public.mod_log where target_id = uid order by created_at desc limit 60) l), '[]'::jsonb)
  ) into out from public.profiles p where p.id = uid;
  return out;
end $function$;
create policy "proofs: read own or admin" on storage.objects for select to authenticated
  using ((bucket_id = 'proofs'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR is_staff()));
create policy "proofs: upload own" on storage.objects for insert to authenticated
  with check ((bucket_id = 'proofs'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text));
create policy "own warnings; staff see all" on public.user_warnings for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_staff() AS is_staff));
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '242_standing_proof.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIG);
  await h.ok('242 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy'); // gets warned and banned
  const rex = await h.signup('rex@test.dev', 'rexthereporter'); // reports amy
  const bob = await h.signup('bob@test.dev', 'bob'); // nosy bystander
  const mod = await h.signup('mod@test.dev', 'mod');
  const mod2 = await h.signup('mod2@test.dev', 'mod2'); // flag off for this one
  const adm = await h.signup('adm@test.dev', 'adm');

  await h.admin();
  h.eq('flag exists in test mode', (await h.one(`select mode from feature_flags where key = 'standing_proof'`)).mode, 'test');
  await h.q(`update feature_flags set users = array[$1, $2, $3, $4]::uuid[] where key = 'standing_proof'`, [amy, bob, mod, adm]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, mod2]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Cozy Place', $1) returning id`, [amy])).id;
  const cid = (await h.one(`insert into channels (kind, name, server_id) values ('text', 'general', $1) returning id`, [sid])).id;
  const dm = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'amy:rex') returning id`)).id;
  const at = (min) => `now() - interval '${min} minutes'`;
  const msg = async (author, text, min, ch = cid) =>
    (await h.one(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, $3, ${at(min)}) returning id, created_at`, [ch, author, text]));
  await h.q(`set session_replication_role = replica`); // seed messages without the posting triggers (rate limits)
  const before = await msg(amy, 'lol whatever', 12);
  const rexLine = await msg(rex, 'please stop, this is rex', 11);
  const bad = await msg(amy, 'you are all idiots', 10);
  const after = await msg(amy, 'and I will keep going', 9);
  const ev = [before, rexLine, after].map((m, i) => ({
    id: m.id, channel_id: cid, content: ['lol whatever', 'please stop, this is rex', 'and I will keep going'][i], attachment: null,
    created_at: m.created_at, author_id: [amy, rex, amy][i], kind: 'text',
  }));
  const rid = (await h.one(`insert into reports (reporter_id, target_id, message_id, channel_id, message_content, reason, details, evidence, server_id)
    values ($1, $2, $3, $4, 'you are all idiots', 'harassment', 'rex here, she keeps doing this to me', $5::jsonb, $6) returning id`,
  [rex, amy, bad.id, cid, JSON.stringify(ev), sid])).id;
  const dmMsg = await msg(amy, 'secret dm insult', 5, dm);
  const ridUser = (await h.one(`insert into reports (reporter_id, target_id, reason, details, evidence)
    values ($1, $2, 'harassment', 'rex: account report', $3::jsonb) returning id`,
  [rex, amy, JSON.stringify([
    { id: dmMsg.id, channel_id: dm, content: 'secret dm insult', attachment: null, created_at: dmMsg.created_at, author_id: amy }, // no kind: the channel is checked
    { id: bad.id, channel_id: '00000000-0000-0000-0000-000000000000', content: 'line from a deleted channel', attachment: null, created_at: bad.created_at, author_id: amy, kind: 'text' },
    { id: bad.id, channel_id: cid, content: 'you are all idiots', attachment: null, created_at: bad.created_at, author_id: amy, kind: 'text' },
  ])])).id;
  const bobMsg = await msg(bob, 'hi', 3);
  const ridBob = (await h.one(`insert into reports (reporter_id, target_id, message_id, channel_id, message_content, reason)
    values ($1, $2, $3, $4, 'hi', 'spam') returning id`, [rex, bob, bobMsg.id, cid])).id;
  // DM and group-chat message reports (and one whose DM channel is gone: no channel, no server).
  const grp = (await h.one(`insert into channels (kind, name) values ('group', 'besties') returning id`)).id;
  const grpMsg = await msg(amy, 'group chat insult', 4, grp);
  const ridDm = (await h.one(`insert into reports (reporter_id, target_id, message_id, channel_id, message_content, reason)
    values ($1, $2, $3, $4, 'secret dm insult', 'harassment') returning id`, [rex, amy, dmMsg.id, dm])).id;
  const ridGrp = (await h.one(`insert into reports (reporter_id, target_id, message_id, channel_id, message_content, reason)
    values ($1, $2, $3, $4, 'group chat insult', 'harassment') returning id`, [rex, amy, grpMsg.id, grp])).id;
  const ridGone = (await h.one(`insert into reports (reporter_id, target_id, message_content, reason)
    values ($1, $2, 'dm from a deleted chat', 'harassment') returning id`, [rex, amy])).id;
  await h.q(`set session_replication_role = origin`);

  // Screenshots: each mod uploads into their own folder of the private bucket.
  const shot = (who, n = 1, ext = 'png') => `${who}/${1700000000000 + n}-abc${n}.${ext}`;
  await h.as(mod);
  for (const n of [1, 2, 3, 4, 5]) await h.q(`insert into storage.objects (bucket_id, name) values ('proofs', $1)`, [shot(mod, n)]);
  await h.fails('mods can only upload into their own folder', `insert into storage.objects (bucket_id, name) values ('proofs', $1)`, [shot(amy, 9)]);
  await h.as(bob);
  await h.q(`insert into storage.objects (bucket_id, name) values ('proofs', $1)`, [shot(bob, 1)]);

  // ---------- staff-only attach ----------
  await h.as(bob);
  await h.fails('non-staff cannot warn with proof', `select mod_warn_with_proof($1, 'be nice', $2, true, 'x', null)`, [amy, rid]);
  await h.fails('non-staff cannot ban with proof', `select mod_ban_with_proof($1, 'be nice please', false, $2, true, null, null)`, [amy, rid]);
  await h.fails('nobody can call the builder directly', `select standing_proof_build($1, $2, true, null, null)`, [amy, rid]);
  await h.as(mod2);
  await h.fails('staff without the flag cannot attach proof', `select mod_warn_with_proof($1, 'be nice', $2, true, null, null)`, [amy, rid]);

  await h.as(mod);
  await h.fails('report must be about them', `select mod_warn_with_proof($1, 'be nice', $2, true, null, null)`, [amy, ridBob]);
  await h.fails('report must be about them (not attaching)', `select mod_warn_with_proof($1, 'be nice', $2, false, 'note', null)`, [amy, ridBob]);
  await h.fails('5 screenshots is too many', `select mod_warn_with_proof($1, 'be nice', null, true, null, $2)`, [amy, [1, 2, 3, 4, 5].map((n) => shot(mod, n))]);
  await h.fails('screenshot from someone else’s folder', `select mod_warn_with_proof($1, 'be nice', null, true, null, $2)`, [amy, [shot(bob, 1)]]);
  await h.fails('screenshot that was never uploaded', `select mod_warn_with_proof($1, 'be nice', null, true, null, $2)`, [amy, [shot(mod, 8)]]);
  await h.fails('not a picture path', `select mod_warn_with_proof($1, 'be nice', null, true, null, $2)`, [amy, [`${mod}/../x.png`]]);
  for (const [label, r] of [['DM', ridDm], ['group chat', ridGrp], ['deleted DM (no channel, no server)', ridGone]]) {
    await h.fails(`${label} message can't be attached`, `select mod_warn_with_proof($1, 'be nice', $2, true, null, null)`, [amy, r]);
  }
  await h.admin();
  h.eq('failed attempts left no warning', (await h.one(`select count(*)::int n from user_warnings`)).n, 0);

  await h.as(mod);
  await h.ok('mod warns from the report with a note and 2 screenshots', () => h.q(
    `select mod_warn_with_proof($1, 'Keep it friendly', $2, true, '  Called people idiots after being asked to stop.  ', $3)`,
    [amy, rid, [shot(mod, 1), shot(mod, 2), shot(mod, 1)]]));

  await h.admin();
  const w = await h.one(`select * from user_warnings where user_id = $1`, [amy]);
  h.eq('warning went through mod_warn (reason, by, report closed)', [w.reason, w.by, (await h.one(`select status from reports where id = $1`, [rid])).status], ['Keep it friendly', mod, 'actioned']);
  h.eq('message snapshot comes from the report row', [w.proof.message.content, w.proof.message.channel_name, w.proof.message.server_name, w.proof.message.author_id],
    ['you are all idiots', 'general', 'Cozy Place', amy]);
  h.eq('context is only their own lines, oldest first', w.proof.context.map((c) => c.content), ['lol whatever', 'and I will keep going']);
  h.eq('note trimmed, screenshots deduped', [w.proof.note, w.proof.images], ['Called people idiots after being asked to stop.', [shot(mod, 1), shot(mod, 2)]]);
  h.eq('no report id stored', 'report_id' in w.proof, false);
  const raw = JSON.stringify(w.proof);
  h.eq('nothing about the reporter is stored', [raw.includes(rex), raw.includes('rex'), raw.includes('keeps doing this')], [false, false, false]);

  // Account report with DM lines: DM lines are left out of the context.
  await h.as(mod);
  await h.ok('second warning from an account report', () => h.q(`select mod_warn_with_proof($1, 'Second warning', $2, true, null, null)`, [amy, ridUser]));
  await h.ok('third warning, message not attached, no note: no proof', () => h.q(`select mod_warn_with_proof($1, 'Third warning', $2, false, null, null)`, [amy, rid]));
  await h.admin();
  const w2 = await h.one(`select proof from user_warnings where reason = 'Second warning'`);
  h.eq('account report: no message, DM and gone-channel lines dropped (kind not trusted)', [w2.proof.message ?? null, w2.proof.context.map((c) => c.content)], [null, ['you are all idiots']]);
  await h.as(mod);
  await h.ok('DM report: a note alone is fine', () => h.q(`select mod_warn_with_proof($1, 'DM warning', $2, false, 'Be kind in DMs', null)`, [amy, ridDm]));
  await h.admin();
  h.eq('DM note-only proof has no message', (await h.one(`select proof from user_warnings where reason = 'DM warning'`)).proof, { note: 'Be kind in DMs' });
  h.eq('nothing attached means no proof', (await h.one(`select proof from user_warnings where reason = 'Third warning'`)).proof, null);

  // ---------- owner sees own proof, others can't ----------
  await h.as(amy);
  const mine = (await h.one(`select my_standing_proof() r`)).r;
  h.eq('amy sees her 3 warnings with proof', [mine.on, mine.warnings.length, mine.ban], [true, 3, null]);
  const ownRows = JSON.stringify(await h.q(`select * from user_warnings where user_id = $1`, [amy]));
  h.eq('report id not readable from her own rows either', [ownRows.includes(rid), ownRows.includes(ridUser), ownRows.includes(ridDm), ownRows.includes(rex)], [false, false, false, false]);
  const p1 = mine.warnings.find((x) => x.id === w.id).proof;
  h.eq('amy sees the message, context, note and screenshots', [p1.message.content, p1.context.length, p1.note, p1.images.length], ['you are all idiots', 2, 'Called people idiots after being asked to stop.', 2]);
  const seen = JSON.stringify(mine);
  h.eq('no report id, author id or reporter in what she sees', [seen.includes(rid), seen.includes(rex), 'author_id' in p1.message, 'report_id' in p1], [false, false, false, false]);
  h.eq('amy can open her screenshots', (await h.one(`select count(*)::int n from storage.objects where bucket_id = 'proofs' and name = any($1)`, [[shot(mod, 1), shot(mod, 2)]])).n, 2);
  h.eq('but not the mod’s other uploads', (await h.one(`select count(*)::int n from storage.objects where bucket_id = 'proofs' and name = $1`, [shot(mod, 3)])).n, 0);

  await h.as(bob);
  const bobs = (await h.one(`select my_standing_proof() r`)).r;
  h.eq('bob sees nothing of amy’s', [bobs.warnings.length, bobs.ban], [0, null]);
  h.eq('bob cannot read amy’s warnings table rows', (await h.one(`select count(*)::int n from user_warnings where user_id = $1`, [amy])).n, 0);
  h.eq('bob cannot open amy’s screenshots', (await h.one(`select count(*)::int n from storage.objects where name = any($1)`, [[shot(mod, 1), shot(mod, 2)]])).n, 0);

  await h.as(mod);
  const file = (await h.one(`select mod_user_case($1) r`, [amy])).r;
  h.eq('staff see the proof in the mod file', file.warnings.filter((x) => x.proof).length, 3);

  // ---------- bans ----------
  await h.as(mod);
  await h.fails('a mod cannot wipe', `select mod_ban_with_proof($1, 'Harassing people', true, $2, true, null, null)`, [amy, rid]);
  await h.ok('mod bans from the report with proof', () => h.q(`select mod_ban_with_proof($1, 'Harassing people', false, $2, true, 'Third strike', $3)`, [amy, rid, [shot(mod, 3)]]));
  await h.admin();
  h.eq('ban row keeps no report id (the row is broadcast to the person)', 'report_id' in (await h.one(`select proof from site_bans where user_id = $1`, [amy])).proof, false);
  await h.as(amy);
  const banned = (await h.one(`select my_standing_proof() r`)).r;
  h.eq('amy sees her ban proof', [banned.ban.note, banned.ban.message.content, banned.ban.images.length, 'report_id' in banned.ban], ['Third strike', 'you are all idiots', 1, false]);
  h.eq('amy can open the ban screenshot', (await h.one(`select count(*)::int n from storage.objects where name = $1`, [shot(mod, 3)])).n, 1);

  await h.as(adm);
  await h.ok('admin re-bans with the old RPC (no proof)', () => h.q(`select site_ban($1, 'Permanent now', false)`, [amy]));
  await h.admin();
  h.eq('re-ban dropped the old ban’s proof', (await h.one(`select reason, proof from site_bans where user_id = $1`, [amy])), { reason: 'Permanent now', proof: null });
  await h.as(adm);
  await h.ok('admin re-bans with proof', () => h.q(`select mod_ban_with_proof($1, 'Permanent, with proof', false, null, true, 'See the screenshots', null)`, [amy]));
  await h.admin();
  h.eq('new proof sits on the new ban', (await h.one(`select proof from site_bans where user_id = $1`, [amy])).proof, { note: 'See the screenshots' });
  await h.q(`update site_bans set expires_at = now() where user_id = $1`, [amy]); // lifted
  await h.as(amy);
  h.eq('a lifted ban shows no proof', (await h.one(`select my_standing_proof() r`)).r.ban, null);
  h.eq('nor its screenshots', (await h.one(`select count(*)::int n from storage.objects where name = $1`, [shot(mod, 3)])).n, 0);

  // ---------- shape and size ----------
  await h.admin();
  await h.fails('unknown key refused', `update user_warnings set proof = '{"reporter": "x"}' where id = $1`, [w.id]);
  await h.fails('6 context lines refused', `update user_warnings set proof = jsonb_build_object('context', (select jsonb_agg(jsonb_build_object('content', 'x')) from generate_series(1, 6))) where id = $1`, [w.id]);
  await h.fails('5 images refused', `update user_warnings set proof = '{"images": ["a","b","c","d","e"]}' where id = $1`, [w.id]);
  await h.fails('long note refused', `update user_warnings set proof = jsonb_build_object('note', repeat('x', 501)) where id = $1`, [w.id]);
  await h.ok('a full-size proof within limits is fine', () => h.q(`update user_warnings set proof = jsonb_build_object('message', jsonb_build_object('content', repeat('\u00e9', 4000)), 'context', (select jsonb_agg(jsonb_build_object('content', repeat('\u00e9', 300))) from generate_series(1, 5)), 'note', repeat('\u00e9', 500), 'images', to_jsonb($1::text[])) where reason = 'Third warning'`, [[1, 2, 3, 4].map((n) => shot(mod, n))]));
  await h.fails('bad image path refused', `update user_warnings set proof = '{"images": ["../etc/x.png"]}' where id = $1`, [w.id]);
  await h.fails('image path outside a user folder refused', `update user_warnings set proof = '{"images": ["standing/x.png"]}' where id = $1`, [w.id]);
  await h.fails('report_id can no longer be stored', `update user_warnings set proof = jsonb_build_object('report_id', $2::text) where id = $1`, [w.id, rid]);
  await h.fails('oversized proof refused (32 KB cap)', `update user_warnings set proof = jsonb_build_object('message', jsonb_build_object('content', 'x', 'kind', repeat('x', 40000))) where id = $1`, [w.id]);
  await h.fails('reporter field inside message refused', `update user_warnings set proof = '{"message": {"content": "x", "reporter_id": "y"}}' where id = $1`, [w.id]);
  await h.fails('not an object refused', `update site_bans set proof = '"hi"' where user_id = $1`, [amy]);
  await h.as(amy);
  await h.q(`update user_warnings set proof = null where id = $1`, [w.id]).catch(() => undefined);
  await h.admin();
  h.eq('nobody writes proof directly (RLS: no update)', (await h.one(`select proof is not null as kept from user_warnings where id = $1`, [w.id])).kept, true);

  // ---------- flag off ----------
  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'standing_proof'`, [mod, adm]);
  await h.as(amy);
  h.eq('flag off: nothing to see', (await h.one(`select my_standing_proof() r`)).r, { on: false, ban: null, warnings: [] });
  h.eq('flag off: screenshots closed', (await h.one(`select count(*)::int n from storage.objects where name = any($1)`, [[shot(mod, 1), shot(mod, 2)]])).n, 0);

  await h.as(null);
  await h.fails('anon cannot read proof', `select my_standing_proof()`);
  await h.fails('anon cannot attach proof', `select mod_warn_with_proof($1, 'hello there', null, true, null, null)`, [amy]);
}
