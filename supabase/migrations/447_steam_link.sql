-- 447: Link a Steam account to your profile (flag steam_link, test).
--   * You sign in on Steam (OpenID 2.0, app/api/steam/*); the server checks the answer with Steam and stores your
--     SteamID64 here. One Steam account belongs to one Yapin' account.
--   * Your Steam name, avatar, game count, top games and latest achievements are cached in the same row, written
--     only by the server (service_role) with the STEAM_API_KEY: on link (at most every 10 minutes) and from
--     Settings (once an hour), per user (steam_refresh_log). Profile views read this row and never call Steam.
--   * Everyone signed in can read the rows (it's what Steam itself shows publicly); you can delete your own (Disconnect).
-- Re-runnable. New table only, nothing else is locked.

create table if not exists public.steam_links (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  steam_id text not null unique check (steam_id ~ '^7656119[0-9]{10}$'),
  persona text not null default '' check (char_length(persona) <= 64),
  avatar_url text check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 300)),
  profile_url text check (profile_url is null or (profile_url ~ '^https://steamcommunity\.com/' and char_length(profile_url) <= 300)),
  -- false when Steam hides their game details (private profile): no games or achievements to show.
  games_public boolean not null default false,
  game_count int check (game_count is null or game_count >= 0),
  games jsonb not null default '[]' check (jsonb_typeof(games) = 'array' and jsonb_array_length(games) <= 6),
  achievements jsonb not null default '[]' check (jsonb_typeof(achievements) = 'array' and jsonb_array_length(achievements) <= 12),
  refreshed_at timestamptz,
  linked_at timestamptz not null default now()
);

alter table public.steam_links enable row level security;
drop policy if exists "read steam links" on public.steam_links;
create policy "read steam links" on public.steam_links for select to authenticated using (true);
drop policy if exists "unlink own steam" on public.steam_links;
create policy "unlink own steam" on public.steam_links for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.steam_links from public, anon, authenticated;
grant select, delete on public.steam_links to authenticated;
grant all on public.steam_links to service_role;

-- When each user last made the server call Steam (link or refresh). Separate from steam_links so a disconnect
-- doesn't reset the wait. Server only: no grants to anon/authenticated.
create table if not exists public.steam_refresh_log (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  at timestamptz not null default now()
);
alter table public.steam_refresh_log enable row level security;
revoke all on public.steam_refresh_log from public, anon, authenticated;
grant all on public.steam_refresh_log to service_role;

-- True (and the clock restarts) when the user's last Steam call is older than p_gap_sec. One statement, so two
-- requests at once can't both get a turn.
create or replace function public.steam_claim_refresh(p_user uuid, p_gap_sec int)
returns boolean language sql security definer set search_path = public as $$
  with t as (
    insert into public.steam_refresh_log as l (user_id, at) values (p_user, now())
    on conflict (user_id) do update set at = now()
      where l.at < now() - make_interval(secs => greatest(p_gap_sec, 60))
    returning 1
  )
  select exists (select 1 from t);
$$;
revoke all on function public.steam_claim_refresh(uuid, int) from public, anon, authenticated;
grant execute on function public.steam_claim_refresh(uuid, int) to service_role;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('steam_link', 'Steam on profiles', 'Link a Steam account and show its name, games and achievements on your profile', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
