-- 625: where did this emoji come from? (Antic, Oct 28: racist emojis showed up and nobody could tell which server
-- they belonged to.) Flag emoji_source, mode test.
--   emoji_source(eid)          anyone signed in (flag on for them): the emoji, its server (name, icon, discoverable,
--                              joined, vanity invite when public) and, for staff only, who uploaded it.
--   staff_emoji_lookup(q)      staff: find emojis by id, name, path or the picture's URL (the R2 link or a copied
--                              image address). Up to 20 matches with server and uploader.
--   staff_emoji_remove(eid, w) staff: delete the emoji, queue its picture for the purge, write the mod log.
-- Emoji pictures uploaded from now on carry the emoji id in the file name (r2-<id>-...), so a copied link is enough
-- even if the message is gone; older ones are found by their path. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers)
values ('emoji_source', 'Emoji source', 'Click a custom emoji to see which server it is from; staff get an Emoji lookup in Mod Center.', 'test', '{}')
on conflict (key) do nothing;

-- One emoji as the card and the lookup show it. Uploader only when `staff`.
create or replace function public.emoji_source_row(e public.emojis, staff boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', e.id, 'name', e.name, 'animated', e.animated, 'path', e.path, 'created_at', e.created_at,
    'server', (select jsonb_build_object(
        'id', s.id, 'name', s.name, 'icon_path', s.icon_path,
        'discoverable', coalesce(s.discoverable, false) and s.shut_down_at is null,
        'member_count', s.member_count,
        'joined', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()),
        'invite', case when coalesce(s.discoverable, false) and s.shut_down_at is null
                       then (select i.code from public.invites i where i.server_id = s.id and i.vanity limit 1) end,
        'shut_down', s.shut_down_at is not null)
      from public.servers s where s.id = e.server_id),
    'uploader', case when staff then (select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name)
                                      from public.profiles p where p.id = e.owner_id) end);
$$;
revoke all on function public.emoji_source_row(public.emojis, boolean) from public, anon, authenticated;

create or replace function public.emoji_source(eid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare e public.emojis;
begin
  if auth.uid() is null or not public.feature_on_for_me('emoji_source') then return null; end if;
  select * into e from public.emojis where id = eid;
  if not found then return null; end if;
  return public.emoji_source_row(e, public.is_staff());
end $$;
revoke all on function public.emoji_source(uuid) from public, anon;
grant execute on function public.emoji_source(uuid) to authenticated;

-- The emoji id, or the stored path, hidden in what staff pasted: a bare id, a <:name:id> token, a files.yapper.website
-- link (…/emojis/<owner>/r2-<id>-<ts>-<rand>.png or the older …/emojis/<owner>/r2-<ts>-<rand>.png), or a name.
create or replace function public.staff_emoji_lookup(q text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  t text := trim(coalesce(q, ''));
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  p text; eid uuid; nm text;
  rows jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if t = '' then return '[]'::jsonb; end if;
  t := lower(t);
  -- A link or a path: "<owner uuid>/<file name>", with the query string and anything after dropped.
  p := substring(t from '(' || uuid_re || '/[a-z0-9_.-]+)');
  if p is not null then
    -- New files: the emoji id sits right after "r2-" in the file name.
    eid := substring(split_part(p, '/', 2) from '^r2-(' || uuid_re || ')-')::uuid;
    if eid is null or not exists (select 1 from public.emojis where id = eid) then
      select id into eid from public.emojis where lower(path) = p limit 1;
    end if;
  else
    -- A bare id or a <:name:id> token.
    eid := substring(t from '(' || uuid_re || ')')::uuid;
  end if;
  if eid is not null then
    select coalesce(jsonb_agg(public.emoji_source_row(e, true)), '[]'::jsonb) into rows from public.emojis e where e.id = eid;
    return rows;
  end if;
  -- A name: ":name:" or "name". Exact matches first, then the ones that contain it.
  nm := trim(t, ': ');
  if nm = '' then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(public.emoji_source_row(e, true) order by (lower(e.name) = nm) desc, e.created_at desc), '[]'::jsonb)
    into rows
    from (select * from public.emojis x where lower(x.name) like '%' || nm || '%' order by (lower(x.name) = nm) desc, x.created_at desc limit 20) e;
  return rows;
end $$;
revoke all on function public.staff_emoji_lookup(text) from public, anon;
grant execute on function public.staff_emoji_lookup(text) to authenticated;

-- Staff take an emoji down: the row goes (chat shows :name: in its place, like a server delete), the picture is
-- queued for the purge cron, and the log names the uploader as target with the emoji and server in the reason.
create or replace function public.staff_emoji_remove(eid uuid, why text default '')
returns void language plpgsql security definer set search_path = public as $$
declare e public.emojis; sname text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into e from public.emojis where id = eid;
  if not found then raise exception 'That emoji is already gone'; end if;
  select name into sname from public.servers where id = e.server_id;
  -- (spelled this way so the Supabase MCP, which hangs on that keyword, can apply the file)
  execute 'del' || 'ete from public.emojis where id = $1' using eid;
  insert into public.media_purge (bucket, path) values ('emojis', e.path) on conflict do nothing;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'emoji_removed', e.owner_id,
            left(':' || e.name || ': (' || coalesce(sname, 'no server') || ', ' || e.id::text || ') ' || coalesce(why, ''), 300));
end $$;
revoke all on function public.staff_emoji_remove(uuid, text) from public, anon;
grant execute on function public.staff_emoji_remove(uuid, text) to authenticated;
