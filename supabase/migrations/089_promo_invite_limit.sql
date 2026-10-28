-- #promote-your-server: one invite post per person every 6 hours (applied live Oct 15).
-- The channel took 6,000 invite posts in two days; the top posters put 40 to 80 a day in it.
create or replace function public.invites_only_in_promo()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare ch record; last_at timestamptz;
begin
  if new.content !~* '(yapper\.website/invite/|discord\.gg/|discord(app)?\.com/invite/|t\.me/|guilded\.gg/)' then return new; end if;
  select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;
  if ch.server_id is null or ch.server_id <> (select default_server_id from public.app_settings limit 1) or public.is_staff() then return new; end if;
  if ch.name !~* 'promot' then
    raise exception 'Invite links only go in #promote-your-server.' using errcode = 'check_violation';
  end if;
  -- One invite post per person every 6 hours there: a few people were posting 40 to 80 a day.
  select max(m.created_at) into last_at from public.messages m
    where m.channel_id = new.channel_id and m.author_id = new.author_id and m.id <> new.id
      and m.created_at > now() - interval '6 hours'
      and m.content ~* '(yapper\.website/invite/|discord\.gg/|discord(app)?\.com/invite/|t\.me/|guilded\.gg/)';
  if last_at is not null then
    raise exception 'You can post an invite in #promote-your-server once every 6 hours. Next one in % min', greatest(1, ceil(extract(epoch from (last_at + interval '6 hours' - now())) / 60)) using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;
