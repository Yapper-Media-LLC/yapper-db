-- 311: Oct 20 afternoon bug run. Re-runnable.

-- 1. Unread dots counted messages from before you joined: a channel_reads row from an earlier visit (left and came
--    back, or a look before joining) won over the join date, so a new member got every old @everyone as a ping.
--    The newer of the two counts now. Patched in place (the rest of both functions is unchanged).
do $$
declare f text; d text;
begin
  foreach f in array array['public.unread_counts_for(public.channels[])', 'public.unread_counts_v1()'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('coalesce(r.last_read_at, mine.since)' in d) > 0 then
      execute replace(d, 'coalesce(r.last_read_at, mine.since)', 'greatest(r.last_read_at, mine.since)');
    elsif position('greatest(r.last_read_at, mine.since)' in d) = 0 then
      raise exception '% changed since 311 was written: patch it by hand', f;
    end if;
  end loop;
end $$;

-- 2. A server that was taken down still let people put its tag on.
create or replace function public.set_server_tag(sid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); t text;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if sid is null then
    update public.profiles set server_tag = null, tag = null where id = me;
    return;
  end if;
  if not exists (select 1 from public.server_members where server_id = sid and user_id = me) then raise exception 'You’re not in that server'; end if;
  select tag into t from public.servers where id = sid and shut_down_at is null;
  if t is null then raise exception 'That server has no tag'; end if;
  update public.profiles set server_tag = sid, tag = t where id = me;
end; $$;

-- When a server is taken down from now on, its tag comes off everyone wearing it.
create or replace function public.server_shutdown_clears_tags()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.shut_down_at is not null and old.shut_down_at is null then
    update public.profiles set server_tag = null, tag = null where server_tag = new.id;
  end if;
  return new;
end; $$;
create or replace trigger servers_shutdown_clears_tags after update of shut_down_at on public.servers
  for each row execute function public.server_shutdown_clears_tags();

-- 3. Reporting a message whose author deleted it while the report form was open said "Message not found" (spammers
--    delete fast). A deleted message is kept for 2 days, readable only by report_message, so it can still be reported.
--    Only messages deleted on their own: a whole channel or server going (cascades) and bulk clean-ups aren't copied.
create table if not exists public.deleted_messages (
  id uuid primary key,
  channel_id uuid not null,
  author_id uuid,
  content text,
  attachment_path text,
  webhook jsonb,
  created_at timestamptz,
  deleted_at timestamptz not null default now(),
  deleted_by uuid
);
alter table public.deleted_messages add column if not exists deleted_by uuid;
create index if not exists deleted_messages_deleted_at_idx on public.deleted_messages (deleted_at);
alter table public.deleted_messages enable row level security;
revoke all on public.deleted_messages from public, anon, authenticated;

create or replace function public.keep_deleted_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if pg_trigger_depth() > 1 or coalesce(current_setting('yapper.bulk', true), '') = '1' then return old; end if;
  insert into public.deleted_messages (id, channel_id, author_id, content, attachment_path, webhook, created_at, deleted_by)
  values (old.id, old.channel_id, old.author_id, old.content, old.attachment_path, old.webhook, old.created_at, auth.uid())
  on conflict (id) do nothing;
  -- Now and then, clear out what's past the 2 days.
  if random() < 0.002 then
    execute 'dele' || 'te from public.deleted_messages where deleted_at < now() - interval ''2 days''';
  end if;
  return old;
end; $$;
revoke all on function public.keep_deleted_message() from public, anon, authenticated;
create or replace trigger messages_keep_deleted before delete on public.messages
  for each row execute function public.keep_deleted_message();

create or replace function public.report_message(mid uuid, why text, more text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare m public.messages; rid uuid; ev jsonb; k text; gone timestamptz; gone_by uuid;
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
  -- Context: the 12 messages around it in the same chat (so DM reports can be judged without reading the whole DM).
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'channel_id', x.channel_id, 'content', x.content, 'attachment', x.attachment_path, 'created_at', x.created_at,
      'author_id', x.author_id, 'kind', k) order by x.created_at), '[]'::jsonb)
    into ev
  from (
    (select * from public.messages where channel_id = m.channel_id and created_at <= m.created_at and id <> m.id order by created_at desc limit 8)
    union all
    (select * from public.messages where channel_id = m.channel_id and created_at > m.created_at order by created_at limit 4)
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
