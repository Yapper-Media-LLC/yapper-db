-- DMs without friending (like Discord): anyone you share a server with can message you,
-- unless you set "Who can message me" to friends only. Staff can always reach people.
alter table public.profiles add column if not exists dms_from text not null default 'servers' check (dms_from in ('everyone', 'servers', 'friends'));
create or replace function public.get_or_create_dm(other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); k text; cid uuid; pref text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if other is null or other = me then raise exception 'Pick someone else to chat with'; end if;
  select dms_from into pref from public.profiles where id = other;
  if pref is null then raise exception 'User not found'; end if;
  k := least(me::text, other::text) || ':' || greatest(me::text, other::text);
  select id into cid from public.channels where dm_key = k;
  if cid is not null then return cid; end if;
  if public.is_blocked_between(me, other) then raise exception 'You can''t message this person'; end if;
  if not public.are_friends(me, other) and not public.is_staff() then
    if pref = 'friends' then raise exception 'They only take messages from friends. Send a friend request first.'; end if;
    if pref = 'servers' and not exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = other) then
      raise exception 'You need to share a server with them or be friends to message them.';
    end if;
  end if;
  insert into public.channels (kind, dm_key, created_by) values ('dm', k, me) on conflict (dm_key) do nothing returning id into cid;
  if cid is null then select id into cid from public.channels where dm_key = k;
  else insert into public.channel_members (channel_id, user_id) values (cid, me), (cid, other); end if;
  return cid;
end; $$;
update public.profiles set dms_from = 'friends' where id in (select user_id from public.site_admins);
