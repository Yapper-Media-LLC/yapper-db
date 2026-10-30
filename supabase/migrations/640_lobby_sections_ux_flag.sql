-- 640: flag for the lobby editor UX pass (components/LobbyEditor.tsx, components/LobbyV2.tsx): each section in the
-- Sections tab says what it shows and where it comes from with a live preview line, the Content tab follows the page's
-- order with a sentence per field, and empty cards on the lobby link to the right tab. Test mode: HQ test server and
-- Antic. Data only, no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('lobby_sections_ux', 'Lobby editor explainers', 'Customize lobby: every section explains itself with a live preview line, Content fields follow the page order, and empty lobby cards link straight to the right tab.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
