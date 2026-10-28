-- 204: Bug Hunter is given automatically when one of your bug reports is marked fixed.
-- Before, staff had to press "Give Bug Hunter" by hand for each person, so most people whose bugs were fixed
-- never got it (165 on Oct 17) and kept asking. Now:
--   * trigger bug_reports_bug_hunter: a report going to status 'fixed' gives its reporter the badge
--     (not while they're site-banned), with a mod_log line;
--   * a one-time backfill gives it to everyone who already has a fixed report.
--   * new reports always start as open, not staff-picked and without a staff note: the insert policy only
--     checked user_id, so a report could be filed already "fixed" (and would have counted here).
--     mod_log action 'badge_auto' (actor = the staff member who marked it fixed, null for the backfill), so these
--     don't count toward a moderator's hourly manual badge limit.
-- Removing the badge by hand (admin_set_badge off) still works; it only comes back with a newly fixed report.
-- Re-runnable.

create or replace function public.bug_hunter_on_fix()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.status <> 'fixed' or old.status = 'fixed' then return new; end if;
  -- Only staff can mark reports fixed (RLS), and staff can't award themselves this way (admin_set_badge's
  -- mod limits would be skipped). SQL editor / service role (no auth.uid()) is fine.
  if auth.uid() is not null and (not public.is_staff() or (new.user_id = auth.uid() and not public.is_site_admin())) then
    return new;
  end if;
  if exists (select 1 from public.site_bans b where b.user_id = new.user_id and (b.expires_at is null or b.expires_at > now())) then
    return new;
  end if;
  -- Never let the badge stop the report from being marked fixed (e.g. a profile guard refusing the update).
  begin
    update public.profiles p set badges = array(select distinct unnest(coalesce(p.badges, '{}'::text[]) || 'bug_hunter'::text))
     where p.id = new.user_id and not ('bug_hunter' = any(coalesce(p.badges, '{}'::text[])));
    if found then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'badge_auto', new.user_id, 'bug_hunter (report fixed)');
      perform public.rt_profile_changed(array[new.user_id]);
    end if;
  exception when others then
    raise warning 'bug_hunter_on_fix: % (report %)', sqlerrm, new.id;
  end;
  return new;
end $function$;
revoke all on function public.bug_hunter_on_fix() from public, anon, authenticated;

create or replace trigger bug_reports_bug_hunter
  after update of status on public.bug_reports
  for each row when (new.status = 'fixed' and old.status is distinct from 'fixed')
  execute function public.bug_hunter_on_fix();

-- Backfill: everyone with a fixed report who doesn't have the badge yet (not site-banned).
do $$
declare ids uuid[];
begin
  with todo as (
    select distinct b.user_id from public.bug_reports b join public.profiles p on p.id = b.user_id
    where b.status = 'fixed' and coalesce(b.staff_note, '') <> ''   -- closed by staff (all of them carry a note)
      and not ('bug_hunter' = any(coalesce(p.badges, '{}'::text[])))
      and not exists (select 1 from public.site_bans s where s.user_id = b.user_id and (s.expires_at is null or s.expires_at > now()))
  ), upd as (
    update public.profiles p set badges = array(select distinct unnest(coalesce(p.badges, '{}'::text[]) || 'bug_hunter'::text))
    from todo where p.id = todo.user_id returning p.id
  )
  select array_agg(id) into ids from upd;
  if ids is not null then
    insert into public.mod_log (actor, action, target_id, reason) select null, 'badge_auto', u, 'bug_hunter (report fixed, backfill)' from unnest(ids) u;
    perform public.rt_profile_changed(ids);
  end if;
end $$;

-- New reports can't be filed as fixed / staff-picked / with a staff note (the insert policy only checked user_id).
create or replace function public.bug_report_limit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if (select count(*) from public.bug_reports where user_id = new.user_id and created_at > now() - interval '1 day') >= 5 then raise exception 'You can file 5 bug reports a day'; end if;
  if auth.uid() is not null and not public.is_staff() then
    new.status := 'open';
    new.staff_pick := false;
    new.staff_note := '';  -- not null column (default '')
  end if;
  return new;
end; $function$;
