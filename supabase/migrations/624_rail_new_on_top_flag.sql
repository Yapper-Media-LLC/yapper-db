-- 624: flag rail_new_on_top (test). A server you just joined or created goes to the top of the rail (on its own,
-- outside folders) and opens, saved to profiles.server_order the same way a drag is (lib/servers.ts putServerOnTop).
-- Without the flag it lands at the end, like before. Data only, no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('rail_new_on_top', 'New servers on top', 'A server you just joined or created goes to the top of the server rail and opens, instead of landing at the bottom.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
