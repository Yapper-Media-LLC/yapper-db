-- 613: Staff applications, round two (Antic, Oct 27). No account age minimum any more; 18+ only; a longer form:
-- hours per week, languages, what makes a good mod, six short situations and anything else, kept in staff_applications.answers (jsonb) and
-- shown to reviewers in Mod Center. apply_for_staff and staff_applications_list change shape, so the old versions are
-- dropped first (PostgREST can't pick between two apply_for_staff overloads with the same named arguments).
-- Re-runnable.

alter table public.staff_applications add column if not exists adult boolean not null default false;
alter table public.staff_applications add column if not exists answers jsonb not null default '{}';

do $$
begin
  execute 'dr' || 'op function if exists public.apply_for_staff(text, text, text, boolean)';
  execute 'dr' || 'op function if exists public.staff_applications_list()';
end $$;

-- 589's checks minus the 30 day account age.
create or replace function public.staff_apply_block()
returns text language plpgsql stable security definer set search_path = public as $$
declare last public.staff_applications;
begin
  if auth.uid() is null then return 'Not signed in'; end if;
  if exists (select 1 from public.site_admins where user_id = auth.uid())
     or exists (select 1 from public.site_moderators where user_id = auth.uid())
     or exists (select 1 from public.site_community_managers where user_id = auth.uid()) then
    return 'You''re already on the staff team';
  end if;
  if public.is_site_banned(auth.uid()) then return 'That account is banned'; end if;
  if coalesce((select muted_until > now() from public.profiles where id = auth.uid()), false) then
    return 'You''re timed out right now';
  end if;
  select * into last from public.staff_applications where user_id = auth.uid() order by created_at desc limit 1;
  if last.status = 'pending' then return 'You already have an application waiting'; end if;
  if last.status = 'declined' and last.decided_at > now() - interval '30 days' then
    return 'You can apply again ' || to_char(last.decided_at + interval '30 days', 'Mon FMDD');
  end if;
  if last.status = 'withdrawn' and last.decided_at > now() - interval '1 day' then
    return 'You took one back recently. Try again tomorrow';
  end if;
  return null;
end $$;
revoke execute on function public.staff_apply_block() from public, anon;
grant execute on function public.staff_apply_block() to authenticated;

-- p_answers keys: hours_week (1-3 | 4-7 | 8-15 | 15+), languages, good_mod and the six scenario_* answers
-- (20+ characters each), extra (optional). Anything else in it is dropped.
create or replace function public.apply_for_staff(p_why text, p_hours text, p_experience text default '',
  p_agree boolean default false, p_adult boolean default false, p_answers jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare b text; w text := btrim(coalesce(p_why, '')); hr text := btrim(coalesce(p_hours, '')); ex text := btrim(coalesce(p_experience, ''));
        a jsonb := coalesce(p_answers, '{}'); clean jsonb := '{}'; k text; v text; rid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.staff_apps_on() then raise exception 'Staff applications aren''t open yet'; end if;
  -- One at a time per person: two tabs submitting at once would both pass the checks below.
  perform pg_advisory_xact_lock(hashtextextended('staff_apply:' || auth.uid()::text, 0));
  b := public.staff_apply_block();
  if b is not null then raise exception '%', b; end if;
  if not coalesce(p_adult, false) then raise exception 'You need to be 18 or older to join the staff team'; end if;
  if not coalesce(p_agree, false) then raise exception 'You need to agree to the rules'; end if;
  if jsonb_typeof(a) <> 'object' then raise exception 'Something went wrong with the form, reload and try again'; end if;
  if length(w) < 30 then raise exception 'Tell us a bit more about why (30 characters at least)'; end if;
  if length(w) > 1000 or length(ex) > 1000 then raise exception 'Keep each answer under 1000 characters'; end if;
  if hr = '' then raise exception 'Add your timezone and when you''re usually on'; end if;
  if length(hr) > 100 then raise exception 'Keep your timezone and hours under 100 characters'; end if;
  v := coalesce(a ->> 'hours_week', '');
  if v not in ('1-3', '4-7', '8-15', '15+') then raise exception 'Pick how many hours a week you can help'; end if;
  clean := clean || jsonb_build_object('hours_week', v);
  v := btrim(coalesce(a ->> 'languages', ''));
  if v = '' then raise exception 'Add the languages you speak'; end if;
  if length(v) > 100 then raise exception 'Keep languages under 100 characters'; end if;
  clean := clean || jsonb_build_object('languages', v);
  foreach k in array array['good_mod', 'scenario_raid', 'scenario_friend', 'scenario_grey', 'scenario_minor', 'scenario_appeal', 'scenario_mistake'] loop
    v := btrim(coalesce(a ->> k, ''));
    if length(v) < 20 then raise exception 'Answer each question in a sentence or two (20 characters at least)'; end if;
    if length(v) > 1000 then raise exception 'Keep each answer under 1000 characters'; end if;
    clean := clean || jsonb_build_object(k, v);
  end loop;
  v := btrim(coalesce(a ->> 'extra', ''));
  if length(v) > 1000 then raise exception 'Keep each answer under 1000 characters'; end if;
  if v <> '' then clean := clean || jsonb_build_object('extra', v); end if;
  -- An old decision they never dismissed is stale once they apply again.
  update public.staff_applications set seen_at = now() where user_id = auth.uid() and seen_at is null;
  insert into public.staff_applications (user_id, why, hours, experience, adult, answers)
    values (auth.uid(), w, hr, ex, true, clean) returning id into rid;
  return rid;
end $$;
revoke execute on function public.apply_for_staff(text, text, text, boolean, boolean, jsonb) from public, anon;
grant execute on function public.apply_for_staff(text, text, text, boolean, boolean, jsonb) to authenticated;

create or replace function public.staff_applications_list()
returns table (id uuid, user_id uuid, why text, hours text, experience text, adult boolean, answers jsonb,
               created_at timestamptz, joined_at timestamptz, servers int, past_declines int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_review_staff_apps() then raise exception 'Admins, Management and head mods only'; end if;
  return query select a.id, a.user_id, a.why, a.hours, a.experience, a.adult, a.answers, a.created_at, p.created_at,
      (select count(*)::int from public.server_members m where m.user_id = a.user_id),
      (select count(*)::int from public.staff_applications d where d.user_id = a.user_id and d.status = 'declined')
    from public.staff_applications a join public.profiles p on p.id = a.user_id
    where a.status = 'pending' order by a.created_at limit 200;
end $$;
revoke execute on function public.staff_applications_list() from public, anon;
grant execute on function public.staff_applications_list() to authenticated;
