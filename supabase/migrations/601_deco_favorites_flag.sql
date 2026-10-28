-- 601: flag deco_favorites (test). The avatar decoration picker gets a star on each tile and a Show filter
-- (Included: All / Favorites / Pictures / Effects; Community: All / Favorites / Owned / Halloween). The stars are
-- saved in the account's user_prefs row (lib/prefs.ts, favDecos), so no new table. Flag row only, re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_favorites', 'Decorations: favorites and filters', 'Star decorations in the picker and filter by favorites, owned, pictures or effects.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
