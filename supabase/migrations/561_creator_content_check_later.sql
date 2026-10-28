-- 561 (applied live Oct 26 under the name 545_creator_content_check_later; renumbered): "Check later" for creator content (Antic, Oct 26: a fresh video with 200 views shouldn't have to be approved
-- for nothing or rejected; park it and look again when the views have grown). creator_content.check_after: while it's
-- in the future the piece is "growing": still pending, hidden from To review, not counted against the creator's 3
-- waiting, shown to the creator as "we check again on <date>". snooze_creator_content(cid, days) sets it (admins).
-- submit_creator_content is replaced in place (the cap change only). Re-runnable.
set lock_timeout = '4s';
alter table public.creator_content add column if not exists check_after timestamptz;
create index if not exists creator_content_growing_idx on public.creator_content (check_after) where status = 'pending';

create or replace function public.snooze_creator_content(cid uuid, days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare c public.creator_content; until_at timestamptz;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if days is null or days < 1 or days > 60 then raise exception 'Between 1 and 60 days'; end if;
  select * into c from public.creator_content where id = cid for update;
  if c.id is null then raise exception 'Not found'; end if;
  if c.status <> 'pending' then raise exception 'Already reviewed'; end if;
  until_at := now() + make_interval(days => days);
  update public.creator_content set check_after = until_at where id = cid;
  insert into public.mod_log (actor, action, target_id, reason) values
    ((select auth.uid()), 'content_later', c.user_id, left(c.link, 200) || ': check again on ' || to_char(until_at, 'YYYY-MM-DD'));
  return until_at;
end; $$;
revoke all on function public.snooze_creator_content(uuid, int) from public, anon;
grant execute on function public.snooze_creator_content(uuid, int) to authenticated;

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
  -- Pieces parked as "growing" (check_after in the future, 545) don't count against the 3 waiting.
  if (select count(*) from public.creator_content where user_id = me and status = 'pending' and (check_after is null or check_after <= now())) >= 3 then
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
reset lock_timeout;
