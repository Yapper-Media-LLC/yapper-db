-- 567: Creator Program applications take the channel and the follower count only (Antic, Oct 26: "ppl sending non
-- related videos to creator program, only allow vid upload when ur accepted"). The recent-post link that 543 asked
-- for on platforms we can't read is gone; mods open the channel themselves. Videos go in after approval, through the
-- dashboard (submit_creator_content already needs the badge). apply_creator replaced in place, same signature.
set lock_timeout = '4s';
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
  -- No post links at application (Antic, Oct 26: people sent unrelated videos). Videos come after approval, through
  -- the dashboard. p_recent_link is accepted and ignored for older clients.
  insert into public.creator_applications (user_id, followers, content_link, note, recent_link, channel_check)
  values (me, p_followers, btrim(p_content_link), left(coalesce(p_note, ''), 1000), null, chk)
  returning id into rid;
  return rid;
end; $$;
reset lock_timeout;
