-- 597: Raids view v2 flag (test: Antic). Data only, no schema change, safe at any hour.
-- v2 = Mod Center Raids shows the last hour by default (older ones behind "Show older"), one clear card per raid:
-- which server or sign-up source, when it started, how many accounts, whether the raid lock is still on, and
-- Ban all / End raid lock / Open server / Dismiss. The Raids badge counts only open raids from the last hour.
-- Publish: update public.feature_flags set mode = 'everyone' where key = 'raids_view_v2';
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('raids_view_v2', 'Raids view v2', 'Mod Center Raids: last hour by default, clear cards (server, started, accounts, still going), Ban all, End raid lock, Open server.', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
