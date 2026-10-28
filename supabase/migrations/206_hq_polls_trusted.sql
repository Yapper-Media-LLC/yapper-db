-- 206: In Yapper HQ, only verified people, Bug Hunters and Yapper Plus members can make polls (Oct 18, Antic:
-- people kept making bad/annoying polls). Staff and anyone who can manage HQ are not affected. Other servers
-- are unchanged (they use the Create Polls permission as before). Patched into the live create_poll in place.
-- Re-runnable.
do $do$
declare
  d text := pg_get_functiondef('public.create_poll(uuid, text, text[], boolean, integer)'::regprocedure);
  a text := $a$  if sid is not null and not public.server_perm(sid, 'create_polls') then raise exception 'You can''t create polls in this server'; end if;$a$;
  b text := $b$  if sid is not null and not public.server_perm(sid, 'create_polls') then raise exception 'You can''t create polls in this server'; end if;
  -- Yapper HQ: polls are for verified people, Bug Hunters and Plus members (and staff / server managers).
  if sid is not null and sid = (select default_server_id from public.app_settings limit 1)
     and not public.is_staff() and not public.server_perm(sid, 'manage_server')
     and not exists (select 1 from public.profiles p where p.id = auth.uid()
                     and (p.verified_as is not null or 'bug_hunter' = any(coalesce(p.badges, '{}'::text[])) or p.plus_until > now())) then
    raise exception 'In Yapper HQ, polls are for verified people, Bug Hunters and Plus members' using errcode = 'check_violation';
  end if;$b$;
begin
  if strpos(d, 'polls are for verified people') > 0 then return; end if;
  if strpos(d, a) = 0 then raise exception '206: create_poll() changed on the live database, anchor not found'; end if;
  execute replace(d, a, b);
end $do$;
