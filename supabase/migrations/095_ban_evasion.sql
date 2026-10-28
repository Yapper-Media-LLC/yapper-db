-- Ban evasion (applied live Oct 15): the sign-up route refuses new accounts from a network that a
-- currently site-banned account signed in from in the last 7 days. Service role only.
create or replace function public.ip_banned_recently(p_ip text)
 returns boolean language sql stable security definer set search_path to 'public' as $function$
  select exists (
    select 1 from public.login_attempts la
    join public.profiles p on lower(p.username) = lower(la.username)
    join public.site_bans b on b.user_id = p.id
    where la.ip = p_ip and la.ok and la.at > now() - interval '7 days'
      and (b.expires_at is null or b.expires_at > now())
  );
$function$;
revoke all on function public.ip_banned_recently(text) from public, anon, authenticated;
