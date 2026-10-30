-- 689: Folder customization (flag folder_custom). Server folders (154, flag server_folders) already keep a name and a
-- colour in user_server_folders, synced to the account. This only adds the flag for the new bits in the app: any
-- colour (picker + hex box, not just the 10 presets), a preview, and the colour shown on closed folders too.
-- Data only: no schema change, so no schema reload.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('folder_custom', 'Folder customization',
  'Server folders: any colour (picker + hex), a preview in Folder settings, and the colour on closed folders. Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
