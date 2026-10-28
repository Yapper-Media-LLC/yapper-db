-- Hourly limits for every moderator action, not just bans and timeouts (applied live Oct 15).
-- mod_guard counts the mod_log rows a guard action produces, so limits can't be dodged by the log name.

create or replace function public.mod_guard(action text, target uuid, why text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action
    when 'ban' then 15 when 'timeout' then 60 when 'reset' then 20
    when 'unban' then 10 when 'badge' then 10 when 'untimeout' then 30 when 'verify' then 60
    when 'unwarn' then 30 when 'mark_bot' then 20 else 60 end;
  logged := case action
    when 'badge' then array['badge_given', 'badge_removed']
    when 'untimeout' then array['timeout_cleared']
    when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof']
    when 'mark_bot' then array['marked_bot', 'unmarked_bot']
    when 'reset' then array['reset', 'profile_reset']
    else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    update public.site_moderators set suspended_at = now(), suspended_reason = 'Automatic: more than ' || lim || ' ' || action || 's in an hour' where user_id = auth.uid();
    insert into public.mod_log (actor, action, reason) values (auth.uid(), 'auto_suspended', 'More than ' || lim || ' ' || action || 's in an hour');
    raise exception 'You''ve hit the hourly limit for that; your moderator powers are paused until an admin reviews.';
  end if;
end; $function$;

create or replace function public.site_unban(uid uuid) returns void
language plpgsql security definer set search_path to 'public' as $function$
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

create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean) returns void
language plpgsql security definer set search_path to 'public' as $function$
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff') then raise exception 'Unknown badge'; end if;
  perform public.mod_guard('badge', uid, null);
  update public.profiles set badges = case when on_off then array(select distinct unnest(badges || badge)) else array_remove(badges, badge) end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

create or replace function public.admin_clear_timeout(uid uuid) returns void
language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.mod_guard('untimeout', uid, null);
  update public.profiles set muted_until = null, muted_reason = null, voice_muted_until = null where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'timeout_cleared', uid, '');
end; $function$;

create or replace function public.mod_mark_bot(uid uuid, on_off boolean) returns void
language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if exists (select 1 from public.bot_accounts where user_id = uid) then raise exception 'That is one of Yapper''s own bots'; end if;
  perform public.mod_guard('mark_bot', uid, null);
  update public.profiles set badges = case when on_off then array(select distinct unnest(coalesce(badges, '{}'::text[]) || array['bot']))
                                           else array_remove(coalesce(badges, '{}'::text[]), 'bot') end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'marked_bot' else 'unmarked_bot' end, uid, '');
end $function$;

create or replace function public.mod_remove_warning(wid uuid) returns void
language plpgsql security definer set search_path to 'public' as $function$
declare w public.user_warnings;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into w from public.user_warnings where id = wid;
  if w.id is null or w.removed_at is not null then raise exception 'That warning is already gone'; end if;
  if not public.is_site_admin() and w.by is distinct from auth.uid() then raise exception 'Only the moderator who gave it (or an admin) can remove it'; end if;
  perform public.mod_guard('unwarn', w.user_id, null);
  update public.user_warnings set removed_at = now(), removed_by = auth.uid(), seen_at = coalesce(seen_at, now()) where id = wid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unwarn', w.user_id, left('Removed warning: ' || w.reason, 300));
end $function$;

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default '') returns void
language plpgsql security definer set search_path to 'public' as $function$
declare r public.verification_requests; label text;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  perform public.mod_guard('verify', null, null);
  update public.verification_requests
    set status = case when approve then 'approved' else 'rejected' end, reviewed_by = auth.uid(), reviewed_at = now(), review_note = coalesce(p_note, '')
    where id = rid;
  if approve then
    label := case r.platform when 'youtube' then 'YouTube' when 'twitch' then 'Twitch' when 'tiktok' then 'TikTok'
                             when 'instagram' then 'Instagram' when 'x' then 'X' else 'Creator' end || ' · ' || r.handle;
    update public.profiles set verified_as = label where id = r.user_id;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), case when approve then 'verify' else 'verify_reject' end, r.user_id, coalesce(p_note, '') || ' (' || r.platform || ' ' || r.handle || ')');
  perform public.bc('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $function$;

create or replace function public.ask_verification_proof(rid uuid, p_note text default '') returns void
language plpgsql security definer set search_path to 'public' as $function$
declare r public.verification_requests;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  perform public.mod_guard('verify', null, null);
  update public.verification_requests set status = 'needs_proof',
    review_note = coalesce(nullif(btrim(p_note), ''), 'Put "yapper: ' || (select username from public.profiles where id = r.user_id) || '" in your channel bio or description so we can see it''s really you.'),
    asked_at = now(), proof_added_at = null, reviewed_by = auth.uid() where id = rid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'verify_ask_proof', r.user_id, coalesce(p_note, ''));
  perform public.bc('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $function$;
