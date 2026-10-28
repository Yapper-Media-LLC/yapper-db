-- Raid protection (applied live Oct 14): servers.locked_until/lock_reason, channels.auto_slow_until.
-- auto_lock_on_raid (25 joins/min -> 15 min lock), auto_slowmode (30 msgs from 6 people in 10s -> 5s slowmode
-- for 10 min), join_server/join_public_server refuse locked servers, message_slowmode = mods only when locked,
-- set_server_lock(sid, minutes) for managers.
alter table public.servers add column if not exists locked_until timestamptz;
alter table public.servers add column if not exists lock_reason text;
alter table public.channels add column if not exists auto_slow_until timestamptz;
create index if not exists server_members_joined_idx on public.server_members (server_id, joined_at desc);
