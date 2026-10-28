-- 352: Translate button on Mod Center report cards (flag mod_translate). Rows only, no schema change.
-- Uses /api/translate, which already checks the `translate` flag (on for everyone).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_translate', 'Translate reports', 'A Translate button on Mod Center reports for messages that aren''t in your language.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
