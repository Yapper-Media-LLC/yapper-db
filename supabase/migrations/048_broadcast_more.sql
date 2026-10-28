-- Move the rest of the chatty tables off postgres_changes (which re-checks RLS per
-- connected client on every change) onto broadcast topics.
-- server:<id>  -> 'server' (servers row), 'channel' (channels/channel_roles/channel_post_roles), 'roles' (roles/member_roles), 'emoji', 'sound'
-- user:<id>    -> 'friend' (friendships), 'chan' (channel_members: DMs/groups), 'report' (admins/mods only)

create or replace function public.bc_server()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('server:' || coalesce(new.id, old.id), 'server', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;
create or replace function public.bc_channel()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  sid := coalesce(new.server_id, old.server_id);
  if sid is not null then perform realtime.broadcast_changes('server:' || sid, 'channel', tg_op, tg_table_name, tg_table_schema, new, old); end if;
  return null;
end; $$;
create or replace function public.bc_channel_role()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = coalesce(new.channel_id, old.channel_id);
  if sid is not null then perform realtime.broadcast_changes('server:' || sid, 'channel', tg_op, tg_table_name, tg_table_schema, new, old); end if;
  return null;
end; $$;
create or replace function public.bc_roles()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('server:' || coalesce(new.server_id, old.server_id), 'roles', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;
create or replace function public.bc_emoji()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid := coalesce(new.server_id, old.server_id);
begin
  if sid is not null then perform realtime.broadcast_changes('server:' || sid, 'emoji', tg_op, tg_table_name, tg_table_schema, new, old); end if;
  return null;
end; $$;
create or replace function public.bc_friend()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('user:' || coalesce(new.requester, old.requester), 'friend', tg_op, tg_table_name, tg_table_schema, new, old);
  perform realtime.broadcast_changes('user:' || coalesce(new.addressee, old.addressee), 'friend', tg_op, tg_table_name, tg_table_schema, new, old);
  return null;
end; $$;
create or replace function public.bc_channel_member()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid := coalesce(new.channel_id, old.channel_id); uid uuid;
begin
  -- Everyone in the DM/group (including the one leaving) hears about it.
  for uid in (select user_id from public.channel_members where channel_id = cid union select coalesce(new.user_id, old.user_id)) loop
    perform realtime.broadcast_changes('user:' || uid, 'chan', tg_op, tg_table_name, tg_table_schema, new, old);
  end loop;
  return null;
end; $$;
create or replace function public.bc_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  for uid in (select user_id from public.site_admins union select user_id from public.site_moderators) loop
    perform realtime.broadcast_changes('user:' || uid, 'report', tg_op, tg_table_name, tg_table_schema, new, old);
  end loop;
  return null;
end; $$;

drop trigger if exists servers_bc on public.servers;
create trigger servers_bc after update on public.servers for each row execute function public.bc_server();
drop trigger if exists channels_bc on public.channels;
create trigger channels_bc after insert or update or delete on public.channels for each row execute function public.bc_channel();
drop trigger if exists channel_roles_bc on public.channel_roles;
create trigger channel_roles_bc after insert or delete on public.channel_roles for each row execute function public.bc_channel_role();
drop trigger if exists channel_post_roles_bc on public.channel_post_roles;
create trigger channel_post_roles_bc after insert or delete on public.channel_post_roles for each row execute function public.bc_channel_role();
drop trigger if exists roles_bc on public.roles;
create trigger roles_bc after insert or update or delete on public.roles for each row execute function public.bc_roles();
drop trigger if exists member_roles_bc on public.member_roles;
create trigger member_roles_bc after insert or delete on public.member_roles for each row execute function public.bc_roles();
drop trigger if exists emojis_bc on public.emojis;
create trigger emojis_bc after insert or update or delete on public.emojis for each row execute function public.bc_emoji();
drop trigger if exists friendships_bc on public.friendships;
create trigger friendships_bc after insert or update or delete on public.friendships for each row execute function public.bc_friend();
drop trigger if exists channel_members_bc on public.channel_members;
create trigger channel_members_bc after insert or delete on public.channel_members for each row execute function public.bc_channel_member();
drop trigger if exists reports_bc on public.reports;
create trigger reports_bc after insert or update on public.reports for each row execute function public.bc_report();

-- These no longer need to be in the postgres_changes publication.
alter publication supabase_realtime drop table public.friendships;
alter publication supabase_realtime drop table public.channel_members;
alter publication supabase_realtime drop table public.servers;
alter publication supabase_realtime drop table public.channels;
alter publication supabase_realtime drop table public.roles;
alter publication supabase_realtime drop table public.member_roles;
alter publication supabase_realtime drop table public.emojis;
alter publication supabase_realtime drop table public.reports;
