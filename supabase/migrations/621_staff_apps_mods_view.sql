-- 621: every site moderator can read staff applications (Antic, Oct 27); deciding stays with admins, Management and
-- head mods (can_review_staff_apps, unchanged in decide_staff_application). is_site_mod covers head mods and needs
-- 2FA like the others. Same body as 613 apart from the check. Re-runnable.

create or replace function public.staff_applications_list()
returns table (id uuid, user_id uuid, why text, hours text, experience text, adult boolean, answers jsonb,
               created_at timestamptz, joined_at timestamptz, servers int, past_declines int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can_review_staff_apps() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  return query select a.id, a.user_id, a.why, a.hours, a.experience, a.adult, a.answers, a.created_at, p.created_at,
      (select count(*)::int from public.server_members m where m.user_id = a.user_id),
      (select count(*)::int from public.staff_applications d where d.user_id = a.user_id and d.status = 'declined')
    from public.staff_applications a join public.profiles p on p.id = a.user_id
    where a.status = 'pending' order by a.created_at limit 200;
end $$;
revoke execute on function public.staff_applications_list() from public, anon;
grant execute on function public.staff_applications_list() to authenticated;
