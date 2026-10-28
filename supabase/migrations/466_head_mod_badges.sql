-- 466: head mods can give and take the Artist badge (flag head_mod_badges). Antic, Oct 24: "give badge perms to head
-- mods" (greninja asked: people get Artist with ChatGPT art and head mods should be able to take it off). Only Artist:
-- staff, creator tiers, partner and early stay admin-only, Bug Hunter stays open to every mod as before. mod_guard still
-- applies (not yourself, not staff, 10 badge changes an hour) and every change is logged as before.
-- Test: Antic + the four head mods (four accounts). Re-runnable; the body is live's plus one line.

create or replace function public.admin_set_badge(uid uuid, badge text, on_off boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  -- A null badge made both checks below null, so neither raised and a null went into badges.
  if badge is null or on_off is null then raise exception 'Unknown badge'; end if;
  if not (public.is_site_admin()
          or (public.is_site_mod() and badge = 'bug_hunter')
          or (badge = 'artist' and public.feature_on('head_mod_badges', null) and public.is_head_mod())) then
    raise exception 'Admins only';
  end if;
  if badge not in ('bug_hunter', 'partner', 'early', 'staff', 'developer', 'community_manager', 'creator_1', 'creator_2', 'creator_3', 'artist') then
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

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('head_mod_badges', 'Head mods give Artist', 'Head moderators can give and remove the Artist badge', 'test', '{}',
        '{00000000-0000-4000-8000-00000000a001,00000000-0000-4000-8000-00000000a003,00000000-0000-4000-8000-00000000a004,00000000-0000-4000-8000-00000000a005,00000000-0000-4000-8000-00000000a006}')
on conflict (key) do nothing;
