-- 370: flag plus_moments (Oct 21). The Plus pop-up at the moments Plus helps: a file over 10 MB (also when the server
-- refuses it), and starting a screen share at 720p. Those two also show to accounts under 3 days old (most Plus
-- buyers buy in their first two days). Client only (components/PlusNudge.tsx). Test: Antic and HQ. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('plus_moments', 'Plus at limit moments', 'Plus pop-up on too-big files and 720p screen share, also for new accounts', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
