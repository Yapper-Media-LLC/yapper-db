-- Inbox: the last messages that mention me (last 30 days), newest first. Flag: mentions_inbox.
create or replace function public.my_mentions(lim int default 40)
returns setof public.messages language sql stable security definer set search_path = public as $$
  select m.* from public.messages m
  where m.created_at > now() - interval '30 days'
    and m.author_id <> auth.uid()
    and (m.content like '%<@' || auth.uid()::text || '>%' or m.content ~ '(^|[^\w])@everyone([^\w]|$)')
    and public.can_access_channel(m.channel_id)
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$$;
revoke all on function public.my_mentions(int) from public, anon;
grant execute on function public.my_mentions(int) to authenticated;
insert into public.feature_flags (key, label, description, mode) values ('mentions_inbox', 'Mentions inbox', 'An @ button by your profile that lists recent mentions and jumps to them', 'off') on conflict (key) do nothing;
