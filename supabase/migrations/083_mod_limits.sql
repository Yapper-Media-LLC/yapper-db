-- Moderator hourly limits: bans 15, timeouts 60 (Oct 15; were 30 / 80). Reset and other stay 20 / 60.
create or replace function public.mod_guard(action text, target uuid, why text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int; lim int;
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action when 'ban' then 15 when 'timeout' then 60 when 'reset' then 20 else 60 end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = mod_guard.action and created_at > now() - interval '1 hour';
  if n >= lim then
    update public.site_moderators set suspended_at = now(), suspended_reason = 'Automatic: more than ' || lim || ' ' || action || 's in an hour' where user_id = auth.uid();
    insert into public.mod_log (actor, action, reason) values (auth.uid(), 'auto_suspended', 'More than ' || lim || ' ' || action || 's in an hour');
    raise exception 'You''ve hit the hourly limit for that; your moderator powers are paused until an admin reviews.';
  end if;
end; $function$;
