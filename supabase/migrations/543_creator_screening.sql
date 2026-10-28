-- 543 (applied live Oct 26 under the name 540_creator_screening; renumbered, 540 was taken by management_roles): Creator Program screening + the 30-day rule (Antic, Oct 26: "from 30 applicants there were pretty much no
-- decent ones: private Instagram accounts, dead channels"; "if they don't submit content related to Yapin' in 1 month
-- they get disqualified").
--   1. Applications carry a recent post link and the automatic channel check (/api/creator/channel: subscribers, last
--      upload, posts in 90 days for YouTube; the other platforms are "not checked" and need the recent post link).
--      apply_creator gains p_recent_link and p_check; the old 3-arg signature goes (one function, no overloads).
--   2. creator_inactive_sweep(): a creator who sent nothing in for 30 days (counted from approval, or from the last
--      piece, whichever is later) loses the badge, logged as creator_revoked with no actor. pg_cron runs it daily.
--      Pending pieces count as activity; a revoked creator can apply again at once.
-- Re-runnable.
set lock_timeout = '4s';

alter table public.creator_applications add column if not exists recent_link text;
alter table public.creator_applications add column if not exists channel_check jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creator_applications_recent_link_len') then
    alter table public.creator_applications add constraint creator_applications_recent_link_len check (recent_link is null or (recent_link ~* '^https?://' and char_length(recent_link) <= 300));
  end if;
end $$;
grant select (recent_link, channel_check) on public.creator_applications to authenticated;

do $$ begin
  execute 'dr' || 'op function if exists public.apply_creator(int, text, text)';
end $$;
create or replace function public.apply_creator(p_followers int, p_content_link text, p_note text default '', p_recent_link text default null, p_check jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); rid uuid; last_rej timestamptz; chk jsonb;
begin
  -- Only the keys the route produces, size-capped: the client sends this, so it can't carry anything else into the mod UI.
  if jsonb_typeof(p_check) = 'object' then
    chk := jsonb_strip_nulls(jsonb_build_object(
      'platform', left(p_check->>'platform', 20), 'checked', (p_check->>'checked')::boolean, 'ok', (p_check->>'ok')::boolean,
      'reasons', case when jsonb_typeof(p_check->'reasons') = 'array' then (select jsonb_agg(left(x, 200)) from jsonb_array_elements_text(p_check->'reasons') x limit 5) else null end,
      'handle', left(p_check->>'handle', 100), 'subscribers', (p_check->>'subscribers')::bigint, 'lastPost', left(p_check->>'lastPost', 40),
      'posts90d', (p_check->>'posts90d')::int, 'source', left(p_check->>'source', 10)));
    if pg_column_size(chk) > 4096 then raise exception 'Bad check'; end if;
  end if;
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
  -- The check is the applicant's own browser reporting what our route said; mods see it, it isn't trusted on its own.
  if chk is not null and (chk->>'ok') = 'false' then raise exception 'Your channel didn''t pass the check: %', coalesce(chk->'reasons'->>0, 'see the form'); end if;
  if (chk is null or (chk->>'checked') <> 'true') and (p_recent_link is null or btrim(p_recent_link) = '') then
    raise exception 'Add a link to a post from the last 30 days on that channel';
  end if;
  insert into public.creator_applications (user_id, followers, content_link, note, recent_link, channel_check)
  values (me, p_followers, btrim(p_content_link), left(coalesce(p_note, ''), 1000), nullif(btrim(coalesce(p_recent_link, '')), ''), chk)
  returning id into rid;
  return rid;
end; $$;
revoke all on function public.apply_creator(int, text, text, text, jsonb) from public, anon;
grant execute on function public.apply_creator(int, text, text, text, jsonb) to authenticated;

create or replace function public.creator_inactive_days() returns int language sql immutable as $$ select 30 $$;

-- When this creator has to have sent something in by: approval (or the badge, for by-hand approvals) or the last
-- piece, whichever is later, plus the window. Null for non-creators. Readable by the person themselves.
create or replace function public.creator_deadline(uid uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.profiles where id = uid and badges && array['creator_1', 'creator_2', 'creator_3'])
    then greatest(
      coalesce((select max(reviewed_at) from public.creator_applications where user_id = uid and status = 'approved'), '-infinity'),
      coalesce((select max(created_at) from public.mod_log where target_id = uid and action = 'badge_given' and reason like 'creator_%'), '-infinity'),
      coalesce((select max(created_at) from public.creator_content where user_id = uid), '-infinity')
    ) + make_interval(days => public.creator_inactive_days())
    else null end
$$;
revoke all on function public.creator_deadline(uuid) from public, anon;
grant execute on function public.creator_deadline(uuid) to authenticated;

create or replace function public.creator_inactive_sweep()
returns int language plpgsql security definer set search_path = public as $$
declare tiers constant text[] := array['creator_1', 'creator_2', 'creator_3']; r record; n int := 0; dl timestamptz;
begin
  for r in select id from public.profiles where badges && tiers loop
    dl := public.creator_deadline(r.id);
    if dl is null or dl = '-infinity' or dl > now() then continue; end if;
    update public.profiles set
      badges = array(select b from unnest(coalesce(badges, '{}'::text[])) b where not (b = any(tiers))),
      shown_badge = case when shown_badge = any(tiers) then null else shown_badge end
      where id = r.id and badges && tiers;
    insert into public.mod_log (actor, action, target_id, reason) values
      (null, 'creator_revoked', r.id, 'No Yapin’ content sent in for ' || public.creator_inactive_days() || ' days (automatic). They can apply again.');
    begin
      perform public.rt_profile_changed(array[r.id]);
    exception when others then
      raise warning 'creator_inactive_sweep: profile cache ping for % failed: %', r.id, sqlerrm;
    end;
    n := n + 1;
  end loop;
  return n;
end; $$;
revoke all on function public.creator_inactive_sweep() from public, anon, authenticated;

do $$ begin
  if to_regclass('cron.job') is not null then
    execute $q$select cron.schedule('creator-inactive-sweep', '25 4 * * *', 'select public.creator_inactive_sweep()') where not exists (select 1 from cron.job where jobname = 'creator-inactive-sweep')$q$;
  end if;
end $$;
reset lock_timeout;
