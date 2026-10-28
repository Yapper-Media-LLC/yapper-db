set lock_timeout = '3s';
-- 288: end-to-end encrypted calls (flag call_e2ee). Everyone in a call must agree on encryption or nobody hears
-- anything, so the decision is per room, never per person: /api/livekit-token asks call_e2ee(cid) when a call starts,
-- pins the answer in the LiveKit room's metadata and hands that to everyone who joins later. Server voice channel: on
-- when that server is in the flag's servers. DM or group call: on when anyone in the chat is in the flag's users. Not
-- "member of a test server" for DMs: anyone can open a DM with anyone and ask, which would show who's in private test
-- servers (269 hid those). What it still shows in test mode is "this person is a tester". Re-runnable.

-- Test group like the other test flags: the Yapper test server and Antic (DMs and group calls with him).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('call_e2ee', 'Encrypted calls', 'Voice and screen share are end-to-end encrypted. Keys never leave people''s devices.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.call_e2ee(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select f.mode = 'everyone' or (f.mode = 'test' and case
      when c.server_id is not null then c.server_id = any(f.servers)
      else exists (select 1 from public.channel_members m
                    where m.channel_id = c.id and m.user_id = any(f.users))
    end)
    from public.channels c, public.feature_flags f
    where c.id = cid and c.kind in ('voice', 'dm', 'group') and f.key = 'call_e2ee'
      -- Only people who can see the call get an answer.
      and public.can_access_channel(c.id)
  ), false);
$$;
revoke all on function public.call_e2ee(uuid) from public, anon;
grant execute on function public.call_e2ee(uuid) to authenticated;
reset lock_timeout;
