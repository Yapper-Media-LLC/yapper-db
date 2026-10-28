-- 306: username_taken() under a name only our servers use (Oct 20).
-- Since 280 made username_taken() service-role only, scripts kept calling it anyway: ~1.5M refused calls an hour
-- from 100+ IPs (python-requests). Each refusal still went through Supabase's gateway to Postgres
-- ("permission denied for function username_taken", ~8M Postgres errors a day). srv_username_taken is the same
-- function; once the app calls it (app/api/signup, app/api/bots), 307 moves the old name out of the API schema so
-- PostgREST answers those calls from its schema cache (404) and the database never sees them. Re-runnable.

create or replace function public.srv_username_taken(name text)
returns boolean language sql stable security definer set search_path to 'public' as $function$
  select exists (select 1 from public.profiles where lower(username) = lower(name))
      or (exists (select 1 from public.username_holds h where h.name_key = lower(name) and h.until > now())
          and exists (select 1 from public.feature_flags where key = 'username_limits' and mode <> 'off'));
$function$;
revoke all on function public.srv_username_taken(text) from public, anon, authenticated;
grant execute on function public.srv_username_taken(text) to service_role;
