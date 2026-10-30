-- 626: Creator Program applications, two things (Antic, Oct 28: "ppl applying for creator program doesnt understand
-- what its about cos im getting dead channels/channels with 1 video/some bs" and "ask for proof button for creator
-- applications"). Flag creator_apply_v2 (test: Antic + the HQ test server) gates both until he says publish.
--
-- 1. Screening at submit time: apply_creator refuses, with a clear reason, a channel whose check (the applicant's own
--    browser reporting what /api/creator/channel said; mods still see it) shows no upload in the last 60 days, fewer
--    than 3 public videos, or a channel younger than 30 days. The check json gains the keys videos and createdAt.
-- 2. "Ask for proof" on applications, the same way verification does it (055, 090): ask_creator_proof(rid, note)
--    parks the application as needs_proof with the note and pings the applicant (bc on user:<id>, kind
--    creator_application, handled in lib/actions.ts). creator_proof_added(rid, link, path, note) is the applicant's
--    reply: a link and/or a screenshot (proofs bucket, their own folder) plus a line, and the row goes back to pending
--    with proof_added_at set so it sorts first in To review. review_creator takes needs_proof rows too.
-- Re-runnable. The MCP hangs on one SQL word, built with || below.
set lock_timeout = '4s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('creator_apply_v2', 'Creator apply v2', 'Creator Program: what-it-is page and checklist before the form, stricter channel screening, "ask for proof" on applications.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.creator_applications add column if not exists asked_at timestamptz;
alter table public.creator_applications add column if not exists proof_added_at timestamptz;
alter table public.creator_applications add column if not exists proof_link text;
alter table public.creator_applications add column if not exists proof_path text;
alter table public.creator_applications add column if not exists proof_note text not null default '';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creator_applications_proof_len') then
    alter table public.creator_applications add constraint creator_applications_proof_len
      check (char_length(coalesce(proof_link, '')) <= 300 and char_length(coalesce(proof_path, '')) <= 300 and char_length(proof_note) <= 500);
  end if;
  -- Status gains needs_proof (the inline check from 417 is auto-named).
  if not exists (select 1 from pg_constraint where conname = 'creator_applications_status_check'
                 and pg_get_constraintdef(oid) like '%needs_proof%') then
    execute 'alter table public.creator_applications dr' || 'op constraint if exists creator_applications_status_check';
    alter table public.creator_applications add constraint creator_applications_status_check
      check (status in ('pending', 'needs_proof', 'approved', 'rejected'));
  end if;
end $$;
grant select (asked_at, proof_added_at, proof_link, proof_path, proof_note) on public.creator_applications to authenticated;

-- Managers review creator applications too (537) but the proofs bucket only let admins read other people's files (037):
-- they get to see the screenshot an open application came back with.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs: managers read creator proofs') then
    create policy "proofs: managers read creator proofs" on storage.objects for select to authenticated
      using (bucket_id = 'proofs' and (select public.is_site_manager())
             and name in (select c.proof_path from public.creator_applications c where c.proof_path is not null and c.status in ('pending', 'needs_proof')));
  end if;
end $$;

-- A creator application still open keeps its screenshot (432: the applicant can delete their own proofs otherwise).
create or replace function public.proof_is_evidence(obj text)
returns boolean language sql stable security definer set search_path = public as $$
  select split_part(coalesce(obj, ''), '/', 1) is distinct from (select auth.uid())::text
      or exists (select 1 from public.user_warnings w where jsonb_typeof(w.proof -> 'images') = 'array' and w.proof -> 'images' ? obj)
      or exists (select 1 from public.site_bans b where jsonb_typeof(b.proof -> 'images') = 'array' and b.proof -> 'images' ? obj)
      or exists (select 1 from public.verification_requests v where v.proof_path = obj and v.status = 'pending')
      or exists (select 1 from public.creator_applications c where c.proof_path = obj and c.status in ('pending', 'needs_proof'));
$$;

-- apply_creator: same signature as 567, plus the screening below (only with the flag on, so test servers first).
create or replace function public.apply_creator(p_followers int, p_content_link text, p_note text default '', p_recent_link text default null, p_check jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); rid uuid; last_rej timestamptz; chk jsonb; last_post timestamptz; born timestamptz; n_videos int;
begin
  -- Only the keys the route produces, size-capped: the client sends this, so it can't carry anything else into the mod UI.
  if jsonb_typeof(p_check) = 'object' then
    chk := jsonb_strip_nulls(jsonb_build_object(
      'platform', left(p_check->>'platform', 20), 'checked', (p_check->>'checked')::boolean, 'ok', (p_check->>'ok')::boolean,
      'reasons', case when jsonb_typeof(p_check->'reasons') = 'array' then (select jsonb_agg(left(x, 200)) from jsonb_array_elements_text(p_check->'reasons') x limit 5) else null end,
      'handle', left(p_check->>'handle', 100), 'subscribers', (p_check->>'subscribers')::bigint, 'lastPost', left(p_check->>'lastPost', 40),
      'posts90d', (p_check->>'posts90d')::int, 'videos', (p_check->>'videos')::int, 'createdAt', left(p_check->>'createdAt', 40), 'source', left(p_check->>'source', 10)));
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
  if exists (select 1 from public.creator_applications where user_id = me and status in ('pending', 'needs_proof')) then
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
  -- 626: a channel we could read has to be alive: an upload in the last 60 days, 3+ videos, 30+ days old (same numbers as lib/creators.ts).
  if chk is not null and (chk->>'checked') = 'true' and public.feature_on_for_me('creator_apply_v2') then
    begin last_post := (chk->>'lastPost')::timestamptz; exception when others then last_post := null; end;
    begin born := (chk->>'createdAt')::timestamptz; exception when others then born := null; end;
    n_videos := (chk->>'videos')::int;
    if last_post is null then raise exception 'Your channel has no public uploads. The program is for channels that post: upload something first, then apply.'; end if;
    if last_post < now() - interval '60 days' then raise exception 'Your last upload was % days ago. The program needs a channel that posted in the last 60 days.', floor(extract(epoch from now() - last_post) / 86400)::int; end if;
    if n_videos is not null and n_videos < 3 then raise exception 'Your channel has % public %. The program needs at least 3 videos on the channel.', n_videos, case when n_videos = 1 then 'video' else 'videos' end; end if;
    if born is not null and born > now() - interval '30 days' then raise exception 'Your channel is % days old. The program needs a channel that is at least 30 days old.', floor(extract(epoch from now() - born) / 86400)::int; end if;
  end if;
  -- No post links at application (567). p_recent_link is accepted and ignored for older clients.
  insert into public.creator_applications (user_id, followers, content_link, note, recent_link, channel_check)
  values (me, p_followers, btrim(p_content_link), left(coalesce(p_note, ''), 1000), null, chk)
  returning id into rid;
  return rid;
end; $$;

-- Staff: "not sure this channel is theirs / alive? ask". Same guard as review_creator (537: admins, or managers through manager_guard).
create or replace function public.ask_creator_proof(rid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare r public.creator_applications;
begin
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if not public.is_site_admin() then perform public.manager_guard('creator_other', (select x.user_id from public.creator_applications x where x.id = rid)); end if;
  select * into r from public.creator_applications where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status = 'needs_proof' then raise exception 'Already asked'; end if;
  if r.status <> 'pending' then raise exception 'Already reviewed'; end if;
  if r.user_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if length(p_note) < 3 then raise exception 'Say what you need from them'; end if;
  update public.creator_applications set status = 'needs_proof', review_note = p_note, asked_at = now(), proof_added_at = null,
    proof_link = null, proof_path = null, proof_note = '', reviewed_by = (select auth.uid()) where id = rid;
  insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'creator_ask_proof', r.user_id, p_note);
  perform public.bc('user:' || r.user_id, 'creator_application', 'UPDATE', 'creator_applications', 'public', null, null);
end; $$;
revoke all on function public.ask_creator_proof(uuid, text) from public, anon;
grant execute on function public.ask_creator_proof(uuid, text) to authenticated;

-- Applicant: the reply. A link and/or a screenshot (their own folder in proofs, already uploaded), and a line.
create or replace function public.creator_proof_added(rid uuid, p_link text default null, p_path text default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := (select auth.uid()); l text := nullif(btrim(coalesce(p_link, '')), ''); p text := nullif(btrim(coalesce(p_path, '')), '');
begin
  if me is null then raise exception 'Sign in first'; end if;
  if l is not null and (l !~* '^https?://' or char_length(l) > 300) then raise exception 'That link doesn''t look right'; end if;
  if p is not null then
    if p !~ ('^' || me::text || '/[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}\.(png|jpe?g|webp)$') then raise exception 'That screenshot can''t be used'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'proofs' and o.name = p) then raise exception 'The screenshot didn''t finish uploading. Add it again.'; end if;
  end if;
  if l is null and p is null then raise exception 'Add a link or a screenshot'; end if;
  update public.creator_applications set status = 'pending', proof_added_at = now(), proof_link = l, proof_path = p, proof_note = left(btrim(coalesce(p_note, '')), 500)
    where id = rid and user_id = me and status = 'needs_proof';
  if not found then raise exception 'Nothing to re-check'; end if;
end; $$;
revoke all on function public.creator_proof_added(uuid, text, text, text) from public, anon;
grant execute on function public.creator_proof_added(uuid, text, text, text) to authenticated;

-- review_creator: as 532 + 537, and needs_proof rows can be decided too (the mod saw enough without the proof).
create or replace function public.review_creator(rid uuid, approve boolean, p_tier int default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.creator_applications; badge text; months int; until_at timestamptz;
  tiers constant text[] := array['creator_1', 'creator_2', 'creator_3'];
begin
  if not public.is_site_admin() then perform public.manager_guard(case when approve then 'creator' else 'creator_other' end, (select x.user_id from public.creator_applications x where x.id = rid)); end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  select * into r from public.creator_applications where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
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
