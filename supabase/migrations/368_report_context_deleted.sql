-- 368: report context includes recently deleted messages (flag report_context_deleted, test). The context saved with a
-- message report (8 before, 4 after, from 311) only read public.messages, so someone could delete the lead-up before a
-- report was filed and staff saw the last message without it. Messages deleted in the last 2 days (deleted_messages,
-- kept only for reports) now fill in, marked "deleted": true, text only (their files may already be gone from R2).
-- Only in DMs and group chats (server reports are readable by that server's managers, who must not get deleted
-- messages on demand), only ones their author deleted (not staff removals), and never one that is still up.
-- Same access rule as before: the reporter must be able to open the chat. Flag checked with feature_on(.., null),
-- so it follows the reporter. Re-runnable.

create index if not exists deleted_messages_channel_created_idx on public.deleted_messages (channel_id, created_at);

create or replace function public.report_message(mid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare m public.messages; rid uuid; ev jsonb; k text; gone timestamptz; gone_by uuid; with_gone boolean;
begin
  perform public.report_guard(auth.uid());
  select * into m from public.messages where id = mid;
  if m.id is null then
    select d.id, d.channel_id, d.author_id, d.content, d.attachment_path, d.webhook, d.created_at, d.deleted_at, d.deleted_by
      into m.id, m.channel_id, m.author_id, m.content, m.attachment_path, m.webhook, m.created_at, gone, gone_by
      from public.deleted_messages d where d.id = mid and d.deleted_at > now() - interval '2 days';
  end if;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  if m.author_id = auth.uid() then raise exception 'You can''t report your own message'; end if;
  select kind into k from public.channels where id = m.channel_id;
  with_gone := public.feature_on('report_context_deleted', null) and k in ('dm', 'group');
  -- Context: the 12 messages around it in the same chat (so DM reports can be judged without reading the whole DM),
  -- with the flag on also the ones deleted in the last 2 days.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'channel_id', x.channel_id, 'content', x.content, 'attachment', x.attachment_path, 'created_at', x.created_at,
      'author_id', x.author_id, 'kind', k) || case when x.deleted then '{"deleted": true}'::jsonb else '{}'::jsonb end
      order by x.created_at), '[]'::jsonb)
    into ev
  from (
    (select * from (
       (select id, channel_id, content, attachment_path, created_at, author_id, false deleted from public.messages
         where channel_id = m.channel_id and created_at <= m.created_at and id <> m.id order by created_at desc limit 8)
       union all
       (select d.id, d.channel_id, d.content, null::text, d.created_at, d.author_id, true from public.deleted_messages d
         where with_gone and d.channel_id = m.channel_id and d.created_at <= m.created_at and d.id <> m.id
           and d.deleted_at > now() - interval '2 days' and d.deleted_by is not distinct from d.author_id
           and not exists (select 1 from public.messages mm where mm.id = d.id)
         order by d.created_at desc limit 8)
     ) b order by created_at desc limit 8)
    union all
    (select * from (
       (select id, channel_id, content, attachment_path, created_at, author_id, false from public.messages
         where channel_id = m.channel_id and created_at > m.created_at order by created_at limit 4)
       union all
       (select d.id, d.channel_id, d.content, null::text, d.created_at, d.author_id, true from public.deleted_messages d
         where with_gone and d.channel_id = m.channel_id and d.created_at > m.created_at
           and d.deleted_at > now() - interval '2 days' and d.deleted_by is not distinct from d.author_id
           and not exists (select 1 from public.messages mm where mm.id = d.id)
         order by d.created_at limit 4)
     ) a order by created_at limit 4)
  ) x;
  -- A deleted one has no row to point at (message_id references messages): it goes in marked deleted, like a report
  -- whose message is deleted afterwards.
  insert into public.reports (reporter_id, target_id, message_id, channel_id, message_content, message_attachment, reason, details, evidence, server_id, webhook_id,
                              message_deleted_at, message_deleted_by)
  values (auth.uid(), coalesce((select w.created_by from public.webhooks w where m.webhook is not null and w.id = (m.webhook ->> 'id')::uuid), m.author_id),
          case when gone is null then m.id end, m.channel_id, m.content, m.attachment_path, why, left(coalesce(more, ''), 1000), ev,
          (select server_id from public.channels where id = m.channel_id), (m.webhook ->> 'id')::uuid,
          gone, case when gone is null then null when gone_by is null then 'system' when gone_by = m.author_id then 'author'
                     when public.is_staff_user(gone_by) then 'staff' else 'server_mod' end)
  returning id into rid;
  return rid;
end;
$$;
revoke all on function public.report_message(uuid, text, text) from public, anon;
grant execute on function public.report_message(uuid, text, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('report_context_deleted', 'Deleted messages in report context', 'Messages deleted in the last 2 days show in the conversation saved with a report, marked deleted', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
