-- 387: flag call_ringtones (Oct 22). Real ringtones for DM and group calls instead of the beeps: public/sounds/ring-in
-- (someone is calling you, loops until you answer, decline or it stops) and ring-out (your call is ringing the other
-- side, loops until someone joins, you hang up, or "No answer"). Client only (lib/calls.ts, lib/notify.ts playLoop).
-- Test: Antic and HQ. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('call_ringtones', 'Call ringtones', 'Ringtones for incoming and outgoing calls instead of beeps', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
