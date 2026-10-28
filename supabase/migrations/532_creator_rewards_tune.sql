-- 532: Creator Program rewards tuned (Antic, Oct 26): joining as Pro Creator gives 3 months of Plus, Elite 6, plain
-- Creator none; content pays 1 / 2 / 4 / 8 months at 5k / 25k / 100k / 500k long-form views (was 1 / 3 / 6 / 12).
-- Mirrored in lib/creators.ts (REWARD_LADDER, JOIN_MONTHS). Re-runnable: both functions are replaced in place.
set lock_timeout = '4s';

create or replace function public.creator_reward_months(fmt text, v int)
returns int language sql immutable as $$
  select case
    when public.creator_views_equiv(fmt, v) >= 500000 then 8
    when public.creator_views_equiv(fmt, v) >= 100000 then 4
    when public.creator_views_equiv(fmt, v) >= 25000 then 2
    when public.creator_views_equiv(fmt, v) >= 5000 then 1
    else 0 end
$$;

create or replace function public.review_creator(rid uuid, approve boolean, p_tier int default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.creator_applications; badge text; months int; until_at timestamptz;
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  select * into r from public.creator_applications where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if r.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if approve then
    if p_tier is null or p_tier not between 1 and 3 then raise exception 'Pick a tier'; end if;
    if public.is_site_banned(r.user_id) then raise exception 'That account is banned'; end if;
    -- Plus for joining by tier (Antic, Oct 26): Creator 0, Pro 3, Elite 6 months.
    months := case p_tier when 2 then 3 when 3 then 6 else 0 end;
    badge := 'creator_' || p_tier;
    update public.profiles set
      badges = array(select distinct unnest(
        array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers) and b <> badge)) || badge)),
      shown_badge = case when shown_badge = any(tiers) then badge else shown_badge end,
      plus_until = case when months > 0 then greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * months) else plus_until end
      where id = r.user_id
      returning plus_until into until_at;
    update public.creator_applications set status = 'approved', tier = p_tier, plus_months = months,
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = rid;
    perform public.creator_link_code(r.user_id);
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'creator_approved', r.user_id, 'Tier ' || p_tier || case when months > 0 then ', ' || months || ' months Plus' else '' end || case when p_note <> '' then ': ' || p_note else '' end),
      ((select auth.uid()), 'badge_given', r.user_id, badge);
    if months > 0 then
      insert into public.mod_log (actor, action, target_id, reason) values
        ((select auth.uid()), 'plus_gift', r.user_id, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program tier ' || p_tier);
    end if;
    begin
      perform public.rt_profile_changed(array[r.user_id]);
    exception when others then
      raise warning 'review_creator: profile cache ping for % failed: %', r.user_id, sqlerrm;
    end;
  else
    if length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
    update public.creator_applications set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = rid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'creator_rejected', r.user_id, p_note);
  end if;
end; $$;

reset lock_timeout;

-- Shards for real invites (Antic, Oct 26: "shards for real people that join, a reasonable amount"): 50 Shards to the
-- creator each time a referral is counted (518's checks decide "real": 7 days old, 3 active days, confirmed email, not a
-- bot, not the creator's own device). Half the friend-invite reward, no Plus boost, once per invited account (kind
-- 'invite', ref 'creator:<user>'). A frozen or banned creator's wallet refuses the post; the count still goes through.
set lock_timeout = '4s';
create or replace function public.creator_invite_shards() returns int language sql immutable as $$ select 50 $$;

create or replace function public.creator_referral_check(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r public.creator_referrals; n int; until_at timestamptz; days int; wait boolean := false;
begin
  select * into r from public.creator_referrals where user_id = p_user and status = 'pending' for update;
  if r.user_id is null then return null; end if;
  if public.shard_is_bot(r.user_id) then
    update public.creator_referrals set status = 'refused', reason = 'bot' where user_id = p_user; return 'refused';
  end if;
  if public.shard_shared_device(r.referrer, p_user) then
    update public.creator_referrals set status = 'refused', reason = 'same device or network' where user_id = p_user; return 'refused';
  end if;
  if exists (select 1 from public.profiles where id = p_user and (verify_required or created_at > now() - interval '7 days'))
     or public.is_site_banned(p_user)
     or exists (select 1 from public.shard_wallets where user_id = p_user and frozen)
     or not exists (select 1 from auth.users where id = p_user and email_confirmed_at is not null) then
    wait := true;
  end if;
  if not wait then
    select count(*) into days from public.shard_days where user_id = p_user and minutes >= 5;
    wait := days < 3;
  end if;
  if not wait and (public.is_site_banned(r.referrer)
      or not exists (select 1 from public.profiles where id = r.referrer and badges && array['creator_1', 'creator_2', 'creator_3'])) then
    wait := true;
  end if;
  if wait then
    if r.created_at < now() - interval '60 days' then
      update public.creator_referrals set status = 'refused', reason = 'never counted' where user_id = p_user; return 'refused';
    end if;
    update public.creator_referrals set checked_at = now() where user_id = p_user;
    return 'waiting';
  end if;
  perform public.creator_link_code(r.referrer);
  update public.creator_links set counted = counted + 1 where user_id = r.referrer returning counted into n;
  if n is null then return 'waiting'; end if;
  update public.creator_referrals set status = 'counted', confirmed_at = now(), seq = n, checked_at = now() where user_id = p_user;
  begin
    perform public.shard_post(r.referrer, public.creator_invite_shards(), 'invite', 'creator:' || p_user, 'Creator Program: a real person joined through your link');
  exception when others then
    raise warning 'creator_referral_check: shards for % failed: %', r.referrer, sqlerrm;
  end;
  if n % public.creator_referral_step() = 0 then
    update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + interval '31 days'
      where id = r.referrer returning plus_until into until_at;
    insert into public.mod_log (actor, action, target_id, reason) values
      (null, 'plus_gift', r.referrer, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program, ' || n || ' sign-ups through their link');
    begin
      perform public.rt_profile_changed(array[r.referrer]);
    exception when others then
      raise warning 'creator_referral_check: profile cache ping for % failed: %', r.referrer, sqlerrm;
    end;
  end if;
  return 'counted';
end; $$;
revoke all on function public.creator_referral_check(uuid) from public, anon, authenticated;
reset lock_timeout;
