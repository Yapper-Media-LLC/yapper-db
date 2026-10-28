-- 428: chat bug reports, Oct 23. Three live message triggers patched in place (none of them is in the repo in its
-- current form), each with a "changed, patch by hand" guard like 421. Re-runnable: a function already patched is
-- skipped. Function bodies only (no tables, no grants beyond the new helper), safe to apply any time; the app needs
-- no new build for any of it.
--
-- 1. message_raid_guard: @everyone needed Manage Messages. A role with Mention @everyone (and no Manage Messages)
--    saw the ping for a moment, then the saved message came back as a plain "@everyone" with a zero-width space.
--    Now Mention @everyone is enough there too; message_perm_guard still applies the channel overrides for it.
-- 2. not_site_banned: a limited account ("can't send links") couldn't share a Copy message link either. Links to
--    a message on Yapin' itself (/?server=&channel=&msg=, ids only) don't count as links for that rule now.
-- 3. invites_only_in_promo: since the yapin.gg rename, invite links are yapin.gg/invite/..., and this trigger only
--    knew yapper.website, so in Yapin' HQ new invite links skipped every promo rule (only in #promote-your-server,
--    a server you're in, once per 6 hours). It now reads both addresses. (411 fixed the HQ allowlist half.)

-- Links to a message here, removed from a text (for "is there a link in this?" checks). Only a whole link: one
-- with more glued on after the message id ("&next=//...") stays.
create or replace function public.strip_message_links(body text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(coalesce(body, ''),
    'https?://(?:www\.)?(?:yapin\.gg|yapper\.website)/\?(?:server=[0-9a-f-]{36}&)?channel=[0-9a-f-]{36}&msg=[0-9a-f-]{36}(?=$|[[:space:]<>()]|\[|\])',
    '', 'gi');
$$;
revoke all on function public.strip_message_links(text) from public, anon;
grant execute on function public.strip_message_links(text) to authenticated;

do $$
declare
  f text;
  fixes text[][] := array[
    -- function, old text, new text, marker that it's already patched
    array['message_raid_guard',
      'and ((c.server_id is not null and public.server_perm(c.server_id, ''manage_messages''))',
      'and ((c.server_id is not null and (public.server_perm(c.server_id, ''manage_messages'') or public.server_perm(c.server_id, ''mention_everyone'')))',
      'public.server_perm(c.server_id, ''mention_everyone'')'],
    array['not_site_banned',
      'if coalesce(new.content, '''') ~* ',
      'if public.strip_message_links(new.content) ~* ',
      'public.strip_message_links(new.content)'],
    array['invites_only_in_promo',
      'yapper\.website/invite/',
      '(?:yapper\.website|yapin\.gg)/invite/',
      '|yapin\.gg)/invite/']
  ];
  i int;
begin
  for i in 1 .. array_length(fixes, 1) loop
    -- Every overload; none on databases without it.
    for f in select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = fixes[i][1] loop
      if position(fixes[i][4] in f) > 0 then continue; end if; -- already patched
      if position(fixes[i][2] in f) = 0 then raise exception '428: % changed, patch it by hand', fixes[i][1]; end if;
      execute replace(f, fixes[i][2], fixes[i][3]);
    end loop;
  end loop;
end $$;
