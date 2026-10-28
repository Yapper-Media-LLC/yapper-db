-- 450: Steam on profiles, customizable (flag steam_link, from 447).
--   * prefs: how your Steam block looks (hidden, style, which parts show, up to 3 pinned games and 8 pinned
--     achievements). You change it yourself (column grant + own-row policy); the server never touches it.
--   * Hidden really hides: others can't read the row at all, only you.
--   * The cache keeps more for the Steam dashboard: up to 12 games and 60 achievements (pinned ones are kept on refresh).
-- Re-runnable (run 447 only together with this). Only the small steam_links table is touched; locks wait at most 5 s.
set lock_timeout = '5s';

alter table public.steam_links add column if not exists prefs jsonb not null default '{}';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'steam_links_prefs_check') then
    alter table public.steam_links add constraint steam_links_prefs_check check (
      jsonb_typeof(prefs) = 'object'
      and pg_column_size(prefs) <= 2000
      and (not prefs ? 'hidden' or jsonb_typeof(prefs -> 'hidden') = 'boolean')
      and (not prefs ? 'show_count' or jsonb_typeof(prefs -> 'show_count') = 'boolean')
      and (not prefs ? 'show_games' or jsonb_typeof(prefs -> 'show_games') = 'boolean')
      and (not prefs ? 'show_achs' or jsonb_typeof(prefs -> 'show_achs') = 'boolean')
      and (not prefs ? 'style' or prefs ->> 'style' in ('plain', 'steam', 'theme'))
      and (not prefs ? 'games' or (jsonb_typeof(prefs -> 'games') = 'array' and jsonb_array_length(prefs -> 'games') <= 3))
      and (not prefs ? 'achs' or (jsonb_typeof(prefs -> 'achs') = 'array' and jsonb_array_length(prefs -> 'achs') <= 8))
    );
  end if;
end $$;

-- Bigger cache for the dashboard.
alter table public.steam_links drop constraint if exists steam_links_games_check;
alter table public.steam_links drop constraint if exists steam_links_achievements_check;
alter table public.steam_links add constraint steam_links_games_check
  check (jsonb_typeof(games) = 'array' and jsonb_array_length(games) <= 12);
alter table public.steam_links add constraint steam_links_achievements_check
  check (jsonb_typeof(achievements) = 'array' and jsonb_array_length(achievements) <= 60);

-- Hidden rows are yours alone.
alter policy "read steam links" on public.steam_links
  using (user_id = (select auth.uid()) or not coalesce((prefs ->> 'hidden')::boolean, false));
drop policy if exists "edit own steam prefs" on public.steam_links;
create policy "edit own steam prefs" on public.steam_links for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke update on public.steam_links from authenticated;
grant update (prefs) on public.steam_links to authenticated;
reset lock_timeout;
