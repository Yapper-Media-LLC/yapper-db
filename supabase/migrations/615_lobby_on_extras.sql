-- Lobby v2, part 2 (flag lobby_v2):
-- 1. Lobbies are off by default. servers.lobby_on: members only see the lobby (and land on it) once a manager switches
--    it on with set_server_lobby_on. Managers always see it so they can set it up first.
-- 2. lobby_extras(sid): what the lobby shows from features the server already uses, in one call when the lobby opens
--    (never at startup): the Levels bot's top 10 (current members, not site-banned, like !top) and live giveaways in
--    channels the caller can open.
-- 3. set_server_lobby_v2 accepts the two new sections (leaderboard, giveaways).

set lock_timeout = '3s';

alter table public.servers add column if not exists lobby_on boolean not null default false;

create or replace function public.set_server_lobby_on(sid uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can change the lobby' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('lobby_v2', sid) then
    raise exception 'Lobby customizing isn''t on in this server yet' using errcode = 'check_violation';
  end if;
  update public.servers set lobby_on = coalesce(p_on, false) where id = sid and lobby_on is distinct from coalesce(p_on, false);
  if found then
    perform public.audit_add(sid, 'server_update_lobby', 'server', sid, (select s.name from public.servers s where s.id = sid),
      jsonb_build_object('lobby_on', coalesce(p_on, false)));
  end if;
end $$;

revoke all on function public.set_server_lobby_on(uuid, boolean) from public, anon;
grant execute on function public.set_server_lobby_on(uuid, boolean) to authenticated;

create or replace function public.lobby_extras(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  board jsonb := '[]'::jsonb;
  gws jsonb := '[]'::jsonb;
begin
  -- Nothing for banned accounts or shut-down servers (as everywhere since 298); giveaways get the same from can_access_channel.
  if auth.uid() is null or public.is_site_banned(auth.uid()) or not public.is_server_member(sid)
     or exists (select 1 from public.servers s where s.id = sid and s.shut_down_at is not null and not public.is_staff())
     or not public.feature_on('lobby_v2', sid) then
    return null;
  end if;

  if exists (select 1 from public.server_bots b where b.server_id = sid and b.bot = 'levels' and b.enabled) then
    select coalesce(jsonb_agg(jsonb_build_object('user_id', t.user_id, 'xp', t.xp, 'level', t.level) order by t.xp desc), '[]'::jsonb)
      into board
      from (
        select x.user_id, x.xp, x.level from public.server_xp x
        where x.server_id = sid
          and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = x.user_id)
          and not exists (select 1 from public.site_bans b where b.user_id = x.user_id and (b.expires_at is null or b.expires_at > now()))
        order by x.xp desc
        limit 10
      ) t;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'prize', g.prize, 'winners', g.winners, 'ends_at', g.ends_at,
      'channel_id', g.channel_id, 'message_id', g.message_id) order by g.ends_at), '[]'::jsonb)
    into gws
    from (
      select * from public.giveaways g
      where g.ended_at is null and g.ends_at > now() and g.server_id = sid and public.can_access_channel(g.channel_id)
      order by g.ends_at
      limit 3
    ) g;

  return jsonb_build_object('leaderboard', board, 'giveaways', gws);
end $$;

revoke all on function public.lobby_extras(uuid) from public, anon;
grant execute on function public.lobby_extras(uuid) to authenticated;

create or replace function public.set_server_lobby_v2(sid uuid, p_about text, p_faq jsonb, p_featured uuid[], p_show_staff boolean,
  p_style jsonb, p_sections jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  st jsonb := coalesce(p_style, '{}'::jsonb);
  out_style jsonb := '{}'::jsonb;
  out_sections jsonb := '[]'::jsonb;
  seen text[] := '{}';
  k text;
  v text;
  item jsonb;
  label text;
  url text;
  ch uuid;
  btns jsonb := '[]'::jsonb;
  problem text;
begin
  if auth.uid() is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can change the lobby' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('lobby_v2', sid) then
    raise exception 'Lobby customizing isn''t on in this server yet' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(st) <> 'object' then
    raise exception 'The lobby look has to be an object' using errcode = 'check_violation';
  end if;
  if p_sections is not null and (jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) > 20) then
    raise exception 'That''s too many lobby sections' using errcode = 'check_violation';
  end if;
  if st ? 'buttons' and (jsonb_typeof(st -> 'buttons') <> 'array' or jsonb_array_length(st -> 'buttons') > 4) then
    raise exception 'Up to 4 lobby buttons' using errcode = 'check_violation';
  end if;

  -- Choices: each key takes one of a few values; anything else is refused so the client can't store junk.
  for k, v in select key, value #>> '{}' from jsonb_each(st) where key in ('preset', 'bg', 'cards', 'font', 'hero', 'align') loop
    if v is null or not v = any (case k
        when 'preset' then array['classic', 'spotlight', 'magazine', 'compact']
        when 'bg' then array['plain', 'glow', 'banner', 'mesh']
        when 'cards' then array['filled', 'outline', 'glass']
        when 'font' then array['default', 'rounded', 'serif', 'mono', 'display']
        when 'hero' then array['tall', 'normal', 'short']
        when 'align' then array['left', 'center'] end) then
      raise exception 'Unknown lobby % "%"', k, coalesce(v, '') using errcode = 'check_violation';
    end if;
    out_style := out_style || jsonb_build_object(k, v);
  end loop;

  if st ? 'accent' and jsonb_typeof(st -> 'accent') <> 'null' then
    v := st ->> 'accent';
    if v is null or v !~ '^#[0-9a-fA-F]{6}$' then
      raise exception 'The accent has to be a colour like #ff8800' using errcode = 'check_violation';
    end if;
    out_style := out_style || jsonb_build_object('accent', lower(v));
  end if;

  v := btrim(coalesce(st ->> 'tagline', ''));
  if char_length(v) > 120 then
    raise exception 'The tagline can be up to 120 characters' using errcode = 'check_violation';
  end if;
  problem := public.lobby_text_problem(v);
  if problem is not null then
    raise exception '%', problem using errcode = 'check_violation';
  end if;
  if v <> '' then out_style := out_style || jsonb_build_object('tagline', v); end if;

  for item in select value from jsonb_array_elements(coalesce(st -> 'buttons', '[]'::jsonb)) loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'Each lobby button needs a label and a link or channel' using errcode = 'check_violation';
    end if;
    label := btrim(coalesce(item ->> 'label', ''));
    url := nullif(btrim(coalesce(item ->> 'url', '')), '');
    continue when label = '' and url is null and coalesce(item ->> 'channel', '') = '';
    if label = '' or char_length(label) > 24 then
      raise exception 'Button labels can be 1 to 24 characters' using errcode = 'check_violation';
    end if;
    problem := public.lobby_text_problem(label);
    if problem is not null then
      raise exception '%', problem using errcode = 'check_violation';
    end if;
    if url is not null then
      if char_length(url) > 500 or url !~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]{1,5})?([/?#]\S*)?$' then
        raise exception 'Button links have to be https:// addresses' using errcode = 'check_violation';
      end if;
      if public.has_adult_link(url) then
        raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
      end if;
      btns := btns || jsonb_build_array(jsonb_build_object('label', label, 'url', url));
    else
      begin
        ch := (item ->> 'channel')::uuid;
      exception when others then
        ch := null;
      end;
      if ch is null or not exists (select 1 from public.channels c where c.id = ch and c.server_id = sid and c.ticket_by is null) then
        raise exception 'Button channels have to be channels in this server' using errcode = 'check_violation';
      end if;
      btns := btns || jsonb_build_array(jsonb_build_object('label', label, 'channel', ch));
    end if;
  end loop;
  if jsonb_array_length(btns) > 0 then out_style := out_style || jsonb_build_object('buttons', btns); end if;

  -- Sections: known blocks only, each once, in the order given.
  for item in select value from jsonb_array_elements(coalesce(p_sections, '[]'::jsonb)) loop
    k := item ->> 'id';
    if jsonb_typeof(item) <> 'object' or k is null
       or not k = any (array['about', 'channels', 'live', 'faq', 'roles', 'rules', 'staff', 'links', 'leaderboard', 'giveaways']) then
      raise exception 'Unknown lobby section' using errcode = 'check_violation';
    end if;
    continue when k = any(seen);
    seen := seen || k;
    out_sections := out_sections || jsonb_build_array(jsonb_build_object('id', k, 'on', coalesce(case when jsonb_typeof(item -> 'on') = 'boolean' then (item -> 'on')::boolean end, true)));
  end loop;

  -- The content, with all of set_server_lobby's checks (and its audit entry).
  perform public.set_server_lobby(sid, p_about, p_faq, p_featured, p_show_staff);

  update public.server_lobby set style = out_style, sections = out_sections where server_id = sid;
end $$;
