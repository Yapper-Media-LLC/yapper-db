-- 216: Yapper HQ blocks keyboard-mash style spam (Oct 18, Antic): one 50+ character "word" (keyboard mash,
-- 100 emojis in a row), letters spaced out one by one (also used to sneak links past the filters:
-- "h t t p s : / / ..."), and long messages made of 4 or fewer different characters ("BELELELE...",
-- "NOOOOOOO..." over 40 characters). Links, custom emojis, mentions and code are ignored when measuring.
-- Checked against the last 24 h of HQ messages: 114 of 64,257 (0.18%) would have been blocked, nearly all spam.
-- Applies to new messages and edits. Staff and bots are not affected. Other servers are unchanged. Patched into the live message_automod in place.
-- Re-runnable.

create or replace function public.spam_shape(t text)
returns text
language plpgsql
immutable
set search_path to 'public'
as $function$
declare s text; nospace text; tok text;
begin
  if t is null or char_length(t) < 26 then return null; end if;
  -- Code blocks first, on their own (a lazy quantifier inside a top-level alternation is greedy in Postgres).
  s := regexp_replace(t, '```.*?```', ' ', 'g');
  s := regexp_replace(s, 'https?://\S+|<a?:\w+:[0-9a-f-]+>|<@&?[0-9a-f-]+>|<#[0-9a-f-]+>|`[^`]*`', ' ', 'g');
  foreach tok in array regexp_split_to_array(s, '\s+') loop
    if char_length(tok) >= 50 then return 'mash'; end if;
  end loop;
  if s ~ '(^|\s)(\S\s){12,}\S(\s|$)' then return 'spaced'; end if;
  nospace := regexp_replace(s, '\s', '', 'g');
  if char_length(nospace) between 40 and 600 and (select count(distinct c) from regexp_split_to_table(lower(nospace), '') c) <= 4 then
    return 'repeat';
  end if;
  return null;
end $function$;
revoke all on function public.spam_shape(text) from public, anon;
grant execute on function public.spam_shape(text) to authenticated, service_role;

do $do$
declare
  d text := pg_get_functiondef('public.message_automod()'::regprocedure);
  a text := $a$  if tg_op = 'INSERT' then
    if length(new.content) > 3 then$a$;
  b text := $b$  -- Yapper HQ: keyboard mash / spaced-out letters / one character over and over (216), new messages and edits.
  -- Cheapest test first: only HQ messages ever run spam_shape. Staff skip it.
  if length(new.content) >= 26
     and (select c.server_id from public.channels c where c.id = new.channel_id) = (select default_server_id from public.app_settings limit 1)
     and public.spam_shape(new.content) is not null
     and not public.is_staff() then
    raise exception 'That looks like spam. Type it like a normal message.' using errcode = 'check_violation';
  end if;
  if tg_op = 'INSERT' then
    if length(new.content) > 3 then$b$;
begin
  if strpos(d, 'spam_shape(') > 0 then return; end if;
  if strpos(d, a) = 0 then raise exception '216: message_automod() changed on the live database, anchor not found'; end if;
  execute replace(d, a, b);
end $do$;
