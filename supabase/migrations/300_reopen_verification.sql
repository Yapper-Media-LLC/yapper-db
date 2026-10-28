-- 300: staff can undo a verification rejection that was a mistake.
-- Before this a rejection was final ("Already reviewed") and the user could not apply again for 7 days.
-- reopen_verification puts the request back in the queue as pending, only while the 7 day wait is still running,
-- only for the user's latest request, and only if they have no badge and nothing else open.
-- No table or column changes: one function (DDL), so apply it once, outside the evening peak.

create or replace function public.reopen_verification(rid uuid, p_note text default '')
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r public.verification_requests;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status <> 'rejected' then raise exception 'Only rejected requests can be reopened'; end if;
  if r.reviewed_at is null or r.reviewed_at < now() - interval '7 days' then
    raise exception 'That rejection is older than 7 days. They can apply again themselves';
  end if;
  -- Target = the applicant: a mod can't reopen their own rejection or a staff member's. Own action name, so
  -- reopens have their own hourly limit in mod_guard (default 60) and don't eat the 'verify' one.
  perform public.mod_guard('verify_reopen', r.user_id, null);
  if public.is_site_banned(r.user_id) then raise exception 'That account is banned'; end if;
  if exists (select 1 from public.profiles where id = r.user_id and verified_as is not null) then
    raise exception 'They are already verified';
  end if;
  if exists (select 1 from public.verification_requests
             where user_id = r.user_id and id <> r.id and (status in ('pending', 'needs_proof') or created_at > r.created_at)) then
    raise exception 'They have a newer request. Review that one instead';
  end if;
  update public.verification_requests
    set status = 'pending', reviewed_by = null, reviewed_at = null, review_note = ''
    where id = rid;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), 'verify_reopen', r.user_id,
          left(coalesce(nullif(btrim(p_note), ''), 'Rejected by mistake'), 300) || ' (' || r.platform || ' ' || r.handle || ')');
  perform public.bc('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $function$;

revoke all on function public.reopen_verification(uuid, text) from public, anon;
grant execute on function public.reopen_verification(uuid, text) to authenticated;
