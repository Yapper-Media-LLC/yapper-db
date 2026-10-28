-- 571: Community Helper badge for the current Community Managers. Antic on Oct 26 2026: "give the badges out to existing
-- comm managers". Data only, re-runnable: everyone in site_community_managers who doesn't have it yet gets
-- 'community_helper' (shown_badge untouched), logged as badge_auto by Antic, and the profile cache is pinged.
-- Apply after 568 (the key) and 569 (the flag), so the badge shows as soon as it's on.
do $$
declare ids uuid[];
begin
  select array_agg(m.user_id) into ids
    from public.site_community_managers m join public.profiles p on p.id = m.user_id
   where not ('community_helper' = any(coalesce(p.badges, '{}'::text[])));
  if ids is null then return; end if;
  update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || 'community_helper'::text))
   where id = any(ids);
  insert into public.mod_log (actor, action, target_id, reason)
    select '00000000-0000-4000-8000-00000000a001', 'badge_auto', u, 'community_helper' from unnest(ids) u;
  perform public.rt_profile_changed(ids);
end $$;
