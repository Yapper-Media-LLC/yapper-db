-- 157: re-bans that actually ban, and reports that outlive their message.
--
-- Bans: an unban keeps the site_bans row and sets expires_at = now(). Every ban path then inserted with
-- `on conflict (user_id) do nothing` (mod_ban, apply_auto_action) or an update that left expires_at alone
-- (site_ban, staff_vote_tally), so banning someone who had been unbanned before wrote "ban" to mod_log and
-- changed nothing (ZAY_URAQT: banned 3 times by kj on Oct 15, still not banned). Now:
--   * a lifted (expired) row is replaced: reason, banned_by, created_at = now(), and the new ban's expiry;
--   * a running ban is only replaced by one that lasts at least as long (null = permanent), so a mod's
--     7-day ban never shortens a permanent one.
-- The same stale row also made apply_auto_action skip people who had been unbanned (no auto-ban ever again)
-- and triage_rules close every new report on them as "Already banned"; both now look at running bans only.
-- After an unban, auto-ban only counts reports made since the ban ended, so a lifted ban isn't re-applied
-- straight away by the reports that caused it.
--
-- Reports: reports.message_id is `on delete set null`, so the report row and its saved message_content /
-- message_attachment survive a delete. The queue lost them because the staff "Delete" buttons resolved the
-- report as soon as the message was gone (the app change ships with this file). The report now also records
-- when its message went and who removed it (the reported person, staff, someone running the server, or the
-- system), set by a trigger that only fires when a reported message is deleted. When the reported person
-- deletes their own upload, /api/media/remove keeps the file while a report on it is open; closing the last
-- open report on it queues it in media_purge, so it doesn't sit on R2 forever.
--
-- Unban: a ban queues the person's stored files for deletion (queue_banned_media); site_unban now takes the
-- ones still waiting back out, so lifting a ban (including the image model's 7-day auto-ban) doesn't delete
-- their files. Patched in site_unban rather than making runPurge skip unbanned owners, because media_purge
-- also holds files that must go whatever the owner's standing (takedowns, deleted reported uploads), and the
-- queue has no column saying why a row is there.
--
-- Live function bodies are patched in place (pg_get_functiondef + replace) so nothing else in them is
-- clobbered; each patch fails loudly if its target text isn't there, and is skipped once applied (marker 157:).

-- ---------- reports: who deleted the message ----------
alter table public.reports add column if not exists message_deleted_at timestamptz;
alter table public.reports add column if not exists message_deleted_by text
  check (message_deleted_by in ('author', 'staff', 'server_mod', 'system'));

create or replace function public.report_message_gone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Runs as part of the `on delete set null` from messages, under the session of whoever deleted it.
  new.message_deleted_at := now();
  new.message_deleted_by := case
    when auth.uid() is null then 'system'
    when auth.uid() = new.target_id then 'author'
    when public.is_staff_user(auth.uid()) then 'staff'
    -- Anyone else who could delete it: a server mod or owner (also by deleting the channel or server).
    else 'server_mod' end;
  return new;
end $$;
revoke execute on function public.report_message_gone() from public, anon, authenticated;

create or replace trigger reports_message_gone
  before update of message_id on public.reports
  for each row when (old.message_id is not null and new.message_id is null)
  execute function public.report_message_gone();

-- The reported person deleted their own upload and the file was kept as evidence: once no open report holds it
-- any more, queue it for deletion (runPurge removes it from R2). Also when the report row goes (account deletion
-- cascades the reports about that account) so a held file is never left behind.
create or replace function public.report_release_attachment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare r public.reports;
begin
  if tg_op = 'DELETE' then
    -- Only an open report on the reported person's own upload (the files the hold keeps).
    if old.status <> 'open' or old.message_attachment is null
       or split_part(old.message_attachment, '/', 1) is distinct from old.target_id::text then
      return null;
    end if;
    r := old;
  else
    r := new;
  end if;
  if not exists (select 1 from public.reports x where x.id <> r.id and x.status = 'open' and x.message_attachment = r.message_attachment) then
    insert into public.media_purge (bucket, path) values ('attachments', r.message_attachment) on conflict do nothing;
  end if;
  return null;
end $$;
revoke execute on function public.report_release_attachment() from public, anon, authenticated;

create or replace trigger reports_release_attachment
  after update of status on public.reports
  for each row when (old.status = 'open' and new.status <> 'open' and new.message_id is null
                     and new.message_attachment is not null and new.message_deleted_by = 'author')
  execute function public.report_release_attachment();
create or replace trigger reports_release_attachment_gone
  after delete on public.reports
  for each row execute function public.report_release_attachment();

-- ---------- site bans: a re-ban after an unban queues their files like a first ban does ----------
create or replace trigger site_bans_queue_media_reban
  after update of expires_at on public.site_bans
  for each row when (old.expires_at is not null and old.expires_at <= now() and (new.expires_at is null or new.expires_at > now()))
  execute function public.queue_banned_media();

-- ---------- site bans: patch every insert into site_bans ----------
do $$
declare
  src text; out text; step text;
  old_nothing constant text := $a$on conflict (user_id) do nothing;$a$;
  old_update constant text := $a$on conflict (user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();$a$;
  new_conflict constant text := $b$on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now(), expires_at = excluded.expires_at
    -- 157: a lifted (expired) ban is replaced; a running one only by a ban at least as long (null = permanent).
    where site_bans.expires_at <= now() or excluded.expires_at is null
       or (site_bans.expires_at is not null and excluded.expires_at >= site_bans.expires_at);$b$;
begin
  -- Moderators' (7 days) and admins' (permanent) bans from the Mod Center. A longer ban already running: say so,
  -- and don't log a ban or close their reports.
  src := pg_get_functiondef('public.mod_ban(uuid, text)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src, old_nothing, new_conflict || $b$
  if not found then raise exception 'Already banned for longer'; end if;$b$);
    if out = src then raise exception '157: mod_ban patch did not apply'; end if;
    execute out;
  end if;

  -- Admin ban (permanent).
  src := pg_get_functiondef('public.site_ban(uuid, text, boolean)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src, old_update, new_conflict);
    if out = src then raise exception '157: site_ban patch did not apply'; end if;
    execute out;
  end if;

  -- A passed staff vote (permanent).
  src := pg_get_functiondef('public.staff_vote_tally(uuid)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src, old_update, new_conflict);
    if out = src then raise exception '157: staff_vote_tally patch did not apply'; end if;
    execute out;
  end if;

  -- Report-driven auto-ban (permanent): only skip people whose ban is still running, and after an unban
  -- only count the reports made since the ban ended.
  src := pg_get_functiondef('public.apply_auto_action(uuid, public.reports)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src, old_nothing, new_conflict);
    if out = src then raise exception '157: apply_auto_action patch (conflict) did not apply'; end if;
    step := out;
    out := replace(step,
      $a$ or exists (select 1 from public.site_bans where user_id = target) then return null; end if;$a$,
      $b$ or public.is_site_banned(target) then return null; end if;
  -- 157: a lifted ban leaves its row behind; only reports made since it ended count.
  select coalesce(max(b.expires_at), '-infinity') into since from public.site_bans b where b.user_id = target;$b$);
    if out = step then raise exception '157: apply_auto_action patch (guard) did not apply'; end if;
    step := out;
    out := replace(step,
      $a$declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean;$a$,
      $b$declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean; since timestamptz;$b$);
    if out = step then raise exception '157: apply_auto_action patch (declare) did not apply'; end if;
    step := out;
    out := replace(step,
      $a$x.created_at > now() - interval '1 hour' and$a$,
      $b$x.created_at > greatest(now() - interval '1 hour', since) and$b$);
    if out = step then raise exception '157: apply_auto_action patch (1h window) did not apply'; end if;
    step := out;
    out := replace(step,
      $a$x.created_at > now() - interval '7 days' and$a$,
      $b$x.created_at > greatest(now() - interval '7 days', since) and$b$);
    if out = step then raise exception '157: apply_auto_action patch (7d window) did not apply'; end if;
    execute out;
  end if;

  -- New reports on someone whose ban was lifted were closed as "Already banned".
  src := pg_get_functiondef('public.triage_rules(public.reports)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src,
      $a$if exists (select 1 from public.site_bans b where b.user_id = r.target_id) then$a$,
      $b$if public.is_site_banned(r.target_id) then -- 157: only a ban that's still running$b$);
    if out = src then raise exception '157: triage_rules patch did not apply'; end if;
    execute out;
  end if;

  -- Unban: files the ban queued for deletion and that haven't gone yet stay (a deleted reported upload of
  -- theirs stays queued: they deleted it themselves).
  src := pg_get_functiondef('public.site_unban(uuid)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src,
      $a$  update public.site_bans set expires_at = now() where user_id = uid;$a$,
      $b$  update public.site_bans set expires_at = now() where user_id = uid;
  -- 157: take back their files the ban queued for deletion, if they haven't gone yet.
  execute 'del' || 'ete from public.media_purge p where p.done_at is null and split_part(p.path, ''/'', 1) = $1
     and not exists (select 1 from public.reports r where p.bucket = ''attachments'' and r.message_attachment = p.path and r.message_deleted_by = ''author'')'
    using uid::text;$b$);
    if out = src then raise exception '157: site_unban patch did not apply'; end if;
    execute out;
  end if;

  -- "Make permanent" on a lifted ban silently re-banned them (and logged no ban): only a running ban.
  src := pg_get_functiondef('public.admin_confirm_ban(uuid)'::regprocedure);
  if position('157:' in src) = 0 then
    out := replace(src,
      $a$update public.site_bans set expires_at = null where user_id = uid;$a$,
      $b$update public.site_bans set expires_at = null where user_id = uid and (expires_at is null or expires_at > now());
  -- 157: a lifted ban stays lifted; ban them again instead.
  if not found then raise exception 'That ban isn''t running anymore. Ban them again instead.'; end if;$b$);
    if out = src then raise exception '157: admin_confirm_ban patch did not apply'; end if;
    execute out;
  end if;
end $$;

notify pgrst, 'reload schema';

-- reports.message_id is `on delete set null`, so every message delete looks it up. This index already exists
-- live (made by hand); listed here so a fresh database gets it too. CONCURRENTLY can't run inside a
-- transaction: run this statement on its own, outside the migration's transaction.
create index concurrently if not exists reports_message_idx on public.reports (message_id) where message_id is not null;
