-- 492: Import from Discord keeps who can see and post in each channel (security pass 2, N3; flag
-- discord_import_access, test). Before: every imported channel came over public and writable, so a Discord server's
-- staff-only or private channels were open to everyone who joined the copy on Yapin.
-- The route (app/api/import/discord/route.ts) works out each channel's Discord overwrites and sends, per channel:
--   private (bool), role_keys (Discord role ids allowed to see it), read_only (bool), post_role_keys (may post).
-- Roles now go in before channels so those keys map to the new role ids. A key that maps to no imported role is
-- simply left out (the route already made such channels private and lists them for review). Without the new keys a
-- channel is created exactly as before. Same signature and grants as 378. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('discord_import_access', 'Discord import: keep channel access', 'Private channels, role access and read-only channels come over from Discord', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.import_discord_server(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me uuid := auth.uid(); sid uuid; c jsonb; r jsonb; e jsonb; n int := 0; cats jsonb := '{}'::jsonb; roles jsonb := '{}'::jsonb;
  cid uuid; rid uuid; fancy boolean; k text; priv boolean; ro boolean;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('discord_import', null) then raise exception 'Importing isn''t open yet'; end if;
  perform public.check_icon_path(p->>'icon_path');
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, description) values (left(btrim(p->>'name'), 100), p->>'icon_path', me, left(coalesce(p->>'description', ''), 300)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  -- the same branch create_channel takes for text channel names
  fancy := public.feature_on('fancy_names', sid);
  for c in select * from jsonb_array_elements(coalesce(p->'categories', '[]'::jsonb)) loop
    begin
      insert into public.channel_categories (server_id, name, position) values (sid, left(btrim(coalesce(c->>'name', '')), 40), coalesce((c->>'position')::int, n)) returning id into cid;
    exception when others then -- refused name: fallback name
      insert into public.channel_categories (server_id, name, position) values (sid, 'category', coalesce((c->>'position')::int, n)) returning id into cid;
    end;
    cats := cats || jsonb_build_object(c->>'key', cid);
    n := n + 1;
    exit when n >= 50;
  end loop;
  -- Roles before channels, so channel access can point at them by their Discord id (key).
  n := 0;
  for r in select * from jsonb_array_elements(coalesce(p->'roles', '[]'::jsonb)) loop
    insert into public.roles (server_id, name, color, position, perms)
      values (sid, left(r->>'name', 32), nullif(r->>'color', ''), coalesce((r->>'position')::int, n), coalesce(r->'perms', '{}'::jsonb))
      returning id into rid;
    if coalesce(r->>'key', '') <> '' then roles := roles || jsonb_build_object(r->>'key', rid); end if;
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'channels', '[]'::jsonb)) loop
    -- Set in the insert itself: an update after it logged a channel_update and broadcast every channel twice.
    priv := coalesce(c->'private' = 'true'::jsonb, false);
    ro := coalesce(c->'read_only' = 'true'::jsonb, false) and c->>'kind' is distinct from 'voice';
    begin
      insert into public.channels (kind, name, server_id, created_by, position, category_id, private, read_only)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
                case when c->>'kind' = 'voice' then left(c->>'name', 100)
                     else coalesce(case when fancy then public.fancy_channel_slug(c->>'name') else public.slugify_channel(c->>'name') end, 'channel') end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid, priv, ro)
        returning id into cid;
    exception when check_violation or raise_exception then -- refused name: fallback name
      insert into public.channels (kind, name, server_id, created_by, position, category_id, private, read_only)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end, case when c->>'kind' = 'voice' then 'Voice' else 'channel' end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid, priv, ro)
        returning id into cid;
    end;
    -- Who can see it: private channels open only to the listed roles (owner and admins see every channel anyway).
    if priv then
      for k in select distinct x from jsonb_array_elements_text(case when jsonb_typeof(c->'role_keys') = 'array' then c->'role_keys' else '[]'::jsonb end) x loop
        if roles ? k then
          insert into public.channel_roles (channel_id, role_id, server_id) values (cid, (roles->>k)::uuid, sid) on conflict do nothing;
        end if;
      end loop;
    end if;
    -- Who can post: read-only text channels with the roles that may still post.
    if ro then
      for k in select distinct x from jsonb_array_elements_text(case when jsonb_typeof(c->'post_role_keys') = 'array' then c->'post_role_keys' else '[]'::jsonb end) x loop
        if roles ? k then
          insert into public.channel_post_roles (channel_id, role_id, server_id) values (cid, (roles->>k)::uuid, sid) on conflict do nothing;
        end if;
      end loop;
    end if;
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for e in select * from jsonb_array_elements(coalesce(p->'emojis', '[]'::jsonb)) loop
    begin
      insert into public.emojis (owner_id, server_id, name, path, animated) values (me, sid, e->>'name', e->>'path', coalesce((e->>'animated')::boolean, false));
      n := n + 1;
    exception when others then null; -- one bad emoji (name clash, unscanned) shouldn't sink the import
    end;
    exit when n >= 50;
  end loop;
  return sid;
end; $function$;
revoke all on function public.import_discord_server(jsonb) from public, anon;
grant execute on function public.import_discord_server(jsonb) to authenticated, service_role;
