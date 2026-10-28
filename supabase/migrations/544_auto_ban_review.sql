-- 544: every automatic ban gets a human look (legal list B12, Terms 12.2 / GDPR Art. 22). Bans with no banned_by
-- (ban evasion on a known device, several slur reports, the image scanner) used to be seen only if the person
-- appealed. Mod Center, Bans, "Auto, not reviewed" lists them; staff either lift the ban (existing tools) or keep it
-- with "Looks right" (staff_review_auto_ban), which stamps reviewed_at / reviewed_by and logs it.
-- No flag: it's a staff list and a stamp. Re-runnable. Applied live as "543_auto_ban_review" (renumbered after: another 543 landed).

alter table public.site_bans add column if not exists reviewed_at timestamptz;
alter table public.site_bans add column if not exists reviewed_by uuid;

create or replace function public.staff_review_auto_ban(uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.site_bans set reviewed_at = now(), reviewed_by = auth.uid()
  where user_id = uid and banned_by is null and reviewed_at is null;
  if not found then raise exception 'Nothing to review for that one'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'auto_ban_reviewed', uid, 'kept');
end $$;

revoke all on function public.staff_review_auto_ban(uuid) from public, anon;
grant execute on function public.staff_review_auto_ban(uuid) to authenticated;
