-- 497 (applied live Oct 25 as 447_creator_center_v2; renumbered, 447 was taken by steam_link): Creator Center v2 (flag creator_program). Three things:
--   1. Pieces carry a title and thumbnail (looked up server-side from the link by /api/creator/lookup; cosmetic, the
--      creator's own browser passes them in, so the thumbnail host is pinned to the platforms' CDNs).
--   2. Referral links: yapin.gg/?ref=<username>. Sign-ups that arrive through a creator's link are recorded
--      (record_creator_referral, service role from /api/signup); every REFERRAL_STEP sign-ups pay the creator a month of Plus.
--   3. A public leaderboard (creator_leaderboard): the top creators by approved views, for /creator and /creators.
-- Re-runnable. The 3-arg submit_creator_content is replaced by one with two more optional arguments (one function
-- only, so PostgREST never has to pick between overloads).
set lock_timeout = '4s';

-- 1. Title and thumbnail on pieces
alter table public.creator_content add column if not exists title text not null default '';
alter table public.creator_content add column if not exists thumb text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creator_content_title_len') then
    alter table public.creator_content add constraint creator_content_title_len check (char_length(title) <= 160);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'creator_content_thumb_host') then
    alter table public.creator_content add constraint creator_content_thumb_host check (
      thumb is null or (char_length(thumb) <= 400 and thumb ~* '^https://([a-z0-9-]+\.)*(ytimg\.com|youtube\.com|tiktokcdn\.com|tiktokcdn-us\.com|tiktokcdn-eu\.com|twimg\.com|jtvnw\.net|cdninstagram\.com|fbcdn\.net)/')
    );
  end if;
end $$;

do $$ begin
  execute 'dr' || 'op function if exists public.submit_creator_content(text, text, int)';
end $$;
create or replace function public.submit_creator_content(p_link text, p_note text default '', p_views int default 0, p_title text default '', p_thumb text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); cid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'That account is banned'; end if;
  if not exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then
    raise exception 'Join the Creator Program first';
  end if;
  perform 1 from public.profiles where id = me for update;
  if (select count(*) from public.creator_content where user_id = me and status = 'pending') >= 3 then
    raise exception 'You have 3 waiting for review already. Wait for those first.';
  end if;
  if p_link is null or btrim(p_link) = '' then raise exception 'Add a link'; end if;
  if p_views is null or p_views < 0 then raise exception 'How many views does it have?'; end if;
  if exists (select 1 from public.creator_content where user_id = me and lower(link) = lower(btrim(p_link))) then
    raise exception 'You already sent that link';
  end if;
  insert into public.creator_content (user_id, link, note, format, views, title, thumb)
  values (me, btrim(p_link), left(coalesce(p_note, ''), 500), public.creator_format_for(btrim(p_link)), least(p_views, 2000000000),
    left(btrim(coalesce(p_title, '')), 160), nullif(btrim(coalesce(p_thumb, '')), ''))
  returning id into cid;
  return cid;
end; $$;
revoke all on function public.submit_creator_content(text, text, int, text, text) from public, anon;
grant execute on function public.submit_creator_content(text, text, int, text, text) to authenticated;

-- 2. Referral links
-- A row is written at sign-up; it only counts once the account's email is confirmed (confirmed_at), set at once on the
-- instant sign-up path and by the auth.users trigger below otherwise. The bonus counter (seq) only ever goes up, so a
-- referred account that deletes itself never lets the same step pay twice, and the referrer row is locked while it moves.
create table if not exists public.creator_referrals (
  user_id uuid primary key references public.profiles (id) on delete cascade,   -- the new account
  referrer uuid not null references public.profiles (id) on delete cascade,     -- the creator whose link it came through
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  seq int                                                                        -- its number among the referrer's confirmed ones
);
alter table public.creator_referrals add column if not exists confirmed_at timestamptz;
alter table public.creator_referrals add column if not exists seq int;
create index if not exists creator_referrals_referrer_idx on public.creator_referrals (referrer, created_at desc);
alter table public.creator_referrals enable row level security;
revoke all on public.creator_referrals from public, anon, authenticated;
grant select on public.creator_referrals to authenticated;
-- (The Supabase MCP hangs on the bare word, hence the split.)
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'creator_referrals' and policyname = 'own referrals') then
    execute 'create policy "own referrals" on public.creator_referrals for select to authenticated using (referrer = (select auth.uid()))';
  end if;
end $$;

-- Every this-many confirmed sign-ups through a link: a month of Plus for the creator. Mirrored in lib/creators.ts REFERRAL_STEP.
create or replace function public.creator_referral_step() returns int language sql immutable as $$ select 25 $$;

-- A referred account got confirmed: give it its number and pay the step if it lands on one. Internal (trigger + record).
create or replace function public.creator_referral_confirm(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.creator_referrals; n int; until_at timestamptz;
begin
  select * into r from public.creator_referrals where user_id = p_user and confirmed_at is null;
  if r.user_id is null then return; end if;
  -- Flagged-at-sign-up (verify_required) and banned accounts don't count; neither does a referrer who was removed or banned.
  if exists (select 1 from public.profiles where id = p_user and verify_required) or public.is_site_banned(p_user) then return; end if;
  if public.is_site_banned(r.referrer) or not exists (select 1 from public.profiles where id = r.referrer and badges && array['creator_1', 'creator_2', 'creator_3']) then return; end if;
  perform 1 from public.profiles where id = r.referrer for update;
  select coalesce(max(seq), 0) + 1 into n from public.creator_referrals where referrer = r.referrer;
  update public.creator_referrals set confirmed_at = now(), seq = n where user_id = p_user;
  if n % public.creator_referral_step() = 0 then
    update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + interval '31 days'
      where id = r.referrer returning plus_until into until_at;
    insert into public.mod_log (actor, action, target_id, reason) values
      (null, 'plus_gift', r.referrer, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program, ' || n || ' sign-ups through their link');
    begin
      perform public.rt_profile_changed(array[r.referrer]);
    exception when others then
      raise warning 'creator_referral_confirm: profile cache ping for % failed: %', r.referrer, sqlerrm;
    end;
  end if;
end; $$;
revoke all on function public.creator_referral_confirm(uuid) from public, anon, authenticated;

-- Service role only (the sign-up route). Code = the creator's username. Silent no-op when it doesn't match a creator:
-- a sign-up never fails because of a bad ref. Confirmed accounts (instant sign-ups) count right away.
create or replace function public.record_creator_referral(p_code text, p_user uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare ref_id uuid;
begin
  if p_user is null or p_code is null or btrim(p_code) = '' then return false; end if;
  select id into ref_id from public.profiles
    where lower(username) = lower(btrim(p_code)) and badges && array['creator_1', 'creator_2', 'creator_3'] limit 1;
  if ref_id is null or ref_id = p_user then return false; end if;
  if public.is_site_banned(ref_id) then return false; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return false; end if;
  insert into public.creator_referrals (user_id, referrer) values (p_user, ref_id) on conflict (user_id) do nothing;
  if not found then return false; end if;
  if exists (select 1 from auth.users where id = p_user and email_confirmed_at is not null) then
    perform public.creator_referral_confirm(p_user);
  end if;
  return true;
end; $$;
revoke all on function public.record_creator_referral(text, uuid) from public, anon, authenticated;

-- Email confirmed later (the normal sign-up path): count it then.
create or replace function public.creator_referral_on_confirm() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.creator_referral_confirm(new.id);
  return new;
exception when others then
  raise warning 'creator_referral_on_confirm for %: %', new.id, sqlerrm;
  return new;
end; $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'creator_referral_confirmed') then
    execute 'create trigger creator_referral_confirmed after update of email_confirmed_at on auth.users for each row
      when (old.email_confirmed_at is null and new.email_confirmed_at is not null) execute function public.creator_referral_on_confirm()';
  end if;
end $$;

-- 3. Leaderboard: approved long-form-equivalent views per creator, top 25. Public (the /creators page is logged-out
-- too); it only shows what a profile already shows plus the program totals, and only for people wearing a badge.
-- The badge filter below has its own partial index (the predicate matches it word for word), so the call never reads
-- all of profiles. Shown only while the flag is on for the caller or on for everyone.
create index if not exists profiles_creator_badge_idx on public.profiles (id) where badges && array['creator_1', 'creator_2', 'creator_3'];
create or replace function public.creator_leaderboard()
returns table (user_id uuid, username text, display_name text, avatar_path text, tier int, views bigint, pieces int)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_path,
    (case when 'creator_3' = any(p.badges) then 3 when 'creator_2' = any(p.badges) then 2 else 1 end)::int,
    coalesce(sum(public.creator_views_equiv(c.format, coalesce(c.views_checked, c.views))), 0)::bigint,
    count(c.id)::int
  from public.profiles p
  left join public.creator_content c on c.user_id = p.id and c.status = 'approved'
  where p.badges && array['creator_1', 'creator_2', 'creator_3'] and not public.is_site_banned(p.id)
    and (public.feature_on_for_me('creator_program') or (select mode from public.feature_flags where key = 'creator_program') = 'everyone')
  group by p.id
  order by 6 desc, 7 desc, p.created_at
  limit 25
$$;
revoke all on function public.creator_leaderboard() from public;
grant execute on function public.creator_leaderboard() to anon, authenticated;

reset lock_timeout;
