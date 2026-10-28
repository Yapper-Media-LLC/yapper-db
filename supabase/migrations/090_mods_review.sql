-- Moderators can do more of the daily work (applied live Oct 15), all of it in the Log:
--   * lift automatic (image scanner) and temporary bans; confirmed bans stay admin-only
--   * review creator verification (approve, reject, ask for proof)
--   * hand out the Bug Hunter badge when closing bug reports
-- site_unban now expires the ban instead of removing the row, so the history stays visible.
create or replace function public.site_unban(uid uuid)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans;
begin
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if not public.is_site_mod() then raise exception 'Moderators only'; end if;
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  update public.media_scans set forgiven = true where user_id = uid and verdict = 'blocked' and not forgiven;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unban', uid, coalesce(b.reason, ''));
end;
$function$;

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default ''::text)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare r public.verification_requests; label text;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
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

create or replace function public.ask_verification_proof(rid uuid, p_note text default ''::text)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare r public.verification_requests;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  update public.verification_requests set status = 'needs_proof',
    review_note = coalesce(nullif(btrim(p_note), ''), 'Put "yapper: ' || (select username from public.profiles where id = r.user_id) || '" in your channel bio or description so we can see it''s really you.'),
    asked_at = now(), proof_added_at = null, reviewed_by = auth.uid() where id = rid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'verify_ask_proof', r.user_id, coalesce(p_note, ''));
  perform public.bc('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $function$;

create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean)
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff') then raise exception 'Unknown badge'; end if;
  update public.profiles set badges = case when on_off then array(select distinct unnest(badges || badge)) else array_remove(badges, badge) end where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

drop policy if exists "staff see verification requests" on public.verification_requests;
create policy "staff see verification requests" on public.verification_requests for select to authenticated using (public.is_staff());
