-- 412: flag ui_panel (test): the Discord-style window from the dev branch. Brand strip on top, sidebar and chat in one
-- bordered panel, floating rail icons, dimmer borders, and the Shift action bar on messages. Everything else from that
-- branch (profile identity rows, DM dock details, badge overflow) ships to everyone. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('ui_panel', 'Panel look', 'Discord-style window: brand strip on top, sidebar and chat in one bordered panel, floating rail icons, dimmer borders, and the Shift action bar on messages', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
