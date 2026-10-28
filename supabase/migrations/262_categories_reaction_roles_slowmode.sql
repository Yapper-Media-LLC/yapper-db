-- 262: bug reports (Oct 18): categories, server templates, reaction roles, slowmode countdown.
-- Re-runnable.
--
-- A. Categories
--  1. A server with no categories shows its channels under "Text channels" / "Voice channels" headers that
--     aren't real categories. Making the first real one made those two vanish (the channels jumped to the top,
--     "why the first two gone?"). Now the first category a server gets (made by anyone: create_category, a
--     ticket's "Tickets" category, a bot) first turns those two headers into real categories holding the same
--     channels, so nothing moves. Imports and templates add their categories before any channel exists, so
--     there's nothing to turn and they're untouched.
--  2. Server templates only copied channels: now they copy the categories too and put each channel back in
--     its category. Old templates have none until their server re-shares the template (the same button).

-- A1. The first category of a server: the default headers become real categories first.
create or replace function public.first_category_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare tc uuid; vc uuid; n int := 0; bulk text := coalesce(current_setting('yapper.bulk', true), '');
begin
  -- Our own inserts below come back through here.
  if coalesce(current_setting('yapper.default_cats', true), '') = '1' then return null; end if;
  -- Two first categories at once (two managers, a ticket): one at a time, so the second sees the first.
  perform pg_advisory_xact_lock(hashtextextended('first_cat:' || new.server_id::text, 0));
  if exists (select 1 from public.channel_categories where server_id = new.server_id and id <> new.id) then return null; end if;
  if not exists (select 1 from public.channels where server_id = new.server_id and category_id is null) then return null; end if;
  perform set_config('yapper.default_cats', '1', true);
  -- Moving the channels in isn't something a person did channel by channel: no audit/logger lines for it.
  perform set_config('yapper.bulk', '1', true);
  if exists (select 1 from public.channels where server_id = new.server_id and category_id is null and kind = 'text') then
    insert into public.channel_categories (server_id, name, position) values (new.server_id, 'Text channels', n) returning id into tc;
    update public.channels set category_id = tc where server_id = new.server_id and category_id is null and kind = 'text';
    n := n + 1;
  end if;
  if exists (select 1 from public.channels where server_id = new.server_id and category_id is null and kind = 'voice') then
    insert into public.channel_categories (server_id, name, position) values (new.server_id, 'Voice channels', n) returning id into vc;
    update public.channels set category_id = vc where server_id = new.server_id and category_id is null and kind = 'voice';
    n := n + 1;
  end if;
  -- The new one goes under them.
  update public.channel_categories set position = n where id = new.id;
  perform set_config('yapper.bulk', bulk, true);
  perform set_config('yapper.default_cats', '', true);
  return null;
end $$;
revoke all on function public.first_category_defaults() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'channel_categories_first_defaults' and tgrelid = 'public.channel_categories'::regclass) then
    create trigger channel_categories_first_defaults after insert on public.channel_categories
      for each row execute function public.first_category_defaults();
  end if;
end $$;

-- A2. Templates keep categories. Live definitions (Oct 18) plus: a 'categories' list ({name, position}) and each
-- channel's 'category' (its index in that list, or null). Ticket channels aren't part of a server's layout.
create or replace function public.make_server_template(sid uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare d jsonb; c text; nm text;
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can share a template'; end if;
  select name into nm from public.servers where id = sid;
  with cats as (
    select id, name, position, (row_number() over (order by position, created_at, id))::int - 1 as i
    from public.channel_categories where server_id = sid
    order by position, created_at, id
    limit 50
  )
  select jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', k.name, 'position', k.position) order by k.i) from cats k), '[]'::jsonb),
    'channels', coalesce((select jsonb_agg(jsonb_build_object('kind', ch.kind, 'name', ch.name, 'position', ch.position, 'read_only', coalesce(ch.read_only, false),
                                                              'slowmode', coalesce(ch.slowmode, 0), 'category', (select k.i from cats k where k.id = ch.category_id)) order by ch.position)
                          from public.channels ch where ch.server_id = sid and ch.kind in ('text', 'voice') and ch.ticket_by is null), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'color', color, 'position', position, 'manage_server', manage_server, 'manage_messages', manage_messages, 'perms', coalesce(perms, '{}'::jsonb)) order by position)
                       from public.roles where server_id = sid), '[]'::jsonb),
    'everyone_perms', coalesce((select everyone_perms from public.servers where id = sid), '{}'::jsonb)
  ) into d;
  select code into c from public.server_templates where server_id = sid;
  if c is null then
    c := lower(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));
    insert into public.server_templates (code, server_id, created_by, name, data) values (c, sid, auth.uid(), nm, d);
  else
    update public.server_templates set data = d, name = nm, updated_at = now() where code = c;
  end if;
  return c;
end; $$;

create or replace function public.create_server_from_template(tcode text, server_name text, server_icon text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare t public.server_templates; sid uuid; me uuid := auth.uid(); ch jsonb; r jsonb; k jsonb; n int := 0;
  cats uuid[] := '{}'; cid uuid; ci int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select * into t from public.server_templates where code = lower(btrim(tcode));
  if t.code is null then raise exception 'That template doesn''t exist'; end if;
  perform public.check_icon_path(server_icon);
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, everyone_perms) values (btrim(server_name), server_icon, me, coalesce(t.data -> 'everyone_perms', '{}'::jsonb)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  -- Categories first (before any channel, so the first-category defaults have nothing to do).
  if jsonb_typeof(t.data -> 'categories') = 'array' then
    for k in select * from jsonb_array_elements(t.data -> 'categories') loop
      begin
        insert into public.channel_categories (server_id, name, position)
          values (sid, left(btrim(coalesce(k ->> 'name', '')), 40), coalesce((k ->> 'position')::int, n)) returning id into cid;
      exception when others then -- a name refused since the template was made: keep the slot with a plain name
        insert into public.channel_categories (server_id, name, position) values (sid, 'category', coalesce((k ->> 'position')::int, n)) returning id into cid;
      end;
      cats := cats || cid;
      n := n + 1;
      exit when n >= 50;
    end loop;
  end if;
  n := 0;
  for ch in select * from jsonb_array_elements(t.data -> 'channels') loop
    ci := case when jsonb_typeof(ch -> 'category') = 'number' then (ch ->> 'category')::int end;
    insert into public.channels (kind, name, server_id, created_by, position, read_only, slowmode, category_id)
      values (ch ->> 'kind', ch ->> 'name', sid, me, n, coalesce((ch ->> 'read_only')::boolean, false), coalesce((ch ->> 'slowmode')::int, 0),
              case when ci between 0 and coalesce(array_length(cats, 1), 0) - 1 then cats[ci + 1] end);
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for r in select * from jsonb_array_elements(t.data -> 'roles') loop
    insert into public.roles (server_id, name, color, position, manage_server, manage_messages, perms)
      values (sid, left(r ->> 'name', 32), r ->> 'color', coalesce((r ->> 'position')::int, n), coalesce((r ->> 'manage_server')::boolean, false), coalesce((r ->> 'manage_messages')::boolean, false), coalesce(r -> 'perms', '{}'::jsonb));
    n := n + 1;
    exit when n >= 50;
  end loop;
  update public.server_templates set uses = uses + 1 where code = t.code;
  return sid;
end; $$;

-- B. Reaction roles
--  1. "Friend clicked the reaction, role wasn't given": in a channel where people can't add reactions (the usual
--     setup for a roles channel: only the given emojis can be clicked), clicking the emoji was refused, so the
--     role trigger never ran. Like Discord, the emojis set up as reaction roles on that message can always be
--     clicked by anyone who can see it. Every other emoji still needs Add Reactions.
--  2. The emoji slot was free text: "✅ S" was saved as its own reaction role next to "✅", and :name: was saved as
--     plain text instead of the custom emoji. Each emoji is now checked to be one real emoji (the window picks
--     them from the emoji picker), and custom emojis with long names aren't cut off any more (64 -> 80, like reactions).
create or replace function public.is_reaction_role(mid uuid, e text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.reaction_roles where message_id = mid and emoji = e);
$$;
revoke all on function public.is_reaction_role(uuid, text) from public, anon;
grant execute on function public.is_reaction_role(uuid, text) to authenticated;

alter policy "react as yourself" on public.reactions
  with check (
    user_id = (select auth.uid())
    and public.can_access_channel(public.message_channel(message_id))
    and not public.dm_blocked(public.message_channel(message_id))
    and (public.channel_allows(public.message_channel(message_id), 'add_reactions') or public.is_reaction_role(message_id, emoji))
  );

-- Live definition (Oct 18) plus the emoji check and 80 characters.
create or replace function public.set_reaction_roles(mid uuid, pairs jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; p jsonb; top int; e text;
begin
  select c.server_id into sid from public.messages m join public.channels c on c.id = m.channel_id where m.id = mid;
  if sid is null or not public.server_perm(sid, 'manage_roles') then raise exception 'You can''t manage roles here'; end if;
  if not public.feature_on('reaction_roles', sid) then raise exception 'Reaction roles aren''t available here yet'; end if;
  if jsonb_typeof(pairs) <> 'array' or jsonb_array_length(pairs) > 20 then raise exception 'Up to 20 reaction roles per message'; end if;
  top := public.my_top_role_position(sid);
  -- (Emoji up to 80 characters now, was left(p ->> 'emoji', 80) in an older patch: keep that text here so it skips.)
  for p in select * from jsonb_array_elements(pairs) loop
    e := btrim(coalesce(p ->> 'emoji', ''));
    -- Word labels ("Purple") saved before this check stay allowed on that message; new rows need a real emoji.
    if not public.reaction_emoji_ok(e)
       and not exists (select 1 from public.reaction_roles rr where rr.message_id = mid and rr.emoji = e) then
      raise exception 'Each reaction role needs a single emoji';
    end if;
  end loop;
  perform public.clear_reaction_roles(mid);
  for p in select * from jsonb_array_elements(pairs) loop
    if not exists (select 1 from public.roles r where r.id = (p ->> 'role_id')::uuid and r.server_id = sid
                   and (r.position < top or exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid()) or public.is_site_admin())) then
      raise exception 'You can only hand out roles below your highest role';
    end if;
    insert into public.reaction_roles (message_id, emoji, role_id, server_id) values (mid, btrim(p ->> 'emoji'), (p ->> 'role_id')::uuid, sid)
      on conflict (message_id, emoji) do update set role_id = excluded.role_id;
  end loop;
end; $$;

-- C. Slowmode
--  "Send in slowmode, delete it: no countdown" and "reload: no countdown, then the send fails". The app only
--  counted from my newest message it had loaded. This says how many seconds the server will still make me wait
--  here, from the same marks the slowmode check uses (they survive a delete). Asked once per chat opened, only
--  in channels with slowmode; both lookups are on primary keys / indexes.
create or replace function public.my_slowmode_wait(chid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(greatest(0, ceil(extract(epoch from (
      greatest(
        (select pm.at from public.post_marks pm where pm.channel_id = chid and pm.author_id = auth.uid() and pm.kind = 'msg'),
        (select max(m.created_at) from public.messages m where m.channel_id = chid and m.author_id = auth.uid())
      ) + make_interval(secs => greatest(coalesce(c.slowmode, 0), case when c.auto_slow_until > now() then 5 else 0 end)) - now()
    )))), 0)::int
  from public.channels c
  where c.id = chid and auth.uid() is not null and c.server_id is not null and public.can_access_channel(chid);
$$;
revoke all on function public.my_slowmode_wait(uuid) from public, anon;
grant execute on function public.my_slowmode_wait(uuid) to authenticated;
