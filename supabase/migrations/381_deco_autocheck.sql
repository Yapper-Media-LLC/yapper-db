-- 381: automatic "is this decoration stolen?" check for community decorations (flag deco_autocheck, test).
-- After a decoration or effect is sent in (and once for the ones already there), the server compares it with earlier
-- uploads by other artists (media_scans.phash) and asks Claude whether it looks ripped from Discord's shop, another
-- app, a known character or brand, the internet, or another Yapper artist (lib/server/decoCheck.ts). Suspect and
-- stolen ones show in Mod Center -> Decorations -> Flagged; approving one needs a staff note first ("cleared").
-- Results are staff-only: no grants to anon/authenticated, staff read them through staff_flagged_decos().
-- Spend is recorded per check so the server can stop at its daily and one-time limits.
-- Also schedules deco-checks-tick (every minute, same secret as 326) for missed checks and the one-time pass.
-- Re-runnable.

set lock_timeout = '5s';

create table if not exists public.community_deco_checks (
  deco_id uuid primary key references public.community_decos(id) on delete cascade,
  verdict text not null check (verdict in ('clean', 'suspect', 'stolen', 'error')),
  source text not null default 'none'
    check (source in ('none', 'discord', 'other_app', 'character_or_brand', 'internet', 'yapper_copy', 'other')),
  confidence real not null default 0 check (confidence between 0 and 1),
  reason text not null default '' check (length(reason) <= 300),
  -- The earlier upload by another artist it copies, when that's what it is.
  match_id uuid references public.community_decos(id) on delete set null,
  model text not null default '' check (length(model) <= 60),
  cost_usd numeric(10, 6) not null default 0 check (cost_usd >= 0),
  -- Part of the one-time pass over decorations sent in before this existed (its own spending limit).
  backfill boolean not null default false,
  -- Tries so far: a check that keeps failing (timeouts still cost money) stops after 3.
  attempts int not null default 1,
  checked_at timestamptz not null default now(),
  cleared_by uuid references public.profiles(id) on delete set null,
  cleared_at timestamptz,
  cleared_note text not null default '' check (length(cleared_note) <= 300)
);
create index if not exists community_deco_checks_match_idx on public.community_deco_checks (match_id) where match_id is not null;
create index if not exists community_deco_checks_cleared_by_idx on public.community_deco_checks (cleared_by) where cleared_by is not null;
create index if not exists community_deco_checks_open_idx on public.community_deco_checks (checked_at)
  where verdict in ('suspect', 'stolen') and cleared_at is null;
create index if not exists community_deco_checks_spend_idx on public.community_deco_checks (backfill, checked_at);

alter table public.community_deco_checks enable row level security;
revoke all on public.community_deco_checks from anon, authenticated;

-- ---------- server side (service role only) ----------

-- New uploads an artist can have checked a day: sending one in, withdrawing it and sending it again would otherwise
-- spend the whole day's limit and leave everyone else's unchecked. Past it, theirs wait for the next day.
create or replace function public.deco_artist_checks_today(p_artist uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.community_deco_checks c join public.community_decos d on d.id = c.deco_id
  where d.artist_id = p_artist and not c.backfill and c.checked_at > now() - interval '24 hours';
$$;

-- Claim a decoration for checking, so the submit hook and the cron never pay twice for the same one. Takes it when it
-- was never checked, or when its last try failed more than 6 hours ago (3 tries at most). Not when the artist already
-- had 8 new ones checked today. The placeholder row reads 'error' until done.
create or replace function public.deco_check_claim(p_id uuid, p_backfill boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare got int; who uuid;
begin
  select artist_id into who from public.community_decos where id = p_id;
  if who is null then return false; end if;
  if not p_backfill and public.deco_artist_checks_today(who) >= 8 then return false; end if;
  insert into public.community_deco_checks (deco_id, verdict, reason, backfill)
    values (p_id, 'error', 'Checking', p_backfill)
    on conflict (deco_id) do nothing;
  get diagnostics got = row_count;
  if got > 0 then return true; end if;
  update public.community_deco_checks set checked_at = now(), reason = 'Checking', backfill = p_backfill, attempts = attempts + 1
    where deco_id = p_id and verdict = 'error' and checked_at < now() - interval '6 hours' and attempts < 3;
  get diagnostics got = row_count;
  return got > 0;
end; $$;

-- Earlier uploads by other artists whose first-frame hash (media_scans.phash) is within p_max_bits of this one,
-- nearest first. Near-blank hashes (almost all one colour) match everything, so those are skipped like nsfw_hash_hit.
create or replace function public.deco_lookalikes(p_id uuid, p_max_bits int default 6, p_limit int default 4)
returns table (id uuid, name text, path text, artist_id uuid, status text, bits int)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select d.artist_id, d.created_at, s.phash
    from public.community_decos d
    join public.media_scans s on s.bucket = 'avatars' and s.path = d.path
    where d.id = p_id and s.phash is not null and bit_count(s.phash::bit(64)) between 6 and 58
  )
  select o.id, o.name, o.path, o.artist_id, o.status, bit_count((s.phash # me.phash)::bit(64))::int as bits
  from me
  join public.community_decos o on o.artist_id <> me.artist_id and o.created_at < me.created_at
  join public.media_scans s on s.bucket = 'avatars' and s.path = o.path and s.phash is not null
  where bit_count((s.phash # me.phash)::bit(64)) <= least(greatest(p_max_bits, 0), 16)
  order by bits, o.created_at
  limit least(greatest(p_limit, 0), 8);
$$;

-- What the cron should check next: waiting ones first, then live ones, newest first. Not ones that failed 3 times, and
-- not new ones from an artist who is at today's limit (they'd only be refused and hold up the rest).
create or replace function public.deco_checks_todo(p_limit int default 6)
returns table (id uuid, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select d.id, d.created_at
  from public.community_decos d
  left join public.community_deco_checks c on c.deco_id = d.id
  where d.status in ('pending', 'approved')
    and (c.deco_id is null or (c.verdict = 'error' and c.checked_at < now() - interval '6 hours' and c.attempts < 3))
    and (d.status <> 'pending' or d.created_at < now() - interval '1 hour' or public.deco_artist_checks_today(d.artist_id) < 8)
  order by (d.status = 'pending') desc, d.created_at desc
  limit least(greatest(p_limit, 0), 50);
$$;

-- Money spent so far: new uploads in the last 24 hours, the one-time pass, and everything.
create or replace function public.deco_check_spend()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'day', coalesce(sum(cost_usd) filter (where not backfill and checked_at > now() - interval '24 hours'), 0),
    'backfill', coalesce(sum(cost_usd) filter (where backfill), 0),
    'total', coalesce(sum(cost_usd), 0))
  from public.community_deco_checks;
$$;

revoke all on function public.deco_artist_checks_today(uuid) from public, anon, authenticated;
revoke all on function public.deco_check_claim(uuid, boolean) from public, anon, authenticated;
revoke all on function public.deco_lookalikes(uuid, int, int) from public, anon, authenticated;
revoke all on function public.deco_checks_todo(int) from public, anon, authenticated;
revoke all on function public.deco_check_spend() from public, anon, authenticated;
grant execute on function public.deco_artist_checks_today(uuid) to service_role;
grant execute on function public.deco_check_claim(uuid, boolean) to service_role;
grant execute on function public.deco_lookalikes(uuid, int, int) to service_role;
grant execute on function public.deco_checks_todo(int) to service_role;
grant execute on function public.deco_check_spend() to service_role;

-- ---------- staff ----------

-- Flagged ones still waiting or live that nobody has cleared, worst first, with the earlier upload it looks copied from.
create or replace function public.staff_flagged_decos()
returns table (
  id uuid, kind text, name text, artist_id uuid, path text, status text, review_note text, created_at timestamptz,
  verdict text, source text, confidence real, reason text, checked_at timestamptz,
  match_id uuid, match_name text, match_path text, match_artist_id uuid, match_status text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  return query
    select d.id, d.kind, d.name, d.artist_id, d.path, d.status, d.review_note, d.created_at,
      c.verdict, c.source, c.confidence, c.reason, c.checked_at,
      m.id, m.name, m.path, m.artist_id, m.status
    from public.community_deco_checks c
    join public.community_decos d on d.id = c.deco_id
    left join public.community_decos m on m.id = c.match_id
    where c.verdict in ('suspect', 'stolen') and c.cleared_at is null and d.status in ('pending', 'approved')
    order by (c.verdict = 'stolen') desc, (d.status = 'pending') desc, c.confidence desc, d.created_at
    limit 200;
end; $$;

-- "It's fine": a staff member looked at a flagged one and says why. It leaves the Flagged tab and can be approved.
create or replace function public.staff_clear_deco_check(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos; got int;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if length(p_note) < 3 then raise exception 'Say why it''s fine (a few words)'; end if;
  select * into d from public.community_decos where id = p_id;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  update public.community_deco_checks set cleared_by = (select auth.uid()), cleared_at = now(), cleared_note = p_note
    where deco_id = p_id and verdict in ('suspect', 'stolen') and cleared_at is null;
  get diagnostics got = row_count;
  if got > 0 then
    insert into public.mod_log (actor, action, target_id, reason)
      values ((select auth.uid()), 'deco_check_cleared', d.artist_id, left(d.name || ': ' || p_note, 300));
  end if;
end; $$;

revoke all on function public.staff_flagged_decos() from public, anon;
revoke all on function public.staff_clear_deco_check(uuid, text) from public, anon;
grant execute on function public.staff_flagged_decos() to authenticated;
grant execute on function public.staff_clear_deco_check(uuid, text) to authenticated;

-- 360's text (live Oct 22); a flagged one can't be approved until someone clears it with a note.
create or replace function public.review_community_deco(p_id uuid, p_status text, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos; got int;
begin
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Staff only'; end if;
  if p_status not in ('approved', 'rejected', 'removed') then raise exception 'Bad status'; end if;
  p_note := left(btrim(coalesce(p_note, '')), 300);
  if p_status <> 'approved' and length(p_note) < 3 then raise exception 'Say why, so they know what to change'; end if;
  select * into d from public.community_decos where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if d.artist_id = (select auth.uid()) then raise exception 'Someone else has to review your own'; end if;
  if d.status = 'removed' then raise exception 'That one was taken down'; end if;
  if p_status = 'approved' and not public.media_ok('avatars', d.path) then raise exception 'Its picture didn''t pass the check'; end if;
  if p_status = 'approved' and exists (select 1 from public.community_deco_checks c
      where c.deco_id = p_id and c.verdict in ('suspect', 'stolen') and c.cleared_at is null) then
    raise exception 'The auto-check flagged this one. Say why it''s fine first';
  end if;
  update public.community_decos set status = p_status, review_note = p_note, reviewed_by = (select auth.uid()), reviewed_at = now()
    where id = p_id;
  if d.status = 'approved' and p_status <> 'approved' then perform public.community_deco_unwear(d.path); end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values ((select auth.uid()), 'deco_' || p_status, d.artist_id, left(d.name || case when p_note <> '' then ': ' || p_note else '' end, 300));
  if p_status = 'approved' and d.status <> 'approved' and not public.is_site_banned(d.artist_id) then
    begin
      update public.profiles set badges = array_append(coalesce(badges, '{}'), 'artist')
        where id = d.artist_id and not ('artist' = any(coalesce(badges, '{}')));
      get diagnostics got = row_count;
      if got > 0 then
        insert into public.mod_log (actor, action, target_id, reason) values ((select auth.uid()), 'badge_auto', d.artist_id, 'artist');
        perform public.rt_profile_changed(array[d.artist_id]);
      end if;
    exception when others then
      raise warning 'review_community_deco: artist badge for % not given: %', d.artist_id, sqlerrm;
    end;
  end if;
end; $$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_autocheck', 'Decorations: stolen art check', 'Checks community decorations for stolen art and puts suspicious ones in a Flagged tab for staff.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

-- Every minute: missed checks and the one-time pass (the route answers at once when there's nothing to do or the flag
-- is off). Remove with select cron.unschedule('deco-checks-tick').
do $$ begin
  -- Nested: plpgsql plans a whole condition at once, and cron.job doesn't exist everywhere (local tests).
  if to_regclass('cron.job') is not null then
  if not exists (select 1 from cron.job where jobname = 'deco-checks-tick') then
    perform cron.schedule('deco-checks-tick', '* * * * *', $job$
      select net.http_post(
        url := 'https://www.yapper.website/api/cron/deco-checks',
        body := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
          'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1)),
        timeout_milliseconds := 60000)
      where exists (select 1 from vault.decrypted_secrets where name = 'request_limits_secret')
    $job$);
  end if;
  end if;
end $$;

reset lock_timeout;
