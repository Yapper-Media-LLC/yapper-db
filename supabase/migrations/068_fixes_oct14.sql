-- Bug fixes from the Oct 14 reports (applied live; kept here for the record).
-- 1. Slowmode error read "5ss" ('%s' in RAISE is '%' + 's'). See message_slowmode: '... in %s', wait.
-- 2. Deleted messages were broadcast with their full content; now only id/channel_id/author_id (broadcast_message_change).
-- 3. Vanity invite reserved words could be dodged with look-alikes (adm1n, YAPPERS): lookalike_key() + set_vanity_invite.
create or replace function public.lookalike_key(t text) returns text language sql immutable as $$
  select translate(lower(coalesce(t, '')), '013457$@!|l', 'oieastsailli');
$$;
