-- 424: "No GIFs" channel setting (flag no_gifs, test). Asked for in HQ: some channels want pictures but not a wall of
-- GIFs. channels.no_gifs: with it on, GIF attachments (the picker stores KLIPY GIFs as .gif attachments) and GIF
-- links (a .gif URL, tenor, giphy, klipy) are refused for everyone without Manage Messages in that channel; other
-- pictures and files are still fine. Same shape as text-only (no_images, 091/202): bots pass, managers pass, the
-- trigger runs before insert or update of content/attachment_path. The audit log records the switch like no_images.
-- Re-runnable.
set lock_timeout = '3s';

alter table public.channels add column if not exists no_gifs boolean not null default false;

create or replace function public.no_gifs_channel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare c public.channels;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null or not c.no_gifs then return new; end if;
  if public.channel_allows(c.id, 'manage_messages') then return new; end if;
  if new.attachment_path ~* '\.gif(\?|$)'
     or new.content ~* 'https?://\S+\.gif(?![a-z0-9])'
     or new.content ~* '(tenor\.com|giphy\.com|klipy\.com)/' then
    raise exception 'GIFs are off in this channel.' using errcode = 'check_violation';
  end if;
  return new;
end; $$;
revoke execute on function public.no_gifs_channel() from public, anon, authenticated;
drop trigger if exists messages_no_gifs on public.messages;
create trigger messages_no_gifs before insert or update of content, attachment_path on public.messages
  for each row execute function public.no_gifs_channel();

-- The audit log (232) sees the switch too: the trigger lists the column, and audit_channels() (232's text, one key
-- added to the diff list) writes the change. The trigger alone wasn't enough: the function diffs a fixed key list.
create or replace function public.audit_channels() returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  -- Tickets open and close all day: not worth a line each.
  if coalesce(new.ticket_by, old.ticket_by) is not null then return null; end if;
  if tg_op = 'INSERT' then
    if new.server_id is not null then
      perform public.audit_add(new.server_id, 'channel_create', 'channel', new.id, new.name, jsonb_build_object('kind', new.kind));
    end if;
  elsif tg_op = 'DELETE' then
    if old.server_id is not null then
      perform public.audit_add(old.server_id, 'channel_delete', 'channel', old.id, old.name, jsonb_build_object('kind', old.kind));
    end if;
  elsif new.server_id is not null then
    -- A deleted category clears category_id on its channels (cascade): that's not a channel edit.
    if pg_trigger_depth() > 1 and new.category_id is null and old.category_id is not null then return null; end if;
    d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'private', 'read_only', 'slowmode', 'no_images', 'no_gifs', 'category_id']);
    if jsonb_array_length(d) > 0 then
      perform public.audit_add(new.server_id, 'channel_update', 'channel', new.id, new.name, jsonb_build_object('changes', d));
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger channels_audit after insert or delete or update of name, private, read_only, slowmode, no_images, no_gifs, category_id
  on public.channels for each row execute function public.audit_channels();

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('no_gifs', 'No GIFs channel setting', 'Edit channel: a switch that refuses GIF attachments and GIF links in that channel (managers excepted)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
reset lock_timeout;
