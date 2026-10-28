-- 173: slowmode lets a picture album through (bug reports: "can't post multiple images on servers with slowmode").
-- The app sends several pictures as one message each (the text rides with the first). With slowmode on,
-- every picture after the first was refused. Like Discord (one message with up to 10 attachments), the
-- picture-only messages right after an accepted message now count as part of it: up to 9 extra pictures
-- (10 messages in total), within 15 seconds of the accepted one. They don't move the slowmode clock.
-- The extras are counted in post_marks.album_n (reset whenever a normal message is accepted), so deleting
-- them doesn't free up room for more. Only images qualify (not voice messages or files).
-- Same as 142's message_slowmode otherwise. Re-runnable.

alter table public.post_marks add column if not exists album_n int not null default 0;

create or replace function public.message_slowmode()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare c public.channels; last_at timestamptz; mark timestamptz; wait int; slow int; bumped boolean;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null then return new; end if;
  if (case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
       then public.channel_perm(c.id, 'manage_messages')
       else public.server_perm(c.server_id, 'manage_messages') end) then
    return new;
  end if;
  if public.server_locked(c.server_id) then
    raise exception 'This server is locked by its mods right now. Only mods can post.' using errcode = 'P0001';
  end if;
  slow := greatest(coalesce(c.slowmode, 0), case when c.auto_slow_until > now() then 5 else 0 end);
  if slow <= 0 then return new; end if;
  perform pg_advisory_xact_lock(hashtext('slow:' || new.author_id::text || ':' || new.channel_id::text));
  select at into mark from public.post_marks where channel_id = new.channel_id and author_id = new.author_id and kind = 'msg';
  -- Album: a picture-only message (no text, no reply) right after the accepted one rides along with it.
  if mark is not null and mark > now() - interval '15 seconds'
     and coalesce(new.content, '') = '' and new.reply_to_id is null and new.voice_secs is null
     and new.attachment_path ~* '\.(png|jpe?g|gif|webp|avif)$' then
    update public.post_marks set album_n = album_n + 1
      where channel_id = new.channel_id and author_id = new.author_id and kind = 'msg' and at = mark and album_n < 9
      returning true into bumped;
    if bumped then return new; end if;
  end if;
  select max(created_at) into last_at from public.messages
    where channel_id = new.channel_id and author_id = new.author_id and id <> new.id;
  last_at := greatest(last_at, mark);
  if last_at is not null and last_at > now() - make_interval(secs => slow) then
    wait := ceil(extract(epoch from (last_at + make_interval(secs => slow) - now())));
    raise exception 'Slowmode is on. You can send another message in %s', wait using errcode = 'P0001';
  end if;
  insert into public.post_marks (channel_id, author_id, kind, at, album_n) values (new.channel_id, new.author_id, 'msg', now(), 0)
    on conflict (channel_id, author_id, kind) do update set at = excluded.at, album_n = 0;
  return new;
end $$;
