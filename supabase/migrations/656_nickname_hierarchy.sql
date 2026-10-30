-- 656: Manage Nicknames let a mod rename anyone in the server, the owner and people above them included
-- (bug report 2bc9e767, "it shows i can moderate people that are above my role"). Like Discord, changing someone
-- else's nickname now also needs to outrank them (public.outranks: the owner, or a higher top role), the same rule
-- time out, kick and ban follow. Your own nickname is unchanged (Change Nickname).
-- set_nickname is the live text as of Oct 28 2026 with that one check added. Re-runnable.

set lock_timeout = '3s';

create or replace function public.set_nickname(sid uuid, target uuid, nick text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare n text := left(public.clean_name(nick), 32);
begin
  if not public.feature_on('nicknames', sid) then
    raise exception 'Nicknames aren''t available here yet';
  end if;
  if target = auth.uid() then
    if not public.server_perm(sid, 'change_nickname') then
      raise exception 'You can''t change your nickname here';
    end if;
  elsif not public.server_perm(sid, 'manage_nicknames') then
    raise exception 'You can''t change other people''s nicknames';
  elsif not public.outranks(sid, target) then
    raise exception 'You can only change nicknames of people below your top role';
  end if;
  if n is not null and n !~ '[[:alnum:]]' then
    raise exception 'Nicknames need at least one letter or number';
  end if;
  if n is not null and (public.bad_name(n) or public.has_adult_link(n) or (public.brand_name(n) and not public.is_site_admin())) then
    raise exception 'That nickname isn''t allowed.';
  end if;
  update public.server_members set nickname = n where server_id = sid and user_id = target;
end;
$function$;
