-- 508: flag rt_presence (test). Who's online through our realtime server instead of the database: tabs send their
-- status over the socket (ops/realtime/presence.mjs) and get who is online pushed every 3 s, instead of asking
-- who_online every ~2 min and on every server switch (~1,225 calls a minute on Oct 25). who_online is still asked every
-- 5 min (bots and older tabs only exist in the database). The heartbeat keeps its 45 s while in test (people without
-- the flag still read the database) and drops to every 5 min once the flag is on for everyone. lib/presence.ts, lib/rt.ts.
-- Needs the realtime server with presence.mjs deployed first (an older one ignores the frames: the tab then shows the
-- database's dots, nothing breaks). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('rt_presence', 'Online status over realtime', 'Online dots come from the realtime server instead of polling the database', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
