// 157: re-bans after an unban, and reports whose message gets deleted.
// PGlite can't replay every migration, so like stage24w this starts from stage 24, adds small stand-ins for the
// live pieces 157 leans on, then the live definitions of every function 157 patches (and the report triggers),
// copied verbatim from the live database (read-only), so the patch targets are checked against the real text.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.profiles add column if not exists voice_muted_until timestamptz;
alter table public.messages add column if not exists webhook jsonb;
alter table public.reports add column if not exists server_id uuid;
alter table public.reports add column if not exists triage text;
alter table public.reports add column if not exists triage_note text;
alter table public.reports add column if not exists webhook_id uuid;
alter table public.app_settings add column if not exists webhook_user_id uuid;
alter table public.app_settings add column if not exists staff_vote_pct int not null default 60;
create table if not exists public.webhooks (id uuid primary key, created_by uuid);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz, suspended_reason text);
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid,
  message_id uuid, reason text, created_at timestamptz not null default now());
create table if not exists public.media_scans (bucket text, path text, user_id uuid, score real, verdict text,
  forgiven boolean not null default false, primary key (bucket, path));
create table if not exists public.media_purge (bucket text, path text, done_at timestamptz, primary key (bucket, path));
create table if not exists public.staff_votes (id uuid primary key default gen_random_uuid(), target uuid, reason text,
  opened_by uuid, closed_at timestamptz, outcome text);
create table if not exists public.staff_vote_ballots (vote_id uuid, voter uuid);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_admins where user_id = uid) or exists (select 1 from public.site_moderators where user_id = uid);
$$;
create or replace function public.require_staff_reauth() returns void language sql as $$ select $$;
create or replace function public.staff_vote_needed(target uuid) returns int language sql stable as $$ select 1 $$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
end $$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.is_site_banned(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$function$;
CREATE OR REPLACE FUNCTION public.trusted_reporter(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.profiles p
    where p.id = uid
      and p.created_at < now() - interval '3 days'
      and not ('bot' = any(coalesce(p.badges, '{}'::text[])))
      and not exists (select 1 from public.site_bans b where b.user_id = uid and (b.expires_at is null or b.expires_at > now()))
      and (select count(*) from (select 1 from public.messages m where m.author_id = uid limit 5) x) >= 5
  );
$function$;
CREATE OR REPLACE FUNCTION public.report_message(mid uuid, why text, more text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.messages; rid uuid; ev jsonb; k text;
begin
  perform public.report_guard(auth.uid());
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  if m.author_id = auth.uid() then raise exception 'You can''t report your own message'; end if;
  select kind into k from public.channels where id = m.channel_id;
  -- Context: the 12 messages around it in the same chat (so DM reports can be judged without reading the whole DM).
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'channel_id', x.channel_id, 'content', x.content, 'attachment', x.attachment_path, 'created_at', x.created_at,
      'author_id', x.author_id, 'kind', k) order by x.created_at), '[]'::jsonb)
    into ev
  from (
    (select * from public.messages where channel_id = m.channel_id and created_at <= m.created_at and id <> m.id order by created_at desc limit 8)
    union all
    (select * from public.messages where channel_id = m.channel_id and created_at > m.created_at order by created_at limit 4)
  ) x;
  insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details, evidence, server_id, webhook_id)
  values (auth.uid(), coalesce((select w.created_by from public.webhooks w where m.webhook is not null and w.id = (m.webhook ->> 'id')::uuid), m.author_id), m.id, m.channel_id, m.content, m.attachment_path, why, left(coalesce(more, ''), 1000), ev, (select server_id from public.channels where id = m.channel_id), (m.webhook ->> 'id')::uuid)
  returning id into rid;
  return rid;
end;
$function$;
CREATE OR REPLACE FUNCTION public.triage_rules(r reports)
 RETURNS TABLE(status text, triage text, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reporters int;
  recent_bans int;
begin
  if exists (select 1 from public.site_bans b where b.user_id = r.target_id) then
    return query select 'actioned', 'auto', 'Already banned'; return;
  end if;
  if exists (select 1 from public.site_admins a where a.user_id = r.target_id) then
    return query select 'dismissed', 'auto', 'Report against an admin'; return;
  end if;
  if r.message_id is not null and not exists (select 1 from public.messages m where m.id = r.message_id) then
    return query select 'actioned', 'auto', 'Message already removed'; return;
  end if;
  if public.has_slur(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Slur in message'; return;
  end if;
  if public.has_adult_link(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Link to porn site'; return;
  end if;
  if r.reason in ('sexual', 'minor_safety', 'illegal') and r.message_attachment is not null then
    return query select 'open', 'ban', 'Image reported as ' || r.reason; return;
  end if;
  if r.reason = 'minor_safety' then
    return query select 'open', 'ban', 'Minor-safety report'; return;
  end if;
  select count(distinct reporter_id) into reporters from public.reports x where x.target_id = r.target_id and x.created_at > now() - interval '7 days';
  if reporters >= 3 then
    return query select 'open', 'ban', 'Reported by ' || reporters || ' different people'; return;
  end if;
  return query select 'open', null::text, null::text;
end;
$function$;
CREATE OR REPLACE FUNCTION public.triage_new_report()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; n int;
begin
  select * into t from public.triage_rules(new);
  new.triage := t.triage;
  new.triage_note := t.note;
  if t.status <> 'open' then
    new.status := t.status; new.resolved_at := now();
  end if;
  if new.status = 'open' and new.details like '[voice]%' and new.channel_id is not null then
    select count(distinct reporter_id) + 1 into n from public.reports x
      where x.target_id = new.target_id and x.channel_id = new.channel_id and x.reporter_id <> new.reporter_id and x.created_at > now() - interval '10 minutes';
    if n >= 3 and not exists (select 1 from public.site_admins where user_id = new.target_id) then
      update public.profiles set voice_muted_until = greatest(coalesce(voice_muted_until, now()), now() + interval '10 minutes') where id = new.target_id;
      new.triage := 'ban';
      new.triage_note := coalesce(new.triage_note || ' · ', '') || 'Reported in voice by ' || n || ' people · auto voice timeout 10m';
    end if;
  end if;
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.apply_auto_action(target uuid, r reports)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean;
begin
  if target is null or target = (select a.webhook_user_id from public.app_settings a limit 1) or exists (select 1 from public.site_admins where user_id = target) or exists (select 1 from public.site_bans where user_id = target) then return null; end if;
  slur := public.has_slur(coalesce(r.message_content, ''));
  select count(distinct x.reporter_id) into reporters_1h from public.reports x
    where x.target_id = target and x.created_at > now() - interval '1 hour' and public.trusted_reporter(x.reporter_id);
  select count(distinct x.reporter_id) into reporters_7d from public.reports x
    where x.target_id = target and x.created_at > now() - interval '7 days' and public.trusted_reporter(x.reporter_id);
  if (slur and reporters_7d >= 2) or reporters_1h >= 10 then
    insert into public.site_bans (user_id, reason)
    values (target, case when slur then 'Auto-ban: slurs, reported by ' || reporters_7d || ' people' else 'Auto-ban: reported by ' || reporters_1h || ' trusted people in an hour' end)
    on conflict (user_id) do nothing;
    update public.reports set status = 'actioned', triage = 'auto', triage_note = 'Auto-banned', resolved_at = now() where target_id = target and status = 'open';
    return 'Auto-banned';
  end if;
  if reporters_1h >= 5 then
    select muted_until into mu from public.profiles where id = target;
    if mu is null or mu < now() then
      update public.profiles set muted_until = now() + interval '1 hour', muted_reason = 'reported by ' || reporters_1h || ' people' where id = target;
    end if;
    return 'Auto timeout 1h';
  end if;
  return null;
end;
$function$;
CREATE OR REPLACE FUNCTION public.auto_action_new_report()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare note text;
begin
  if new.status = 'open' then
    note := public.apply_auto_action(new.target_id, new);
    if note is not null and note <> 'Auto-banned' then
      update public.reports set triage = 'ban', triage_note = coalesce(triage_note || ' · ', '') || note where id = new.id;
    end if;
  end if;
  return null;
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
  on conflict (user_id) do nothing;
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
  on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  if wipe then
    perform public.require_staff_reauth();
    delete from public.messages where author_id = uid;
  end if;
  -- Close their open reports as handled.
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
   where target_id = uid and status = 'open';
end;
$function$;
CREATE OR REPLACE FUNCTION public.site_unban(uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b public.site_bans;
begin
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if not public.is_site_mod() then raise exception 'Moderators only'; end if;
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  update public.media_scans set forgiven = true where user_id = uid and verdict = 'blocked' and not forgiven;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unban', uid, coalesce(b.reason, ''));
end; $function$;
CREATE OR REPLACE FUNCTION public.admin_confirm_ban(uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.site_bans set expires_at = null where user_id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'ban_confirmed', uid, '');
end;
$function$;
CREATE OR REPLACE FUNCTION public.staff_vote_tally(vid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.staff_votes; n int; needed int;
begin
  select * into v from public.staff_votes where id = vid;
  if v.id is null or v.closed_at is not null then return; end if;
  select count(*) into n from public.staff_vote_ballots b
    where b.vote_id = vid and b.voter <> v.target
      and (exists (select 1 from public.site_admins a where a.user_id = b.voter)
        or exists (select 1 from public.site_moderators m where m.user_id = b.voter and m.suspended_at is null));
  needed := public.staff_vote_needed(v.target);
  if n < needed then return; end if;
  -- Paused rather than removed: powers and badge go at once, and admins still see who it was and why.
  update public.site_moderators set suspended_at = now(), suspended_reason = left('Removed by staff vote: ' || v.reason, 500) where user_id = v.target;
  insert into public.site_bans (user_id, reason, banned_by) values (v.target, left('Staff vote: ' || v.reason, 500), v.opened_by)
    on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  update public.staff_votes set closed_at = now(), outcome = 'passed' where id = vid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'vote_ban', v.target, v.reason || ' (' || n || ' of ' || needed || ' votes)');
end; $function$;
CREATE OR REPLACE FUNCTION public.queue_banned_media()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.media_purge (bucket, path)
  select bucket_id, name from storage.objects
  where (storage.foldername(name))[1] = new.user_id::text
  on conflict do nothing;
  return new;
end;
$function$;
create trigger reports_triage before insert on public.reports for each row execute function public.triage_new_report();
create trigger reports_auto_action after insert on public.reports for each row execute function public.auto_action_new_report();
create trigger site_bans_queue_media after insert on public.site_bans for each row execute function public.queue_banned_media();
`;

const FILE = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '157_rebans_and_deleted_reports.sql'), 'utf8');
// The CONCURRENTLY index has to run on its own, outside the rest of the file's (implicit) transaction.
const INDEX = FILE.match(/^create index concurrently[^;]*;/m)?.[0];
const MIGRATION = FILE.replace(INDEX ?? '', '');

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIGRATION);
  await h.ok('157 re-runs cleanly', () => h.db.exec(MIGRATION));
  h.eq('index statement found', !!INDEX, true);
  await h.ok('index runs on its own (twice)', async () => { await h.db.exec(INDEX); await h.db.exec(INDEX); });
  h.eq('message_id index exists', (await h.one(`select count(*)::int n from pg_indexes where indexname = 'reports_message_idx'`)).n, 1);
  const marks = await h.one(`select ${['mod_ban(uuid,text)', 'site_ban(uuid,text,boolean)', 'staff_vote_tally(uuid)', 'apply_auto_action(uuid,reports)', 'triage_rules(reports)', 'admin_confirm_ban(uuid)', 'site_unban(uuid)']
    .map((f, i) => `(select count(*) from regexp_matches(pg_get_functiondef('public.${f}'::regprocedure), '157:', 'g'))::int f${i}`).join(', ')}`);
  h.eq('every ban path patched exactly once', Object.values(marks), [1, 1, 1, 2, 1, 1, 1]);

  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };
  const ban = async (uid) => { await h.admin(); return h.one(`select user_id, reason, banned_by, expires_at, created_at, is_site_banned(user_id) banned,
      expires_at > now() + interval '6 days' as week from site_bans where user_id = $1`, [uid]); };

  const adm = await h.signup('adm@test.dev', 'adm');
  const mod = await h.signup('mod@test.dev', 'kj');
  const mod2 = await h.signup('mod2@test.dev', 'mod_two');
  const zay = await h.signup('zay@test.dev', 'ZAY_URAQT');
  const owner = await h.signup('owner@test.dev', 'owner');
  const r1 = await h.signup('r1@test.dev', 'reporter_one');
  const r2 = await h.signup('r2@test.dev', 'reporter_two');
  const perm = await h.signup('perm@test.dev', 'perm_banned');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [adm]);
  await h.q(`insert into site_moderators (user_id) values ($1), ($2)`, [mod, mod2]);

  // ---- mod_ban: ban, unban, ban again ----
  await h.as(mod);
  await h.q(`select mod_ban($1, 'raiding the server')`, [zay]);
  let b = await ban(zay);
  h.eq('mod ban: 7 days', [b.banned, b.week, b.banned_by], [true, true, mod]);
  await h.as(adm);
  await h.q(`select site_unban($1)`, [zay]);
  h.eq('unbanned (row kept, expired)', (await ban(zay)).banned, false);
  await h.admin();
  await h.q(`update site_bans set created_at = now() - interval '2 days' where user_id = $1`, [zay]);
  await h.as(mod2);
  await h.q(`select mod_ban($1, 'raiding again, third time')`, [zay]);
  b = await ban(zay);
  h.eq('mod re-ban after unban bans again', [b.banned, b.week, b.banned_by, b.reason], [true, true, mod2, 'raiding again, third time']);
  h.eq('re-ban starts now', (await h.one(`select created_at > now() - interval '1 minute' fresh from site_bans where user_id = $1`, [zay])).fresh, true);

  // ---- site_ban (admin, permanent): ban, unban, ban again ----
  await h.as(adm);
  await h.q(`select site_unban($1)`, [zay]);
  await h.q(`select site_ban($1, 'slurs in general')`, [zay]);
  b = await ban(zay);
  h.eq('admin re-ban after unban is permanent', [b.banned, b.expires_at, b.banned_by, b.reason], [true, null, adm, 'slurs in general']);
  // A mod's 7-day ban must not shorten it.
  await h.as(adm);
  await h.q(`select site_ban($1, 'permanent one')`, [perm]);
  await h.admin();
  const permLogs = (await h.one(`select count(*)::int n from mod_log where target_id = $1`, [perm])).n;
  await h.as(mod);
  const pe = await err(`select mod_ban($1, 'spam spam spam')`, [perm]);
  h.eq('mod ban on a longer running ban says so', pe?.message, 'Already banned for longer');
  b = await ban(perm);
  h.eq('mod ban leaves a running permanent ban alone', [b.banned, b.expires_at, b.banned_by, b.reason], [true, null, adm, 'permanent one']);
  h.eq('and logs no ban', (await h.one(`select count(*)::int n from mod_log where target_id = $1`, [perm])).n, permLogs);
  // A running mod ban is extended by a later one, never shortened.
  await h.admin();
  await h.q(`update site_bans set expires_at = now() + interval '1 day' where user_id = $1`, [zay]);
  await h.as(mod);
  await h.q(`select mod_ban($1, 'kept going after the ban')`, [zay]);
  b = await ban(zay);
  h.eq('mod ban extends a shorter running ban', [b.banned, b.week, b.banned_by], [true, true, mod]);
  await h.admin();
  await h.q(`update site_bans set expires_at = now() + interval '30 days', reason = 'long one' where user_id = $1`, [zay]);
  await h.as(mod2);
  h.eq('a shorter mod ban is refused', (await err(`select mod_ban($1, 'shorter ban attempt')`, [zay]))?.message, 'Already banned for longer');
  await h.admin();
  h.eq('mod ban does not shorten a longer running ban', (await h.one(`select reason, expires_at > now() + interval '29 days' long from site_bans where user_id = $1`, [zay])), { reason: 'long one', long: true });

  // ---- admin_confirm_ban: only a running ban ----
  await h.as(adm);
  await h.q(`select site_unban($1)`, [zay]);
  const ce = await err(`select admin_confirm_ban($1)`, [zay]);
  h.eq('make permanent refuses a lifted ban', /isn't running anymore/.test(ce?.message ?? ''), true);
  h.eq('lifted ban stays lifted', (await ban(zay)).banned, false);
  await h.as(mod);
  await h.q(`select mod_ban($1, 'one more time now')`, [zay]);
  await h.as(adm);
  await h.q(`select admin_confirm_ban($1)`, [zay]);
  b = await ban(zay);
  h.eq('make permanent works on a running ban', [b.banned, b.expires_at], [true, null]);

  // ---- staff vote: re-ban a mod who was unbanned before ----
  await h.admin();
  await h.q(`insert into site_bans (user_id, reason, banned_by, expires_at, created_at) values ($1, 'old', $2, now() - interval '1 day', now() - interval '9 days')`, [mod2, adm]);
  const vid = (await h.one(`insert into staff_votes (target, reason, opened_by) values ($1, 'abusing powers', $2) returning id`, [mod2, adm])).id;
  await h.q(`insert into staff_vote_ballots (vote_id, voter) values ($1, $2)`, [vid, mod]);
  await h.q(`select staff_vote_tally($1)`, [vid]);
  b = await ban(mod2);
  h.eq('staff vote re-bans after an old lifted ban', [b.banned, b.expires_at, b.reason], [true, null, 'Staff vote: abusing powers']);

  // ---- re-ban queues their stored files like a first ban ----
  await h.q(`insert into storage.buckets (id, name) values ('proofs', 'proofs') on conflict do nothing`);
  await h.q(`insert into storage.objects (bucket_id, name) values ('proofs', $1)`, [`${perm}/proof.png`]);
  await h.as(adm);
  await h.q(`select site_unban($1)`, [perm]);
  await h.admin();
  await h.q(`delete from media_purge`);
  await h.as(adm);
  await h.q(`select site_ban($1, 'back again')`, [perm]);
  await h.admin();
  h.eq('re-ban queues their files', (await h.q(`select path from media_purge`)).map((r) => r.path), [`${perm}/proof.png`]);

  // ---- unban takes the files the ban queued back out (not ones already gone, not their deleted reported uploads) ----
  await h.q(`insert into media_purge (bucket, path, done_at) values ('proofs', $1, now())`, [`${perm}/gone.png`]);
  await h.q(`insert into media_purge (bucket, path) values ('attachments', $1), ('attachments', $2)`, [`${perm}/held.png`, `${owner}/other.png`]);
  await h.q(`insert into reports (target_id, message_attachment, reason, status, message_deleted_by) values ($1, $2, 'sexual', 'dismissed', 'author')`, [perm, `${perm}/held.png`]);
  await h.as(adm);
  await h.q(`select site_unban($1)`, [perm]);
  await h.admin();
  h.eq('unban: pending ban purge removed, others kept', (await h.q(`select path, done_at is not null done from media_purge order by path`)).map((r) => [r.path, r.done]),
    [[`${owner}/other.png`, false], [`${perm}/gone.png`, true], [`${perm}/held.png`, false]].sort((a, b) => a[0].localeCompare(b[0])));
  await h.q(`delete from media_purge`);
  await h.q(`delete from reports`);

  // ---- a server to post and report in ----
  await h.as(owner);
  const sid = (await h.one(`select create_server('Reports', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id = $1 and kind = 'text' limit 1`, [sid])).id;
  await h.admin();
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($1, $4) on conflict do nothing`, [sid, zay, r1, r2]);
  // Trusted reporters: older accounts with a few messages.
  await h.q(`update profiles set created_at = now() - interval '10 days' where id in ($1, $2)`, [r1, r2]);
  for (const r of [r1, r2]) for (let i = 0; i < 5; i++) {
    await h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, $3, now() - make_interval(mins => $4))`, [gen, r, `hello ${i}`, 300 + i]);
  }
  h.eq('reporters are trusted', (await h.one(`select trusted_reporter($1) a, trusted_reporter($2) b`, [r1, r2])), { a: true, b: true });

  // ---- auto-ban: ban, unban, ban again ----
  await h.as(adm);
  await h.q(`select site_unban($1)`, [zay]);
  await h.admin();
  await h.q(`update site_bans set expires_at = now() - interval '1 hour' where user_id = $1`, [zay]);
  const rep = (reporter, at) => h.one(`insert into reports (reporter_id, target_id, message_content, reason, created_at)
      values ($1, $2, 'you retard', 'hate', $3) returning id, status, triage_note`, [reporter, zay, at]);
  // A report from before the ban was lifted doesn't count toward a new auto-ban.
  await rep(r2, new Date(Date.now() - 2 * 3600_000).toISOString());
  const first = await rep(r1, new Date().toISOString());
  h.eq('new report on an unbanned person stays open (not "Already banned")', [first.status, first.triage_note], ['open', 'Slur in message']);
  h.eq('reports from before the unban do not count', (await ban(zay)).banned, false);
  await rep(r2, new Date().toISOString());
  b = await ban(zay);
  h.eq('auto-ban after an unban bans again', [b.banned, b.expires_at, b.banned_by, /^Auto-ban: slurs/.test(b.reason)], [true, null, null, true]);
  h.eq('their open reports closed by the auto-ban', (await h.one(`select count(*)::int n from reports where target_id = $1 and status = 'open'`, [zay])).n, 0);
  const late = await rep(r1, new Date().toISOString());
  h.eq('while banned, new reports close as "Already banned"', [late.status, late.triage_note], ['actioned', 'Already banned']);

  // ---- deleting a reported message keeps the report open ----
  await h.as(adm);
  await h.q(`select site_unban($1)`, [zay]);
  await h.admin();
  await h.q(`delete from reports`);
  const post = async (text) => { await h.as(zay); return (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [gen, zay, text])).id; };
  const report = async (mid) => { await h.as(r1); return (await h.one(`select report_message($1, 'harassment', 'mean') r`, [mid])).r; };
  const row = async (rid) => { await h.admin(); return h.one(`select status, message_id, message_content, message_deleted_by, message_deleted_at is not null gone_at from reports where id = $1`, [rid]); };

  const m1 = await post('you are all idiots');
  const rid1 = await report(m1);
  h.eq('report starts open with no delete info', await row(rid1), { status: 'open', message_id: m1, message_content: 'you are all idiots', message_deleted_by: null, gone_at: false });
  await h.as(zay);
  await h.q(`delete from messages where id = $1`, [m1]);
  h.eq('author deletes it: report stays open with the content', await row(rid1),
    { status: 'open', message_id: null, message_content: 'you are all idiots', message_deleted_by: 'author', gone_at: true });
  h.eq('re-running the auto-review keeps it open', (await h.one(`select (t).status from (select triage_rules(r) t from reports r where id = $1) x`, [rid1])).status, 'open');

  const m2 = await post('second rude one');
  const rid2 = await report(m2);
  await h.as(owner);
  await h.q(`delete from messages where id = $1`, [m2]);
  h.eq('server mod deletes it: open, marked server_mod', [(await row(rid2)).status, (await row(rid2)).message_deleted_by], ['open', 'server_mod']);

  const m3 = await post('third rude one');
  const rid3 = await report(m3);
  await h.as(adm);
  await h.q(`select admin_delete_message($1)`, [m3]);
  h.eq('staff deletes it: open, marked staff', [(await row(rid3)).status, (await row(rid3)).message_deleted_by], ['open', 'staff']);

  const m4 = await post('fourth rude one');
  const rid4 = await report(m4);
  await h.admin();
  await h.q(`delete from messages where id = $1`, [m4]);
  h.eq('deleted by the system: open, marked system', [(await row(rid4)).status, (await row(rid4)).message_deleted_by], ['open', 'system']);

  // Other report updates leave the delete info alone, and nobody can write it directly.
  await h.as(adm);
  await h.q(`select resolve_report($1, 'actioned')`, [rid1]);
  h.eq('resolving keeps who deleted it', (await row(rid1)).message_deleted_by, 'author');
  await h.as(zay);
  await h.q(`update reports set message_deleted_by = null where id = $1`, [rid2]);
  h.eq('people cannot clear the delete info', (await row(rid2)).message_deleted_by, 'server_mod');

  // ---- a held upload is queued for deletion once no open report holds it ----
  await h.admin();
  await h.q(`delete from media_purge`);
  const pic = `${zay}/pic.png`;
  const mp = (await h.one(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, 'look', $3) returning id`, [gen, zay, pic])).id;
  const ra = await report(mp);
  await h.as(r2);
  const rb = (await h.one(`select report_message($1, 'sexual', '') r`, [mp])).r;
  await h.as(zay);
  await h.q(`delete from messages where id = $1`, [mp]);
  await h.as(adm);
  await h.q(`select resolve_report($1, 'dismissed')`, [ra]);
  await h.admin();
  h.eq('still held while another report on it is open', (await h.one(`select count(*)::int n from media_purge`)).n, 0);
  await h.as(adm);
  await h.q(`select resolve_report($1, 'actioned')`, [rb]);
  await h.admin();
  h.eq('last open report closed: file queued', (await h.q(`select bucket, path from media_purge`)), [{ bucket: 'attachments', path: pic }]);
  // A message staff deleted: the file wasn't held, nothing queued.
  await h.q(`delete from media_purge`);
  const mq = (await h.one(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, 'look2', $3) returning id`, [gen, zay, `${zay}/pic2.png`])).id;
  const rc = await report(mq);
  await h.as(adm);
  await h.q(`select admin_delete_message($1)`, [mq]);
  await h.q(`select resolve_report($1, 'dismissed')`, [rc]);
  await h.admin();
  h.eq('not held (staff deleted it): nothing queued', (await h.one(`select count(*)::int n from media_purge`)).n, 0);
  // Account deletion takes the reports about them with it: their held upload is queued then.
  const mz = (await h.one(`insert into messages (channel_id, author_id, content, attachment_path) values ($1, $2, 'look3', $3) returning id`, [gen, zay, `${zay}/pic3.png`])).id;
  await report(mz);
  await h.admin();
  await h.q(`delete from auth.users where id = $1`, [zay]);
  h.eq('account deleted: their reported upload is queued', (await h.q(`select path from media_purge`)).map((r) => r.path), [`${zay}/pic3.png`]);
  await h.admin();
}
