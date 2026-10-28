-- 141: server themes (flag `server_theme`) and Find people in DMs (flag `user_search`). Applied live via MCP.
-- The slowmode chip (flag `slowmode_chip`) needs no SQL.
-- Re-runnable.

set lock_timeout = '5s';

-- ---------- Server themes ----------
-- servers.theme = {"accent": "#rrggbb", "tint": "#rrggbb"}, both optional; null = no theme.
-- No update policy on servers: it is only written through set_server_theme (Manage Server).
alter table public.servers add column if not exists theme jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'servers_theme_check' and conrelid = 'public.servers'::regclass) then
    alter table public.servers add constraint servers_theme_check check (
      theme is null or (
        jsonb_typeof(theme) = 'object'
        and theme <> '{}'::jsonb
        and (theme - array['accent', 'tint']) = '{}'::jsonb
        and (not theme ? 'accent' or (jsonb_typeof(theme->'accent') = 'string' and theme->>'accent' ~ '^#[0-9a-f]{6}$'))
        and (not theme ? 'tint' or (jsonb_typeof(theme->'tint') = 'string' and theme->>'tint' ~ '^#[0-9a-f]{6}$'))
      )
    );
  end if;
end $$;

create or replace function public.set_server_theme(sid uuid, p_accent text, p_tint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a text := nullif(lower(btrim(coalesce(p_accent, ''))), ''); t text := nullif(lower(btrim(coalesce(p_tint, ''))), ''); th jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only people who can manage the server can change its theme'; end if;
  if a is not null and a !~ '^#[0-9a-f]{6}$' then raise exception 'Colours look like #ff6b4a'; end if;
  if t is not null and t !~ '^#[0-9a-f]{6}$' then raise exception 'Colours look like #ff6b4a'; end if;
  th := jsonb_strip_nulls(jsonb_build_object('accent', a, 'tint', t));
  if th = '{}'::jsonb then th := null; end if;
  update public.servers set theme = th where id = sid;
  return th;
end; $$;
revoke all on function public.set_server_theme(uuid, text, text) from public, anon;
grant execute on function public.set_server_theme(uuid, text, text) to authenticated;

-- ---------- Find people ----------
-- Prefix search on username / display name. "C" collation indexes so a prefix is an index range
-- scan that comes out already sorted, and the limit stops it early (the en_US index can't do prefixes).
-- profiles is ~40k rows, so a plain build is a second or two.
create index if not exists profiles_username_c_idx on public.profiles ((lower(username) collate "C"));
create index if not exists profiles_display_name_c_idx on public.profiles ((lower(display_name) collate "C")) where display_name is not null;

-- Who you can find: your friends (online or not, substring match), or people who share a server
-- with you AND are online right now (invisible / offline people only show up if they're your friend).
-- Never people you blocked or who blocked you, nor site-banned accounts. Up to 20, at least 2 characters.
-- It never walks a server's member list: candidates come from the name indexes, and each one costs a
-- few primary-key probes (their memberships via server_members_user_idx, presence, blocks).
-- Rate limit (review fix): 20 searches a minute, 200 an hour per person, so the online list of a big
-- server can't be scraped two letters at a time. Only search_people touches this table.
create table if not exists public.people_search_quota (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  minute_start timestamptz not null default now(),
  minute_n int not null default 0,
  hour_start timestamptz not null default now(),
  hour_n int not null default 0
);
alter table public.people_search_quota enable row level security;
revoke all on public.people_search_quota from anon, authenticated;

create or replace function public.search_people(q text)
returns table(id uuid, username text, display_name text, avatar_path text, mutual int, friend boolean)
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  qt public.people_search_quota;
  needle text := ltrim(lower(btrim(coalesce(q, ''))), '@');
  pat text;
  hi text;
  sids uuid[];
  friends uuid[];
begin
  if me is null then return; end if;
  needle := left(needle, 32);
  if char_length(needle) < 2 then return; end if;
  if not public.feature_on_for_me('user_search') then return; end if;
  insert into public.people_search_quota as z (user_id, minute_n, hour_n) values (me, 1, 1)
  on conflict (user_id) do update set
    minute_start = case when z.minute_start < now() - interval '1 minute' then now() else z.minute_start end,
    minute_n = case when z.minute_start < now() - interval '1 minute' then 1 else z.minute_n + 1 end,
    hour_start = case when z.hour_start < now() - interval '1 hour' then now() else z.hour_start end,
    hour_n = case when z.hour_start < now() - interval '1 hour' then 1 else z.hour_n + 1 end
  returning * into qt;
  if qt.minute_n > 20 or qt.hour_n > 200 then
    raise exception 'Slow down a bit, try searching again in a minute' using errcode = 'P0001';
  end if;
  -- Range bounds as well as LIKE: a range on a parameter still uses the index in a generic (cached) plan.
  hi := needle || chr(1114111);
  pat := replace(replace(replace(needle, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select coalesce(array_agg(sm.server_id), '{}') into sids from public.server_members sm where sm.user_id = me;
  select coalesce(array_agg(case when f.requester = me then f.addressee else f.requester end), '{}') into friends
    from public.friendships f where (f.requester = me or f.addressee = me) and f.status = 'accepted';

  return query
  with cand as (
    -- Friends: a small set, so a substring match is fine.
    (select p.id from public.profiles p
      where p.id = any(friends)
        and (lower(p.username) like '%' || pat or lower(coalesce(p.display_name, '')) like '%' || pat)
      limit 20)
    union
    (select p.id from public.profiles p
      where char_length(needle) >= 3
        and (lower(p.username) collate "C") >= needle and (lower(p.username) collate "C") < hi
        and lower(p.username) like pat
        and p.id <> me
        and exists (select 1 from public.server_members x where x.user_id = p.id and x.server_id = any(sids))
        and exists (select 1 from public.presence pr where pr.user_id = p.id
                      and pr.last_seen > now() - interval '100 seconds' and pr.pref is distinct from 'invisible')
      order by (lower(p.username) collate "C")
      limit 20)
    union
    (select p.id from public.profiles p
      where char_length(needle) >= 3
        and p.display_name is not null
        and (lower(p.display_name) collate "C") >= needle and (lower(p.display_name) collate "C") < hi
        and lower(p.display_name) like pat
        and p.id <> me
        and exists (select 1 from public.server_members x where x.user_id = p.id and x.server_id = any(sids))
        and exists (select 1 from public.presence pr where pr.user_id = p.id
                      and pr.last_seen > now() - interval '100 seconds' and pr.pref is distinct from 'invisible')
      order by (lower(p.display_name) collate "C")
      limit 20)
  )
  select p.id, p.username, p.display_name, p.avatar_path,
         (select count(*)::int from public.server_members x where x.user_id = p.id and x.server_id = any(sids)) as mutual,
         p.id = any(friends) as friend
  from cand
  join public.profiles p on p.id = cand.id
  where p.id <> me
    and not exists (select 1 from public.blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
    and not exists (select 1 from public.site_bans sb where sb.user_id = p.id and (sb.expires_at is null or sb.expires_at > now()))
  order by (lower(p.username) = needle) desc, (p.id = any(friends)) desc, lower(p.username)
  limit 20;
end; $$;
revoke all on function public.search_people(text) from public, anon;
grant execute on function public.search_people(text) to authenticated;

-- ---------- Flags (test: Antic's test server + Antic) ----------
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('server_theme', 'Server themes', 'Servers pick an accent colour and a background tint; members see it while they are in the server', 'test',
     array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[]),
  ('user_search', 'Find people', 'Search people you share a server with (or friends) from the DM list and message them', 'test',
     array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[]),
  ('slowmode_chip', 'Slowmode countdown', 'A stopwatch chip above the composer counts down your slowmode wait', 'test',
     array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
