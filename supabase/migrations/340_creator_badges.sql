-- 340: Creator badges in three tiers (flag creator_badges, test): creator_1 "Creator", creator_2 "Pro Creator",
-- creator_3 "Elite Creator", for people who make videos about Yapper. Admins hand them out (Badges in the user's mod
-- file / profile menu). One tier at a time: giving a tier takes the other tiers off, and if they were showing their old
-- tier they now show the new one. Taking any badge off also clears shown_badge when it pointed at that badge.
-- admin_set_badge also learns 'community_manager': the badge editor offered it but the function said "Unknown badge".
-- Same body as 290 otherwise. Function + flag row only, no table changes. Re-runnable.

create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not (public.is_site_admin() or (public.is_site_mod() and badge = 'bug_hunter')) then raise exception 'Admins only'; end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff', 'developer', 'community_manager', 'creator_1', 'creator_2', 'creator_3') then
    raise exception 'Unknown badge';
  end if;
  perform public.mod_guard('badge', uid, null);
  if on_off then
    update public.profiles set
      badges = array(select distinct unnest(
        array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (badge = any(tiers) and b = any(tiers) and b <> badge))
        || badge)),
      shown_badge = case when badge = any(tiers) and shown_badge = any(tiers) then badge else shown_badge end
    where id = uid;
  else
    update public.profiles set
      badges = array_remove(badges, badge),
      shown_badge = case when shown_badge = badge then null else shown_badge end
    where id = uid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), case when on_off then 'badge_given' else 'badge_removed' end, uid, badge);
end; $function$;

revoke all on function public.admin_set_badge(uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_badge(uuid, text, boolean) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('creator_badges', 'Creator badges', 'Creator, Pro Creator and Elite Creator badges for people who make videos about Yapper.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
