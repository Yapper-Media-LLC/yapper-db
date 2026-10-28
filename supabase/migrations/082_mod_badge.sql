-- Moderator badge (applied live Oct 14): profiles.badges gets 'mod' while someone is an active site moderator.
-- Added, removed or suspended in site_moderators -> badge follows automatically. Admins can still hand it out
-- or take it away from the badges row like any other badge.
create or replace function public.sync_mod_badge()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare uid uuid := coalesce(new.user_id, old.user_id);
        active boolean := tg_op <> 'DELETE' and new.suspended_at is null;
begin
  if active then
    update public.profiles set badges = array_append(coalesce(badges, '{}'), 'mod')
      where id = uid and not ('mod' = any(coalesce(badges, '{}')));
  else
    update public.profiles set badges = array_remove(badges, 'mod'),
      shown_badge = case when shown_badge = 'mod' then null else shown_badge end
      where id = uid and 'mod' = any(coalesce(badges, '{}'));
  end if;
  return null;
end; $function$;

drop trigger if exists site_moderators_badge on public.site_moderators;
create trigger site_moderators_badge
  after insert or update of suspended_at or delete on public.site_moderators
  for each row execute function public.sync_mod_badge();

-- Current moderators get it now.
update public.profiles p set badges = array_append(coalesce(p.badges, '{}'), 'mod')
  from public.site_moderators m
  where m.user_id = p.id and m.suspended_at is null and not ('mod' = any(coalesce(p.badges, '{}')));
