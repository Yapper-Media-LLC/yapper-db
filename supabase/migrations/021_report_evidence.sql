-- ============================================================
-- Yapper · Reports about a person include their recent messages
-- So admins have something to look at even when nobody reported a
-- specific message. Only messages the reporter could see are included.
-- ============================================================

alter table public.reports add column if not exists evidence jsonb not null default '[]'::jsonb;

create or replace function public.report_user(uid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
  ev jsonb;
begin
  perform public.report_guard(auth.uid());
  if uid = auth.uid() then raise exception 'You can''t report yourself'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'User not found'; end if;
  -- Their last 15 messages in places the reporter can see.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'channel_id', m.channel_id, 'content', m.content,
      'attachment', m.attachment_path, 'created_at', m.created_at) order by m.created_at desc), '[]'::jsonb)
    into ev
  from (
    select * from public.messages
    where author_id = uid and public.can_access_channel(channel_id)
    order by created_at desc limit 15
  ) m;
  insert into public.reports (reporter_id, target_id, reason, details, evidence)
  values (auth.uid(), uid, why, left(coalesce(more, ''), 1000), ev)
  returning id into rid;
  return rid;
end;
$$;
