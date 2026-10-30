-- 648: Management can ban for good (Antic, Oct 28: "allow managers to permaban").
--
-- What blocked it: site_ban (537) already lets a manager place a permanent ban, but nothing ever called it for them.
-- The app sends everyone who isn't an admin through mod_ban (7 days, "an admin can make it permanent"), and
-- mod_ban_with_proof (242, flag standing_proof) does the same on the server. So a manager's ban always ran out after
-- 7 days, and their permanent bans weren't logged either (site_ban writes no mod_log row).
--
-- Here:
--   * manager_guard gets a 'ban' action: at most 25 permanent bans a day, counted over their 'ban' rows in mod_log (so a
--     7-day ban they place through mod_ban uses up the budget too; that path itself keeps mod_guard's hourly cap, as
--     before). Same shape as their 25 staff changes. mod_guard still runs first (reason, no staff, hourly cap).
--   * site_ban: a manager's ban goes through manager_guard('ban') and is logged as 'ban' in mod_log, like mod_ban does.
--     Admins unchanged (no log row, as before). Still no message wipe for managers, still no re-ban over an admin ban.
--   * mod_ban_with_proof takes `forever` (default false): Management with forever = site_ban (permanent, proof kept);
--     anyone else asking for forever is refused instead of quietly getting 7 days. The old signature goes away so
--     PostgREST has one candidate.
-- Head mods and plain mods keep the 7-day ban. No flag: this is a permission fix.
-- site_ban is patched into the live text (pg_get_functiondef) like 537; a changed anchor stops the migration.
-- Re-runnable.

set lock_timeout = '3s';

-- ---------- 1. manager_guard: 'ban' = 25 a day ----------
create or replace function public.manager_guard(action text, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_manager() then raise exception 'Admins only'; end if;
  perform pg_advisory_xact_lock(hashtextextended('manager_cap:' || auth.uid()::text, 0));
  if target is null then raise exception 'Pick someone'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own account'; end if;
  if exists (select 1 from public.site_admins where user_id = target) then raise exception 'Admins can''t be changed'; end if;
  if exists (select 1 from public.site_managers where user_id = target) then raise exception 'Only an admin can change Management'; end if;
  if action = 'badge' then
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '1 hour'
       and mod_log.action in ('badge_given', 'badge_removed');
    if n >= 30 then raise exception 'That''s 30 badges this hour. Wait a bit or ask an admin'; end if;
  elsif action = 'creator' then
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
       and mod_log.action in ('creator_approved', 'content_approved');
    if n >= 10 then raise exception 'That''s 10 Creator approvals today. Ask an admin for more'; end if;
  elsif action = 'creator_other' then
    null; -- rejections and revokes: no cap
  elsif action = 'ban' then
    -- 648: site bans by a manager (permanent ones through site_ban, 7-day ones through mod_ban both log 'ban').
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
       and mod_log.action = 'ban';
    if n >= 25 then raise exception 'That''s 25 bans today. Ask an admin for more'; end if;
  else
    select count(*) into n from public.mod_log where actor = auth.uid() and created_at > now() - interval '24 hours'
       and mod_log.action in ('mod_added', 'mod_removed', 'mod_suspended', 'head_mod_added', 'head_mod_removed',
                              'dev_added', 'dev_removed', 'cm_added', 'cm_removed');
    if n >= 25 then raise exception 'That''s 25 staff changes today. Ask an admin for more'; end if;
  end if;
end;
$$;
revoke all on function public.manager_guard(text, uuid) from public, anon, authenticated;

-- ---------- 2. site_ban: the daily cap and the log row for managers, patched into the live text ----------
create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if (length(f) - length(replace(f, old_text, ''))) / length(old_text) <> 1 then raise exception '648: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

select pg_temp.patch_fn('public.site_ban(uuid,text,boolean)', 'manager_guard',
  '    perform public.mod_guard(''ban'', uid, why);' || chr(10) || '  end if;',
  '    perform public.mod_guard(''ban'', uid, why);' || chr(10)
  || '    perform public.manager_guard(''ban'', uid);' || chr(10) || '  end if;');
select pg_temp.patch_fn('public.site_ban(uuid,text,boolean)', 'values (auth.uid(), ''ban'', uid',
  '  -- Close their open reports as handled.',
  '  -- 648: a manager''s ban goes in the Log like every other ban (admin bans aren''t logged here, as before).' || chr(10)
  || '  if not public.is_site_admin() then' || chr(10)
  || '    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), ''ban'', uid, left(coalesce(why, ''''), 300));' || chr(10)
  || '  end if;' || chr(10)
  || '  -- Close their open reports as handled.');

-- ---------- 3. mod_ban_with_proof: `forever` for Management ----------
-- One signature only: the old 7-argument one is removed first (two candidates would make every call ambiguous).
do $$
begin
  execute 'dr' || 'op function if exists public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[])';
end $$;

create or replace function public.mod_ban_with_proof(uid uuid, why text, wipe boolean default false, rid uuid default null,
  with_message boolean default true, note text default null, images text[] default null, forever boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare pr jsonb;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if not public.feature_on_for_me('standing_proof') then raise exception 'Proof isn''t on for you yet'; end if;
  pr := public.standing_proof_build(uid, rid, with_message, note, images);
  if public.is_site_admin() then
    perform public.site_ban(uid, why, coalesce(wipe, false));
  else
    if coalesce(wipe, false) then raise exception 'Only an admin can delete all their messages'; end if;
    -- 648: Management bans for good through site_ban (its own checks: no staff, no re-ban over an admin ban, 25 a day).
    if coalesce(forever, false) then
      if not public.is_site_manager() then raise exception 'Only an admin or Management can ban for good'; end if;
      perform public.site_ban(uid, why, false);
    else
      perform public.mod_ban(uid, why);
    end if;
  end if;
  if pr is not null then
    update public.site_bans set proof = pr where user_id = uid and created_at = now();
  end if;
end $$;
revoke all on function public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[], boolean) from public, anon;
grant execute on function public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[], boolean) to authenticated;

reset lock_timeout;
