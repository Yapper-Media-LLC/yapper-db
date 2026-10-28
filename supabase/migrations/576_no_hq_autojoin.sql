-- 576: new accounts stop auto-joining Yapper HQ (flag no_hq_autojoin, test: Antic).
-- Signup can't be gated per user (auth.uid() is not the new account inside the trigger), so the
-- trigger only skips the join once the flag is published (mode everyone). In test mode the app
-- just shows Antic the Discover landing; HQ still gets every new account.
-- Publish: update public.feature_flags set mode = 'everyone' where key = 'no_hq_autojoin';
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('no_hq_autojoin', 'No HQ auto-join',
  'New accounts are not added to Yapper HQ. They land on Discover (plain list, no promoted row) and pick their own servers.',
  'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.join_default_server()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  sid uuid := (select default_server_id from public.app_settings where id);
begin
  if sid is null then return new; end if;
  -- Flag no_hq_autojoin published: new accounts pick their own servers from Discover instead.
  if exists (select 1 from public.feature_flags f where f.key = 'no_hq_autojoin' and f.mode = 'everyone') then
    return new;
  end if;
  -- Bot accounts (app/api/bots makes them with user_metadata.bot = true, before their bots row exists).
  if exists (select 1 from auth.users u where u.id = new.id and coalesce(u.raw_user_meta_data ->> 'bot', '') = 'true')
     or public.is_bot_user(new.id) then
    return new;
  end if;
  insert into public.server_members (server_id, user_id) values (sid, new.id) on conflict do nothing;
  return new;
end;
$function$;
