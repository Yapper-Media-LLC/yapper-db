-- Text-only channels (applied live Oct 15): channels.no_images. With it on, attachments and image/GIF
-- links are refused for everyone without Manage Messages. HQ #general is text only; #memes keeps images.
-- Asked for after a wave of NSFW pictures posted and deleted in #general.
alter table public.channels add column if not exists no_images boolean not null default false;

create or replace function public.no_images_channel()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare c public.channels;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null or not c.no_images then return new; end if;
  if public.server_perm(c.server_id, 'manage_messages') then return new; end if;
  if new.attachment_path is not null
     or new.content ~* '\.(png|jpe?g|gif|webp|avif|mp4|webm|mov)(\?[^\s]*)?(\s|$)'
     or new.content ~* '(tenor\.com|giphy\.com|klipy\.com|imgur\.com|media\.discordapp\.net|cdn\.discordapp\.com)/' then
    raise exception 'This channel is text only. Images and GIFs go in an images channel.' using errcode = 'check_violation';
  end if;
  return new;
end; $function$;
drop trigger if exists messages_no_images on public.messages;
create trigger messages_no_images before insert or update of content, attachment_path on public.messages
  for each row execute function public.no_images_channel();
