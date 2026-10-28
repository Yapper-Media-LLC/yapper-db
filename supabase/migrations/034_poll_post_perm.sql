-- Polls follow the same "who can post here" rule as messages (read-only channels, dm blocks).
create or replace function public.create_poll(cid uuid, question text, opts text[], multi boolean default false, hours int default 24)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; mid uuid; pid uuid; o jsonb := '[]'::jsonb; i int;
begin
  select server_id into sid from public.channels where id = cid;
  if not public.can_access_channel(cid) then raise exception 'Channel not found'; end if;
  if not public.can_post_channel(cid) or public.dm_blocked(cid) then raise exception 'You can''t post in this channel'; end if;
  if not (public.feature_on('polls', sid) or public.feature_on_for_me('polls')) then raise exception 'Polls aren''t available here yet'; end if;
  if coalesce(array_length(opts, 1), 0) < 2 or array_length(opts, 1) > 10 then raise exception 'Give 2 to 10 options'; end if;
  for i in 1 .. array_length(opts, 1) loop
    if char_length(trim(opts[i])) = 0 or char_length(opts[i]) > 80 then raise exception 'Options are 1–80 characters'; end if;
    o := o || jsonb_build_object('id', i::text, 'text', trim(opts[i]));
  end loop;
  insert into public.messages (channel_id, author_id, content) values (cid, auth.uid(), '📊 ' || left(question, 200)) returning id into mid;
  insert into public.polls (message_id, channel_id, question, options, multi, closes_at, created_by)
  values (mid, cid, left(question, 200), o, multi, case when hours > 0 then now() + make_interval(hours => least(hours, 24 * 14)) end, auth.uid())
  returning id into pid;
  return pid;
end;
$$;
