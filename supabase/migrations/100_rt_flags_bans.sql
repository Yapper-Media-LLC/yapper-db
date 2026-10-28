-- The last two things the app still listened to through Supabase Realtime (postgres_changes on
-- feature_flags and site_bans) now go through our own realtime server like everything else:
--   feature_flags -> topic 'all' (every signed-in tab), event 'flags'
--   site_bans     -> topic 'user:<id>' (just that person), event 'site_ban'

create or replace function public.bc_flags() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.bc('all', 'flags', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;

create or replace trigger feature_flags_bc after insert or update or delete on public.feature_flags
  for each row execute function public.bc_flags();

create or replace function public.bc_site_ban() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.bc('user:' || coalesce(new.user_id, old.user_id), 'site_ban', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;

create or replace trigger site_bans_bc after insert or update or delete on public.site_bans
  for each row execute function public.bc_site_ban();
