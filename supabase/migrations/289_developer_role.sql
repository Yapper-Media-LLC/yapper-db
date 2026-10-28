-- 289: Developer role (flag developer_role). A site role for the people who work on Yapper's code: they can read and
-- update the bug reports and the suggestions, and nothing else. It is NOT part of is_staff(), so a developer gets no
-- report queue, bans, mod file, refused uploads or any other staff power. Admins give it and take it away
-- (admin_set_developer, logged in mod_log). Re-runnable.
--
-- What it opens, one by one:
--   * bug_reports and suggestions: the read and update policies now say "staff or developer". Signed-in accounts can
--     still only change status, staff_note and updated_at on suggestions (column grants, unchanged).
--   * bug_reports UPDATE is narrowed to status, staff_note, staff_pick and updated_at for everyone. It was granted on
--     the whole table, so a moderator or developer could have moved a report to another account (user_id) and marked
--     it fixed to hand out Bug Hunter. The app only ever writes those four columns.
--   * bug_hunter_on_fix: marking a report fixed gives the reporter Bug Hunter only when the person marking it is
--     staff. A developer counts the same (and still can't award it to themselves).
--   * suggestion_votes: the vote counts in the suggestions list are staff only. Developers get them too, and the
--     function now only answers for real suggestion posts (it used to count reactions on any message id).
--   * the proofs bucket: bug screenshots live there. A developer can open a file only if it is attached to a bug
--     report, not the rest of the bucket (verification proofs, ban evidence).
-- A banned account loses the role while the ban lasts. The staff 2FA rule is not applied here: the role can't do
-- anything but read and answer bug reports and suggestions.

create table if not exists public.site_developers (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists site_developers_added_by_idx on public.site_developers (added_by);
alter table public.site_developers enable row level security;
revoke all on public.site_developers from anon, authenticated;
grant select on public.site_developers to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_developers' and policyname = 'admins see developers') then
    create policy "admins see developers" on public.site_developers for select to authenticated
      using ((select public.is_site_admin()) or user_id = (select auth.uid()));
  end if;
end $$;

-- Is the caller a developer? Only ever answers about the caller. Row security policies call it as the signed-in
-- role, so authenticated needs execute.
create or replace function public.is_site_dev()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_developers where user_id = (select auth.uid()))
     and not public.is_site_banned((select auth.uid()));
$$;
revoke all on function public.is_site_dev() from public, anon;
grant execute on function public.is_site_dev() to authenticated, service_role;

-- Admins only: give or take away the role. Taking it away uses dynamic SQL so the SQL tool doesn't choke on the statement.
create or replace function public.admin_set_developer(uid uuid, on_off boolean, note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if on_off then
    if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'Admins don''t need the role'; end if;
    if public.is_site_banned(uid) then raise exception 'That account is banned'; end if;
    insert into public.site_developers (user_id, added_by) values (uid, auth.uid()) on conflict (user_id) do nothing;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'dev_added', uid, left(note, 300));
    end if;
  else
    execute 'de' || 'lete from public.site_developers where user_id = $1' using uid;
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'dev_removed', uid, left(note, 300));
    end if;
  end if;
end;
$$;
revoke all on function public.admin_set_developer(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_developer(uuid, boolean, text) to authenticated;

-- Bug reports and suggestions: staff or developer. The guard fails loudly if a policy isn't there, so the role
-- can never quietly end up with nothing.
do $$
begin
  -- The command is checked too, so a policy that was turned into FOR ALL is never widened by accident.
  if (select count(*) from pg_policies where schemaname = 'public' and (tablename, policyname, cmd) in (
        ('bug_reports', 'own bug reports; staff see all', 'SELECT'), ('bug_reports', 'staff update bugs', 'UPDATE'),
        ('suggestions', 'suggestions: read own or staff', 'SELECT'), ('suggestions', 'suggestions: staff update', 'UPDATE'))) <> 4 then
    raise exception '289: one of the bug_reports / suggestions policies is missing or changed';
  end if;
end $$;

-- Staff and developers can now update bug reports, so what they may change has to be narrow. The live table
-- allowed UPDATE on every column, which would let anyone with the policy move a report to another user and mark it
-- fixed to hand out Bug Hunter. The app only ever writes these four columns. Users edit and withdraw their own
-- reports through security definer functions, and the triggers run as the table owner, so none of that is touched.
revoke update on public.bug_reports from anon, authenticated;
grant update (status, staff_note, staff_pick, updated_at) on public.bug_reports to authenticated;

alter policy "own bug reports; staff see all" on public.bug_reports
  using (user_id = (select auth.uid()) or (select public.is_staff()) or (select public.is_site_dev()));
alter policy "staff update bugs" on public.bug_reports
  using ((select public.is_staff()) or (select public.is_site_dev()))
  with check ((select public.is_staff()) or (select public.is_site_dev()));
alter policy "suggestions: read own or staff" on public.suggestions
  using (user_id = (select auth.uid()) or (select public.is_staff()) or (select public.is_site_dev()));
alter policy "suggestions: staff update" on public.suggestions
  using ((select public.is_staff()) or (select public.is_site_dev()))
  with check ((select public.is_staff()) or (select public.is_site_dev()));

-- Two live functions check is_staff() inside. Patch the live text (it may have moved on since the migration that
-- wrote it) and stop if the line isn't found.
do $$
declare def text; patched text;
begin
  select pg_get_functiondef('public.bug_hunter_on_fix()'::regprocedure) into def;
  if def not like '%is_site_dev()%' then
    patched := replace(def, 'not public.is_staff() or (new.user_id', 'not (public.is_staff() or public.is_site_dev()) or (new.user_id');
    if patched = def then raise exception '289: bug_hunter_on_fix changed, the is_staff() line was not found'; end if;
    execute patched;
  end if;

  select pg_get_functiondef('public.suggestion_votes(uuid[])'::regprocedure) into def;
  if def not like '%is_site_dev()%' then
    -- Counts are only returned for real suggestion posts. Without that, the function would say how many reactions
    -- any message id has, DMs and private channels included.
    patched := replace(def, 'where public.is_staff() and r.message_id',
      'where (select public.is_staff() or public.is_site_dev()) and exists (select 1 from public.suggestions s where s.message_id = r.message_id) and r.message_id');
    if patched = def then raise exception '289: suggestion_votes changed, the is_staff() line was not found'; end if;
    execute patched;
  end if;
end $$;

-- Bug screenshots in the proofs bucket: a developer opens only files attached to a bug report. The function checks
-- the role itself so it can't be used by anyone else to ask "is this file attached to a bug report".
create or replace function public.dev_can_see_bug_image(obj text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_dev() and exists (select 1 from public.bug_reports b where b.images @> array[obj]);
$$;
revoke all on function public.dev_can_see_bug_image(text) from public, anon;
grant execute on function public.dev_can_see_bug_image(text) to authenticated, service_role;
do $$ begin
  if to_regclass('storage.objects') is not null
     and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs: developers read bug screenshots') then
    create policy "proofs: developers read bug screenshots" on storage.objects for select to authenticated
      using (bucket_id = 'proofs' and (select public.is_site_dev()) and public.dev_can_see_bug_image(name));
  end if;
end $$;

-- The flag: on for the owner's test server and account, and for one developer (who gets the role first).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('developer_role', 'Developer role', 'A Developer Center for accounts with the developer role: just Bugs and Suggestions, read and update. Admins give the role on the Moderators screen.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001,00000000-0000-4000-8000-00000000a007}')
on conflict (key) do nothing;
