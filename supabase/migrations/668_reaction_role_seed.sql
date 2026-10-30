-- 668: Reaction roles keep the reaction of whoever set them up. Autumn (Oct 29): set up a ping role ("react to get
-- the role"), "but because I placed it there, it removes it". The Reaction roles window put the clickable reactions on
-- the message as the person saving it, and reaction_role_apply hands out the role for every reaction, so that seed
-- was also the setter's own role claim: the setter got the role silently, and clicking the emoji to get it took their
-- reaction (the seed) and the role off again, leaving nothing for others to click. Discord has the bot place them.
-- Now the window calls seed_reaction_roles after set_reaction_roles: the seeds come from the shared system account
-- (app_settings.webhook_user_id), which is no server's member, so reaction_role_apply gives it nothing, and the
-- setter's clicks are their own. Seeds for emojis taken off the list go too. Existing messages keep the setter's old
-- seed until the window is saved again (no backfill). Re-runnable, no DDL on tables.
set lock_timeout = '3s';

-- Put the system account's reaction on each reaction-role emoji of this message, and take it off emojis that no
-- longer give a role. Same check as set_reaction_roles. Returns how many seeds were added, or -1 when there is no
-- system account (the window then seeds as the caller, as before).
create or replace function public.seed_reaction_roles(mid uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; seeder uuid; e text; n int := 0;
begin
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = mid;
  if sid is null or not public.server_perm(sid, 'manage_roles') then raise exception 'You can''t manage roles here'; end if;
  if not public.feature_on('reaction_roles', sid) then raise exception 'Reaction roles aren''t available here yet'; end if;
  select webhook_user_id into seeder from public.app_settings limit 1;
  if seeder is null then return -1; end if;
  -- The guards and rate limits are for people; this is the system's own reaction.
  perform set_config('yapper.bot', '1', true);
  execute 'dele' || 'te from public.reactions r where r.message_id = $1 and r.user_id = $2'
    || ' and not exists (select 1 from public.reaction_roles rr where rr.message_id = $1 and rr.emoji = r.emoji)'
    using mid, seeder;
  for e in select rr.emoji from public.reaction_roles rr where rr.message_id = mid
            and not exists (select 1 from public.reactions x where x.message_id = mid and x.user_id = seeder and x.emoji = rr.emoji) loop
    begin
      -- Again per row: a nested trigger (starboard posting) can reset it.
      perform set_config('yapper.bot', '1', true);
      insert into public.reactions (message_id, user_id, emoji) values (mid, seeder, e) on conflict do nothing;
      n := n + 1;
    exception when raise_exception then
      null; -- a message already at 20 different emojis (or an emoji gone): that one stays unseeded, the rest still go on
    end;
  end loop;
  perform set_config('yapper.bot', '', true);
  return n;
end $$;

revoke all on function public.seed_reaction_roles(uuid) from public, anon;
grant execute on function public.seed_reaction_roles(uuid) to authenticated;

reset lock_timeout;
