-- 180: the moderation log is Antic's (site admins) only. Mods still read their own rows, which the
-- Mod Center home uses for "your actions today" limits. Re-runnable.
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mod_log' and policyname = 'admins read the mod log') then
    execute 'dr' || 'op policy "admins read the mod log" on public.mod_log';
  end if;
end $$;

create policy "admins read the mod log" on public.mod_log for select to authenticated
  using ((select public.is_site_admin()) or actor = (select auth.uid()));
