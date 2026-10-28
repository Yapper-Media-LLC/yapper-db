-- 249: server watch flagged servers for their own rules ("No NSFW", "no porn", "18+ content is not allowed"): the
-- scan matched the words with nothing looking at what's around them (156 hit the same thing for spam).
-- server_watch_unneg() cuts out negated mentions after the cheap LIKE prefilter, before the regex: sentences and list
-- lines that start with "no" / "don't" / "never", "X is not allowed / banned", "banned: ..." lists, and mid-sentence
-- "no X" with only filler words or list items in between. Anything else still counts: "nsfw allowed", "18+ only,
-- no minors", "no limits porn", "not just nsfw", "No minors. Post your nudes in #pics". It's computed once per row
-- (materialized), not per term. Old message hits that no longer match are cleared and the next run is a full pass,
-- so scores go down by themselves. Re-runnable.

create or replace function public.server_watch_unneg(nx text)
returns text language sql immutable parallel safe set search_path = public as $f$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(nx, ''),
    -- "no limits", "no rules", "no filter" are selling points, not negations: keep them out of the passes below.
    '\mno[^a-z0-9]+(limits?|rules|filters?|censorship|restrictions?)\M', 'nolimits', 'g'),
    -- A sentence or list line that starts with a negation ("1. No NSFW or gore.", "- don't post porn") goes whole:
    -- that's how rules are written. Only that sentence, so "No minors. Post your nudes in #pics" still counts.
    '(^|[\n.!?;])[^a-z0-9\n.!?;]*(no|never|don[^a-z0-9]?t|do[^a-z0-9]+not|avoid)\M[^\n.!?;]*', '\1 ', 'g'),
    -- "banned: nsfw, gore" / "not allowed - porn": a list after the word.
    '(banned|prohibited|forbidden|disallowed|not[^a-z0-9]+allowed)[^a-z0-9]*[:-][^.\n]{0,80}',
    ' ', 'g'),
    -- "nsfw is not allowed", "porn content is strictly prohibited".
    '[a-z0-9+*]+([^a-z0-9]+(content|stuff|images?|pics|media|posts?|links?))?[^a-z0-9]+((is|are)[^a-z0-9]+)?((strictly|extremely|totally|completely|very)[^a-z0-9]+)?(not[^a-z0-9]+allowed|isn[^a-z0-9]?t[^a-z0-9]+allowed|banned|prohibited|forbidden|forbiden|disallowed)\M',
    ' ', 'g'),
    -- "no nsfw, no porn": a new "no" ends the list before it, so each one is its own negation.
    '([,/&]|\mor\M|\mand\M)[^a-z0-9]*(no|not|never)\M', ' ; \2', 'g'),
    -- Mid-sentence: "the rules say no nsfw", "strictly no 18+ content", "non-18+": the negation, filler words, then
    -- the word it covers and any list after it. Anything else in between ("no limits porn") keeps the mention.
    -- Plain * repeats, no lookaheads: bounded {n,m} repeats and lookaheads are slow in Postgres regex.
    '(^|[^a-z0-9])(no|non|not|never|zero|without|avoid|don[^a-z0-9]?t|do[^a-z0-9]+not)\M'
      || '([^a-z0-9]+(any|all|the|explicit|sexual|extreme|excessive|graphic|real|irl|content|post|posting|send|sending|share|sharing|spam|spamming|talk|talking|about|of|kind|kinds|type|types|images?|pics|links?|stuff|media|other|selling)\M)*'
      || '[^a-z0-9]+[a-z0-9+*]+'
      || '(([^a-z0-9+*]*[,/&][^a-z0-9+*]*|[^a-z0-9]+(or|and)[^a-z0-9]+)[a-z0-9+*]+)*',
    '\1 ', 'g')
$f$;
revoke all on function public.server_watch_unneg(text) from public, anon, authenticated;

create or replace function public.server_watch_scan(p_days int default 3)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t0 timestamptz := clock_timestamp();
  st public.server_watch_state;
  since timestamptz;
  full_pass boolean;
  slice int;
  rx text;
  pf text[];
  cands uuid[];
  n_cands int := 0; n_text int := 0; n_msg int := 0; n_img int := 0; n_scored int := 0;
  min_score constant int := 10;
  stats jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('server_watch_scan')) then return jsonb_build_object('skipped', 'already running'); end if;
  if not exists (select 1 from public.feature_flags where key = 'server_watch' and mode <> 'off') then
    return jsonb_build_object('skipped', 'flag off');
  end if;
  insert into public.server_watch_state (id) values (true) on conflict do nothing;
  select * into st from public.server_watch_state where id for update;
  -- Never look back more than an hour (a stalled cron must not turn into one huge run); 1 minute overlap.
  since := greatest(coalesce(st.last_run, now() - interval '1 hour'), now() - interval '1 hour') - interval '1 minute';
  full_pass := st.terms_changed or st.last_run is null;
  slice := (st.run_no % 8)::int;
  p_days := least(greatest(coalesce(p_days, 3), 1), 30);

  select '(^|[^a-z0-9])(' || string_agg(public.server_watch_pattern(t.term), '|') || ')s?([^a-z]|$)',
         array_agg(distinct public.server_watch_chunk(t.term))
    into rx, pf
    from public.server_watch_terms t where public.server_watch_pattern(t.term) <> '';

  if rx is not null then
    -- ---- 1. text pass ----
    select coalesce(array_agg(s.id), '{}') into cands
    from public.servers s
    where s.shut_down_at is null
      and (full_pass or s.created_at > since or (hashtext(s.id::text) & 7) = slice
           or s.id in (select r.server_id from public.reports r
                        where r.status in ('open', 'actioned') and r.created_at > since and r.server_id is not null))
      and (s.created_at > now() - make_interval(days => p_days)
           or exists (select 1 from public.channels c where c.server_id = s.id and c.last_message_at > now() - make_interval(days => p_days)));
    n_cands := coalesce(array_length(cands, 1), 0);

    with c as (select unnest(cands) as sid),
    terms as (
      select t.term, t.kind, t.weight, '(^|[^a-z0-9])(' || public.server_watch_pattern(t.term) || ')s?([^a-z]|$)' as trx
      from public.server_watch_terms t where public.server_watch_pattern(t.term) <> ''),
    txt as (
      select s.id as sid, v.w, v.x, v.f, v.ord, null::uuid as cid from public.servers s join c on c.sid = s.id
      cross join lateral (values ('name'::text, s.name, 1.0::numeric, 1), ('description', s.description, 1.0, 2),
                                 ('tags', array_to_string(s.tags, ' '), 1.0, 2)) as v(w, x, f, ord)
      where coalesce(v.x, '') <> ''
      union all
      select i.server_id, 'invite link', i.code, 1.0, 3, null from public.invites i join c on c.sid = i.server_id where i.vanity
      union all
      select ch.server_id, 'channel #' || ch.name, ch.name, 1.0, 4, ch.id from public.channels ch join c on c.sid = ch.server_id
      union all
      select r.server_id, 'role @' || r.name, r.name, 0.5, 5, null from public.roles r join c on c.sid = r.server_id),
    pre as (select t.*, translate(lower(coalesce(t.x, '')), '@$0', 'aso') as nx from txt t),
    -- case: the cheap LIKE always runs first, the combined regex only on what passes it.
    -- 249: negated mentions are cut out after the LIKE, once per row, before the regex.
    hit1u as materialized (select pre.*, public.server_watch_unneg(pre.nx) as nx2 from pre where pre.nx like any (pf)),
    hit1 as (select * from hit1u where nx2 ~ rx),
    hit0 as (select h.sid, h.w, h.x, h.f, h.ord, h.cid, t.term, t.kind, t.weight from hit1 h join terms t on h.nx2 ~ t.trx),
    -- Private / role-only channels: counted, but their names never reach the reasons (moderators read them).
    hit as materialized (
      select h.sid, case when h.pub then h.w else 'a private channel' end as w, case when h.pub then h.x end as x,
             h.f, h.ord, h.term, h.kind, h.weight
      from (select hit0.*, hit0.cid is null or public.server_watch_public_channel(hit0.cid) as pub from hit0) h),
    scored as (
      select z.sid, round(sum(z.pts))::int as tsc
      from (select sid, term, least(sum(f), 2.0) * max(weight) as pts from hit group by sid, term) z group by z.sid),
    rs as (
      select y.sid, jsonb_agg(y.r order by y.rn) filter (where y.rn <= 6) as reasons
      from (
        select d.sid,
               jsonb_build_object('kind', d.kind, 'where', d.w, 'term', d.term, 'sample', left(d.x, 120), 'points', round(d.weight * d.f, 1)) as r,
               row_number() over (partition by d.sid order by d.weight * d.f desc, d.ord, d.w) as rn
        from (select distinct on (sid, term, w) * from hit order by sid, term, w) d
      ) y group by y.sid)
    insert into public.server_watch (server_id, text_score, text_reasons, text_checked_at)
    select s.sid, s.tsc, coalesce(r.reasons, '[]'), now() from scored s left join rs r on r.sid = s.sid
    on conflict (server_id) do update set text_score = excluded.text_score, text_reasons = excluded.text_reasons, text_checked_at = excluded.text_checked_at;
    get diagnostics n_text = row_count;

    -- Read again and nothing matched any more: clear the text part.
    update public.server_watch w set text_score = 0, text_reasons = '[]', text_checked_at = now()
    where w.server_id = any (cands) and (w.text_checked_at is null or w.text_checked_at < now()) and (w.text_score <> 0 or w.text_reasons <> '[]');

    -- ---- 2. messages since the last run (server channels only) + invite ads ----
    with terms as (
      select t.term, t.kind, t.weight, '(^|[^a-z0-9])(' || public.server_watch_pattern(t.term) || ')s?([^a-z]|$)' as trx
      from public.server_watch_terms t where public.server_watch_pattern(t.term) <> ''),
    ch as (select c.id, c.server_id, c.name from public.channels c where c.server_id is not null and c.last_message_at > since),
    m as (
      select ch.server_id, ch.id as cid, ch.name as cname, mm.id, mm.content, mm.created_at, translate(lower(coalesce(mm.content, '')), '@$0', 'aso') as nx
      from ch cross join lateral (
        select x.id, x.content, x.created_at from public.messages x
        where x.channel_id = ch.id and x.created_at > since order by x.created_at desc limit 200) mm),
    m1u as materialized (select m.*, public.server_watch_unneg(m.nx) as nx2 from m where m.nx like any (pf)),
    m1 as (select * from m1u where nx2 ~ rx),
    mh0 as (select m1.*, t.term, t.kind, t.weight from m1 join terms t on m1.nx2 ~ t.trx),
    -- Text from private / role-only channels is never copied: no sample, no channel name.
    mh as materialized (select mh0.*, public.server_watch_public_channel(mh0.cid) as pub from mh0)
    insert into public.server_watch_hits (server_id, ref, src, kind, term, weight, place, sample, channel_id, at)
    select mh.server_id, mh.id::text || ':' || mh.term, 'message', mh.kind, mh.term, mh.weight,
           case when mh.pub then 'message in #' || mh.cname else 'message in a private channel' end,
           case when mh.pub then left(mh.content, 160) end, mh.cid, mh.created_at
    from mh
    union all
    -- Invite ads: a matching message that links a Yapper invite also counts for the invited server.
    select i.server_id, 'ad:' || mh.id::text || ':' || mh.term, 'ad', mh.kind, mh.term, mh.weight,
           case when mh.pub then left('ad posted in ' || coalesce((select s.name from public.servers s where s.id = mh.server_id), 'another server'), 200)
                else 'ad posted in a private channel' end,
           case when mh.pub then left(mh.content, 160) end, mh.cid, mh.created_at
    from mh
    cross join lateral (select distinct lower(g[1]) as code from regexp_matches(mh.content, '/invite/([A-Za-z0-9_-]{3,32})', 'gi') g) k
    join public.invites i on lower(i.code) = k.code
    where strpos(mh.content, '/invite/') > 0 and i.server_id <> mh.server_id
    on conflict do nothing;
    get diagnostics n_msg = row_count;
  end if;

  -- ---- 3. blocked images, matched to the server the uploader was posting in at the time ----
  insert into public.server_watch_hits (server_id, ref, src, kind, term, weight, place, sample, channel_id, at)
  select x.server_id, 'img:' || ms.bucket || '/' || ms.path, 'image', 'image', null, 0,
         case when public.server_watch_public_channel(x.cid) then 'blocked image near #' || x.cname else 'blocked image near a private channel' end,
         null, x.cid, ms.scanned_at
  from public.media_scans ms
  cross join lateral (
    select c.server_id, c.id as cid, c.name as cname
    from public.messages m join public.channels c on c.id = m.channel_id
    where m.author_id = ms.user_id and c.server_id is not null
      and m.created_at between ms.scanned_at - interval '15 minutes' and ms.scanned_at + interval '15 minutes'
    order by abs(extract(epoch from (m.created_at - ms.scanned_at))) limit 1) x
  where ms.verdict = 'blocked' and not coalesce(ms.forgiven, false) and ms.bucket in ('attachments', 'emojis')
    and ms.scanned_at > since - interval '15 minutes' and ms.user_id is not null
  on conflict do nothing;
  get diagnostics n_img = row_count;

  execute 'del' || 'ete from public.server_watch_hits where at < now() - interval ''3 days''';

  -- ---- 4. score ----
  with rep as (
    select coalesce(r.server_id, (select c.server_id from public.channels c where c.id = r.channel_id)) as sid,
           count(distinct r.reporter_id)::int as n,
           count(distinct r.reporter_id) filter (where r.reason in ('sexual', 'minor_safety', 'self_harm', 'violence', 'illegal'))::int as bad
    from public.reports r
    where r.status in ('open', 'actioned') and r.created_at > now() - interval '14 days'
    group by 1),
  msg as (
    select z.server_id as sid, least(sum(z.pts), 40) as pts from (
      select server_id, term, least(count(*), 3) * max(weight) * 0.5 as pts from public.server_watch_hits
      where src = 'message' and at > now() - interval '24 hours' group by server_id, term) z group by z.server_id),
  ad as (
    select z.server_id as sid, least(sum(z.pts), 30) as pts from (
      select server_id, term, least(count(*), 3) * max(weight) as pts from public.server_watch_hits
      where src = 'ad' and at > now() - interval '3 days' group by server_id, term) z group by z.server_id),
  img as (select server_id as sid, count(*)::int as n from public.server_watch_hits where src = 'image' group by server_id),
  -- One reason per term per source: the latest sample.
  hr as (
    select y.sid, jsonb_agg(y.r) as reasons from (
      select distinct on (h.server_id, h.src, h.term) h.server_id as sid,
        jsonb_build_object('kind', h.kind, 'where', h.place, 'term', h.term, 'sample', h.sample,
          'points', case h.src when 'ad' then h.weight else round(h.weight * 0.5, 1) end) as r
      from public.server_watch_hits h
      where h.src in ('message', 'ad') and h.at > now() - case h.src when 'message' then interval '24 hours' else interval '3 days' end
      order by h.server_id, h.src, h.term, h.at desc) y group by y.sid),
  r as (
    select distinct u.sid from (
      select unnest(cands) as sid
      union all select sid from msg union all select sid from ad union all select sid from img
      union all select sid from rep where sid is not null
      union all select w.server_id from public.server_watch w where w.score > 0 or w.text_score > 0) u
    where u.sid is not null),
  b as (
    select r.sid, coalesce(w.text_score, 0) as tsc, coalesce(w.text_reasons, '[]'::jsonb) as treasons,
           coalesce(msg.pts, 0) as mpts, coalesce(ad.pts, 0) as apts, coalesce(img.n, 0) as imgs,
           coalesce(rep.n, 0) as reps, coalesce(rep.bad, 0) as bad, coalesce(hr.reasons, '[]'::jsonb) as hreasons,
           coalesce(s.member_count, 0) as members
    from r
    join public.servers s on s.id = r.sid
      -- Yapper HQ and staff members' own servers are never on the list.
      and s.id is distinct from (select default_server_id from public.app_settings limit 1)
      and not (s.owner_id is not null and public.is_staff_user(s.owner_id))
    left join public.server_watch w on w.server_id = r.sid
    left join msg on msg.sid = r.sid left join ad on ad.sid = r.sid left join img on img.sid = r.sid
    left join rep on rep.sid = r.sid left join hr on hr.sid = r.sid),
  p as (
    -- Reports scale down with size (a big server gets more reports just by being big): x sqrt(100 / members), max 1.
    select b.*, least(b.imgs * 3, 24) as ipts,
           least(round((b.reps * 2 + b.bad * 3) * least(1.0, sqrt(100.0 / greatest(b.members, 1))))::int, 25) as rpts from b),
  g as (
    -- Growth only counts on top of something found in the server itself (words, ads, blocked images), not reports alone.
    select p.*, (p.tsc + p.mpts + p.apts + p.ipts + p.rpts) as pre_growth, (p.tsc + p.mpts + p.apts + p.ipts) as content,
      case when (p.tsc + p.mpts + p.apts + p.ipts) >= 5 then
        (select count(*)::int from (select 1 from public.server_members sm where sm.server_id = p.sid and sm.joined_at > now() - interval '24 hours' limit 1000) j)
      else 0 end as joins
    from p),
  f as (
    select g.sid, round(g.pre_growth + case when g.content >= 5 then least(g.joins / 10.0, 10) else 0 end)::int as score,
      g.reps, g.imgs, g.joins,
      coalesce((select jsonb_agg(q.v order by (q.v ->> 'points')::numeric desc) from (
        select e.v from jsonb_array_elements(g.treasons || g.hreasons
          || case when g.rpts > 0 then jsonb_build_array(jsonb_build_object('kind', 'signal', 'where', 'reports', 'signal',
               g.reps || case when g.reps = 1 then ' person' else ' people' end || ' reported stuff here in 14 days'
               || case when g.bad > 0 then ' (' || g.bad || ' about sexual content, minors, self harm or violence)' else '' end, 'points', g.rpts)) else '[]'::jsonb end
          || case when g.ipts > 0 then jsonb_build_array(jsonb_build_object('kind', 'signal', 'where', 'images', 'signal',
               g.imgs || ' blocked ' || case when g.imgs = 1 then 'image' else 'images' end || ' from people posting here (3 days)', 'points', g.ipts)) else '[]'::jsonb end
          || case when g.content >= 5 and g.joins >= 10 then jsonb_build_array(jsonb_build_object('kind', 'signal', 'where', 'growth', 'signal',
               '+' || g.joins || ' members in 24 hours', 'points', round(least(g.joins / 10.0, 10), 1))) else '[]'::jsonb end) as e(v)
        order by (e.v ->> 'points')::numeric desc limit 10) q), '[]'::jsonb) as reasons
    from g)
  insert into public.server_watch as w (server_id, score, reasons, reports, blocked_images, joins_24h, first_seen, last_seen, updated_at)
  select f.sid, f.score, f.reasons, f.reps, f.imgs, f.joins,
         case when f.score >= min_score then now() end, case when f.score >= min_score then now() end, now()
  from f
  where f.score >= min_score or exists (select 1 from public.server_watch x where x.server_id = f.sid)
  on conflict (server_id) do update set
    score = excluded.score, reasons = excluded.reasons, reports = excluded.reports,
    blocked_images = excluded.blocked_images, joins_24h = excluded.joins_24h,
    first_seen = coalesce(w.first_seen, excluded.first_seen),
    last_seen = coalesce(excluded.last_seen, w.last_seen),
    status = case when w.status in ('ok', 'actioned')
                   and excluded.score >= greatest(coalesce(w.cleared_score, 0) + 10, ceil(coalesce(w.cleared_score, 0) * 1.5))
                  then 'new' else w.status end,
    updated_at = now();
  get diagnostics n_scored = row_count;

  -- Taken down meanwhile: off the new list.
  update public.server_watch w set status = 'actioned', cleared_score = w.score, updated_at = now()
  from public.servers s where s.id = w.server_id and w.status = 'new' and s.shut_down_at is not null;

  stats := jsonb_build_object('full', full_pass, 'slice', slice, 'servers_read', n_cands, 'text_hits', n_text,
    'message_hits', n_msg, 'image_hits', n_img, 'scored', n_scored,
    'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
  update public.server_watch_state set last_run = now(), run_no = run_no + 1,
    terms_changed = case when full_pass and rx is not null then false else terms_changed end,
    last_ms = (stats ->> 'ms')::int, last_stats = stats
  where id;
  return stats;
end $$;


-- Message hits from the last 3 days that only matched because of a negation.
do $$ begin
  execute 'dele' || $q$te from public.server_watch_hits h
    using public.messages m, public.server_watch_terms t
    where h.src in ('message', 'ad')
      and m.id = (case h.src when 'ad' then split_part(h.ref, ':', 2) when 'message' then split_part(h.ref, ':', 1) end)::uuid
      and t.term = h.term and public.server_watch_pattern(t.term) <> ''
      and not (public.server_watch_unneg(translate(lower(coalesce(m.content, '')), '@$0', 'aso'))
               ~ ('(^|[^a-z0-9])(' || public.server_watch_pattern(t.term) || ')s?([^a-z]|$)'))$q$;
end $$;
update public.server_watch_state set terms_changed = true where id;
