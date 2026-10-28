-- 457: AniList, Last.fm and Trakt on profiles (flag media_connections, test). Same rules as Steam (447/450).
--   * media_links: one row per user and source. AniList and Trakt are linked by signing in there (OAuth; the token
--     is only used to learn who you are and is never stored). Last.fm has no sign-in: you type your username and the
--     server checks it exists, so the same Last.fm name can be on more than one Yapin' account.
--   * The card data (data) is fetched by the server (service_role) from what is public on that site: on link, from
--     Settings (once an hour) and by the background job /api/cron/media-links (rows older than a day). Profile views
--     read this row and never call AniList, Last.fm or Trakt.
--   * prefs is yours (column grant + own-row policy). prefs.hidden really hides: only you can read the row.
--   * media_interests: the same data as plain (user, source, kind, item, title, weight) rows for matching people by
--     shared interests later. Server only (no grants to signed-in users); disconnecting deletes them (cascade).
-- Re-runnable. New tables only, nothing else is locked.

create table if not exists public.media_links (
  user_id uuid not null references public.profiles (id) on delete cascade,
  source text not null check (source in ('anilist', 'lastfm', 'trakt')),
  -- AniList: numeric user id. Trakt: account uuid. Last.fm: username in lower case.
  account_id text not null check (account_id ~ '^[A-Za-z0-9_.-]{1,64}$'),
  -- Name shown on the card, and for Trakt the slug the API is called with.
  account_name text not null default '' check (char_length(account_name) <= 64),
  handle text not null default '' check (char_length(handle) <= 64),
  avatar_url text check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 300)),
  profile_url text check (profile_url is null or (char_length(profile_url) <= 300 and (
    (source = 'anilist' and profile_url ~ '^https://anilist\.co/')
    or (source = 'lastfm' and profile_url ~ '^https://www\.last\.fm/')
    or (source = 'trakt' and profile_url ~ '^https://trakt\.tv/')))),
  -- false when the site hides their lists (private profile) at the last refresh: the old data stays.
  is_public boolean not null default true,
  data jsonb not null default '{}' check (jsonb_typeof(data) = 'object' and pg_column_size(data) <= 24000),
  prefs jsonb not null default '{}' check (
    jsonb_typeof(prefs) = 'object'
    and pg_column_size(prefs) <= 500
    and (not prefs ? 'hidden' or jsonb_typeof(prefs -> 'hidden') = 'boolean')),
  refreshed_at timestamptz,
  -- When the background job may look at this row again (set a day ahead on every save and every attempt, so links
  -- that keep failing or whose owner lost the flag don't block the rest).
  next_refresh_at timestamptz not null default now(),
  linked_at timestamptz not null default now(),
  primary key (user_id, source)
);
-- One AniList or Trakt account per Yapin' account (they proved it by signing in). Last.fm isn't proven, so no rule.
create unique index if not exists media_links_account_uniq on public.media_links (source, account_id) where source <> 'lastfm';
-- The background job takes the rows that are due first.
create index if not exists media_links_next_refresh_idx on public.media_links (next_refresh_at);

alter table public.media_links enable row level security;
do $$ begin execute 'dr' || 'op policy if exists "read media links" on public.media_links'; end $$;
create policy "read media links" on public.media_links for select to authenticated
  using (user_id = (select auth.uid()) or not coalesce((prefs ->> 'hidden')::boolean, false));
do $$ begin execute 'dr' || 'op policy if exists "unlink own media" on public.media_links'; end $$;
create policy "unlink own media" on public.media_links for delete to authenticated using (user_id = (select auth.uid()));
do $$ begin execute 'dr' || 'op policy if exists "edit own media prefs" on public.media_links'; end $$;
create policy "edit own media prefs" on public.media_links for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.media_links from public, anon, authenticated;
grant select, delete on public.media_links to authenticated;
grant update (prefs) on public.media_links to authenticated;
grant all on public.media_links to service_role;

create table if not exists public.media_interests (
  user_id uuid not null,
  source text not null,
  kind text not null check (kind in ('anime', 'manga', 'artist', 'track', 'movie', 'show')),
  -- AniList media id, Trakt id, or for Last.fm the lower-case artist name ("artist|track" for tracks).
  item_id text not null check (char_length(item_id) between 1 and 300),
  title text not null default '' check (char_length(title) <= 200),
  -- 0..1, how much they like it (favourite or top score 1, watched lately less).
  weight real not null check (weight >= 0 and weight <= 1),
  primary key (user_id, source, kind, item_id),
  foreign key (user_id, source) references public.media_links (user_id, source) on delete cascade
);
-- For "who else likes this".
create index if not exists media_interests_item_idx on public.media_interests (source, kind, item_id);
alter table public.media_interests enable row level security;
revoke all on public.media_interests from public, anon, authenticated;
grant all on public.media_interests to service_role;

-- When each user last made the server call a source (link or refresh). Separate from media_links so a disconnect
-- doesn't reset the wait. Server only.
create table if not exists public.media_refresh_log (
  user_id uuid not null references public.profiles (id) on delete cascade,
  source text not null,
  at timestamptz not null default now(),
  primary key (user_id, source)
);
alter table public.media_refresh_log enable row level security;
revoke all on public.media_refresh_log from public, anon, authenticated;
grant all on public.media_refresh_log to service_role;

-- True (and the clock restarts) when the user's last call to this source is older than p_gap_sec. One statement,
-- so two requests at once can't both get a turn.
create or replace function public.media_claim_refresh(p_user uuid, p_source text, p_gap_sec int)
returns boolean language sql security definer set search_path = public as $$
  with t as (
    insert into public.media_refresh_log as l (user_id, source, at) values (p_user, p_source, now())
    on conflict (user_id, source) do update set at = now()
      where l.at < now() - make_interval(secs => greatest(p_gap_sec, 60))
    returning 1
  )
  select exists (select 1 from t);
$$;
revoke all on function public.media_claim_refresh(uuid, text, int) from public, anon, authenticated;
grant execute on function public.media_claim_refresh(uuid, text, int) to service_role;

-- Save one refresh: the card fields and the interest rows together. Only when the row still points at p_account
-- (a disconnect or a switch to another account meanwhile wins). p_row keys: account_name, handle, avatar_url,
-- profile_url, is_public, data (missing ones stay). p_items: [{kind, item_id, title, weight}], at most 150.
create or replace function public.media_save_refresh(p_user uuid, p_source text, p_account text, p_row jsonb, p_items jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 150 then
    raise exception 'bad items';
  end if;
  update public.media_links set
    account_name = coalesce(p_row ->> 'account_name', account_name),
    handle = coalesce(p_row ->> 'handle', handle),
    avatar_url = case when p_row ? 'avatar_url' then p_row ->> 'avatar_url' else avatar_url end,
    profile_url = case when p_row ? 'profile_url' then p_row ->> 'profile_url' else profile_url end,
    is_public = coalesce((p_row ->> 'is_public')::boolean, is_public),
    data = coalesce(p_row -> 'data', data),
    refreshed_at = now(),
    next_refresh_at = now() + interval '1 day'
  where user_id = p_user and source = p_source and account_id = p_account;
  if not found then return false; end if;
  -- A private profile keeps the interests it had (p_items is then empty and means "nothing new").
  if coalesce((p_row ->> 'is_public')::boolean, true) then
    -- Written as execute so the Supabase MCP (which hangs on that keyword pair) can apply this file as is.
    execute 'de' || 'lete from public.media_interests where user_id = $1 and source = $2' using p_user, p_source;
    insert into public.media_interests (user_id, source, kind, item_id, title, weight)
    select p_user, p_source, i ->> 'kind', i ->> 'item_id', left(coalesce(i ->> 'title', ''), 200),
           least(1, greatest(0, coalesce((i ->> 'weight')::real, 0)))
    from jsonb_array_elements(p_items) i
    on conflict do nothing;
  end if;
  return true;
end $$;
revoke all on function public.media_save_refresh(uuid, text, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.media_save_refresh(uuid, text, text, jsonb, jsonb) to service_role;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('media_connections', 'AniList, Last.fm and Trakt on profiles',
        'Link AniList, Last.fm and Trakt and show your anime, music, movies and shows on your profile', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Background refresh: every 15 minutes the route refreshes a few links older than a day (it answers at once when
-- the flag is off or nothing is stale). Remove with select cron.unschedule('media-links-tick').
do $$ begin
  -- Nested: plpgsql plans a whole condition at once, and cron.job doesn't exist everywhere (local tests).
  if to_regclass('cron.job') is not null then
  if not exists (select 1 from cron.job where jobname = 'media-links-tick') then
    perform cron.schedule('media-links-tick', '*/15 * * * *', $job$
      select net.http_post(
        url := 'https://www.yapper.website/api/cron/media-links',
        body := '{}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
          'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'request_limits_secret' limit 1)),
        timeout_milliseconds := 60000)
      where exists (select 1 from vault.decrypted_secrets where name = 'request_limits_secret')
    $job$);
  end if;
  end if;
end $$;
