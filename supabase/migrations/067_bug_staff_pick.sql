-- "Should award" tab in Mod Center → Bugs: reports picked as badge-worthy on review.
alter table public.bug_reports add column if not exists staff_pick boolean not null default false;
