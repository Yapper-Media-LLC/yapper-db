-- 565: a budget on how much a site mod can do in a short time (flag mod_burst_guard, test: Antic; publish = mode everyone).
-- Antic, Oct 26, after the HQ wipe: "mods deleting like 1,000 decorations, that shouldn't be possible". On the day a
-- site mod took down 1,870 decorations in six minutes, lifted 61 bans and approved 65 verifications. mod_guard's hourly
-- caps only cover the RPCs that call it: review_community_deco and admin_verify_bot never did (takedowns had no cap at
-- all), ten other staff RPCs write the log without it, and caps are per action with no total, so hitting one just
-- moved her on to the next. Three layers, all behind the flag so Antic can watch the counts first:
-- 1. mod_burst_check: more than 60 logged actions in 10 minutes or 200 in an hour, across every action, and the
--    mod's powers pause (site_moderators.suspended_at, mod_log auto_suspended, "Automatic: ..." reason, the Mod
--    Center already shows paused mods and admins lift it there). The action that reaches the line is the last one let
--    through (the pause has to commit with something; an exception would roll it back); everything after is refused
--    with a clear message. mod_guard calls it first, so every guarded RPC is covered.
-- 2. Every staff RPC that writes mod_log calls mod_guard. New caps: deco takedown 10 an hour, deco review 60, bot
--    review 20, copyright strikes 10, suspension lifts 10, bot promotion ends 10, votes opened 10, image removals 30.
--    The live text of each RPC is patched at its staff check (pg_get_functiondef, like 547): a changed anchor stops the
--    migration, a missing function (PGlite) is skipped.
-- 3. The tables refuse it too, so a future RPC can't forget the guard: community_decos (a takedown past 10 an hour by
--    the same reviewer) and site_bans (an unban past mod_guard's 60 an hour) have before-update triggers that count
--    and run the burst check. Security definer RPCs pass through with auth.uid() set, so these see the mod, not the
--    definer. No signed-in user (service role, dashboard) and site admins pass.
-- 547 (mod_limit_boost) scales mod_guard's per-action caps when applied; this file keeps its anchor ("if n >= lim then",
-- once) and re-applies its line if 547 landed first. The burst budget and the two table caps are hard ceilings, not scaled. Re-runnable. DDL, apply in quiet hours.

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_burst_guard', 'Mod burst guard', 'Pause a site mod who does more than 60 actions in 10 minutes or 200 in an hour, and cap deco takedowns, bot reviews and the other staff actions', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- 1. the burst budget ----------
-- Counts the caller's mod_log rows (anything they did, not system rows or the limit-boost log). Pauses them at the line.
create or replace function public.mod_burst_check()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n10 int; n60 int; why text;
begin
  if me is null or public.is_site_admin() then return; end if;
  if not public.feature_on('mod_burst_guard', null) then return; end if;
  if exists (select 1 from public.site_moderators where user_id = me and suspended_at is not null) then
    -- Paused by this very statement (mod_guard ran a moment ago, then the table trigger asks again): let the action
    -- finish, so the pause commits with it. now() is fixed per transaction, so only a pause set here matches.
    if exists (select 1 from public.site_moderators where user_id = me and suspended_at = now()) then return; end if;
    raise exception 'Your moderator powers are paused. An admin can lift that in the Mod Center.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('mod_burst:' || me::text, 0));
  -- The budget restarts at the last pause: once an admin lifts it, the old rows don't trip it again at once.
  select count(*) filter (where created_at > now() - interval '10 minutes'), count(*)
    into n10, n60
    from public.mod_log
   where actor = me and created_at > now() - interval '1 hour'
     and created_at > coalesce((select max(l.created_at) from public.mod_log l where l.actor = me and l.action = 'auto_suspended' and l.created_at > now() - interval '1 hour'), '-infinity')
     -- badge_auto rides along with an approval (two rows for one decision): not counted, so the line is always hit exactly.
     and action not in ('auto_suspended', 'mod_limit_boost', 'badge_auto');
  if n10 >= 60 or n60 >= 200 then
    raise exception 'Slow down: that''s a lot of actions in a short time (60 in 10 minutes or 200 an hour). Ask an admin if this is real work.';
  end if;
  if n10 = 59 or n60 = 199 then
    why := 'Automatic: ' || case when n10 = 59 then '60 actions in 10 minutes' else '200 actions in an hour' end;
    update public.site_moderators set suspended_at = now(), suspended_reason = why where user_id = me and suspended_at is null;
    insert into public.mod_log (actor, action, reason) values (me, 'auto_suspended', why);
  end if;
end $$;
-- Only mod_guard and the table triggers call it (definer code): nothing for the app to call.
revoke all on function public.mod_burst_check() from public, anon, authenticated;

-- ---------- 2. mod_guard: the burst check first, then the per-action caps (live text of Oct 26 plus the new ones) ----------
create or replace function public.mod_guard(action text, target uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then
    if public.feature_on('mod_burst_guard', null) and exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is not null) then
      raise exception 'Your moderator powers are paused. An admin can lift that in the Mod Center.';
    end if;
    raise exception 'Moderators only';
  end if;
  -- After the mod check: the pause the budget sets has to let this one action finish (see the top).
  perform public.mod_burst_check();
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action
    when 'ban' then 80 when 'takedown' then 5 when 'purge' then 20 when 'timeout' then 60 when 'reset' then 20
    when 'unban' then 60 when 'badge' then 10 when 'untimeout' then 30 when 'verify' then 60
    when 'unwarn' then 30 when 'mark_bot' then 20 when 'server_hide' then 10
    when 'deco_takedown' then 10 when 'deco_review' then 60 when 'bot_review' then 20 when 'copyright' then 10
    when 'suspension_lift' then 10 when 'bot_promo' then 10 when 'vote' then 10 when 'image_removal' then 30
    else 60 end;
  logged := case action
    when 'badge' then array['badge_given', 'badge_removed']
    when 'takedown' then array['server_takedown']
    when 'untimeout' then array['timeout_cleared']
    when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof']
    when 'mark_bot' then array['marked_bot', 'unmarked_bot']
    when 'reset' then array['reset', 'profile_reset']
    when 'deco_takedown' then array['deco_removed']
    when 'deco_review' then array['deco_approved', 'deco_rejected', 'deco_check_cleared']
    when 'bot_review' then array['bot_verified', 'bot_rejected']
    when 'copyright' then array['copyright_strike', 'copyright_strike_removed']
    when 'suspension_lift' then array['suspension_lifted']
    when 'bot_promo' then array['bot_promo_ended']
    when 'vote' then array['vote_opened']
    when 'image_removal' then array['image_removal_removed', 'image_removal_need_info', 'image_removal_rejected']
    else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim;
  end if;
end; $$;
revoke all on function public.mod_guard(text, uuid, text) from public, anon;
grant execute on function public.mod_guard(text, uuid, text) to authenticated;

-- Patch a live function at one anchor. Skips a function that isn't there (PGlite) or is already patched (marker).
create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if (length(f) - length(replace(f, old_text, ''))) / length(old_text) <> 1 then raise exception '565: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

-- 547 landed first: keep its scaled caps.
do $$ begin
  if to_regprocedure('public.mod_limit_boost()') is not null then
    perform pg_temp.patch_fn('public.mod_guard(text,uuid,text)', 'mod_limit_boost',
      'if n >= lim then',
      'lim := ceil(lim * public.mod_limit_boost())::int;' || chr(10) || '  if n >= lim then');
  end if;
end $$;

-- ---------- the RPCs that wrote the log without a guard ----------
-- Decoration review: a takedown of an approved piece has its own small cap; approvals and rejections share the review cap.
select pg_temp.patch_fn('public.review_community_deco(uuid,text,text)', 'mod_guard',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;' || chr(10) ||
  '  perform public.mod_guard(case when p_status = ''removed'' then ''deco_takedown'' else ''deco_review'' end, null, p_note);');
select pg_temp.patch_fn('public.staff_clear_deco_check(uuid,text)', 'mod_guard',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;',
  'if not (public.is_site_admin() or public.is_site_mod()) then raise exception ''Staff only''; end if;' || chr(10) ||
  '  perform public.mod_guard(''deco_review'', null, p_note);');
select pg_temp.patch_fn('public.admin_verify_bot(uuid,boolean,text,boolean)', 'mod_guard',
  'if not public.can_review_bots() then raise exception ''Moderators only''; end if;',
  'if not public.can_review_bots() then raise exception ''Moderators only''; end if;' || chr(10) ||
  '  perform public.mod_guard(''bot_review'', null, note);');
select pg_temp.patch_fn('public.staff_add_copyright_strike(uuid,uuid,text)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''copyright'', null, p_notice);');
select pg_temp.patch_fn('public.staff_remove_copyright_strike(uuid,text)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''copyright'', null, why);');
select pg_temp.patch_fn('public.staff_end_bot_promotion(uuid,text)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''bot_promo'', null, why);');
select pg_temp.patch_fn('public.staff_handle_image_removal(uuid,text,text)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''image_removal'', null, note);');
select pg_temp.patch_fn('public.staff_lift_suspension(uuid)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''suspension_lift'', null, null);');
select pg_temp.patch_fn('public.staff_review_auto_ban(uuid)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Staff only''; end if;',
  'if not public.is_staff() then raise exception ''Staff only''; end if;' || chr(10) || '  perform public.mod_guard(''auto_ban_reviewed'', null, null);');
select pg_temp.patch_fn('public.staff_vote_open(uuid,text)', 'mod_guard',
  'if not public.is_staff() then raise exception ''Moderators only''; end if;',
  'if not public.is_staff() then raise exception ''Moderators only''; end if;' || chr(10) || '  perform public.mod_guard(''vote'', null, why);');
-- Left alone on purpose: staff_vote_cast (one ballot per vote by key), resolve_report (server mods use it too; the
-- staff branch only logs a reopen), note_device and bug_hunter_on_fix (system rows, actor null or automatic).

-- ---------- 3. the tables refuse it too ----------
-- A takedown (status to removed) past 10 an hour by the same reviewer, or by a paused mod, or over the burst budget.
create or replace function public.deco_takedown_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null or new.status <> 'removed' or old.status = 'removed' then return new; end if;
  if public.is_site_admin() or not public.feature_on('mod_burst_guard', null) then return new; end if;
  perform public.mod_burst_check();
  -- Counted from the log, like mod_guard: an artist withdrawing a piece also sets status = removed and must not spend
  -- the approving mod's cap.
  select count(*) into n from public.mod_log where actor = me and action = 'deco_removed' and created_at > now() - interval '1 hour';
  if n >= 10 then raise exception 'You''ve taken down 10 decorations this hour. Ask an admin for the rest.'; end if;
  return new;
end $$;
revoke all on function public.deco_takedown_guard() from public, anon, authenticated;
do $$ begin
  if to_regclass('public.community_decos') is not null then
    execute 'create or replace trigger community_decos_takedown_guard before update of status on public.community_decos for each row execute function public.deco_takedown_guard()';
  end if;
end $$;

-- An unban (expires_at brought into the past) past 60 an hour, or by a paused mod, or over the burst budget.
create or replace function public.unban_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null or new.expires_at is null or new.expires_at > now() then return new; end if;
  if old.expires_at is not null and old.expires_at <= now() then return new; end if;
  if public.is_site_admin() or not public.feature_on('mod_burst_guard', null) then return new; end if;
  perform public.mod_burst_check();
  select count(*) into n from public.mod_log where actor = me and action = 'unban' and created_at > now() - interval '1 hour';
  if n >= 60 then raise exception 'You''ve lifted 60 bans this hour. Ask an admin for the rest.'; end if;
  return new;
end $$;
revoke all on function public.unban_guard() from public, anon, authenticated;
create or replace trigger site_bans_unban_guard before update of expires_at on public.site_bans
  for each row execute function public.unban_guard();

reset lock_timeout;
