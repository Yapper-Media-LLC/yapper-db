-- Moderation and billing columns on profiles were readable by any logged-in user
-- (bug report): who's timed out, why, and Stripe customer ids. Regular users may now only
-- read the public columns. The app selects PROFILE_COLS (lib/types.ts) instead of *.

revoke select on public.profiles from anon, authenticated;
grant select (
  id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
  avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
  pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from
) on public.profiles to anon, authenticated;

-- Your own timeouts (the voice ticket route needs them; the app shows them to you).
create or replace function public.my_sanctions()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object('muted_until', muted_until, 'muted_reason', muted_reason, 'voice_muted_until', voice_muted_until)
       from public.profiles where id = auth.uid()),
    '{}'::jsonb);
$$;
grant execute on function public.my_sanctions() to authenticated;
