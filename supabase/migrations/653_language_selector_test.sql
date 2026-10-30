-- 653: the language selector is back (lib/i18n.ts, Settings, Appearance, Language). The old build (Oct 19) never made
-- it onto main, but its flag row was left on `everyone`, so the rebuilt picker would show for everyone on the next
-- release. Back to `test` (Antic and the Yapper test server) until Antic says publish. Rows only, no schema change.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('language_selector', 'Language selector', 'Pick the app language in Settings, Appearance: Spanish, German, French or Portuguese. Only the main screens are translated so far, the rest stays English.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do update set mode = 'test';
