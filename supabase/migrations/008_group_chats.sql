-- ============================================================
-- Yapper · Stage 8 · Group chats
-- ============================================================

alter table public.channels drop constraint channels_kind_check;
alter table public.channels add constraint channels_kind_check check (kind in ('dm', 'group'));
alter table public.channels
  add column icon_path text,
  add constraint channels_name_check check (name is null or char_length(name) between 1 and 100);

-- Group / server icons live in their uploader's folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('icons', 'icons', true, 8388608, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

create policy "icons: read own folder"
  on storage.objects for select to authenticated
  using (bucket_id = 'icons' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "icons: upload to own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'icons' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "icons: delete own folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'icons' and (storage.foldername(name))[1] = auth.uid()::text);

-- Channel details (name, icon) change live for everyone in the chat.
alter publication supabase_realtime add table public.channels;

create or replace function public.check_icon_path(p text)
returns void
language plpgsql
as $$
begin
  if p is not null and p not like auth.uid()::text || '/%' then
    raise exception 'Invalid picture';
  end if;
end;
$$;

-- Everyone you add must be your friend, and nobody involved can have blocked anyone else involved... at least not you.
create or replace function public.check_addable(people uuid[])
returns void
language plpgsql
set search_path = public
as $$
declare
  p uuid;
begin
  foreach p in array coalesce(people, '{}') loop
    if p = auth.uid() then continue; end if;
    if not public.are_friends(auth.uid(), p) or public.is_blocked_between(auth.uid(), p) then
      raise exception 'You can only add friends';
    end if;
  end loop;
end;
$$;

create or replace function public.create_group(group_name text, group_icon text, member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  people uuid[];
  cid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  people := array(select distinct x from unnest(coalesce(member_ids, '{}')) x where x <> me);
  if cardinality(people) < 1 then raise exception 'Pick at least one friend'; end if;
  if cardinality(people) > 9 then raise exception 'Group chats can have up to 10 people'; end if;
  perform public.check_addable(people);
  perform public.check_icon_path(group_icon);

  insert into public.channels (kind, name, icon_path, created_by)
    values ('group', nullif(btrim(group_name), ''), group_icon, me)
    returning id into cid;
  insert into public.channel_members (channel_id, user_id)
    select cid, x from unnest(people || me) x;
  return cid;
end;
$$;

create or replace function public.add_group_members(cid uuid, member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  people uuid[];
begin
  if not exists (select 1 from public.channels where id = cid and kind = 'group') then
    raise exception 'Group not found';
  end if;
  if not public.is_channel_member(cid) then raise exception 'Group not found'; end if;
  people := array(
    select distinct x from unnest(coalesce(member_ids, '{}')) x
    where not exists (select 1 from public.channel_members where channel_id = cid and user_id = x)
  );
  perform public.check_addable(people);
  if (select count(*) from public.channel_members where channel_id = cid) + cardinality(people) > 10 then
    raise exception 'Group chats can have up to 10 people';
  end if;
  insert into public.channel_members (channel_id, user_id) select cid, x from unnest(people) x;
end;
$$;

create or replace function public.update_group(cid uuid, group_name text, group_icon text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.channels where id = cid and kind = 'group') or not public.is_channel_member(cid) then
    raise exception 'Group not found';
  end if;
  -- Passing the current icon path keeps it; a new one must be your own upload.
  if group_icon is distinct from (select icon_path from public.channels where id = cid) then
    perform public.check_icon_path(group_icon);
  end if;
  update public.channels
    set name = nullif(btrim(group_name), ''), icon_path = group_icon
    where id = cid;
end;
$$;

create or replace function public.leave_group(cid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.channels where id = cid and kind = 'group') then
    raise exception 'Group not found';
  end if;
  delete from public.channel_members where channel_id = cid and user_id = auth.uid();
  delete from public.channel_reads where channel_id = cid and user_id = auth.uid();
  -- Last one out turns off the lights.
  if not exists (select 1 from public.channel_members where channel_id = cid) then
    delete from public.channels where id = cid;
  end if;
end;
$$;

grant execute on function public.create_group(text, text, uuid[]) to authenticated;
grant execute on function public.add_group_members(uuid, uuid[]) to authenticated;
grant execute on function public.update_group(uuid, text, text) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
