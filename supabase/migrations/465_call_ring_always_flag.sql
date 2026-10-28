-- 465: flag call_ring_always (Oct 24). Calls ring (incoming ring and the outgoing ringback) even with "Notification
-- sounds" off, and on the speakers picked in Settings > Voice. Before, turning off message sounds silenced every call
-- both ways (Antic had it off and heard no ring). Do Not Disturb still mutes incoming rings. Client only (lib/calls.ts
-- ringAllowed, lib/notify.ts routeSounds). Data only, no schema reload. Test: Antic and HQ. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('call_ring_always', 'Calls ring with sounds off', 'Call ringtones play even when notification sounds are off, on the chosen speakers', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
