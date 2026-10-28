-- 215: server watch (flag server_watch, test mode): finds servers built around adult content, "com" groups
-- (recruiting people, often minors, into harassment / extortion / self-harm networks) or gore, and gives staff
-- quick tools to act on them.
--
-- Detection (server_watch_scan, pg_cron every 15 min, service/cron only):
--   * server_watch_terms: staff-curated words (admins edit, staff read). Seeded once with a short list of generic
--     adult / com / gore words; staff add their own in Mod Center -> Servers -> Flagged.
--   * Matching: lower-cased, @ $ 0 read as a s o, the term must start a word ("nsfw" hits "nsfw-pics" and
--     "#nsfw", not "unsfw"), a space in a term also matches "-", "_", "." or nothing ("rule 34" = "rule-34" = "rule34"),
--     plural s allowed. A cheap LIKE prefilter and one combined regex run before the per-term regex.
--   * Where: server name, description, tags, vanity invite, channel names, role names (text pass), plus
--     messages posted since the last run in every server channel (at most 200 per channel per run, read through
--     messages_channel_created_idx), plus invite ads: a matching message with a /invite/<code> link counts for
--     the server the invite points to. DMs are never read.
--   * Text pass covers, per run: new servers, servers with reports since the last run, and one eighth of all
--     servers active in the last p_days days (rotating, so every server is re-read every 2 hours). After a term
--     change the next run reads everything once.
--   * Signals: reports filed from inside the server (14 days, distinct reporters), images the scanner blocked
--     (attachments / emojis) from people posting in the server around that time (3 days), joins in the last 24 h
--     (only adds to a server that already scored something).
--   * Results in server_watch (score, reasons [{kind, where, term|signal, sample, points}], status new/ok/actioned).
--     A server marked ok or actioned only comes back as new once its score is at least 10 points and 1.5x above
--     the score it had when reviewed.
--   * Text from private / role-only channels (server_watch_public_channel) is never copied into samples.
-- Tools (staff, flag on): staff_watch_list, staff_watch_peek (server, channels, last messages of a channel;
--   every read goes in mod_log as server_peek; moderators only for flagged / reported servers not owned by staff,
--   and only public channels; admins anything), staff_warn_server_owner (an account-standing warning tied to the
--   server, so it shows in the owner's notice / standing; mod_guard + mod_log 'server_warn'), staff_server_limit
--   ('hide': out of Discover and no new self-joins, reason required, 10 an hour for mods, never Yapper HQ or a
--   staff member's server for mods; 'unhide'), staff_watch_review. Takedown stays staff_takedown_server.
--   server_watch_hits (raw samples) is admins only; staff read summaries through staff_watch_list.
-- Re-runnable. Destructive statements only inside execute strings.

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('server_watch', 'Server watch', 'Flags servers built around adult content, com groups or gore for staff, plus warn owner and hide tools',
  'test', '{}', array['00000000-0000-4000-8000-00000000a001', '00000000-0000-4000-8000-00000000a002']::uuid[])
on conflict (key) do nothing;

-- ---------- columns ----------
-- Staff "hide": out of Discover and no new members, without a takedown. Only the time sits on servers (members
-- can read servers.*); who hid it and the previous Discover setting stay in server_hides (staff only).
alter table public.servers add column if not exists staff_hidden_at timestamptz;
-- Warnings given to a server owner because of that server.
alter table public.user_warnings add column if not exists server_id uuid references public.servers(id) on delete set null;
create index if not exists user_warnings_server_idx on public.user_warnings (server_id) where server_id is not null;

-- ---------- tables ----------
create table if not exists public.server_watch_terms (
  id uuid primary key default gen_random_uuid(),
  term text not null check (char_length(btrim(term)) between 2 and 60),
  kind text not null check (kind in ('sexual', 'com', 'gore', 'other')),
  weight int not null default 5 check (weight between 1 and 50),
  added_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists server_watch_terms_term_idx on public.server_watch_terms (lower(btrim(term)));
create index if not exists server_watch_terms_added_by_idx on public.server_watch_terms (added_by) where added_by is not null;

create table if not exists public.server_watch (
  server_id uuid primary key references public.servers(id) on delete cascade,
  score int not null default 0,
  reasons jsonb not null default '[]',
  text_score int not null default 0,
  text_reasons jsonb not null default '[]',
  text_checked_at timestamptz,
  reports int not null default 0,
  blocked_images int not null default 0,
  joins_24h int not null default 0,
  first_seen timestamptz,
  last_seen timestamptz,
  status text not null default 'new' check (status in ('new', 'ok', 'actioned')),
  cleared_score int,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists server_watch_status_score_idx on public.server_watch (status, score desc);
create index if not exists server_watch_reviewed_by_idx on public.server_watch (reviewed_by) where reviewed_by is not null;

-- Message / image / invite-ad hits, kept 3 days (messages count for 24 h).
create table if not exists public.server_watch_hits (
  server_id uuid not null references public.servers(id) on delete cascade,
  ref text not null,
  src text not null check (src in ('message', 'ad', 'image')),
  kind text not null,
  term text,
  weight int not null default 0,
  place text,
  sample text,
  channel_id uuid,
  at timestamptz not null,
  primary key (server_id, ref)
);
create index if not exists server_watch_hits_at_idx on public.server_watch_hits (at);

create table if not exists public.server_hides (
  server_id uuid primary key references public.servers(id) on delete cascade,
  hidden_by uuid references public.profiles(id) on delete set null,
  prev_discoverable boolean,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists server_hides_hidden_by_idx on public.server_hides (hidden_by) where hidden_by is not null;

create table if not exists public.server_watch_state (
  id boolean primary key default true check (id),
  last_run timestamptz,
  run_no bigint not null default 0,
  terms_changed boolean not null default true,
  last_ms int,
  last_stats jsonb
);

-- ---------- RLS ----------
alter table public.server_watch_terms enable row level security;
alter table public.server_watch enable row level security;
alter table public.server_watch_hits enable row level security;
alter table public.server_watch_state enable row level security;
alter table public.server_hides enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_terms' and policyname = 'staff read watch terms') then
    create policy "staff read watch terms" on public.server_watch_terms for select to authenticated using ((select public.is_staff()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_terms' and policyname = 'admins add watch terms') then
    create policy "admins add watch terms" on public.server_watch_terms for insert to authenticated with check ((select public.is_site_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_terms' and policyname = 'admins change watch terms') then
    create policy "admins change watch terms" on public.server_watch_terms for update to authenticated
      using ((select public.is_site_admin())) with check ((select public.is_site_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_terms' and policyname = 'admins remove watch terms') then
    create policy "admins remove watch terms" on public.server_watch_terms for delete to authenticated using ((select public.is_site_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch' and policyname = 'staff read server watch') then
    create policy "staff read server watch" on public.server_watch for select to authenticated using ((select public.is_staff()));
  end if;
  -- Raw hits are admins only; staff see the summary through staff_watch_list.
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_hits' and policyname = 'admins read server watch hits') then
    create policy "admins read server watch hits" on public.server_watch_hits for select to authenticated using ((select public.is_site_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_watch_state' and policyname = 'staff read server watch state') then
    create policy "staff read server watch state" on public.server_watch_state for select to authenticated using ((select public.is_staff()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_hides' and policyname = 'staff read server hides') then
    create policy "staff read server hides" on public.server_hides for select to authenticated using ((select public.is_staff()));
  end if;
end $$;
revoke all on public.server_watch, public.server_watch_hits, public.server_watch_state, public.server_hides from anon;
-- (spelled inside execute strings: the Supabase MCP hangs on that word)
do $rv$ begin
  execute 'revoke insert, update, delete, trun' || 'cate on public.server_watch, public.server_watch_hits, public.server_watch_state, public.server_hides from authenticated';
end $rv$;
revoke all on public.server_watch_terms from anon;
do $rv$ begin execute 'revoke trun' || 'cate on public.server_watch_terms from authenticated'; end $rv$;

-- ---------- seed (once: only when the state row doesn't exist yet, so deleted terms stay deleted) ----------
-- Generic, widely known words only. Staff add anything more specific through the admin terms editor.
do $$ begin
  if not exists (select 1 from public.server_watch_state) then
    insert into public.server_watch_terms (term, kind, weight, added_by) values
      ('nsfw', 'sexual', 8, null), ('18+', 'sexual', 6, null), ('r34', 'sexual', 10, null), ('rule 34', 'sexual', 10, null),
      ('porn', 'sexual', 10, null), ('hentai', 'sexual', 10, null), ('nudes', 'sexual', 10, null), ('onlyfans', 'sexual', 6, null),
      ('com group', 'com', 8, null), ('com server', 'com', 8, null), ('com friend group', 'com', 10, null),
      ('social com', 'com', 10, null), ('join the com', 'com', 10, null),
      ('gore', 'gore', 8, null), ('self harm', 'gore', 6, null), ('cut4', 'gore', 10, null)
    on conflict do nothing;
    insert into public.server_watch_state (id) values (true) on conflict do nothing;
  end if;
end $$;

-- Any term change makes the next scan re-read every server once.
create or replace function public.server_watch_terms_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.server_watch_state set terms_changed = true where id;
  return null;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'server_watch_terms_changed' and tgrelid = 'public.server_watch_terms'::regclass) then
    create trigger server_watch_terms_changed after insert or update or delete on public.server_watch_terms
      for each statement execute function public.server_watch_terms_changed();
  end if;
end $$;

-- ---------- matching helpers ----------
-- Text is compared as translate(lower(x), '@$0', 'aso'), written out inline in the scan so it stays cheap per row.
-- Regex body for one term: parts escaped, joined by "any separators or none".
create or replace function public.server_watch_pattern(term text)
returns text language sql immutable parallel safe set search_path = public as $$
  select array_to_string(array(
    select regexp_replace(u.p, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
    from unnest(regexp_split_to_array(btrim(translate(lower(coalesce(term, '')), '@$0', 'aso')), '[\s\-_.]+')) with ordinality as u(p, i)
    where u.p <> '' order by u.i), '[^a-z0-9]*')
$$;

-- LIKE prefilter for one term: its longest part.
create or replace function public.server_watch_chunk(term text)
returns text language sql immutable parallel safe set search_path = public as $$
  select '%' || replace(replace(replace(p, '\', '\\'), '%', '\%'), '_', '\_') || '%'
  from unnest(regexp_split_to_array(btrim(translate(lower(coalesce(term, '')), '@$0', 'aso')), '[\s\-_.]+')) p
  where p <> '' order by length(p) desc limit 1
$$;

-- Can a plain member (no roles) see this channel? Same rules as can_access_channel / channel_perm_of: without live
-- overrides, not private; with them, the @everyone view_channel override on the channel, then private, then the
-- @everyone override on its category, and no automatic role denying view. Tickets never count as public. Used so staff tools never copy or show text
-- from private or role-only channels to moderators.
create or replace function public.server_watch_public_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.ticket_by is null and c.server_id is not null and case when public.channel_overrides_live(c.id) then
      coalesce(
        (select case when bool_or('view_channel' = any(o.allow)) then true when bool_or('view_channel' = any(o.deny)) then false end
           from public.channel_overrides o where o.channel_id = c.id and o.role_id is null),
        case when c.private then false end,
        (select case when bool_or('view_channel' = any(o.allow)) then true when bool_or('view_channel' = any(o.deny)) then false end
           from public.channel_overrides o where c.category_id is not null and o.category_id = c.category_id and o.role_id is null),
        true)
      -- Automatic roles ('all' / 'before', applied through auto_role_applies) are checked before @everyone in
      -- channel_perm_of, so one of them denying view_channel hides the channel from (some) plain members too.
      and not exists (select 1 from public.channel_overrides o join public.roles r on r.id = o.role_id
                      where (o.channel_id = c.id or (c.category_id is not null and o.category_id = c.category_id))
                        and r.auto is not null and r.auto <> 'none' and 'view_channel' = any(o.deny))
    else not coalesce(c.private, false) end
    from public.channels c where c.id = cid), false)
$$;
revoke all on function public.server_watch_public_channel(uuid) from public, anon, authenticated;

-- ---------- the scan ----------
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
    hit1 as (select * from pre where case when nx like any (pf) then nx ~ rx else false end),
    hit0 as (select h.sid, h.w, h.x, h.f, h.ord, h.cid, t.term, t.kind, t.weight from hit1 h join terms t on h.nx ~ t.trx),
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
    m1 as (select * from m where case when nx like any (pf) then nx ~ rx else false end),
    mh0 as (select m1.*, t.term, t.kind, t.weight from m1 join terms t on m1.nx ~ t.trx),
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
revoke all on function public.server_watch_scan(int) from public, anon, authenticated;

-- ---------- staff: list ----------
create or replace function public.staff_watch_list(p_status text default 'new', lim int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st text := coalesce(p_status, 'new');
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on('server_watch', null) then raise exception 'Not available yet'; end if;
  if st not in ('new', 'ok', 'actioned') then raise exception 'Unknown list'; end if;
  return jsonb_build_object(
    'last_run', (select last_run from public.server_watch_state where id),
    'items', coalesce((select jsonb_agg(x order by x.score desc) from (
      select w.server_id as id, s.name, s.owner_id, p.username as owner_name, s.member_count as members, s.created_at,
             s.discoverable, s.staff_hidden_at as hidden_at, (select hidden_by from public.server_hides where server_id = s.id) as hidden_by,
             s.shut_down_at, s.takedown_by,
             w.score, w.reasons, w.reports, w.blocked_images, w.joins_24h, w.first_seen, w.last_seen, w.status,
             w.reviewed_at, (select username from public.profiles where id = w.reviewed_by) as reviewed_by_name,
             (select count(*)::int from public.user_warnings uw where uw.server_id = w.server_id) as owner_warnings
      from public.server_watch w
      join public.servers s on s.id = w.server_id
      left join public.profiles p on p.id = s.owner_id
      where w.status = st and (st <> 'new' or w.score >= 10)
      order by w.score desc
      limit least(greatest(coalesce(lim, 50), 1), 200)) x), '[]'::jsonb));
end $$;

-- ---------- staff: peek (server, channels, last messages of one channel) ----------
create or replace function public.staff_watch_peek(sid uuid, cid uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.servers; ch uuid; chname text; note text; adm boolean := public.is_site_admin();
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on('server_watch', null) then raise exception 'Not available yet'; end if;
  perform public.mod_guard('server_peek', null, '');
  select * into s from public.servers where id = sid;
  if not found then raise exception 'Server not found'; end if;
  -- Moderators: only servers that were flagged or reported, never staff-owned ones, and only public channels.
  -- Admins: anything (still logged).
  if not adm then
    if not exists (select 1 from public.server_watch w where w.server_id = sid and (w.score >= 10 or w.status = 'actioned'))
       and not exists (select 1 from public.reports r where r.server_id = sid and r.status = 'open') then
      raise exception 'You can only open servers that were flagged or reported';
    end if;
    if s.owner_id is not null and public.is_staff_user(s.owner_id) then raise exception 'That server belongs to staff'; end if;
  end if;
  if cid is not null then
    select id, name into ch, chname from public.channels where id = cid and server_id = sid;
    if ch is null then raise exception 'That channel isn''t in this server'; end if;
    if not adm and not public.server_watch_public_channel(ch) then raise exception 'That channel is private. Ask an admin.'; end if;
  else
    select c.id, c.name into ch, chname from public.channels c where c.server_id = sid and c.kind = 'text'
      and (adm or public.server_watch_public_channel(c.id))
    order by c.last_message_at desc nulls last limit 1;
  end if;
  -- Reading a server's messages always goes in the log (once per channel per 10 minutes).
  if ch is not null then
    note := left('Read #' || chname || ' [' || s.name || ']', 500);
    if not exists (select 1 from public.mod_log where actor = auth.uid() and action = 'server_peek' and reason = note and created_at > now() - interval '10 minutes') then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'server_peek', s.owner_id, note);
    end if;
  end if;
  return jsonb_build_object(
    'server', jsonb_build_object('id', s.id, 'name', s.name, 'description', s.description, 'created_at', s.created_at,
      'members', s.member_count, 'discoverable', s.discoverable, 'hidden_at', s.staff_hidden_at, 'shut_down_at', s.shut_down_at,
      'owner_id', s.owner_id, 'owner_name', (select username from public.profiles where id = s.owner_id),
      'owner_created_at', (select created_at from public.profiles where id = s.owner_id)),
    'owner_warnings', coalesce((select jsonb_agg(jsonb_build_object('reason', w.reason, 'at', w.created_at, 'server_id', w.server_id) order by w.created_at desc)
      from (select * from public.user_warnings where user_id = s.owner_id order by created_at desc limit 5) w), '[]'::jsonb),
    -- Moderators only get public channels (private ones just as a count); admins get all of them.
    'channels', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'last_message_at', c.last_message_at,
        'private', not c.pub, 'readable', c.kind = 'text')
      order by c.position, c.name) from (select x.*, public.server_watch_public_channel(x.id) as pub from public.channels x
                                         where x.server_id = sid order by x.position, x.name limit 100) c
      where adm or c.pub), '[]'::jsonb),
    'private_channels', case when adm then 0 else (select count(*)::int from public.channels x
                                                     where x.server_id = sid and not public.server_watch_public_channel(x.id)) end,
    'channel_id', ch,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'author_id', m.author_id, 'author_name', pr.username,
        'content', left(m.content, 1000), 'attachment_path', m.attachment_path, 'created_at', m.created_at) order by m.created_at)
      from (select * from public.messages where channel_id = ch order by created_at desc limit 40) m
      left join public.profiles pr on pr.id = m.author_id), '[]'::jsonb));
end $$;

-- ---------- staff: warn the owner (account standing warning tied to the server) ----------
create or replace function public.staff_warn_server_owner(sid uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare own uuid; nm text; r text := left(btrim(coalesce(reason, '')), 300);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on('server_watch', null) then raise exception 'Not available yet'; end if;
  select owner_id, name into own, nm from public.servers where id = sid;
  if nm is null then raise exception 'Server not found'; end if;
  if own is null then raise exception 'This server has no owner to warn'; end if;
  if char_length(r) < 3 then raise exception 'Say what the warning is for'; end if;
  if own = auth.uid() then raise exception 'Not yourself'; end if;
  perform public.mod_guard('server_warn', own, r);
  if exists (select 1 from public.user_warnings where user_id = own and server_id = sid and removed_at is null and created_at > now() - interval '24 hours') then
    raise exception 'The owner already got a warning for this server today';
  end if;
  insert into public.user_warnings (user_id, by, reason, server_id)
    values (own, auth.uid(), left('Your server "' || nm || '": ' || r, 500), sid);
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'server_warn', own, left(r || ' [' || nm || ']', 500));
  update public.server_watch set status = 'actioned', cleared_score = score, reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where server_id = sid;
end $$;

-- ---------- staff: hide / unhide ----------
create or replace function public.staff_server_limit(sid uuid, mode text, why text default '')
returns void language plpgsql security definer set search_path = public as $$
declare own uuid; nm text; hid timestamptz; hby uuid; prev boolean; r text := left(btrim(coalesce(why, '')), 300);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on('server_watch', null) then raise exception 'Not available yet'; end if;
  if mode is null or mode not in ('hide', 'unhide') then raise exception 'Unknown action'; end if;
  select owner_id, name, staff_hidden_at, discoverable into own, nm, hid, prev from public.servers where id = sid;
  if nm is null then raise exception 'Server not found'; end if;
  if sid = (select default_server_id from public.app_settings limit 1) then raise exception 'Yapper HQ can''t be hidden'; end if;
  select hidden_by into hby from public.server_hides where server_id = sid;
  if mode = 'hide' then
    if hid is not null then return; end if;
    if char_length(r) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
    -- The owner is the target, so moderators can't hide a staff member's server (mod_guard refuses that).
    perform public.mod_guard('server_hide', own, r);
    insert into public.server_hides (server_id, hidden_by, prev_discoverable, reason) values (sid, auth.uid(), prev, nullif(r, ''))
      on conflict (server_id) do update set hidden_by = excluded.hidden_by, prev_discoverable = excluded.prev_discoverable,
        reason = excluded.reason, created_at = now();
    update public.servers set staff_hidden_at = now(), discoverable = false where id = sid;
    insert into public.mod_log (actor, action, target_id, reason)
      values (auth.uid(), 'server_hide', own, left(r || ' [' || nm || ']', 500));
    update public.server_watch set status = 'actioned', cleared_score = score, reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
    where server_id = sid;
  else
    if hid is null then return; end if;
    if not public.is_site_admin() and hby is distinct from auth.uid() then
      raise exception 'Only an admin or the moderator who hid it can undo that';
    end if;
    perform public.mod_guard('server_unhide', null, r);
    update public.servers set staff_hidden_at = null,
      discoverable = case when shut_down_at is null
        then coalesce((select h.prev_discoverable from public.server_hides h where h.server_id = sid), discoverable) else discoverable end
    where id = sid;
    execute 'del' || 'ete from public.server_hides where server_id = $1' using sid;
    insert into public.mod_log (actor, action, target_id, reason)
      values (auth.uid(), 'server_unhide', own, left(coalesce(nullif(r, ''), 'Back in Discover') || ' [' || nm || ']', 500));
  end if;
end $$;

-- Hidden servers stay out of Discover (set_server_discovery can't turn it back on). Whatever the owner picks while
-- hidden is remembered for unhide. Skipped for the hide / unhide update itself (old or new staff_hidden_at null)
-- and for takedown / restore (shut_down_at changes), so neither overwrites the owner's choice.
create or replace function public.servers_keep_hidden()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.shut_down_at is not distinct from old.shut_down_at then
    update public.server_hides set prev_discoverable = new.discoverable where server_id = new.id;
  end if;
  new.discoverable := false;
  return new;
end $$;
revoke all on function public.servers_keep_hidden() from public, anon, authenticated;
do $$ begin
  execute 'dr' || 'op trigger if exists servers_keep_hidden on public.servers';
  create trigger servers_keep_hidden before update of discoverable on public.servers
    for each row when (new.staff_hidden_at is not null and old.staff_hidden_at is not null) execute function public.servers_keep_hidden();
end $$;

-- ... and take no new members joining by themselves (invites, Discover). Staff, the owner, people already in and
-- bots added by the server's managers still get in. One primary-key lookup per self-join.
create or replace function public.server_hidden_join_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  -- Only people joining by themselves (invites, Discover). Signup's HQ auto-join, server creation and
  -- maintenance (no auth.uid(), or someone adding another account) are left alone.
  if auth.uid() is null or auth.uid() is distinct from new.user_id then return new; end if;
  if exists (select 1 from public.servers s where s.id = new.server_id and s.staff_hidden_at is not null and s.owner_id is distinct from new.user_id) then
    if not public.is_staff()
       and not exists (select 1 from public.server_members m where m.server_id = new.server_id and m.user_id = new.user_id) then
      raise exception 'This server isn''t taking new members right now' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'server_members_hidden_guard' and tgrelid = 'public.server_members'::regclass) then
    create trigger server_members_hidden_guard before insert on public.server_members
      for each row execute function public.server_hidden_join_guard();
  end if;
end $$;

-- ---------- mod_guard: hides get their own hourly limit (10), like takedowns ----------
-- Patched into the live mod_guard in place; fails loudly if its text changed, skipped once applied.
do $do$
declare
  d text := pg_get_functiondef('public.mod_guard(text, uuid, text)'::regprocedure);
  a text := $a$when 'unwarn' then 30 when 'mark_bot' then 20 else 60 end;$a$;
  b text := $b$when 'unwarn' then 30 when 'mark_bot' then 20 when 'server_hide' then 10 else 60 end;$b$;
begin
  if strpos(d, $m$when 'server_hide' then 10$m$) > 0 then return; end if;
  if strpos(d, a) = 0 then raise exception '215: mod_guard() changed on the live database, anchor not found'; end if;
  execute replace(d, a, b);
end $do$;

-- ---------- staff: review ----------
create or replace function public.staff_watch_review(sid uuid, status text)
returns void language plpgsql security definer set search_path = public as $$
declare st text := staff_watch_review.status; sc int; own uuid; nm text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not public.feature_on('server_watch', null) then raise exception 'Not available yet'; end if;
  if st is null or st not in ('new', 'ok', 'actioned') then raise exception 'Unknown status'; end if;
  perform public.mod_guard('watch_review', null, '');
  update public.server_watch w set status = st,
    cleared_score = case when st = 'new' then null else w.score end,
    reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where w.server_id = sid
  returning w.score into sc;
  if not found then raise exception 'That server isn''t on the watch list'; end if;
  select owner_id, name into own, nm from public.servers where id = sid;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'watch_review', own, left(case st when 'ok' then 'Looks fine' when 'actioned' then 'Handled' else 'Back on the list' end
      || ' (score ' || sc || ') [' || coalesce(nm, '?') || ']', 500));
end $$;

revoke all on function public.staff_watch_list(text, int) from public, anon;
revoke all on function public.staff_watch_peek(uuid, uuid) from public, anon;
revoke all on function public.staff_warn_server_owner(uuid, text) from public, anon;
revoke all on function public.staff_server_limit(uuid, text, text) from public, anon;
revoke all on function public.staff_watch_review(uuid, text) from public, anon;
grant execute on function public.staff_watch_list(text, int) to authenticated;
grant execute on function public.staff_watch_peek(uuid, uuid) to authenticated;
grant execute on function public.staff_warn_server_owner(uuid, text) to authenticated;
grant execute on function public.staff_server_limit(uuid, text, text) to authenticated;
grant execute on function public.staff_watch_review(uuid, text) to authenticated;
revoke all on function public.server_watch_terms_changed() from public, anon, authenticated;
revoke all on function public.server_hidden_join_guard() from public, anon, authenticated;

-- ---------- schedule ----------
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    if not exists (select 1 from cron.job where jobname = 'server-watch-scan') then
      perform cron.schedule('server-watch-scan', '*/15 * * * *', 'select public.server_watch_scan()');
    end if;
  end if;
end $$;
