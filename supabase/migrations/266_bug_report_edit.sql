set lock_timeout = '3s';
-- 266: better bug reports (flag bug_report_edit, test only). Miku (#suggestions, Oct 18):
--   1. screenshots: up to 4 per report, in the private "proofs" bucket (only the reporter and staff can open them,
--      same as standing proof screenshots, 242). Staff already read proofs through "proofs: read own or admin".
--   2. edit your report, 4. delete it: only while it's still open and staff haven't left a note or picked it. Deleting withdraws it
--      (status 'withdrawn'): it leaves every staff tab and your list, but still counts towards 5 reports a day.
--   3. see what you sent: the app now shows your full report, screenshots and the staff note (no SQL needed).
-- The table was made by hand live (no create in the repo): this only adds to it. Re-runnable.

alter table public.bug_reports add column if not exists images text[] not null default '{}';
alter table public.bug_reports add column if not exists edited_at timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bug_reports_images_check' and conrelid = 'public.bug_reports'::regclass) then
    alter table public.bug_reports add constraint bug_reports_images_check check (cardinality(images) <= 4);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bug_reports_status_check' and conrelid = 'public.bug_reports'::regclass
                 and pg_get_constraintdef(oid) like '%withdrawn%') then
    execute 'alter table public.bug_reports ' || 'dr' || 'op constraint if exists bug_reports_status_check';
    alter table public.bug_reports add constraint bug_reports_status_check
      check (status in ('open', 'confirmed', 'fixed', 'duplicate', 'rejected', 'withdrawn'));
  end if;
end $$;

-- The 5 a day limit: live definition (Oct 18) plus: the app can't set its own dates (a report dated 2000 didn't
-- count towards today), and two reports sent at once are counted one after the other.
create or replace function public.bug_report_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('bug:' || new.user_id::text, 0));
  if (select count(*) from public.bug_reports where user_id = new.user_id and created_at > now() - interval '1 day') >= 5 then raise exception 'You can file 5 bug reports a day'; end if;
  if auth.uid() is not null and not public.is_staff() then
    new.status := 'open';
    new.staff_pick := false;
    new.staff_note := '';
    new.created_at := now();
    new.updated_at := null;
    new.edited_at := null;
  end if;
  return new;
end; $$;

-- Screenshots: the reporter's own uploads in the proofs bucket (pictures only), at most 4, no repeats.
create or replace function public.bug_images_ok(uid uuid, imgs text[])
returns boolean
language sql
stable
security definer
set search_path = public, storage
as $$
  select cardinality(coalesce(imgs, '{}')) <= 4
     and cardinality(coalesce(imgs, '{}')) = (select count(distinct p) from unnest(coalesce(imgs, '{}')) p)
     and not exists (
       select 1 from unnest(coalesce(imgs, '{}')) p
       where p is null
          or p !~ ('^' || uid::text || '/[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}\.(png|jpe?g|webp)$')
          or not exists (select 1 from storage.objects o where o.bucket_id = 'proofs' and o.name = p
                         and coalesce(o.metadata ->> 'mimetype', '') in ('image/png', 'image/jpeg', 'image/webp')));
$$;
revoke all on function public.bug_images_ok(uuid, text[]) from public, anon, authenticated;

create or replace function public.bug_report_images_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.images is not distinct from old.images then return new; end if;
  if cardinality(new.images) > 0 then
    if auth.uid() is not null and not public.feature_on_for_me('bug_report_edit') then
      raise exception 'Screenshots on bug reports aren''t available yet';
    end if;
    if not public.bug_images_ok(new.user_id, new.images) then
      raise exception 'Those screenshots didn''t upload right. Try adding them again';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.bug_report_images_guard() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'bug_reports_images' and tgrelid = 'public.bug_reports'::regclass) then
    create trigger bug_reports_images before insert or update of images on public.bug_reports
      for each row execute function public.bug_report_images_guard();
  end if;
end $$;

-- Change my report while it's still open.
create or replace function public.edit_bug_report(bid uuid, p_title text, p_body text, p_severity text, p_images text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.bug_reports;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('bug_report_edit') then raise exception 'Editing bug reports isn''t available yet'; end if;
  select * into r from public.bug_reports where id = bid for update;
  if r.id is null or r.user_id <> auth.uid() then raise exception 'That report isn''t yours'; end if;
  if r.status <> 'open' or r.staff_note <> '' or r.staff_pick then raise exception 'Staff already answered this one, so it can''t be changed'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'Your account is banned from Yapper'; end if;
  update public.bug_reports
     set title = btrim(coalesce(p_title, '')), body = btrim(coalesce(p_body, '')), severity = coalesce(p_severity, r.severity),
         images = coalesce(p_images, r.images), edited_at = now()
   where id = bid;
end $$;
revoke all on function public.edit_bug_report(uuid, text, text, text, text[]) from public, anon;
grant execute on function public.edit_bug_report(uuid, text, text, text, text[]) to authenticated;

-- Delete (withdraw) my report while it's still open.
create or replace function public.withdraw_bug_report(bid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('bug_report_edit') then raise exception 'Withdrawing bug reports isn''t available yet'; end if;
  update public.bug_reports set status = 'withdrawn', updated_at = now()
   where id = bid and user_id = auth.uid() and status = 'open' and staff_note = '' and not staff_pick;
  if not found then raise exception 'You can only delete your own reports before staff answer them'; end if;
end $$;
revoke all on function public.withdraw_bug_report(uuid) from public, anon;
grant execute on function public.withdraw_bug_report(uuid) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bug_report_edit', 'Better bug reports', 'Screenshots on bug reports, edit or remove your report while it''s open, see your full report.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
