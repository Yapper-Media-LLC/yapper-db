-- 419: Elite Creator at 500k total approved views (was 1M in 418), so the badge rows line up with the reward ladder
-- on the Creator Center (one table: 5k / 25k / 100k / 500k). Same function as 418 otherwise. Re-runnable.
set lock_timeout = '3s';
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
    -- The badge ladder: Pro at 100k, Elite at 500k long-form-equivalent approved views. Up only, never down here.
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
    update public.creator_content set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note where id = cid;
    insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'content_rejected', c.user_id, left(c.link, 100) || ': ' || p_note);
  end if;
end; $$;
reset lock_timeout;
