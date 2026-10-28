-- 285: flag for the bot API's database calls going to our own PostgREST (api.yapper.website) first, with a
-- per-request fallback to Supabase (lib/server/apiAdmin.ts, lib/server/apiFetch.ts). Test: bots owned by Antic or by
-- members of the test server. "everyone" also moves the bot token lookup. Off: everything on Supabase as before.
-- Only a row: no schema change. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('api_hetzner_server', 'Bot API on our server', 'Bot API database calls go to our own API server first, Supabase if it can''t answer', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
