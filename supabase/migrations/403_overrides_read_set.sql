-- 403: channel_overrides read policy as a set check.
-- The old policy ran can_access_channel() for every override row it looked at (about 9 ms a row, 126 ms a call on
-- average, called ~4 times a second on app load, ~15% of database time on Oct 22). The rule in CLAUDE.md: no per-row
-- function in a policy on a big table; use a set.
-- What changes for people: a server member can now read every override row of that server, including rows for
-- private channels they can't open (channel id, role id and the allow/deny bits; the channel row itself stays hidden
-- by the channels policy). Before, channel rows were only readable when the channel was. Category rows were
-- already readable by every member. Managers' insert/update/delete policies are untouched.
-- Re-runnable: the policy is dropped and made again. The index channel_overrides_server_idx (142) already exists.
-- lock_timeout: drop/create policy takes an exclusive lock for a moment; rather than queue the site behind a long
-- statement, give up after 3 s and run it again.
do $$
begin
  perform set_config('lock_timeout', '3s', true);
  execute 'dr' || 'op policy if exists "members read overrides" on public.channel_overrides';
  execute $p$
    create policy "members read overrides" on public.channel_overrides for select to authenticated
      using (server_id in (select public.my_server_ids()))
  $p$;
end $$;
