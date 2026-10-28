-- 522: site moderators can give and take the verified badge (Antic, Oct 25: "give mods ability to verify ppl").
-- Flag mod_verify (test: Antic; add a mod's id to users to let them try it). The check is per user, like
-- head_mod_badges (466): feature_on(.., null) has no server to look at.
-- 351 made approving admins only after a mod approved their own alt. With the flag on, a moderator's approve still
-- refuses:
--   * their own request (350, unchanged),
--   * a request from an admin or another moderator (mod_guard with the target),
--   * an account that shares a network with any staff account (its signup IP or a username sign-in IP matches a
--     staff account's signup or sign-in IP): maybe an alt, so it waits for an admin. Best effort only:
--     login_attempts keeps about a day of username sign-ins (email sign-ins aren't logged) and signup_log one IP per
--     account, so a careful alt can slip past. Keep the flag to trusted mods. Shared networks (mobile, school)
--     refuse more than needed; that fails safe,
-- and counts toward mod_guard's hourly 'verify' limit. The name and one-account-per-channel checks (479) apply to
-- everyone. unverify: moderators may take the badge off with a reason (5+ characters), never from staff or
-- themselves, hourly limit via mod_guard. Both still write mod_log ('verify' / 'unverify'). Admins are unchanged,
-- except that unverify on someone who isn't verified now says so instead of logging a no-op.
-- review_verification is the live text from Oct 25 (pg_get_functiondef, = 350 + 351 + 479) with the 351 check
-- widened. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_verify', 'Mods verify people', 'Site moderators can approve verification requests and remove the verified badge', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default ''::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
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
    if not public.feature_on('mod_verify', null) then
      raise exception 'Only admins can approve verifications. Ask for proof or leave it for an admin.';
    end if;
    -- Shares a network with any staff account: maybe a mod's alt (or a friend's), so an admin decides.
    if exists (
      -- (A staff target is refused by mod_guard below, with its own message.)
      with staff as (
        select user_id from public.site_moderators where user_id <> r.user_id
        union select user_id from public.site_admins where user_id <> r.user_id
      ), theirs as (
        select s.ip from public.signup_log s where s.user_id = r.user_id
        union
        select la.ip from public.login_attempts la join public.profiles p on lower(la.username) = lower(p.username)
         where p.id = r.user_id and la.ok
      )
      select 1 from theirs t
      where exists (select 1 from public.signup_log s join staff on staff.user_id = s.user_id where s.ip = t.ip)
         or exists (select 1 from public.login_attempts la join public.profiles p on lower(p.username) = lower(la.username)
                    join staff on staff.user_id = p.id where la.ip = t.ip and la.ok)
    ) then
      raise exception 'This account shares a network with a staff account. Leave it for an admin.';
    end if;
  end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  if approve then
    k := public.verify_name_key(r.handle);
    if k <> '' then perform pg_advisory_xact_lock(hashtext('verify:' || k)); end if;
    select p.username into other from public.profiles p
     where p.id <> r.user_id and p.verified_as is not null
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
  -- A moderator's approve names the target, so mod_guard refuses staff accounts (admins return at once).
  perform public.mod_guard('verify', case when approve then r.user_id end, null);
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

create or replace function public.unverify(uid uuid, p_note text default ''::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_site_admin() then
    if not (public.is_site_mod() and public.feature_on('mod_verify', null)) then raise exception 'Admins only'; end if;
    if length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
    -- Refuses staff targets and yourself, and caps it per hour.
    perform public.mod_guard('unverify', uid, p_note);
  end if;
  update public.profiles set verified_as = null where id = uid and verified_as is not null;
  if not found then raise exception 'They aren''t verified'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unverify', uid, coalesce(p_note, ''));
end;
$function$;

revoke all on function public.review_verification(uuid, boolean, text), public.unverify(uuid, text) from public, anon;
grant execute on function public.review_verification(uuid, boolean, text), public.unverify(uuid, text) to authenticated;
