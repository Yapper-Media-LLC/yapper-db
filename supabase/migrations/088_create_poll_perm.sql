-- create_poll never checked the Create Polls permission (applied live Oct 14, bug report 54619a8d).
create or replace function public.create_poll(cid uuid, question text, opts text[], multi boolean default false, hours integer default 24)
 returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare sid uuid; mid uuid; pid uuid; o jsonb := '[]'::jsonb; i int; last_at timestamptz;
begin
  select server_id into sid from public.channels where id = cid;
  if not public.can_access_channel(cid) then raise exception 'Channel not found'; end if;
  if not public.can_post_channel(cid) or public.dm_blocked(cid) then raise exception 'You can''t post in this channel'; end if;
  -- The Create Polls permission (role or @everyone) was never checked here.
  if sid is not null and not public.server_perm(sid, 'create_polls') then raise exception 'You can''t create polls in this server'; end if;
  if not (public.feature_on('polls', sid) or public.feature_on_for_me('polls')) then raise exception 'Polls aren''t available here yet'; end if;
  select max(created_at) into last_at from public.polls where created_by = auth.uid();
  if last_at is not null and last_at > now() - interval '5 minutes' and not public.server_perm(sid, 'manage_server') then
    raise exception 'You can make another poll in % min', greatest(1, ceil(extract(epoch from (last_at + interval '5 minutes' - now())) / 60));
  end if;
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
$function$;
