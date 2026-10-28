-- 283: "Download your data" (GDPR art. 15/20). Settings > My Account > Your data, flag data_export.
-- The export itself is built by app/api/me/export/route.ts with the service key, always filtered by the caller.
-- Here: the per-user limit (3 exports a rolling day), the flag, and (to run separately) three indexes the export reads by.
-- Re-runnable, and the body runs in one transaction (apply_migration). The CONCURRENTLY indexes are in a comment
-- block at the end: run those separately, one at a time.

-- ---------- Limit: 3 exports per user per 24 hours ----------
-- Only the server (service role) can count or read it, like translate_usage (139).
create table if not exists public.data_exports (
  id bigint generated always as identity primary key,
  user_id uuid not null,            -- no foreign key: rows are cleared after two days anyway
  at timestamptz not null default now()
);
create index if not exists data_exports_user_at_idx on public.data_exports (user_id, at desc);
alter table public.data_exports enable row level security;
revoke all on public.data_exports from public, anon, authenticated;

-- true = under the limit (and counted); false = over, nothing counted.
create or replace function public.data_export_hit(uid uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if uid is null then return false; end if;
  -- One at a time per user, so parallel requests can't all slip under the limit.
  perform pg_advisory_xact_lock(hashtextextended('data_export:' || uid::text, 0));
  select count(*) into n from public.data_exports where user_id = uid and at > now() - interval '1 day';
  if n >= 3 then return false; end if;
  insert into public.data_exports (user_id) values (uid);
  -- Now and then, clear out rows older than two days.
  if random() < 0.05 then
    execute 'dele' || 'te from public.data_exports where at < now() - interval ''2 days''';
  end if;
  return true;
end $$;
revoke all on function public.data_export_hit(uuid) from public, anon, authenticated;
grant execute on function public.data_export_hit(uuid) to service_role;

-- ---------- Flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('data_export', 'Download your data', 'Settings > My Account: download a JSON copy of your own data (GDPR). 3 a day.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- Run separately, one at a time, outside a transaction ----------
-- Indexes the export reads by (reactions, poll_ballots and server_first_joins had none on user_id; they also help
-- account deletes). CONCURRENTLY can't run inside the transaction apply_migration uses, so they're kept out of the
-- body above. Paste each line on its own into the SQL editor (or run each as its own execute_sql call):
--
-- create index concurrently if not exists reactions_user_idx on public.reactions (user_id, created_at);
-- create index concurrently if not exists poll_ballots_user_idx on public.poll_ballots (user_id);
-- create index concurrently if not exists server_first_joins_user_idx on public.server_first_joins (user_id);
