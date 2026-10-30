-- 643: Report claims (flag report_claims, test: Antic + the HQ test server). Tripex (HQ mod): "the claim system that
-- allows you to claim a report and not get it sniped." A staff member claims the open reports of a case; the queue
-- shows who holds it, other mods see it greyed with "Claimed by NAME" and can only take over after 30 minutes without
-- action by the claimer (admins at any time). A claim is a timestamp on the report row: nothing expires it, readers
-- and claim_reports just treat a claim older than 30 minutes as free (no cron). Resolving a report clears its claim
-- (trigger, so every path counts: resolve_report, resolve_reports, bans closing reports). At most 5 cases held per
-- mod. The reports_bc trigger (048) already sends every report update to staff, so the queue updates live. Re-runnable.
set lock_timeout = '4s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('report_claims', 'Report claims', 'Mod Center queue: Claim a case so nobody else works on it. Others see who has it and can take over after 30 minutes without action (admins any time). 5 claims per mod.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.reports add column if not exists claimed_by uuid references public.profiles (id) on delete set null;
alter table public.reports add column if not exists claimed_at timestamptz;
-- Claimed rows are a handful at a time: the partial index covers the FK, the per-mod count and the "claimed by me" lookups.
-- Plain create index, not concurrently: reports had 9,133 rows on Oct 28 (a scan of milliseconds under the 4 s lock_timeout),
-- and this keeps the file one SQL editor paste. Switch to a separate `concurrently` run if reports ever grows into the hundreds of thousands.
create index if not exists reports_claimed_idx on public.reports (claimed_by, claimed_at) where claimed_by is not null;

-- How long a claim holds without the claimer touching it. One place, read by both RPCs.
create or replace function public.report_claim_window()
returns interval language sql immutable as $$ select interval '30 minutes' $$;

-- Claim (or refresh my claim on) these reports. Usually the open reports of one case, from the queue.
-- Refused: not staff, flag off for me, someone else's live claim (admins pass and the takeover is logged),
-- or already holding 5 cases. Returns how many rows are now mine.
create or replace function public.claim_reports(rids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid(); adm boolean; holder uuid; holder_tgt uuid; held int; n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on_for_me('report_claims') then raise exception 'Not available'; end if;
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  adm := public.is_site_admin();
  -- Two mods pressing Claim at the same moment: the second waits for the first and then sees their claim.
  perform 1 from public.reports where id = any(rids) and status = 'open' for update;
  select claimed_by, target_id into holder, holder_tgt from public.reports
   where id = any(rids) and status = 'open'
     and claimed_by is not null and claimed_by <> uid and claimed_at > now() - public.report_claim_window()
   order by claimed_at desc limit 1;
  if holder is not null and not adm then
    raise exception 'Claimed by %. You can take over after 30 minutes without action.',
      coalesce((select username from public.profiles where id = holder), 'someone');
  end if;
  -- At most 5 cases at once (a case = the reported person, or the report itself when there is none).
  -- Reports of a case I already hold don't count again, so new reports on it can be claimed.
  select count(distinct coalesce(target_id::text, id::text)) into held from public.reports
   where claimed_by = uid and status = 'open' and claimed_at > now() - public.report_claim_window()
     and coalesce(target_id::text, id::text) not in (select coalesce(r.target_id::text, r.id::text) from public.reports r where r.id = any(rids));
  if held >= 5 then raise exception 'You already hold 5 claims. Finish or release one first.'; end if;
  update public.reports set claimed_by = uid, claimed_at = now() where id = any(rids) and status = 'open';
  get diagnostics n = row_count;
  if holder is not null then
    insert into public.mod_log (actor, action, target_id, reason)
    values (uid, 'report_claim_taken', holder_tgt, 'Took over the case from ' || coalesce((select username from public.profiles where id = holder), 'someone'));
  end if;
  return n;
end $$;

-- Let go of these reports: my own claims, or anyone's for an admin. Returns how many were released.
create or replace function public.unclaim_reports(rids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if rids is null or array_length(rids, 1) is null then return 0; end if;
  if array_length(rids, 1) > 200 then raise exception 'Too many at once'; end if;
  update public.reports set claimed_by = null, claimed_at = null
   where id = any(rids) and claimed_by is not null and (claimed_by = auth.uid() or public.is_site_admin());
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.claim_reports(uuid[]) from public, anon;
revoke all on function public.unclaim_reports(uuid[]) from public, anon;
revoke all on function public.report_claim_window() from public, anon;
grant execute on function public.claim_reports(uuid[]) to authenticated;
grant execute on function public.unclaim_reports(uuid[]) to authenticated;
grant execute on function public.report_claim_window() to authenticated;

-- A report that is no longer open has no claim, whichever function closed it.
create or replace function public.report_claim_clear()
returns trigger language plpgsql as $$
begin
  if new.status <> 'open' then
    new.claimed_by := null;
    new.claimed_at := null;
  end if;
  return new;
end $$;
drop trigger if exists reports_claim_clear on public.reports;
create trigger reports_claim_clear before update of status on public.reports
  for each row when (new.status <> 'open') execute function public.report_claim_clear();

reset lock_timeout;
