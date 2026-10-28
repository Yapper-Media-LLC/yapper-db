-- 187 (applied live as 183): Levels bot role rewards could hand out any role (found reviewing 182).
-- set_server_bot only checked Manage Server, and bot_levels (security definer) gives reward roles past the
-- role guards. Someone with Manage Server could set "level 1 -> Owner role", chat a bit and get Owner.
-- Now, unless you own the server (or are a site admin), every reward role must be in this server, below
-- your own highest role, and not have Administrator. Patched in place (keeps live edits), re-runnable.

do $$
declare
  def text := pg_get_functiondef('public.set_server_bot(uuid, text, boolean, jsonb)'::regprocedure);
  anchor text := $a$  if jsonb_typeof(cfg -> 'rewards') = 'array' and jsonb_array_length(cfg -> 'rewards') > 20 then raise exception 'Up to 20 role rewards'; end if;$a$;
  add text := $a$
  if jsonb_typeof(cfg -> 'rewards') = 'array'
     and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid())
     and not public.is_site_admin()
     and exists (
       select 1 from jsonb_array_elements(cfg -> 'rewards') rw
       left join public.roles r on r.id = case when (rw ->> 'role_id') ~ '^[0-9a-f-]{36}$' then (rw ->> 'role_id')::uuid end
       where rw ? 'role_id' and (r.id is null or r.server_id <> sid
              or r.position >= public.my_top_role_position(sid)
              or coalesce((r.perms ->> 'administrator')::boolean, false))) then
    raise exception 'Role rewards have to be roles below your highest role';
  end if;$a$;
  patched text;
begin
  if position('Role rewards have to be roles below' in def) > 0 then return; end if;
  patched := replace(def, anchor, anchor || add);
  if patched = def then raise exception '187: rewards anchor not found in set_server_bot, nothing patched'; end if;
  execute patched;
end $$;
