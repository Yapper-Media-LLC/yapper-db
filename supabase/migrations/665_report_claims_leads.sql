-- 665: Report claims for leads (flag report_claims, 643). Firefox (head mod): "Add an option for head mods to take over
-- and unclaim the report, some mods claim and don't know what to do. Also add an unclaim option for mods." Head mods
-- and Management now pass where only admins did: Take over someone else's live claim at any time, or Unclaim it
-- (both logged in mod_log against the reported person, and the queue update reaches the old claimer through
-- reports_bc). An admin's claim stays the admins' and Management's: head mods can't take it over or unclaim it.
-- Mods still unclaim only their own, and take over only after 30 minutes without action. Only the two functions
-- change; their bodies are 643's apart from the override check and the release log row. Re-runnable.
set lock_timeout = '4s';

-- May I take over or release this holder's live claim before the 30 minutes are up? Admins and Management: anyone's.
-- Head mods: anyone's but an admin's.
create or replace function public.report_claim_may_override(holder uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_manager()
      or (public.is_head_mod() and not exists (select 1 from public.site_admins where user_id = holder))
$$;

create or replace function public.claim_reports(rids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); holder uuid; holder_tgt uuid; held int; n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('report_claims') then raise exception 'Not available'; end if;
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  -- Two mods pressing Claim at the same moment: the second waits for the first and then sees their claim.
  perform 1 from public.reports where id = any(rids) and status = 'open' for update;
  select claimed_by, target_id into holder, holder_tgt from public.reports
   where id = any(rids) and status = 'open'
     and claimed_by is not null and claimed_by <> uid and claimed_at > now() - public.report_claim_window()
   order by claimed_at desc limit 1;
  if holder is not null and not public.report_claim_may_override(holder) then
    if public.is_head_mod() then
      raise exception 'Claimed by %, an admin. Only admins and Management can take that over.',
        coalesce((select username from public.profiles where id = holder), 'someone');
    end if;
    raise exception 'Claimed by %. You can take over after 30 minutes without action.',
      coalesce((select username from public.profiles where id = holder), 'someone');
  end if;
  -- At most 5 cases at once (a case = the reported person, else the reported server (663), else the report itself).
  -- Reports of a case I already hold don't count again, so new reports on it can be claimed.
  select count(distinct coalesce(target_id::text, 's:' || reported_server_id::text, id::text)) into held from public.reports
   where claimed_by = uid and status = 'open' and claimed_at > now() - public.report_claim_window()
     and coalesce(target_id::text, 's:' || reported_server_id::text, id::text) not in (
       select coalesce(r.target_id::text, 's:' || r.reported_server_id::text, r.id::text) from public.reports r where r.id = any(rids));
  if held >= 5 then raise exception 'You already hold 5 claims. Finish or unclaim one first.'; end if;
  update public.reports set claimed_by = uid, claimed_at = now() where id = any(rids) and status = 'open';
  get diagnostics n = row_count;
  if holder is not null then
    insert into public.mod_log (actor, action, target_id, reason)
    values (uid, 'report_claim_taken', holder_tgt, 'Took over the case from ' || coalesce((select username from public.profiles where id = holder), 'someone'));
  end if;
  return n;
end $$;

-- Let go of these reports: my own claims, or ones report_claim_may_override allows (logged). Returns how many were released.
create or replace function public.unclaim_reports(rids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  -- Releasing someone else's live claim: one log row per holder and reported person.
  insert into public.mod_log (actor, action, target_id, reason)
  select distinct uid, 'report_claim_released', r.target_id, 'Unclaimed the case from ' || coalesce(p.username, 'someone')
    from public.reports r left join public.profiles p on p.id = r.claimed_by
   where r.id = any(rids) and r.claimed_by is not null and r.claimed_by <> uid
     and r.status = 'open' and r.claimed_at > now() - public.report_claim_window()
     and public.report_claim_may_override(r.claimed_by);
  update public.reports set claimed_by = null, claimed_at = null
   where id = any(rids) and claimed_by is not null and (claimed_by = uid or public.report_claim_may_override(claimed_by));
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.report_claim_may_override(uuid) from public, anon, authenticated;
revoke all on function public.claim_reports(uuid[]) from public, anon;
revoke all on function public.unclaim_reports(uuid[]) from public, anon;
grant execute on function public.claim_reports(uuid[]) to authenticated;
grant execute on function public.unclaim_reports(uuid[]) to authenticated;

update public.feature_flags
   set description = 'Mod Center queue: Claim a case so nobody else works on it. Others see who has it and can take over after 30 minutes without action. Head mods, Management and admins can take over or unclaim any time (an admin''s claim: admins and Management only). 5 claims per mod.'
 where key = 'report_claims';

reset lock_timeout;
