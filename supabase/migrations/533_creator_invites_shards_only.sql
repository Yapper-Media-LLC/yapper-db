-- 533: Creator invites pay 10 Shards per real person and nothing else (Antic, Oct 26: "remove the 1 month of Plus
-- per 25 people invited, and 10 shards per person joined"). creator_referral_check loses the Plus step; the step
-- function stays for creator_referrals_settle's reply shape. Re-runnable.
set lock_timeout = '4s';
create or replace function public.creator_invite_shards() returns int language sql immutable as $$ select 10 $$;

create or replace function public.creator_referral_check(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r public.creator_referrals; n int; days int; wait boolean := false;
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
  -- 10 Shards per counted invite, once per invited account (shard_post pays 'invite' once per ref). A frozen or banned
  -- creator wallet refuses the post; the count still lands.
  begin
    perform public.shard_post(r.referrer, public.creator_invite_shards(), 'invite', 'creator:' || p_user, 'Creator Program: a real person joined through your link');
  exception when others then
    raise warning 'creator_referral_check: shards for % failed: %', r.referrer, sqlerrm;
  end;
  return 'counted';
end; $$;
revoke all on function public.creator_referral_check(uuid) from public, anon, authenticated;
reset lock_timeout;
