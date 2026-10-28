-- Raid lock threshold 25 -> 60 joins a minute (applied live Oct 14).
-- HQ hit exactly 25 real joins in one minute on a busy evening and locked itself for 15 minutes;
-- an actual raid is hundreds a minute.
create or replace function public.auto_lock_on_raid()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int;
begin
  if public.server_locked(new.server_id) then return null; end if;
  select count(*) into n from public.server_members where server_id = new.server_id and joined_at > now() - interval '60 seconds';
  -- 25 tripped on an ordinary busy evening (HQ gets 15-25 real joins a minute at peak). A raid is hundreds.
  if n >= 60 then
    update public.servers set locked_until = now() + interval '15 minutes', lock_reason = 'auto: ' || n || ' joins in a minute' where id = new.server_id;
  end if;
  return null;
end; $function$;
