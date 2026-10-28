-- 446: flag fast_send (test): sending a picture makes fewer back-to-back trips to the database.
-- Our Vercel functions run in iad1 (US) and the database in Frankfurt, so each trip is ~100-200 ms and a send made
-- about ten in a row. With the flag: logins are checked locally (getClaims, ES256) instead of asking Supabase Auth,
-- upload-url's three lookups run together, and the scan reads the file, checks "seen before?" and the rate limit
-- at once, and runs the fingerprint lookup and the small copy alongside the models (lib/server/media.ts).
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('fast_send', 'Faster picture sending', 'Fewer database round trips while a picture is uploaded and checked', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
