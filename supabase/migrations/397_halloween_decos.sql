-- 397: Halloween event decorations (flag halloween_decos, test). The /halloween page lets people send in a spooky
-- avatar decoration for the event; it goes through the same pipeline as community decorations (345: avatars bucket,
-- the nudity check, staff review in the mod centre, 'c:<path>' to wear it), with one extra: community_decos.event
-- says which event it was sent in for, so the review queue can show and filter them and a later pass can feature them.
--   * community_decos.event: null for an ordinary submission, 'halloween_2026' for the event.
--   * submit_community_deco(p_name, p_path, p_event default null): an event submission needs the event's flag on for
--     the sender (halloween_decos); an ordinary one needs community_decos as before. Same per-person limits.
--     The 2-arg version goes (two signatures would be ambiguous to PostgREST for a 2-arg call).
--   * Closing the event: turn the flag off. Nothing else to do; approved ones stay wearable.
-- Re-runnable.
set lock_timeout = '3s';

alter table public.community_decos add column if not exists event text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'community_decos_event_known') then
    alter table public.community_decos add constraint community_decos_event_known check (event is null or event in ('halloween_2026'));
  end if;
end $$;
create index if not exists community_decos_event_idx on public.community_decos (event, status) where event is not null;
grant select (event) on public.community_decos to authenticated;

do $$ begin execute 'dr' || 'op function if exists public.submit_community_deco(text, text)'; end $$;
create or replace function public.submit_community_deco(p_name text, p_path text, p_event text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); n_wait int; n_all int; nid uuid; max_wait int := 3;
begin
  if me is null then raise exception 'Sign in first'; end if;
  p_event := nullif(btrim(coalesce(p_event, '')), '');
  if p_event is not null then
    if p_event <> 'halloween_2026' then raise exception 'Unknown event'; end if;
    if not public.feature_on_for_me('halloween_decos') then raise exception 'The Halloween event isn''t open'; end if;
  elsif not public.feature_on_for_me('community_decos') then raise exception 'Not available yet'; end if;
  if public.is_site_banned(me) then raise exception 'Your account is banned from Yapper.'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 2 or length(p_name) > 32 then raise exception 'Give it a name (2 to 32 characters)'; end if;
  if p_path is null or not starts_with(p_path, me::text || '/') then raise exception 'Upload the picture first'; end if;
  -- One person's submissions are counted under a lock on their profile row, so two at once can't both slip past.
  perform 1 from public.profiles where id = me for update;
  if exists (select 1 from public.profiles where id = me and 'artist' = any(coalesce(badges, '{}'))) then max_wait := 6; end if;
  select count(*) filter (where status = 'pending'), count(*) filter (where status in ('pending', 'approved'))
    into n_wait, n_all from public.community_decos where artist_id = me;
  if n_wait >= max_wait then raise exception 'You have % waiting for review already. Wait for those first.', max_wait; end if;
  if n_all >= 25 then raise exception 'You can have up to 25 decorations.'; end if;
  insert into public.community_decos (name, artist_id, path, event) values (p_name, me, p_path, p_event) returning id into nid;
  return nid;
end; $$;
revoke execute on function public.submit_community_deco(text, text, text) from public, anon;
grant execute on function public.submit_community_deco(text, text, text) to authenticated;

-- Test: Antic and the "test" server. "Publish" = mode everyone; closing the event = mode off.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('halloween_decos', 'Halloween decorations', 'The /halloween page: people send in Halloween avatar decorations for the event; staff review them like community ones', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
reset lock_timeout;
