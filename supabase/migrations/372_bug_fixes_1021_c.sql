-- 372: bug fixes Oct 21 (c). Re-runnable.
--
-- 1. Mentions inbox listing replies to me: already done live by another change on Oct 21 (my_mentions has a "rep"
--    branch), so 372 leaves my_mentions alone.
-- 2. Badges of a taken-down server (servers.shut_down_at): mark_read refuses its channels (can_access_channel, 331),
--    so their unread counts and mentions could never be cleared ("the notifications stay after the server is taken
--    down"). unread_counts_for / unread_counts_v1 skip those servers for everyone but staff, like my_mentions does.
-- 3. Joining (or leaving) a server on one device didn't reach my other devices: for servers up to 1000 members the
--    member event only went to server:<id>, which a device that isn't in the server yet doesn't listen to. The person
--    who joined or left gets a copy on their own user:<id> topic too (the app reloads its server list on it).
--
-- Live definitions patched in place from pg_get_functiondef (Oct 21), like 311/331: only the lines below change;
-- signatures, security definer, search_path and grants stay. If an anchor isn't found exactly the expected number of
-- times, the whole migration stops (the function changed since: read its live text again).

set lock_timeout = '2s';

do $$
declare p record; d text; n text; i int; n_hits int;
begin
  for p in
    select * from (values
      -- 2. unread counts: a "down" list (taken-down servers I'm in, empty for staff), and their channels left out.
      ('public.unread_counts_for(public.channels[])', 'down as materialized',
       array[
         $a$  mine as materialized ($a$,
         $a$    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()$a$
       ],
       array[
         $a$  down as materialized (
    select sd.id from public.server_members dm
    join public.servers sd on sd.id = dm.server_id and sd.shut_down_at is not null
    where dm.user_id = auth.uid() and not public.is_staff()
  ),
  mine as materialized ($a$,
         $a$    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
      and c.server_id not in (select d.id from down d)$a$
       ]),
      ('public.unread_counts_v1()', 'down as materialized',
       array[
         $a$  mine as materialized ($a$,
         $a$    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()$a$
       ],
       array[
         $a$  down as materialized (
    select sd.id from public.server_members dm
    join public.servers sd on sd.id = dm.server_id and sd.shut_down_at is not null
    where dm.user_id = auth.uid() and not public.is_staff()
  ),
  mine as materialized ($a$,
         $a$    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
      and c.server_id not in (select d.id from down d)$a$
       ]),
      -- 3. member events: my own join/leave also on user:<id>.
      ('public.broadcast_member_change()', '372: the person',
       array[
         $a$    perform public.bc('server:' || sid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);$a$
       ],
       array[
         $a$    perform public.bc('server:' || sid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
    -- 372: the person's other devices aren't on server:<id> before they join (or after they leave): tell them directly.
    if tg_op in ('INSERT', 'DELETE') then
      perform public.bc('user:' || uid, 'member', tg_op, tg_table_name, tg_table_schema, new, old);
    end if;$a$
       ])
    ) v(fn, marker, anchors, replacements)
  loop
    d := pg_get_functiondef(p.fn::regprocedure);
    continue when position(p.marker in d) > 0;          -- already patched
    n := d;
    for i in 1 .. array_length(p.anchors, 1) loop
      -- Every anchor must be there exactly once in the live text (replace() would hit every copy).
      n_hits := (length(d) - length(replace(d, p.anchors[i], ''))) / length(p.anchors[i]);
      if n_hits <> 1 then raise exception '% changed: anchor % expected once, found % times. Read its live text again', p.fn, i, n_hits; end if;
      n := replace(n, p.anchors[i], p.replacements[i]);
    end loop;
    execute n;
  end loop;
end $$;
