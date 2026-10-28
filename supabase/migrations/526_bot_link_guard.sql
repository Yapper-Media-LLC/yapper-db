-- 526: blocked links in bot output (flag bot_link_guard, published to everyone Oct 25).
-- On Oct 25 a bot (AntiAlt) handed out "secure sign-in links" to an IP logger as ephemeral button replies. Those never
-- ran has_adult_link: bot_interaction_respond stores ephemeral replies in bot_interaction_replies with no check, and
-- messages_no_adult_links only reads messages.content, not embeds or components (link buttons, embed urls, titles,
-- descriptions, fields, footers, Components V2 text displays and media urls).
--  1. Flag bot_link_guard (published to everyone: Antic said publish, applied at peak as a fix).
--  2. link_strings(j): every string inside a json value, one per line, so link_targets can't join two values into one
--     site name and an escaped "\n" in front of a site name can't hide it (the json text would read "ngrabify.link").
--  3. no_adult_links_json(cols...): trigger on messages (embeds, components) and bot_interaction_replies (content,
--     embeds). Same block list and same error as message text. Only new or changed values are checked, and only when
--     the flag is on for the channel's server. Rows with no embeds or components skip it (WHEN clause), so plain messages
--     pay nothing. Clickable urls ("url" / "icon_url": link buttons, embed links, images, icons, V2 media) also run
--     link_url_problem (276), like profile links: short links, bare IPs and odd site names are refused there too, and
--     so are http(s):// links typed in the text. Bare "bit.ly/x" in text only gets the block list, same as chat text.
--  Covers bot sends, bot edits, interaction reply / update / ephemeral answers and webhooks (all write through these
--  two tables). A refused ephemeral answer rolls back with the whole call, so it doesn't use up one of the 10 answers.

-- Adding a trigger on messages blocks sends while it waits for its lock: give up after 1 s (re-run if it times out).
set lock_timeout = '1s';

-- 1. Flag.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_link_guard', 'Link check on bot embeds', 'Blocked sites (IP loggers, adult sites) are refused in bot and webhook embeds, buttons and ephemeral replies, not just message text', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{}')
on conflict (key) do update set mode = 'everyone', updated_at = now();

-- 2. All string values inside a json value (keys left out), newline-separated.
create or replace function public.link_strings(j jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when j is null then null
    when jsonb_typeof(j) = 'string' then j #>> '{}'
    when jsonb_typeof(j) in ('array', 'object') then
      (select string_agg(v #>> '{}', E'\n') from jsonb_path_query(j, 'strict $.**') v where jsonb_typeof(v) = 'string')
  end;
$$;
revoke all on function public.link_strings(jsonb) from public, anon;
grant execute on function public.link_strings(jsonb) to authenticated, service_role;

-- 3. The check. Shared by two tables: only reads the columns named in the trigger arguments, plus channel_id (both have it).
create or replace function public.no_adult_links_json()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
declare
  col text;
  val jsonb;
  txt text := '';
  vals jsonb := '[]'::jsonb;
  why text;
  sid uuid;
  n jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
begin
  foreach col in array tg_argv loop
    val := n -> col;
    continue when val is null or jsonb_typeof(val) = 'null';
    continue when tg_op = 'UPDATE' and val is not distinct from (o -> col);
    txt := txt || E'\n' || coalesce(public.link_strings(val), '');
    vals := vals || jsonb_build_array(val);
  end loop;
  if btrim(txt, E' \n') = '' then return new; end if;

  select c.server_id into sid from public.channels c where c.id = (n ->> 'channel_id')::uuid;
  if not public.feature_on('bot_link_guard', sid) then return new; end if;

  if public.has_adult_link(txt) then
    raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
  end if;
  -- What people click (button url, embed url / image / thumbnail / author and footer icons, V2 media): the stricter
  -- profile-link rules too, so a short link that redirects to a logger, a bare IP or a new logger name isn't a way round.
  -- Links typed in text (ephemeral content, descriptions, fields, V2 text) too: "Your sign-in link: https://bit.ly/x".
  -- Only scheme + site name is taken, so markdown around it (**, <>, (), a trailing comma) doesn't count as the name.
  select p into why from (
    select public.link_url_problem(u) p
      from jsonb_path_query(vals, 'strict $.**') x
      cross join lateral (values (x ->> 'url'), (x ->> 'icon_url')) f(u)
     where jsonb_typeof(x) = 'object' and u ~* '^https?://'
    union all
    select public.link_url_problem(m[1])
      from regexp_matches(txt, '(https?://[^\s/?#\\<>()\[\]"''`,*|~]+)', 'gi') m
  ) s where p is not null limit 1;
  if why is not null then
    raise exception '%', why using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create or replace trigger messages_no_adult_links_json before insert or update of embeds, components on public.messages
  for each row when (new.embeds is not null or new.components is not null)
  execute function public.no_adult_links_json('embeds', 'components');
create or replace trigger bot_interaction_replies_no_adult_links before insert or update of content, embeds on public.bot_interaction_replies
  for each row when (new.content is not null or new.embeds is not null)
  execute function public.no_adult_links_json('content', 'embeds');
reset lock_timeout;
