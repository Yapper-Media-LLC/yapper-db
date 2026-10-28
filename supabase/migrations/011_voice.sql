-- ============================================================
-- Yapper · Stage 11 · Voice channels
-- The calls themselves run on LiveKit; the database just needs to
-- know which channels are voice channels.
-- ============================================================

alter table public.channels drop constraint channels_kind_check;
alter table public.channels add constraint channels_kind_check check (
  (server_id is null and kind in ('dm', 'group')) or (server_id is not null and kind in ('text', 'voice'))
);

-- New servers get a voice channel too.
create or replace function public.create_server(server_name text, server_icon text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  sid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  perform public.check_icon_path(server_icon);
  if (select count(*) from public.servers where owner_id = me) >= 50 then
    raise exception 'You own a lot of servers already';
  end if;
  insert into public.servers (name, icon_path, owner_id) values (btrim(server_name), server_icon, me) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0);
  insert into public.channels (kind, name, server_id, created_by, position) values ('voice', 'General', sid, me, 1);
  return sid;
end;
$$;

-- Voice channel names can have capitals and spaces ("Gaming Lounge").
create or replace function public.create_channel(sid uuid, channel_name text, channel_kind text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  k text := coalesce(channel_kind, 'text');
  n text;
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage channels here'; end if;
  if k = 'voice' then
    n := left(nullif(regexp_replace(btrim(channel_name), '\s+', ' ', 'g'), ''), 100);
  else
    n := public.slugify_channel(channel_name);
  end if;
  if n is null then raise exception 'Channels need a name'; end if;
  if (select count(*) from public.channels where server_id = sid) >= 100 then raise exception 'Too many channels'; end if;
  insert into public.channels (kind, name, server_id, created_by, position)
    values (k, n, sid, auth.uid(),
            coalesce((select max(position) + 1 from public.channels where server_id = sid), 0))
    returning id into cid;
  return cid;
end;
$$;
