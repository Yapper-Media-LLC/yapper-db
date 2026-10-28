-- 618: decoration sales, after an alt-to-main Shards transfer worry (Antic, Oct 27: "make it 70% of the sale u get,
-- and only allow ppl whos accounts are 5+ days or older to sell for shards, plus bypasses that").
-- * shard_config(): artist_share 80 -> 70, new seller_age_days 5. The Shards page reads both from here.
-- * set_deco_price(): putting a price on a decoration needs an account 5+ days old, or Yapin' Plus. Taking a price off
--   (back to free) always works.
-- * buy_community_deco(): the same rule at buy time, so decorations a new account priced earlier can't be bought until
--   the artist qualifies (the shared-device block from 462 stays).
-- Live text plus these lines. Re-runnable.

create or replace function public.shard_config()
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'daily', 5, 'per_block', 5, 'block_minutes', 5, 'activity_cap', 25, 'streak_days', 7, 'streak_bonus', 30,
    'min_age_days', 1, 'invite', 100, 'invite_age_days', 7, 'invite_active_days', 3, 'invite_cap_30d', 10,
    'artist_share', 70, 'seller_age_days', 5, 'price_min', 25, 'price_max', 5000, 'buyer_age_days', 7, 'level_step', 100, 'level_max', 100);
$$;

-- Who may sell for Shards: 5+ day old account, or Plus right now.
create or replace function public.deco_seller_ok(uid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return exists (select 1 from public.profiles p where p.id = uid
                 and (p.created_at <= now() - make_interval(days => (public.shard_config()->>'seller_age_days')::int)
                      or p.plus_until > now()));
end; $$;
revoke execute on function public.deco_seller_ok(uuid) from public, anon, authenticated;

create or replace function public.set_deco_price(p_id uuid, p_price integer)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); d public.community_decos;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned.'; end if;
  if p_price is not null and p_price <= 0 then p_price := null; end if;
  if p_price is not null and (p_price < 25 or p_price > 5000) then raise exception 'Pick a price from 25 to 5000 Shards'; end if;
  -- 618: selling needs a 5+ day old account, or Plus.
  if p_price is not null and not public.deco_seller_ok(me) then
    raise exception 'Your account needs to be % days old to sell for Shards (Plus members can sell right away)', public.shard_config()->>'seller_age_days';
  end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found or d.artist_id <> me then raise exception 'That''s not one of yours'; end if;
  if d.status not in ('pending', 'approved') then raise exception 'That one isn''t live'; end if;
  if d.price is null and p_price is not null then
    insert into public.deco_owned (user_id, deco_id, price_paid)
      select p.id, d.id, 0 from public.profiles p
      where p.avatar_deco like 'c:%' and p.avatar_deco = 'c:' || d.path and p.id <> me
      on conflict do nothing;
  end if;
  update public.community_decos set price = p_price where id = p_id;
end; $$;

create or replace function public.buy_community_deco(p_id uuid, p_price integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); d public.community_decos; cfg jsonb := public.shard_config(); share int;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('shards') then raise exception 'Not available yet'; end if;
  select * into d from public.community_decos where id = p_id for share;
  if not found or d.status <> 'approved' then raise exception 'That decoration isn''t available'; end if;
  if d.price is null then raise exception 'That one''s free'; end if;
  if d.price is distinct from p_price then raise exception 'The price changed to % Shards. Have another look.', d.price; end if;
  if d.artist_id = me then raise exception 'It''s yours already'; end if;
  if exists (select 1 from public.deco_owned where user_id = me and deco_id = p_id) then raise exception 'You have it already'; end if;
  if public.shard_is_bot(me) then raise exception 'Bots can''t buy decorations'; end if;
  if public.is_site_banned(d.artist_id) then raise exception 'That one isn''t for sale right now'; end if;
  -- 618: the artist has to be allowed to sell (5+ day old account, or Plus).
  if not public.deco_seller_ok(d.artist_id) then raise exception 'That one isn''t for sale yet'; end if;
  if not exists (select 1 from public.profiles where id = me
                 and created_at <= now() - make_interval(days => (cfg->>'buyer_age_days')::int)) then
    raise exception 'Your account needs to be a week old to buy decorations';
  end if;
  if public.shard_shared_device(me, d.artist_id) then raise exception 'You can''t buy from this artist'; end if;
  insert into public.shard_wallets (user_id) values (me), (d.artist_id) on conflict (user_id) do nothing;
  perform 1 from public.shard_wallets where user_id in (me, d.artist_id) order by user_id for update;
  perform public.shard_post(me, -d.price, 'deco_buy', p_id::text, d.name);
  share := (d.price * (cfg->>'artist_share')::int) / 100;
  begin
    perform public.shard_post(d.artist_id, share, 'deco_sale', p_id::text || ':' || me::text, d.name, me);
  exception when others then
    if sqlerrm <> 'Your Shards are frozen' then raise; end if;
  end;
  insert into public.deco_owned (user_id, deco_id, price_paid) values (me, p_id, d.price);
  return public.my_shards();
end; $$;
