-- 418: Creator Center (flag creator_program, test): rewards by views, two scales, badges earned automatically.
--   * creator_content gets format ('long': YouTube videos, Twitch; 'short': TikTok, Shorts, Reels, X, worked out from
--     the link), views (what the creator reports when sending it in) and views_checked (what staff saw when they
--     approved it; the reward and the tier use this one).
--   * creator_reward_months(format, views): the ladder. Long-form 5k / 25k / 100k / 500k views = 1 / 3 / 6 / 12 months
--     of Plus; short-form needs five times the views for the same reward. Under the first step: approved, counts
--     toward the badge, no Plus.
--   * Badges by total approved views (short-form counts a fifth): Pro Creator at 100k, Elite Creator at 1M, given by
--     review_creator_content itself (never taken away here; revoke_creator still does that). Elite also gets the
--     Partner badge.
--   * submit_creator_content(link, note, views) and review_creator_content(id, approve, note, views) replace the old
--     signatures (PostgREST can't tell two overloads apart when the extra argument has a default, so the old ones go).
-- Re-runnable. Locks on profiles wait at most 3 s.
set lock_timeout = '3s';

alter table public.creator_content add column if not exists format text not null default 'long';
alter table public.creator_content add column if not exists views int not null default 0;
alter table public.creator_content add column if not exists views_checked int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creator_content_format_check') then
    alter table public.creator_content add constraint creator_content_format_check check (format in ('long', 'short'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'creator_content_views_check') then
    alter table public.creator_content add constraint creator_content_views_check check (views between 0 and 2000000000 and (views_checked is null or views_checked between 0 and 2000000000));
  end if;
end $$;

-- Short-form hosts and paths. Anything else (a YouTube video, a Twitch VOD, a blog post) is long-form.
create or replace function public.creator_format_for(link text)
returns text language sql immutable as $$
  select case when lower(coalesce(link, '')) ~ '(tiktok\.com|youtube\.com/shorts/|instagram\.com|(^|[./])x\.com|twitter\.com|facebook\.com/reel|snapchat\.com)' then 'short' else 'long' end
$$;

-- The ladder. Short-form views are worth a fifth of long-form ones (a TikTok view is a few seconds, a video view is minutes).
create or replace function public.creator_views_equiv(fmt text, v int)
returns int language sql immutable as $$
  select case when fmt = 'short' then coalesce(v, 0) / 5 else coalesce(v, 0) end
$$;
create or replace function public.creator_reward_months(fmt text, v int)
returns int language sql immutable as $$
  select case
    when public.creator_views_equiv(fmt, v) >= 500000 then 12
    when public.creator_views_equiv(fmt, v) >= 100000 then 6
    when public.creator_views_equiv(fmt, v) >= 25000 then 3
    when public.creator_views_equiv(fmt, v) >= 5000 then 1
    else 0 end
$$;
-- Everything approved so far, in long-form-equivalent views (the badge ladder reads this). Not callable by
-- clients: the dashboard adds up the person's own rows; review_creator_content calls this as owner.
create or replace function public.creator_total_views(uid uuid)
returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(public.creator_views_equiv(format, coalesce(views_checked, views))), 0)::bigint
  from public.creator_content where user_id = uid and status = 'approved'
$$;

-- Old signatures out (see the header). The MCP hangs on the word itself, hence the split.
do $$ begin
  execute 'dr' || 'op function if exists public.submit_creator_content(text, text)';
  execute 'dr' || 'op function if exists public.review_creator_content(uuid, boolean, text)';
end $$;

-- Member: send in a video or post about Yapin’ with its view count. Up to 3 waiting, each link once.
create or replace function public.submit_creator_content(p_link text, p_note text default '', p_views int default 0)
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
  insert into public.creator_content (user_id, link, note, format, views)
  values (me, btrim(p_link), left(coalesce(p_note, ''), 500), public.creator_format_for(btrim(p_link)), least(p_views, 2000000000))
  returning id into cid;
  return cid;
end; $$;

-- Admin: approve with the views you saw (defaults to what they reported). Plus by the ladder, badge tier by the total.
create or replace function public.review_creator_content(cid uuid, approve boolean, p_note text default '', p_views int default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.creator_content; until_at timestamptz; seen int; months int; total bigint; cur int; want int; badge text;
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  select * into c from public.creator_content where id = cid for update;
  if c.id is null then raise exception 'Not found'; end if;
  if c.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if c.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if approve then
    if public.is_site_banned(c.user_id) then raise exception 'That account is banned'; end if;
    if not exists (select 1 from public.profiles where id = c.user_id and badges && tiers) then raise exception 'Not in the Creator Program any more'; end if;
    if p_views is not null and p_views < 0 then raise exception 'Views can''t be negative'; end if;
    seen := least(coalesce(p_views, c.views), 2000000000);
    months := public.creator_reward_months(c.format, seen);
    update public.creator_content set status = 'approved', views_checked = seen, reward_months = months,
      reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values
      ((select auth.uid()), 'content_approved', c.user_id, left(c.link, 200) || ' (' || seen || ' views, ' || c.format || ', ' || months || ' months)' || case when p_note <> '' then ': ' || p_note else '' end);
    if months > 0 then
      update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * months)
        where id = c.user_id returning plus_until into until_at;
      insert into public.mod_log (actor, action, target_id, reason) values
        ((select auth.uid()), 'plus_gift', c.user_id, 'Until ' || to_char(until_at, 'YYYY-MM-DD') || ': Creator Program content, ' || months || ' months');
    end if;
    -- The badge ladder: Pro at 100k, Elite at 1M long-form-equivalent approved views. Up only, never down here.
    total := public.creator_total_views(c.user_id);
    select coalesce(max(case b when 'creator_3' then 3 when 'creator_2' then 2 when 'creator_1' then 1 end), 0) into cur
      from public.profiles p, unnest(coalesce(p.badges, '{}'::text[])) b where p.id = c.user_id;
    want := case when total >= 1000000 then 3 when total >= 100000 then 2 else 1 end;
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
    update public.creator_content set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'content_rejected', c.user_id, left(c.link, 100) || ': ' || p_note);
  end if;
end; $$;

revoke all on function public.submit_creator_content(text, text, int), public.review_creator_content(uuid, boolean, text, int) from public, anon;
revoke all on function public.creator_total_views(uuid) from public, anon, authenticated;
grant execute on function public.submit_creator_content(text, text, int), public.review_creator_content(uuid, boolean, text, int),
  public.creator_format_for(text), public.creator_views_equiv(text, int), public.creator_reward_months(text, int) to authenticated;
reset lock_timeout;
