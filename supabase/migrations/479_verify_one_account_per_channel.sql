-- 479: one verified account per channel, checked when an admin approves. Re-runnable. NOT applied (database freeze Oct 25).
-- Bug 89678f4f: "u can get it on multiple accounts with verified badge if u just change the handle / username".
-- apply_verification refuses a channel that's already verified, but only at the moment someone applies. Two accounts
-- could apply for the same channel while neither was verified yet (or one renamed to the channel name, applied, and
-- renamed away again while waiting), and review_verification approved both without looking again: it never checked
-- for another account with that channel, nor that the applicant's name still matched it. On Oct 25 one channel name
-- was on two verified accounts.
-- Now approving refuses when another account already carries that channel, or when the applicant's username and
-- display name no longer match the channel. An advisory lock on the channel key stops two admins approving two
-- applications for the same channel at the same moment. Rejecting is unchanged. The rest is the live text from
-- Oct 25 (pg_get_functiondef).

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default ''::text)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare r public.verification_requests; label text; k text; other text; me_name text; me_display text;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.user_id = auth.uid() and not public.is_site_admin() then
    raise exception 'You can''t review your own verification. Ask another moderator.';
  end if;
  if approve and not public.is_site_admin() then
    raise exception 'Only admins can approve verifications. Ask for proof or leave it for an admin.';
  end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  -- 479: the channel can only be on one account, and the applicant still has to go by its name.
  if approve then
    k := public.verify_name_key(r.handle);
    if k <> '' then perform pg_advisory_xact_lock(hashtext('verify:' || k)); end if;
    select p.username into other from public.profiles p
     where p.id <> r.user_id and p.verified_as is not null
       -- Matches profiles_verified_name_key_idx (171), so this is an index lookup, not a scan of profiles.
       and public.name_key(public.verify_name_key(split_part(p.verified_as, ' · ', 2))) = public.name_key(k)
       and public.verify_name_key(split_part(p.verified_as, ' · ', 2)) = k
     limit 1;
    if other is not null then
      raise exception 'That channel is already verified on another account (@%). Reject this one, or take the badge off the other account first.', other;
    end if;
    select username, display_name into me_name, me_display from public.profiles where id = r.user_id;
    if k = '' or k not in (public.verify_name_key(me_name), public.verify_name_key(me_display)) then
      raise exception 'Their name doesn''t match the channel (%) any more. Ask them to change it back, then approve.', r.handle;
    end if;
  end if;
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
revoke all on function public.review_verification(uuid, boolean, text) from public, anon;
grant execute on function public.review_verification(uuid, boolean, text) to authenticated;
