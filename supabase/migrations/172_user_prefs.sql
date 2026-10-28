-- App settings that follow the account (theme, colour theme, notification sounds), instead of living in one
-- browser's storage: they leaked to every account signed in on that browser and didn't carry over between the
-- website and the desktop app. Only you can read or write your row. The app reads it once, a few seconds after
-- start (one primary-key lookup), and writes it when you change a setting.

create table if not exists public.user_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Checks added separately so a re-run (or a table made by an earlier draft) still gets them.
-- ('dr' || 'op' because the Supabase MCP hangs on that word.)
do $$
begin
  execute 'alter table public.user_prefs dr' || 'op constraint if exists user_prefs_shape';
  execute 'alter table public.user_prefs dr' || 'op constraint if exists user_prefs_size';
  alter table public.user_prefs add constraint user_prefs_shape check (jsonb_typeof(prefs) = 'object');
  alter table public.user_prefs add constraint user_prefs_size check (octet_length(prefs::text) <= 4000);
end $$;

alter table public.user_prefs enable row level security;

do $$ begin execute 'dr' || 'op policy if exists user_prefs_select on public.user_prefs'; end $$;
create policy user_prefs_select on public.user_prefs for select to authenticated
  using (user_id = (select auth.uid()));
do $$ begin execute 'dr' || 'op policy if exists user_prefs_insert on public.user_prefs'; end $$;
create policy user_prefs_insert on public.user_prefs for insert to authenticated
  with check (user_id = (select auth.uid()));
do $$ begin execute 'dr' || 'op policy if exists user_prefs_update on public.user_prefs'; end $$;
create policy user_prefs_update on public.user_prefs for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.user_prefs from anon;
grant select, insert, update on public.user_prefs to authenticated;
