-- 642: Gift Plus to anyone (flag gift_anyone). Antic, HQ #to-do Oct 28: "u dont have to be friend to gift."
--
-- The friends-only rule only ever lived in the gift dialog's picker (components/GiftPlus.tsx): /api/stripe/checkout
-- and grant_plus_gift (136) never looked at friendships. So the picker gets a search over everyone, and the checks
-- that should have been there move into one place:
--  * gift_search(q): who can I gift? Friends by substring, anyone else by username prefix (3+ letters, or an exact
--    2-letter username), like search_people (141) but without the "online in a shared server" rule. Never: me, bots,
--    banned accounts, people I blocked or who blocked me. Same quota table as search_people (20/min, 200/h), so the
--    two searches together can't scrape usernames two letters at a time. Needs gift_plus and gift_anyone on for me.
--  * gift_plus_check(p_from, p_to): the abuse limits, for /api/stripe/checkout before it makes a Stripe session.
--    null = fine, else a reason: self, not_found, bot, banned, blocked (either direction), gifter_banned. Only the
--    service role calls it. Not in grant_plus_gift: by then the money is taken, refusing there would lose the gift.
--
-- Re-runnable. DDL (two functions): apply in quiet hours, one go. The flag row causes no reload.

set lock_timeout = '2s';

create or replace function public.gift_plus_check(p_from uuid, p_to uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_from is null or p_to is null then return 'not_found'; end if;
  if p_from = p_to then return 'self'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_to) then return 'not_found'; end if;
  if exists (select 1 from public.bots b where b.id = p_to)
     or exists (select 1 from public.bot_accounts ba where ba.user_id = p_to) then return 'bot'; end if;
  if public.is_site_banned(p_from) then return 'gifter_banned'; end if;
  if public.is_site_banned(p_to) then return 'banned'; end if;
  if exists (select 1 from public.blocks k where (k.blocker = p_from and k.blocked = p_to) or (k.blocker = p_to and k.blocked = p_from)) then
    return 'blocked';
  end if;
  return null;
end $$;
revoke all on function public.gift_plus_check(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gift_plus_check(uuid, uuid) to service_role;

create or replace function public.gift_search(q text)
returns table(id uuid, username text, display_name text, avatar_path text, friend boolean)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  qt public.people_search_quota;
  needle text := ltrim(lower(btrim(coalesce(q, ''))), '@');
  pat text;
  hi text;
  friends uuid[];
begin
  if me is null then return; end if;
  needle := left(needle, 32);
  if char_length(needle) < 2 then return; end if;
  if not (public.feature_on_for_me('gift_plus') and public.feature_on_for_me('gift_anyone')) then return; end if;
  if public.is_site_banned(me) then return; end if;
  -- Shared with search_people (141): one budget for both people searches.
  insert into public.people_search_quota as z (user_id, minute_n, hour_n) values (me, 1, 1)
  on conflict (user_id) do update set
    minute_start = case when z.minute_start < now() - interval '1 minute' then now() else z.minute_start end,
    minute_n = case when z.minute_start < now() - interval '1 minute' then 1 else z.minute_n + 1 end,
    hour_start = case when z.hour_start < now() - interval '1 hour' then now() else z.hour_start end,
    hour_n = case when z.hour_start < now() - interval '1 hour' then 1 else z.hour_n + 1 end
  returning * into qt;
  if qt.minute_n > 20 or qt.hour_n > 200 then
    raise exception 'Slow down a bit, try searching again in a minute' using errcode = 'P0001';
  end if;
  -- Range bounds as well as LIKE: a range on a parameter still uses the index in a generic (cached) plan.
  hi := needle || chr(1114111);
  pat := replace(replace(replace(needle, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select coalesce(array_agg(case when f.requester = me then f.addressee else f.requester end), '{}') into friends
    from public.friendships f where (f.requester = me or f.addressee = me) and f.status = 'accepted';

  return query
  with cand as (
    -- Friends: a small set, so a substring match on either name is fine.
    (select p.id from public.profiles p
      where p.id = any(friends)
        and (lower(p.username) like '%' || pat or lower(coalesce(p.display_name, '')) like '%' || pat)
      limit 20)
    union
    -- Everyone else: username prefix only (index range), 3+ letters or that exact username.
    (select p.id from public.profiles p
      where (char_length(needle) >= 3 or lower(p.username) = needle)
        and (lower(p.username) collate "C") >= needle and (lower(p.username) collate "C") < hi
        and lower(p.username) like pat
        and p.id <> me
      order by (lower(p.username) collate "C")
      limit 20)
  )
  select p.id, p.username, p.display_name, p.avatar_path, p.id = any(friends) as friend
  from cand c join public.profiles p on p.id = c.id
  where p.id <> me
    and not exists (select 1 from public.bots b where b.id = p.id)
    and not exists (select 1 from public.bot_accounts ba where ba.user_id = p.id)
    and not public.is_site_banned(p.id)
    and not exists (select 1 from public.blocks k where (k.blocker = me and k.blocked = p.id) or (k.blocker = p.id and k.blocked = me))
  order by (p.id = any(friends)) desc, (lower(p.username) collate "C")
  limit 20;
end $$;
revoke all on function public.gift_search(text) from public, anon;
grant execute on function public.gift_search(text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gift_anyone', 'Gift Plus to anyone', 'The Gift Plus picker searches everyone on Yapin'' by username, not just your friends. Blocked, banned and bot accounts stay out.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
