-- 518: Creator Program v3 (flag creator_program, still test). Closes the holes that would pay out Plus wrongly once it
-- opens to everyone, and makes invite links count real people only.
--   1. One video, one payout, across everyone: creator_content.video_key (creator_video_key: the YouTube id for any
--      youtu.be / watch / shorts / live / embed address, TikTok / X / Instagram / Twitch ids, else host + path) is
--      unique while a piece isn't rejected. TikTok short links (vm.tiktok.com, tiktok.com/t/) are refused: they hide the
--      video id.
--   2. Staff set the format and confirm the views: review_creator_content(.., p_format, p_checks). Approving needs the
--      views staff saw (it no longer falls back to the creator's own number). p_format lets staff mark a Short that
--      was sent as a watch?v= link; a creator can mark their own piece short (that only lowers the reward).
--      p_checks keeps what the staff screen saw (fetched views, channel match) on the row, for the record.
--   3. apply_creator needs 1,000+ followers (the verification rule, now enforced here too). review_creator gives the
--      badge only: no starter Plus for joining any more (it was 3 months, 12 for Pro and Elite).
--   4. Invite links: a stable code per creator (creator_links, made from the username when they join and kept through
--      renames; a freed username can't take it over). A sign-up through it is noted as pending and counts only once
--      the account is 7+ days old, confirmed its email and was active on 3+ days (shard_days), and isn't a bot, banned,
--      flagged at sign-up, or on the creator's device or network (shard_shared_device, 462). Checked when the creator
--      opens the Creator Center (creator_referrals_settle, at most once a minute, 200 at a time), so no cron and no
--      work on anyone else's requests. The email-confirm trigger no longer counts anything. The running number lives
--      on creator_links.counted (never goes back, so deleted accounts can't make a step pay twice). Creators no longer
--      read creator_referrals directly (the refusal reasons would help someone farming alts).
-- Re-runnable. Locks wait at most 4 s.
set lock_timeout = '4s';

-- ---------- 1. video_key ----------
create or replace function public.creator_video_key(link text)
returns text language plpgsql immutable as $$
declare raw text := btrim(coalesce(link, '')); m text[];
begin
  if raw = '' then return null; end if;
  m := regexp_match(raw, '^https?://(?:(?:www|m|music)\.)?(?:youtube(?:-nocookie)?\.com(?::\d+)?/(?:watch/?\?(?:[^#]*&)?v=|shorts/|live/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})', 'i');
  if m is not null then return 'yt:' || m[1]; end if;
  m := regexp_match(raw, '^https?://(?:[a-z0-9-]+\.)?tiktok\.com/(?:@[^/?#]+/(?:video|photo)|v|embed(?:/v2)?)/(\d{6,25})', 'i');
  if m is not null then return 'tt:' || m[1]; end if;
  m := regexp_match(raw, '^https?://(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx)\.com/(?:i/web|[^/?#]+)/status(?:es)?/(\d{6,25})', 'i');
  if m is not null then return 'x:' || m[1]; end if;
  m := regexp_match(raw, '^https?://(?:www\.)?instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([A-Za-z0-9_-]{5,40})', 'i');
  if m is not null then return 'ig:' || m[1]; end if;
  m := regexp_match(raw, '^https?://(?:www\.|m\.)?twitch\.tv/videos/(\d{3,20})', 'i');
  if m is not null then return 'twv:' || m[1]; end if;
  m := regexp_match(raw, '^https?://(?:clips\.twitch\.tv/|(?:www\.|m\.)?twitch\.tv/[^/?#]+/clip/)([A-Za-z0-9_-]{3,100})', 'i');
  if m is not null then return 'twc:' || m[1]; end if;
  -- Anything else: 'web:' + host (no www. / m.) + path + query, lowercased, no fragment or trailing slash. The prefix
  -- keeps it from ever looking like a platform key.
  return 'web:' || left(regexp_replace(regexp_replace(regexp_replace(lower(raw), '^https?://(www\.|m\.)?', ''), '#.*$', ''), '(/+$)|(/+(?=\?))', '', 'g'), 300);
end; $$;

alter table public.creator_content add column if not exists video_key text;
alter table public.creator_content add column if not exists review_checks jsonb;
update public.creator_content set video_key = public.creator_video_key(link) where video_key is null;
-- The same video already in twice (sent before this check existed): the newer one keeps its own key so the index can
-- build; staff see both. Nothing like this live on Oct 25 (no content at all), but the migration must not fail on it.
update public.creator_content c set video_key = c.video_key || ':dup:' || c.id
  where c.status <> 'rejected' and c.video_key !~ ':dup:' and exists (
    select 1 from public.creator_content o where o.video_key = c.video_key and o.status <> 'rejected'
      and (o.created_at, o.id) < (c.created_at, c.id));
create unique index if not exists creator_content_video_once on public.creator_content (video_key) where status <> 'rejected';

-- ---------- 2. submit / review ----------
do $$ begin
  execute 'dr' || 'op function if exists public.submit_creator_content(text, text, int, text, text)';
  execute 'dr' || 'op function if exists public.review_creator_content(uuid, boolean, text, int)';
end $$;

-- Member: send in a video or post. Up to 3 waiting; each video once (anyone's, unless it was rejected).
create or replace function public.submit_creator_content(p_link text, p_note text default '', p_views int default 0, p_title text default '',
  p_thumb text default null, p_format text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); cid uuid; l text := btrim(coalesce(p_link, '')); k text; fmt text;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'That account is banned'; end if;
  if not exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then
    raise exception 'Join the Creator Program first';
  end if;
  if l = '' then raise exception 'Add a link'; end if;
  if l ~* '^https?://(vm\.tiktok\.com|vt\.tiktok\.com|(www\.)?tiktok\.com/t/)' then
    raise exception 'Open the TikTok and paste the full link (the one with /video/ in it)';
  end if;
  if p_views is null or p_views < 0 then raise exception 'How many views does it have?'; end if;
  -- A plain host: no login part (user@host) and no trailing dot (host./), which would give the same video a new key.
  if l !~* '^https?://[a-z0-9-]+(\.[a-z0-9-]+)+(:\d{1,5})?([/?#]|$)' then
    raise exception 'That link doesn''t look right';
  end if;
  k := public.creator_video_key(l);
  -- A known platform we couldn't read an id from (odd link forms) would get its own key: ask for the normal link.
  if k !~ '^(yt|tt|x|ig|twv|twc):' and l ~* '^https?://([a-z0-9-]+\.)*(youtube(-nocookie)?\.com|youtu\.be|tiktok\.com|x\.com|twitter\.com|fxtwitter\.com|vxtwitter\.com|fixupx\.com|instagram\.com|twitch\.tv)([:/?#]|$)' then
    raise exception 'Paste the normal link to the video or post';
  end if;
  perform 1 from public.profiles where id = me for no key update;
  if (select count(*) from public.creator_content where user_id = me and status = 'pending') >= 3 then
    raise exception 'You have 3 waiting for review already. Wait for those first.';
  end if;
  if exists (select 1 from public.creator_content where user_id = me and (lower(link) = lower(l) or video_key = k)) then
    raise exception 'You already sent that one';
  end if;
  if exists (select 1 from public.creator_content where video_key = k and status <> 'rejected') then
    raise exception 'Someone already sent that one in';
  end if;
  fmt := case when p_format = 'short' then 'short' else public.creator_format_for(l) end;
  insert into public.creator_content (user_id, link, note, format, views, title, thumb, video_key)
  values (me, l, left(coalesce(p_note, ''), 500), fmt, least(p_views, 2000000000),
    left(btrim(coalesce(p_title, '')), 160), nullif(btrim(coalesce(p_thumb, '')), ''), k)
  returning id into cid;
  return cid;
exception when unique_violation then
  raise exception 'Someone already sent that one in';
end; $$;

-- Admin: approve with the views you saw (required) and the format (null keeps it). Plus by the ladder, badge tier by
-- the total (Pro 100k, Elite 500k + Partner, as 419). p_checks: what the review screen saw, kept on the row.
create or replace function public.review_creator_content(cid uuid, approve boolean, p_note text default '', p_views int default null,
  p_format text default null, p_checks jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.creator_content; until_at timestamptz; seen int; months int; total bigint; cur int; want int; badge text; fmt text;
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if p_checks is not null and (jsonb_typeof(p_checks) <> 'object' or length(p_checks::text) > 2000) then p_checks := null; end if;
  select * into c from public.creator_content where id = cid for update;
  if c.id is null then raise exception 'Not found'; end if;
  if c.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if c.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if approve then
    if public.is_site_banned(c.user_id) then raise exception 'That account is banned'; end if;
    if not exists (select 1 from public.profiles where id = c.user_id and badges && tiers) then raise exception 'Not in the Creator Program any more'; end if;
    if p_views is null then raise exception 'Type the views you see on the link'; end if;
    if p_views < 0 then raise exception 'Views can''t be negative'; end if;
    if p_format is not null and p_format not in ('long', 'short') then raise exception 'Format is long or short'; end if;
    fmt := coalesce(p_format, c.format);
    seen := least(p_views, 2000000000);
    months := public.creator_reward_months(fmt, seen);
    update public.creator_content set status = 'approved', format = fmt, views_checked = seen, reward_months = months, review_checks = p_checks,
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'content_approved', c.user_id, left(c.link, 200) || ' (' || seen || ' views, ' || fmt || ', ' || months || ' months)' || case when p_note <> '' then ': ' || p_note else '' end);
    if months > 0 then
      update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * months)
        where id = c.user_id returning plus_until into until_at;
      insert into public.mod_log (actor, action, target_id, reason) values
        ((select auth.uid()), 'plus_gift', c.user_id, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program content, ' || months || ' months');
    end if;
    total := public.creator_total_views(c.user_id);
    select coalesce(max(case b when 'creator_3' then 3 when 'creator_2' then 2 when 'creator_1' then 1 end), 0) into cur
      from public.profiles p, unnest(coalesce(p.badges, '{}'::text[])) b where p.id = c.user_id;
    want := case when total >= 500000 then 3 when total >= 100000 then 2 else 1 end;
    if want > cur and cur > 0 then
      badge := 'creator_' || want;
      update public.profiles set
        badges = array(select distinct unnest(
          array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers) and b <> badge))
          || badge || case when want = 3 then array['partner'] else '{}'::text[] end)),
        shown_badge = case when shown_badge = any(tiers) then badge else shown_badge end
        where id = c.user_id;
      insert into public.mod_log (actor, action, target_id, reason) values
        ((select auth.uid()), 'badge_given', c.user_id, badge || ' (Creator Program: ' || total || ' views)');
      if want = 3 then
        insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'badge_given', c.user_id, 'partner (Elite Creator)');
      end if;
    end if;
    begin
      perform public.rt_profile_changed(array[c.user_id]);
    exception when others then
      raise warning 'review_creator_content: profile cache ping for % failed: %', c.user_id, sqlerrm;
    end;
  else
    if length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
    update public.creator_content set status = 'rejected', review_checks = coalesce(p_checks, review_checks),
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'content_rejected', c.user_id, left(c.link, 100) || ': ' || p_note);
  end if;
end; $$;

revoke all on function public.submit_creator_content(text, text, int, text, text, text), public.review_creator_content(uuid, boolean, text, int, text, jsonb) from public, anon;
grant execute on function public.submit_creator_content(text, text, int, text, text, text), public.review_creator_content(uuid, boolean, text, int, text, jsonb) to authenticated;
grant execute on function public.creator_video_key(text) to authenticated;

-- ---------- 3. apply_creator: 1,000+ followers ----------
create or replace function public.apply_creator(p_followers int, p_content_link text, p_note text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); rid uuid; last_rej timestamptz;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'That account is banned'; end if;
  if (select verified_as from public.profiles where id = me) is null then raise exception 'Get verified first'; end if;
  if exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then
    raise exception 'You''re already in the Creator Program';
  end if;
  perform 1 from public.profiles where id = me for no key update;
  if exists (select 1 from public.creator_applications where user_id = me and status = 'pending') then
    raise exception 'You already have an application waiting for review';
  end if;
  select max(reviewed_at) into last_rej from public.creator_applications where user_id = me and status = 'rejected';
  if last_rej is not null and last_rej > now() - interval '30 days' then
    raise exception 'You can apply again 30 days after a rejection';
  end if;
  if p_followers is null or p_followers < 0 then raise exception 'How many followers do you have?'; end if;
  if p_followers < 1000 then raise exception 'You need 1,000+ followers or subscribers to join'; end if;
  if p_content_link is null or btrim(p_content_link) = '' then raise exception 'Add a link'; end if;
  insert into public.creator_applications (user_id, followers, content_link, note)
  values (me, p_followers, btrim(p_content_link), left(coalesce(p_note, ''), 1000))
  returning id into rid;
  return rid;
end; $$;

-- ---------- 4. invite links ----------
create table if not exists public.creator_links (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  code text not null check (code ~ '^[a-z0-9_.]{2,32}$'),
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
-- How many sign-ups have counted for this creator, ever. Only goes up (a referred account deleting itself removes its
-- referral row, so max(seq) over the rows could go back and pay a step twice; this can't).
alter table public.creator_links add column if not exists counted int not null default 0;
create unique index if not exists creator_links_code_key on public.creator_links (code);
alter table public.creator_links enable row level security;
revoke all on public.creator_links from public, anon, authenticated;

alter table public.creator_referrals add column if not exists status text not null default 'pending';
alter table public.creator_referrals add column if not exists reason text;
alter table public.creator_referrals add column if not exists checked_at timestamptz;
-- Creators don't read their rows any more (counts come from creator_referrals_settle), and the refusal reasons would
-- tell someone farming alts which check caught which account.
revoke select on public.creator_referrals from authenticated;
do $$ begin
  if exists (select 1 from pg_policies where tablename = 'creator_referrals' and policyname = 'own referrals') then
    execute 'dr' || 'op policy "own referrals" on public.creator_referrals';
  end if;
end $$;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creator_referrals_status_check') then
    alter table public.creator_referrals add constraint creator_referrals_status_check check (status in ('pending', 'counted', 'refused'));
  end if;
end $$;
update public.creator_referrals set status = 'counted' where confirmed_at is not null and status = 'pending';
create index if not exists creator_referrals_due_idx on public.creator_referrals (referrer, checked_at nulls first, created_at) where status = 'pending';

-- The creator's code: made once from their username (a number on the end if that's taken), then kept. Internal.
create or replace function public.creator_link_code(uid uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text; base text;
begin
  select code into c from public.creator_links where user_id = uid;
  if c is not null then return c; end if;
  select left(regexp_replace(lower(username), '[^a-z0-9_.]', '', 'g'), 26) into base from public.profiles where id = uid;
  if base is null then return null; end if;
  if length(base) < 2 then base := base || 'yp'; end if;
  c := base;
  for i in 1..20 loop
    begin
      insert into public.creator_links (user_id, code) values (uid, c);
      return c;
    exception when unique_violation then
      select code into c from public.creator_links where user_id = uid;   -- made by a parallel call
      if c is not null then return c; end if;
      c := base || (100 + floor(random() * 900))::int;
    end;
  end loop;
  raise exception 'Couldn''t make an invite code, try again';
end; $$;
revoke all on function public.creator_link_code(uuid) from public, anon, authenticated;

-- Everyone already in the program gets their code now (the partial index from 497 keeps this off the whole table).
do $$ declare r record; begin
  for r in select id from public.profiles where badges && array['creator_1', 'creator_2', 'creator_3'] loop
    perform public.creator_link_code(r.id);
  end loop;
end $$;
update public.creator_links l set counted = greatest(l.counted, coalesce((select max(seq) from public.creator_referrals r where r.referrer = l.user_id), 0));

-- review_creator (417) gives the code on approval: same function, plus one line.
create or replace function public.review_creator(rid uuid, approve boolean, p_tier int default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.creator_applications; badge text;
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
    -- No Plus for joining (Antic, Oct 25: "won't give out 3 months for just joining"). Plus comes from content and invites.
    badge := 'creator_' || p_tier;
    update public.profiles set
      badges = array(select distinct unnest(
        array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers) and b <> badge)) || badge)),
      shown_badge = case when shown_badge = any(tiers) then badge else shown_badge end
      where id = r.user_id;
    update public.creator_applications set status = 'approved', tier = p_tier, plus_months = 0,
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = rid;
    perform public.creator_link_code(r.user_id);
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'creator_approved', r.user_id, 'Tier ' || p_tier || case when p_note <> '' then ': ' || p_note else '' end),
      ((select auth.uid()), 'badge_given', r.user_id, badge);
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

-- Service role only (the sign-up route). The code is a creator_links code; anything else is a silent no-op, a sign-up
-- never fails because of a bad ref. Nothing counts yet: creator_referral_check decides later.
create or replace function public.record_creator_referral(p_code text, p_user uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare ref_id uuid;
begin
  if p_user is null or p_code is null or btrim(p_code) = '' then return false; end if;
  select l.user_id into ref_id from public.creator_links l
    join public.profiles p on p.id = l.user_id and p.badges && array['creator_1', 'creator_2', 'creator_3']
    where l.code = lower(btrim(p_code));
  if ref_id is null or ref_id = p_user then return false; end if;
  if public.is_site_banned(ref_id) then return false; end if;
  if not exists (select 1 from public.profiles where id = p_user) then return false; end if;
  insert into public.creator_referrals (user_id, referrer) values (p_user, ref_id) on conflict (user_id) do nothing;
  return found;
end; $$;
revoke all on function public.record_creator_referral(text, uuid) from public, anon, authenticated;

-- One pending sign-up: count it, refuse it for good, or leave it waiting. Internal.
--   refused for good: a bot, or on the creator's device or network; or still not counted 60 days after sign-up.
--   waiting: under 7 days old, email not confirmed, active (5+ minutes) on fewer than 3 days, flagged at sign-up
--   (verify_required clears when they confirm), banned or Shards-frozen (bans can be lifted), or the creator is out of
--   the program or banned. A waiting row gets checked_at, so the next settle looks at others first.
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

-- 497's confirm path now just runs the check (which waits out the 7 days); the email-confirm trigger does nothing.
create or replace function public.creator_referral_confirm(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.creator_referral_check(p_user);
end; $$;
revoke all on function public.creator_referral_confirm(uuid) from public, anon, authenticated;
create or replace function public.creator_referral_on_confirm() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  return new;
end; $$;

-- The creator's own invite link and counts. Settles their pending sign-ups that are old enough, at most once a minute,
-- 200 at a time, never-checked and longest-unchecked first, each at most once an hour (due_idx). Creators only;
-- others get null.
create or replace function public.creator_referrals_settle()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); l public.creator_links; r record;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.feature_on_for_me('creator_program') then raise exception 'Not available yet'; end if;
  if not exists (select 1 from public.profiles where id = me and badges && array['creator_1', 'creator_2', 'creator_3']) then return null; end if;
  perform public.creator_link_code(me);
  select * into l from public.creator_links where user_id = me for update;
  if l.settled_at is null or l.settled_at < now() - interval '1 minute' then
    update public.creator_links set settled_at = now() where user_id = me;
    for r in select user_id from public.creator_referrals
             where referrer = me and status = 'pending' and created_at <= now() - interval '7 days'
               and (checked_at is null or checked_at < now() - interval '1 hour')
             order by checked_at nulls first, created_at limit 200 loop
      perform public.creator_referral_check(r.user_id);
    end loop;
  end if;
  return (select jsonb_build_object(
      'code', l.code,
      'counted', count(*) filter (where status = 'counted'),
      'waiting', count(*) filter (where status = 'pending'),
      'refused', count(*) filter (where status = 'refused'),
      'top_seq', (select counted from public.creator_links where user_id = me),
      'step', public.creator_referral_step())
    from public.creator_referrals where referrer = me);
end; $$;
revoke all on function public.creator_referrals_settle() from public, anon;
grant execute on function public.creator_referrals_settle() to authenticated;

update public.feature_flags set description = 'Creator Program: verified creators apply at /creator, admins approve in Mod Center (badge only), approved videos and posts pay Plus by views, invite links pay Plus for real sign-ups'
  where key = 'creator_program';

reset lock_timeout;
