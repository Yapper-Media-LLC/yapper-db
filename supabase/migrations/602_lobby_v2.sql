-- Lobby v2 (flag lobby_v2, on top of server_lobby): owners customize how the lobby looks and what's on it.
-- style: layout preset, accent, background, cards, font, hero size, alignment, a tagline and up to 4 buttons.
-- sections: the lobby's blocks in the order shown, each on or off. Both saved with the content in one call,
-- set_server_lobby_v2, which runs set_server_lobby for the content (same checks, same audit entry) and then cleans
-- the look: only known keys and values survive, text goes through the lobby text checks, buttons link to https
-- pages or this server's own channels.

set local lock_timeout = '3s';

alter table public.server_lobby add column if not exists style jsonb not null default '{}'::jsonb;
alter table public.server_lobby add column if not exists sections jsonb not null default '[]'::jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'server_lobby_style_shape') then
    alter table public.server_lobby add constraint server_lobby_style_shape check (jsonb_typeof(style) = 'object');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'server_lobby_sections_shape') then
    alter table public.server_lobby add constraint server_lobby_sections_shape
      check (jsonb_typeof(sections) = 'array' and jsonb_array_length(sections) <= 20);
  end if;
end $$;

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('lobby_v2', 'Lobby v2',
   'Customizable lobbies: layouts, colours, fonts, backgrounds, buttons, sections to reorder or hide, templates and a live editor on the lobby itself. Needs server_lobby too. Test: Antic only',
   'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
  on conflict (key) do nothing;

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
       or not k = any (array['about', 'channels', 'live', 'faq', 'roles', 'rules', 'staff', 'links']) then
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

revoke all on function public.set_server_lobby_v2(uuid, text, jsonb, uuid[], boolean, jsonb, jsonb) from public, anon;
grant execute on function public.set_server_lobby_v2(uuid, text, jsonb, uuid[], boolean, jsonb, jsonb) to authenticated;
