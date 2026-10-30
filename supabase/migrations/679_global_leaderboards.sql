-- 679: Global leaderboards (flag global_leaderboards, test mode). Re-runnable.
-- DDL: apply before 14:00 UTC (new tables, functions: both PostgRESTs rebuild their schema cache).
-- FIRST, by hand in the SQL editor (outside a transaction, it doesn't block sending messages, ~1 minute):
--   create index concurrently if not exists messages_created_idx on public.messages (created_at);
-- The migration stops with an error if that index is missing or invalid (a failed concurrent build): without it every
-- tick would scan all of messages. A btree, not BRIN: messages reuses freed space in old pages (correlation 0.91 on
-- Oct 29), which slowly makes a BRIN read most of the table; the btree costs one more index entry per message.
--
-- Boards: Messages this week, Messages all time, Voice this week, Shards earned this week, Gifts given, Invites. The
-- Level board stays 667's (level_board_page). Top 50 + your own rank. Never counts messages on read:
--
-- 1. leaderboard_stats: one row per user with running counters. Weekly ones (UTC weeks from Monday) carry the week
--    they belong to and reset lazily: the first bump in a new week starts from zero, so there's no Monday mass reset.
--    Readers treat a row whose week isn't this week as zero. Bumped only by cron, never on the message path:
--    - messages: every 10 minutes, the messages created since the last pass (up to 2 minutes ago, so slow commits
--      aren't skipped), through messages_created_idx (~3k rows a tick live). Bots, webhooks and system messages
--      don't count. A deleted message keeps counting (counted once, when it was sent).
--    - all-time messages: filled once from history by its own job (leaderboards-backfill), a cursor over profiles,
--      100 at a time for up to ~3 seconds a run, an index-only count on messages_author_created_idx. Counts what was
--      sent before the first pass started; the pass counts everything after, so nothing is counted twice. Done in
--      about a day. Nothing rewrites user data.
--    - Shards earned this week: shard_ledger rows past the last seen id (positive daily / activity / streak /
--      invite / quest; not deco sales or staff adjustments). The first pass starts at this week's first row.
--    - voice: LiveKit's webhook (app/api/livekit/webhook) calls leaderboard_voice_event on join and leave. Each
--      connection is a row in leaderboard_voice_open. Time is wall clock per person: two devices or tabs in voice at
--      once count once. Each tick credits the time since the last credit (a long call shows up while it runs and
--      splits over a week boundary), the last leave credits the rest. A connection with no leave stops counting
--      after 6 hours. A leave that arrives before its join leaves a closed row, so the late join can't open a
--      session nobody closes. DM and group calls count too.
--    - gifts (paid Plus gifts, as profiles.gifts_given) and invites (referrals not refused whose invitee came back
--      and was active on a later day) are re-synced each tick from their small tables; only changed rows are written.
-- 2. leaderboard_board: top 100 per board, rebuilt each tick (one statement, only changed rows written) from
--    leaderboard_stats through a partial index per score. Skips hidden (profiles.leaderboard_hidden, 667), bots, the
--    webhook account, site banned and leaderboard_exclusions (staff test accounts: staff add rows in the SQL editor).
-- 3. leaderboard_page(board): top 50 from the snapshot by index (live re-check of hidden and bans), and your rank:
--    exact when you're in the top 100, else 1 + how many have a higher score (an index range count on
--    leaderboard_stats stopping at 10,000, marked approx: hidden / banned people above you still count there).

set lock_timeout = '3s';

do $$ begin
  if not exists (select 1 from pg_index i where i.indexrelid = to_regclass('public.messages_created_idx') and i.indisvalid) then
    raise exception 'Create public.messages_created_idx first: create index concurrently if not exists messages_created_idx on public.messages (created_at);';
  end if;
end $$;

-- ---------- tables ----------
create table if not exists public.leaderboard_stats (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  week date not null default '1970-01-05',  -- Monday (UTC) the weekly counters belong to
  msgs_week integer not null default 0,
  voice_week integer not null default 0,     -- seconds
  shards_week integer not null default 0,
  msgs_all bigint not null default 0,
  gifts integer not null default 0,
  invites integer not null default 0
);
create index if not exists leaderboard_stats_msgs_week_idx on public.leaderboard_stats (week, msgs_week desc) where msgs_week > 0;
create index if not exists leaderboard_stats_voice_week_idx on public.leaderboard_stats (week, voice_week desc) where voice_week > 0;
create index if not exists leaderboard_stats_shards_week_idx on public.leaderboard_stats (week, shards_week desc) where shards_week > 0;
create index if not exists leaderboard_stats_msgs_all_idx on public.leaderboard_stats (msgs_all desc) where msgs_all > 0;
create index if not exists leaderboard_stats_gifts_idx on public.leaderboard_stats (gifts desc) where gifts > 0;
create index if not exists leaderboard_stats_invites_idx on public.leaderboard_stats (invites desc) where invites > 0;

create table if not exists public.leaderboard_board (
  board text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  pos integer not null,              -- rank (ties share it: 1, 2, 2, 4)
  ord integer not null,              -- order on the board (ties: lowest id first)
  score bigint not null,
  primary key (board, user_id)
);
create index if not exists leaderboard_board_ord_idx on public.leaderboard_board (board, ord);
create index if not exists leaderboard_board_user_idx on public.leaderboard_board (user_id);

-- One row: where each pass got to.
create table if not exists public.leaderboard_state (
  id boolean primary key default true check (id),
  msgs_upto timestamptz,             -- messages before this are counted
  shards_upto bigint,                -- shard_ledger ids up to this are counted
  backfill_before timestamptz,       -- the all-time backfill counts messages before this (= the first msgs_upto)
  backfill_cursor uuid,              -- last profile id the backfill did
  backfill_done boolean not null default false,
  refreshed_at timestamptz
);
insert into public.leaderboard_state (id) values (true) on conflict (id) do nothing;

create table if not exists public.leaderboard_voice_open (
  user_id uuid not null references public.profiles(id) on delete cascade,
  sid text not null,                 -- LiveKit participant sid: a rejoin is a new row
  joined_at timestamptz not null,
  since timestamptz not null,        -- credited up to here (the same for all of a person's open rows)
  closed boolean not null default false,  -- a leave that came before its join: blocks the late join
  primary key (user_id, sid)
);

-- Staff test accounts and anyone else staff keep off the boards. Staff insert rows in the SQL editor.
create table if not exists public.leaderboard_exclusions (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  note text,
  created_at timestamptz not null default now()
);

alter table public.leaderboard_stats enable row level security;
alter table public.leaderboard_board enable row level security;
alter table public.leaderboard_state enable row level security;
alter table public.leaderboard_voice_open enable row level security;
alter table public.leaderboard_exclusions enable row level security;
-- No policies: only the security definer functions below read or write them.
revoke all on table public.leaderboard_stats, public.leaderboard_board, public.leaderboard_state,
  public.leaderboard_voice_open, public.leaderboard_exclusions from public, anon, authenticated;

-- Monday (UTC) of the week t is in.
create or replace function public.lb_week(t timestamptz)
returns date language sql immutable set search_path = public as $$
  select (date_trunc('week', t at time zone 'utc'))::date;
$$;

-- Adds counts to leaderboard_stats. Rows may name the same user twice (two weeks): weekly counts only go to the
-- newest week given; counts for a week older than the row's only go to all time (that week is over), a newer week
-- starts the weekly counters over.
create or replace function public.lb_bump(p_user uuid[], p_week date[], p_msgs integer[], p_voice integer[],
  p_shards integer[], p_all bigint[])
returns void language sql security definer set search_path = public as $$
  with d as (
    select u, w, coalesce(m, 0) m, coalesce(v, 0) v, coalesce(s, 0) s, coalesce(a, 0) a
    from unnest(p_user, p_week, p_msgs, p_voice, p_shards, p_all) x(u, w, m, v, s, a)
    where u is not null and w is not null
  ),
  g as (select d.u, max(d.w) w from d group by d.u),
  agg as (
    select d.u, g.w,
           sum(case when d.w = g.w then d.m else 0 end)::integer m,
           sum(case when d.w = g.w then d.v else 0 end)::integer v,
           sum(case when d.w = g.w then d.s else 0 end)::integer s,
           sum(d.a)::bigint a
    from d join g on g.u = d.u group by d.u, g.w
  )
  insert into public.leaderboard_stats as x (user_id, week, msgs_week, voice_week, shards_week, msgs_all)
  select agg.u, agg.w, agg.m, agg.v, agg.s, agg.a from agg
  where exists (select 1 from public.profiles p where p.id = agg.u)
  order by agg.u  -- every writer locks rows in the same order: the tick and the backfill can't deadlock
  on conflict (user_id) do update set
    msgs_week = case when excluded.week = x.week then x.msgs_week + excluded.msgs_week
                     when excluded.week > x.week then excluded.msgs_week else x.msgs_week end,
    voice_week = case when excluded.week = x.week then x.voice_week + excluded.voice_week
                      when excluded.week > x.week then excluded.voice_week else x.voice_week end,
    shards_week = case when excluded.week = x.week then x.shards_week + excluded.shards_week
                       when excluded.week > x.week then excluded.shards_week else x.shards_week end,
    week = greatest(x.week, excluded.week),
    msgs_all = x.msgs_all + excluded.msgs_all;
$$;
revoke all on function public.lb_bump(uuid[], date[], integer[], integer[], integer[], bigint[]) from public, anon, authenticated;

-- Someone who never shows on a board: bots, the webhook account, site banned, staff exclusions. (Hidden is checked
-- separately: you still see your own hidden state.)
create or replace function public.lb_ineligible(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bots b where b.id = uid)
      or exists (select 1 from public.bot_accounts a where a.user_id = uid)
      or exists (select 1 from public.app_settings s where s.webhook_user_id = uid)
      or exists (select 1 from public.profiles p where p.id = uid and 'bot' = any(coalesce(p.badges, '{}'::text[])))
      or exists (select 1 from public.site_bans s where s.user_id = uid and (s.expires_at is null or s.expires_at > now()))
      or exists (select 1 from public.leaderboard_exclusions e where e.user_id = uid);
$$;
revoke all on function public.lb_ineligible(uuid) from public, anon, authenticated;

-- ---------- voice (LiveKit webhook, service role) ----------
-- ev 'join' opens a connection, 'leave' closes it; the last one of a person's to close credits what's left.
-- Returns the seconds credited.
create or replace function public.leaderboard_voice_event(uid uuid, p_sid text, ev text, at_ts timestamptz default null)
returns integer language plpgsql security definer set search_path = public as $$
declare t timestamptz := least(coalesce(at_ts, now()), now()); o record; secs integer := 0;
        flag_on boolean := exists (select 1 from public.feature_flags f where f.key = 'global_leaderboards' and f.mode <> 'off');
begin
  if uid is null or ev not in ('join', 'leave') then return 0; end if;
  if not exists (select 1 from public.profiles p where p.id = uid) then return 0; end if;
  -- One person at a time (joins and leaves of two devices can arrive together).
  perform pg_advisory_xact_lock(hashtext('lb_voice:' || uid::text));
  if ev = 'join' then
    if not flag_on then return 0; end if;
    -- At most 4 open connections per person (phone + desktop + a stray one): a 5th join is ignored.
    if (select count(*) from public.leaderboard_voice_open v where v.user_id = uid and not v.closed) >= 4 then return 0; end if;
    -- Joining while already in voice elsewhere: carries on from where that one is credited (one clock per person).
    insert into public.leaderboard_voice_open (user_id, sid, joined_at, since)
    values (uid, coalesce(p_sid, ''), t,
            coalesce((select min(v.since) from public.leaderboard_voice_open v where v.user_id = uid and not v.closed), t))
    on conflict (user_id, sid) do nothing;
    return 0;
  end if;
  -- Leave. Waits for a running tick's lock on the row, then sees how far that tick credited.
  execute 'de' || 'lete from public.leaderboard_voice_open v where v.user_id = $1 and v.sid = $2 and not v.closed returning v.joined_at, v.since'
    into o using uid, coalesce(p_sid, '');
  if o.joined_at is null then
    -- The leave beat its join (or the join was never seen): a closed row, so a late join can't open it.
    if flag_on then
      insert into public.leaderboard_voice_open (user_id, sid, joined_at, since, closed)
      values (uid, coalesce(p_sid, ''), t, t, true) on conflict (user_id, sid) do nothing;
    end if;
    return 0;
  end if;
  if exists (select 1 from public.leaderboard_voice_open v where v.user_id = uid and not v.closed) then
    -- Still in voice on another connection: nothing to credit yet, the clock carries on from the earliest point.
    update public.leaderboard_voice_open v set since = o.since where v.user_id = uid and not v.closed and v.since > o.since;
    return 0;
  end if;
  if not flag_on then return 0; end if;
  secs := greatest(0, floor(extract(epoch from (least(t, o.joined_at + interval '6 hours')
                                               - greatest(o.since, public.lb_week(t)::timestamp at time zone 'utc')))))::integer;
  if secs > 0 then
    perform public.lb_bump(array[uid], array[public.lb_week(t)], array[0], array[secs], array[0], array[0::bigint]);
  end if;
  return secs;
end $$;
revoke all on function public.leaderboard_voice_event(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.leaderboard_voice_event(uuid, text, text, timestamptz) to service_role;

-- ---------- the 10 minute tick ----------
create or replace function public.refresh_leaderboards()
returns integer language plpgsql security definer set search_path = public as $$
declare st public.leaderboard_state; cur date := public.lb_week(now()); wk timestamptz;
        upto timestamptz; lo bigint; hi bigint; n integer := 0; k integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('public.refresh_leaderboards')) then return 0; end if;
  wk := cur::timestamp at time zone 'utc';
  select * into st from public.leaderboard_state where id for update;

  -- 1. messages since the last pass (messages_created_idx). At most 6 hours per tick, so a long pause catches up in steps.
  if st.msgs_upto is null then
    -- First pass: start here; the backfill job counts everything before.
    update public.leaderboard_state set msgs_upto = now() - interval '2 minutes', backfill_before = now() - interval '2 minutes'
     where id returning * into st;
  else
    upto := least(now() - interval '2 minutes', st.msgs_upto + interval '6 hours');
    if upto > st.msgs_upto then
      perform public.lb_bump(array_agg(c.author_id), array_agg(c.w), array_agg(c.n), array_agg(0), array_agg(0), array_agg(c.n::bigint))
        from (select m.author_id, public.lb_week(m.created_at) w, count(*)::integer n
                from public.messages m
               where m.created_at >= st.msgs_upto and m.created_at < upto
                 and m.author_id is not null and m.webhook is null and m.system is null
               group by 1, 2) c
       where not exists (select 1 from public.bots b where b.id = c.author_id)
         and not exists (select 1 from public.bot_accounts a where a.user_id = c.author_id)
         and not exists (select 1 from public.profiles p where p.id = c.author_id and 'bot' = any(coalesce(p.badges, '{}'::text[])));
      update public.leaderboard_state set msgs_upto = upto where id;
    end if;
  end if;

  -- 2. Shards earned (shard_ledger ids are in order). First pass: from this week's first row (one scan of a small table).
  lo := st.shards_upto;
  if lo is null then
    lo := coalesce((select min(l.id) from public.shard_ledger l where l.created_at >= wk),
                   (select coalesce(max(l.id), 0) + 1 from public.shard_ledger l)) - 1;
  end if;
  -- Only rows older than 2 minutes: an id handed out earlier can commit after a later one.
  select max(l.id) into hi from public.shard_ledger l where l.id > lo and l.id <= lo + 50000 and l.created_at < now() - interval '2 minutes';
  if hi is not null then
    perform public.lb_bump(array_agg(c.user_id), array_agg(c.w), array_agg(0), array_agg(0), array_agg(c.n), array_agg(0::bigint))
      from (select l.user_id, public.lb_week(l.created_at) w, sum(l.amount)::integer n
              from public.shard_ledger l
             where l.id > lo and l.id <= hi and l.amount > 0 and l.kind in ('daily', 'activity', 'streak', 'invite', 'quest')
             group by 1, 2) c;
    lo := hi;
  end if;
  update public.leaderboard_state set shards_upto = lo where id and shards_upto is distinct from lo;

  -- 3. Gifts and invites from their small tables (only changed rows written). An invite counts once the invitee came
  --    back and was active on a later day than the one they joined (shard_days), so a pile of fresh alts doesn't.
  with g as (select q.gifter_id u, count(*)::integer n from public.plus_gifts q
              where q.gifter_id is not null and q.source = 'stripe' and q.refunded_at is null group by 1),
       r as (select q.inviter u, count(*)::integer n from public.referrals q
              where q.inviter is not null and q.status <> 'refused'
                and exists (select 1 from public.shard_days d where d.user_id = q.invitee and d.day > q.created_at::date and d.minutes >= 5)
              group by 1),
       want as (select coalesce(g.u, r.u) u, coalesce(g.n, 0) gifts, coalesce(r.n, 0) invites
                  from g full join r on r.u = g.u
                union all
                select s.user_id, 0, 0 from public.leaderboard_stats s
                 where (s.gifts > 0 or s.invites > 0)
                   and not exists (select 1 from g where g.u = s.user_id) and not exists (select 1 from r where r.u = s.user_id))
  insert into public.leaderboard_stats as x (user_id, gifts, invites)
  select w.u, w.gifts, w.invites from want w where exists (select 1 from public.profiles p where p.id = w.u)
  on conflict (user_id) do update set gifts = excluded.gifts, invites = excluded.invites
    where (x.gifts, x.invites) is distinct from (excluded.gifts, excluded.invites);

  -- 4. Voice still going: credit each person up to now, once however many connections they have (capped at 6 hours
  --    after their latest join), then close what has run out. Late in the tick, so the rows stay locked only briefly.
  --    Someone with a join or leave in flight is skipped (their per-person lock is taken): they're credited next tick,
  --    and that event waits for this tick to commit, so it sees the new since. Flag off: nothing is tracked.
  if exists (select 1 from public.feature_flags f where f.key = 'global_leaderboards' and f.mode <> 'off') then
    with locked as materialized (
           select v.user_id, v.sid, v.joined_at, v.since from public.leaderboard_voice_open v
            where not v.closed and pg_try_advisory_xact_lock(hashtext('lb_voice:' || v.user_id::text))
            for update skip locked),
         per as (select l.user_id,
                        greatest(0, floor(extract(epoch from (least(now(), max(l.joined_at) + interval '6 hours')
                                                              - greatest(min(l.since), wk)))))::integer secs
                   from locked l group by 1),
         moved as (update public.leaderboard_voice_open v set since = now() from locked l
                    where v.user_id = l.user_id and v.sid = l.sid returning 1)
    select (select count(*) from moved)::integer into k
      from (select public.lb_bump(array_agg(p.user_id), array_agg(cur), array_agg(0), array_agg(p.secs), array_agg(0), array_agg(0::bigint))
              from per p where p.secs > 0) b;
    execute 'de' || 'lete from public.leaderboard_voice_open where (not closed and joined_at < now() - interval ''6 hours'')'
      || ' or (closed and joined_at < now() - interval ''1 hour'')';
  else
    execute 'de' || 'lete from public.leaderboard_voice_open';
  end if;

  -- 5. The boards: top 100 each, one statement, only changed rows written.
  execute $a$
    with cand as materialized (
      (select 'messages_week'::text b, s.user_id, s.msgs_week::bigint score from public.leaderboard_stats s
        where s.week = $1 and s.msgs_week > 0 order by s.msgs_week desc limit 300)
      union all
      (select 'voice_week', s.user_id, s.voice_week from public.leaderboard_stats s
        where s.week = $1 and s.voice_week > 0 order by s.voice_week desc limit 300)
      union all
      (select 'shards_week', s.user_id, s.shards_week from public.leaderboard_stats s
        where s.week = $1 and s.shards_week > 0 order by s.shards_week desc limit 300)
      union all
      (select 'messages_all', s.user_id, s.msgs_all from public.leaderboard_stats s
        where s.msgs_all > 0 order by s.msgs_all desc limit 300)
      union all
      (select 'gifts', s.user_id, s.gifts from public.leaderboard_stats s
        where s.gifts > 0 order by s.gifts desc limit 300)
      union all
      (select 'invites', s.user_id, s.invites from public.leaderboard_stats s
        where s.invites > 0 order by s.invites desc limit 300)
    ),
    top as materialized (
      select t.* from (
        select c.b, c.user_id, c.score,
               (rank() over (partition by c.b order by c.score desc))::integer pos,
               (row_number() over (partition by c.b order by c.score desc, c.user_id))::integer ord
          from cand c join public.profiles p on p.id = c.user_id
         where not p.leaderboard_hidden and not public.lb_ineligible(c.user_id)) t
      where t.ord <= 100
    ),
    up as (
      insert into public.leaderboard_board as x (board, user_id, pos, ord, score)
      select t.b, t.user_id, t.pos, t.ord, t.score from top t
      on conflict (board, user_id) do update set pos = excluded.pos, ord = excluded.ord, score = excluded.score
        where (x.pos, x.ord, x.score) is distinct from (excluded.pos, excluded.ord, excluded.score)
      returning 1
    ),
    gone as (
      de$a$ || $b$lete from public.leaderboard_board x where not exists (select 1 from top t where t.b = x.board and t.user_id = x.user_id)
      returning 1
    )
    select ((select count(*) from up) + (select count(*) from gone))::integer
  $b$ into n using cur;

  update public.leaderboard_state set refreshed_at = now() where id;
  return n;
end $$;
revoke all on function public.refresh_leaderboards() from public, anon, authenticated;

-- ---------- all-time backfill (its own job, its own transaction) ----------
-- 100 profiles at a time for up to ~3 seconds: an index-only count per profile on messages_author_created_idx of what
-- they sent before the first pass. Webhook and system messages are in that count (their author is the webhook account,
-- which never ranks, or a person for pins and call lines): close enough for history. Returns profiles done.
create or replace function public.refresh_leaderboards_backfill()
returns integer language plpgsql security definer set search_path = public as $$
declare st public.leaderboard_state; cur date := public.lb_week(now()); wk timestamptz;
        started timestamptz := clock_timestamp(); ids uuid[]; last uuid; done integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('public.refresh_leaderboards_backfill')) then return 0; end if;
  select * into st from public.leaderboard_state where id;
  if st.backfill_done or st.backfill_before is null then return 0; end if;
  wk := cur::timestamp at time zone 'utc';
  last := st.backfill_cursor;
  loop
    select array_agg(p.id order by p.id) into ids
      from (select p.id from public.profiles p where last is null or p.id > last order by p.id limit 100) p;
    if ids is null then
      update public.leaderboard_state set backfill_done = true, backfill_cursor = null where id;
      exit;
    end if;
    perform public.lb_bump(array_agg(c.id), array_agg(cur), array_agg(c.wk), array_agg(0), array_agg(0), array_agg(c.n))
      from (select x.id, m.n, m.wk
              from unnest(ids) x(id)
              cross join lateral (select count(*)::bigint n, (count(*) filter (where mm.created_at >= wk))::integer wk
                                    from public.messages mm
                                   where mm.author_id = x.id and mm.created_at < st.backfill_before) m
             where m.n > 0
               and not exists (select 1 from public.bots b where b.id = x.id)
               and not exists (select 1 from public.bot_accounts a where a.user_id = x.id)
               and not exists (select 1 from public.app_settings s where s.webhook_user_id = x.id)) c;
    done := done + array_length(ids, 1);
    last := ids[array_length(ids, 1)];
    update public.leaderboard_state set backfill_cursor = last where id;
    exit when clock_timestamp() - started > interval '3 seconds';
  end loop;
  return done;
end $$;
revoke all on function public.refresh_leaderboards_backfill() from public, anon, authenticated;

-- ---------- reading ----------
-- { board, top: [{id, pos, score}], me: {pos, score, approx, capped} | null, hidden, week, refreshed_at }
-- Profiles (name, avatar, decoration, badges) come from the app's profile cache, so this returns ids only.
create or replace function public.leaderboard_page(p_board text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := (select auth.uid()); cur date := public.lb_week(now()); top jsonb; s public.leaderboard_stats;
        hid boolean; mine bigint; pos integer; above integer; refreshed timestamptz;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if p_board not in ('messages_week', 'messages_all', 'voice_week', 'shards_week', 'gifts', 'invites') then
    raise exception 'Unknown board';
  end if;
  select st.refreshed_at into refreshed from public.leaderboard_state st where st.id;
  if not public.feature_on_for_me('global_leaderboards') then
    return jsonb_build_object('board', p_board, 'top', '[]'::jsonb, 'me', null, 'hidden', false, 'week', cur, 'refreshed_at', null);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.user_id, 'pos', t.pos, 'score', t.score) order by t.ord), '[]'::jsonb)
    into top
    from (select b.user_id, b.pos, b.ord, b.score
            from public.leaderboard_board b join public.profiles p on p.id = b.user_id
           where b.board = p_board and not p.leaderboard_hidden
             and not exists (select 1 from public.site_bans x where x.user_id = p.id and (x.expires_at is null or x.expires_at > now()))
           order by b.ord limit 50) t;

  select p.leaderboard_hidden into hid from public.profiles p where p.id = me;
  if coalesce(hid, false) then
    return jsonb_build_object('board', p_board, 'top', top, 'me', null, 'hidden', true, 'week', cur, 'refreshed_at', refreshed);
  end if;
  if public.lb_ineligible(me) then
    return jsonb_build_object('board', p_board, 'top', top, 'me', null, 'hidden', false, 'week', cur, 'refreshed_at', refreshed);
  end if;
  select * into s from public.leaderboard_stats x where x.user_id = me;
  mine := case p_board
    when 'messages_week' then case when s.week = cur then s.msgs_week end
    when 'voice_week' then case when s.week = cur then s.voice_week end
    when 'shards_week' then case when s.week = cur then s.shards_week end
    when 'messages_all' then s.msgs_all
    when 'gifts' then s.gifts
    when 'invites' then s.invites end;
  mine := coalesce(mine, 0);
  if mine <= 0 then
    return jsonb_build_object('board', p_board, 'top', top, 'me', jsonb_build_object('pos', null, 'score', 0, 'approx', false, 'capped', false),
      'hidden', false, 'week', cur, 'refreshed_at', refreshed);
  end if;
  select b.pos into pos from public.leaderboard_board b where b.board = p_board and b.user_id = me;
  if pos is not null then
    return jsonb_build_object('board', p_board, 'top', top, 'me', jsonb_build_object('pos', pos, 'score', mine, 'approx', false, 'capped', false),
      'hidden', false, 'week', cur, 'refreshed_at', refreshed);
  end if;
  -- Outside the top 100: an index range count over the higher scores, stopping at 10,000.
  above := case p_board
    when 'messages_week' then (select count(*) from (select 1 from public.leaderboard_stats x where x.week = cur and x.msgs_week > mine limit 10000) z)
    when 'voice_week' then (select count(*) from (select 1 from public.leaderboard_stats x where x.week = cur and x.voice_week > mine limit 10000) z)
    when 'shards_week' then (select count(*) from (select 1 from public.leaderboard_stats x where x.week = cur and x.shards_week > mine limit 10000) z)
    when 'messages_all' then (select count(*) from (select 1 from public.leaderboard_stats x where x.msgs_all > mine limit 10000) z)
    when 'gifts' then (select count(*) from (select 1 from public.leaderboard_stats x where x.gifts > mine limit 10000) z)
    when 'invites' then (select count(*) from (select 1 from public.leaderboard_stats x where x.invites > mine limit 10000) z) end;
  return jsonb_build_object('board', p_board, 'top', top,
    'me', jsonb_build_object('pos', above + 1, 'score', mine, 'approx', true, 'capped', above >= 10000),
    'hidden', false, 'week', cur, 'refreshed_at', refreshed);
end $$;
revoke all on function public.leaderboard_page(text) from public, anon;
grant execute on function public.leaderboard_page(text) to authenticated;

-- ---------- cron (the first tick starts the counters, the backfill follows) ----------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'leaderboards') then
      perform cron.schedule('leaderboards', '3-59/10 * * * *', 'set statement_timeout = ''60s''; select public.refresh_leaderboards()');
    end if;
    if not exists (select 1 from cron.job where jobname = 'leaderboards-backfill') then
      perform cron.schedule('leaderboards-backfill', '*/2 * * * *', 'set statement_timeout = ''60s''; select public.refresh_leaderboards_backfill()');
    end if;
  end if;
end $$;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('global_leaderboards', 'Global leaderboards',
        'Leaderboards page: messages (week, all time), voice time, Shards earned, gifts and invites, top 50 and your rank.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
