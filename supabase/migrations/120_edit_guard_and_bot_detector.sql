-- Two fixes from #bug-reports (Oct 16).
-- 1. Editing a message failed with "permission denied for table profiles": message_edit_guard ran as the
--    user and read profiles.muted_until, which users can't see. It runs as the owner now.
-- 2. The automatic BOT tag hit real people in fast chats: the rule now needs a "!cmd" or "/cmd" line
--    answered inside 1 second, 15 times in an hour (was: any punctuation-led line, 2 s, 5 times).
--    People it caught in the last week were untagged (see mod_log 'unmarked_bot').

create or replace function public.message_edit_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid;
begin
  new.id := old.id;
  new.channel_id := old.channel_id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  new.attachment_path := old.attachment_path;
  new.attachment_width := old.attachment_width;
  new.attachment_height := old.attachment_height;
  new.attachment_name := old.attachment_name;
  new.attachment_size := old.attachment_size;
  new.reply_to_id := case when new.reply_to_id is null then null else old.reply_to_id end;
  if session_user = 'authenticated' or current_setting('request.jwt.claim.role', true) = 'authenticated' or (current_setting('request.jwt.claims', true)::jsonb ->> 'role') = 'authenticated' then
    new.pinned_at := old.pinned_at;
    new.pinned_by := old.pinned_by;
    if new.content is distinct from old.content then
      if exists (select 1 from public.profiles p where p.id = old.author_id and p.muted_until > now()) then
        raise exception 'You''re timed out, so you can''t edit messages right now.' using errcode = 'check_violation';
      end if;
      select server_id into sid from public.channels where id = old.channel_id;
      if sid is not null and public.server_timed_out(sid, old.author_id) is not null then
        raise exception 'You''re timed out in this server, so you can''t edit messages right now.' using errcode = 'check_violation';
      end if;
    end if;
  end if;
  if new.content is distinct from old.content then new.edited_at := now(); else new.edited_at := old.edited_at; end if;
  return new;
end $$;

create or replace function public.detect_bot_replies() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare prev record; sig public.bot_signals;
begin
  if current_setting('yapper.bot', true) = '1' or current_setting('yapper.bulk', true) = '1' then return new; end if;
  if exists (select 1 from public.bots where id = new.author_id) or exists (select 1 from public.bot_accounts where user_id = new.author_id) then return new; end if;
  select m.author_id, m.content, m.created_at into prev from public.messages m
    where m.channel_id = new.channel_id and m.created_at < new.created_at and m.id <> new.id
    order by m.created_at desc limit 1;
  if prev.author_id is null or prev.author_id = new.author_id then return new; end if;
  if new.created_at - prev.created_at > interval '1 second' then return new; end if;
  if coalesce(prev.content, '') !~ '^[!/$][A-Za-z][A-Za-z0-9_-]*(\s|$)' then return new; end if;
  if public.is_staff_user(new.author_id) then return new; end if;
  insert into public.bot_signals as b (user_id, hits, first_at) values (new.author_id, 1, now())
    on conflict (user_id) do update set
      hits = case when b.first_at < now() - interval '1 hour' then 1 else b.hits + 1 end,
      first_at = case when b.first_at < now() - interval '1 hour' then now() else b.first_at end
    returning * into sig;
  if sig.hits >= 15 and not exists (select 1 from public.profiles where id = new.author_id and 'bot' = any(coalesce(badges, '{}'::text[]))) then
    update public.profiles set badges = array(select distinct unnest(coalesce(badges, '{}'::text[]) || array['bot'])) where id = new.author_id;
    insert into public.mod_log (actor, action, target_id, reason)
      values (null, 'marked_bot', new.author_id, 'Automatic: answered !/ commands within 1 second, 15 times in an hour');
  end if;
  return new;
end $$;

-- Untag the people the old rule caught this week (registered bots and Yapper's own stay tagged).
with hit as (
  select distinct l.target_id from public.mod_log l
  where l.action = 'marked_bot' and l.actor is null and l.created_at > now() - interval '7 days'
    and not exists (select 1 from public.bots b where b.id = l.target_id)
    and not exists (select 1 from public.bot_accounts a where a.user_id = l.target_id)
    and not exists (select 1 from public.mod_log m where m.target_id = l.target_id and m.action = 'marked_bot' and m.actor is not null)
), upd as (
  update public.profiles p set badges = array_remove(p.badges, 'bot'),
    shown_badge = case when p.shown_badge = 'bot' then null else p.shown_badge end
  from hit where p.id = hit.target_id and 'bot' = any(coalesce(p.badges, '{}'::text[]))
  returning p.id
)
insert into public.mod_log (actor, action, target_id, reason) select null, 'unmarked_bot', id, 'Automatic: old bot rule was too eager' from upd;
update public.bot_signals set hits = 0, first_at = now() - interval '2 hours';
