-- 205: feature flag for the browser REST traffic going to our own PostgREST (api.yapper.website, ops/api/).
-- Test mode: only Antic's test servers (members of a listed server) send REST calls there; everyone else stays on
-- Supabase. Code: lib/apiBase.ts + lib/supabase.ts. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers)
values ('api_hetzner', 'API on Hetzner', 'Browser REST calls go to api.yapper.website (our own PostgREST)', 'test', '{}')
on conflict (key) do nothing;
