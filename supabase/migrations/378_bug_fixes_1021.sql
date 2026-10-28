-- 378: bug fixes (21 Oct). One batch, so the API schema cache reloads once. Re-runnable. Every function below is built from
-- its LIVE text (Oct 21), not from the older migration files. Grants are the live ones, unchanged.
--
--  1. my_mentions: the @ badge (unread_counts_for) counts replies to my own messages, but the inbox had no reply branch, so
--     the badge said 1 and the inbox said "Nobody" (3500441c, c3382584, 0bcb917f). Replies now count, same rule as the badge:
--     someone else's message whose reply_to_id is one of my messages.
--     The reply branch is separate on purpose. The per-channel lookup above it only reads messages_pingy_idx (112k rows: the
--     messages that contain '<@' or '@everyone'). Adding "or reply_to_id is not null" to that prefilter makes the planner give
--     up that partial index and scan every message of the last 30 days in every channel (estimated cost 1784 -> 9711 for a
--     user in 500 servers). The reply branch starts from MY messages instead: the newest 500 of the last 30 days
--     (messages_author_created_idx), then messages_reply_to_idx. Measured on live data it adds about 2k buffer hits to a
--     call that reads 20k to 31k. Limit: replies to older messages, or beyond your newest 500 in 30 days, are not listed.
--  2. invite_card compared i.code = invite_code (case sensitive) while get_invite and join_server compare lower() both sides.
--     13,624 of 14,563 live invites have capitals, so a link typed in lower case showed no card (8ccedf54). Now lower() both
--     sides, the same form get_invite uses, which is what the unique index invites_code_lower_idx serves (no duplicates exist).
--  3. import_discord_server named channels with slugify_channel, which turns fancy or non-ASCII names into nothing (the
--     channel became "channel"). create_channel already uses fancy_channel_slug when the fancy_names flag is on for the
--     server. Same branch here (889ab635, 9c12ab06).
--  4. bad_name: a banned word glued to digits ("1111word1111") slipped past the word-boundary tests, because slur_text turns
--     the digits 0 1 3 4 5 7 8 into letters and the word is no longer a word. The word lists are untouched: the old body is
--     kept as bad_name_plain (renamed, so it is byte for byte the live one) and bad_name now also checks
--       a) the name with the digits that touch the start or end of a word removed (user123 -> user, 1111word1111 -> word),
--          through the full old check, skipped when fewer than 3 letters are left (a name like "cp3" stays fine), and
--       b) the name with all digits removed, through has_slur only.
--     Names without digits take the old path and nothing else. Word lists live in bad_name_plain and has_slur_plain now.
--     (dd78dba3)
--  5. reorder_roles: roles at or above your own top role were skipped without a word, so the list sprang back with no
--     message (dd215612, 4ca67a43). Now it says so when the new order would move a role at or above your top role, or put one
--     below it. The owner is unchanged. The whole list can still be sent as it is (that is what the page does): roles above
--     you just have to stay where they are.

-- 1 ---------------------------------------------------------------------------------------------------------------
create or replace function public.my_mentions(lim integer default 40)
 returns setof messages
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid, cm.joined_at as since
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid()) and not public.is_site_banned((select auth.uid()))
    union all
    select v.id, v.server_id, sm.joined_at
    from public.my_visible_server_channels() v
    join public.server_members sm on sm.server_id = v.server_id and sm.user_id = (select auth.uid())
    where not exists (select 1 from public.servers sd where sd.id = v.server_id and sd.shut_down_at is not null and not public.is_staff())
  ),
  ment as (
    select m.*
    from chans
    left join pings p on p.sid = chans.sid
    cross join lateral (
      select x.* from public.messages x
      where x.channel_id = chans.channel_id
        and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
        and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
        and x.author_id <> (select auth.uid())
        and (x.content like '%<@' || (select auth.uid())::text || '>%'
             or x.content ~ '(^|[^\w])@everyone([^\w]|$)'
             or (p.pats is not null and strpos(x.content, '<@&') > 0 and x.content like any (p.pats)))
      order by x.created_at desc
      limit least(greatest(coalesce(lim, 40), 1), 100)
    ) m
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ),
  mine as materialized (
    select array(
      select pm.id from public.messages pm
      where pm.author_id = (select auth.uid()) and pm.created_at > now() - interval '30 days'
      order by pm.created_at desc
      limit 500
    ) as ids
  ),
  rep as (
    select x.*
    from public.messages x
    join chans on chans.channel_id = x.channel_id
    where x.reply_to_id = any ((select ids from mine)::uuid[])
      and x.author_id <> (select auth.uid())
      and x.created_at > greatest(now() - interval '30 days', coalesce(chans.since, now() - interval '30 days'))
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  )
  select m.*
  from (
    select * from ment
    union all
    select * from rep r where not exists (select 1 from ment a where a.id = r.id)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$function$;
revoke all on function public.my_mentions(integer) from public, anon;
grant execute on function public.my_mentions(integer) to authenticated, service_role;

-- 2 ---------------------------------------------------------------------------------------------------------------
create or replace function public.invite_card(invite_code text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'server_id', s.id, 'name', s.name, 'icon_path', s.icon_path,
    'banner_path', s.banner_path, 'banner_x', s.banner_x, 'banner_y', s.banner_y, 'banner_zoom', s.banner_zoom,
    'created_at', s.created_at,
    'member_count', (select count(*) from public.server_members m where m.server_id = s.id),
    'online_count', (select count(*) from public.server_members m join public.presence p on p.user_id = m.user_id
                     where m.server_id = s.id and p.last_seen > now() - interval '100 seconds'),
    'already_member', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.invites i join public.servers s on s.id = i.server_id
  where lower(i.code) = lower(invite_code);
$function$;
revoke all on function public.invite_card(text) from public;
grant execute on function public.invite_card(text) to anon, authenticated, service_role;

-- 3 ---------------------------------------------------------------------------------------------------------------
create or replace function public.import_discord_server(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me uuid := auth.uid(); sid uuid; c jsonb; r jsonb; e jsonb; n int := 0; cats jsonb := '{}'::jsonb; cid uuid; pos int := 0; fancy boolean;
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
  n := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'channels', '[]'::jsonb)) loop
    begin
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
                case when c->>'kind' = 'voice' then left(c->>'name', 100)
                     else coalesce(case when fancy then public.fancy_channel_slug(c->>'name') else public.slugify_channel(c->>'name') end, 'channel') end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    exception when check_violation or raise_exception then -- refused name: fallback name
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end, case when c->>'kind' = 'voice' then 'Voice' else 'channel' end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    end;
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for r in select * from jsonb_array_elements(coalesce(p->'roles', '[]'::jsonb)) loop
    insert into public.roles (server_id, name, color, position, perms)
      values (sid, left(r->>'name', 32), nullif(r->>'color', ''), coalesce((r->>'position')::int, n), coalesce(r->'perms', '{}'::jsonb));
    n := n + 1;
    exit when n >= 50;
  end loop;
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

-- 4 ---------------------------------------------------------------------------------------------------------------
-- First run: the live bad_name (word lists and all) becomes bad_name_plain, untouched. Later runs skip this.
do $$
begin
  if to_regprocedure('public.bad_name_plain(text)') is null then
    alter function public.bad_name(text) rename to bad_name_plain;
  end if;
end $$;
revoke all on function public.bad_name_plain(text) from public, anon;
grant execute on function public.bad_name_plain(text) to authenticated, service_role;

create or replace function public.bad_name(t text)
 returns boolean
 language sql
 immutable
 set search_path to 'public', 'extensions'
as $function$
  select public.bad_name_plain(t)
    or coalesce((
      select case
          -- digits touching the start or end of a word taken off (a letter right before or after keeps them)
          when v.v1 <> f.s and char_length(regexp_replace(v.v1, '[^[:alpha:]]', '', 'g')) >= 3 and public.bad_name_plain(v.v1) then true
          -- every digit taken off, slur list only
          when v.v2 <> v.v1 and public.has_slur(v.v2) then true
          else false end
      from (select public.fold_fancy(t) as s) f
      cross join lateral (
        select regexp_replace(regexp_replace(f.s, '(?<![[:alpha:]])[0-9]+', '', 'g'), '[0-9]+(?![[:alpha:]])', '', 'g') as v1,
               regexp_replace(f.s, '[0-9]+', '', 'g') as v2
      ) v
      where f.s ~ '[0-9]'
    ), false);
$function$;
revoke all on function public.bad_name(text) from public, anon;
grant execute on function public.bad_name(text) to authenticated, service_role;

-- 5 ---------------------------------------------------------------------------------------------------------------
create or replace function public.reorder_roles(sid uuid, ids uuid[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int; i int; tp int; want uuid[]; below uuid[]; slots int[]; f int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  n := coalesce(array_length(ids, 1), 0);
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    for i in 1 .. n loop
      update public.roles set position = n - i where id = ids[i] and server_id = sid;
    end loop;
    return;
  end if;
  if not (public.server_perm(sid, 'manage_roles') or public.server_perm(sid, 'administrator')) then
    raise exception 'You need Manage Roles to rearrange roles';
  end if;
  select coalesce(max(r.position), -1) into tp from public.roles r join public.member_roles mr on mr.role_id = r.id
    where r.server_id = sid and mr.server_id = sid and mr.user_id = auth.uid();
  -- The roles asked about: this server's only, each once, in the order given (first mention wins).
  select array_agg(x.id order by x.ord) into want from (
    select r.id, min(u.ord) ord from unnest(ids) with ordinality u(id, ord) join public.roles r on r.id = u.id
    where r.server_id = sid group by r.id) x;
  select array_agg(w.id order by w.ord) into below from unnest(want) with ordinality w(id, ord)
    join public.roles r on r.id = w.id where r.position < tp;
  select count(*) into f from public.roles r where r.id = any(want) and r.position >= tp;
  -- Roles at or above your highest role must stay put, at the top of the list in their own order (equal positions can
  -- come in any order). Anything else would be skipped below, so say so instead of ignoring it quietly.
  if f > 0 and exists (
    select 1 from (
      select r.position, lag(r.position) over (order by w.ord) as prev
      from unnest(want[1:f]) with ordinality w(id, ord) join public.roles r on r.id = w.id) z
    where z.position < tp or z.position > z.prev
  ) then
    raise exception 'You can only move roles below your own top role';
  end if;
  -- Only the roles below your highest role, among the places they already hold.
  select array_agg(r.position order by r.position desc) into slots from public.roles r where r.id = any(below);
  if below is null then raise exception 'You can only move roles below your own top role'; end if;
  for i in 1 .. array_length(below, 1) loop
    update public.roles set position = slots[i] where id = below[i];
  end loop;
end;
$function$;
revoke all on function public.reorder_roles(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_roles(uuid, uuid[]) to authenticated, service_role;
