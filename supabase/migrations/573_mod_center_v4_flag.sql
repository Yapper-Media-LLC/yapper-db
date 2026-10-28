-- 573: Mod Center v4 flag (test: Antic). Data only, no schema change, safe at any hour.
-- v4 = confirm sheets before one-click actions (unban, pause, remove, reset standing, limit boost...), a 10 s Undo
-- after queue and verification decisions, a pace line + 3 s gap past 10 verifications a minute, a real
-- "couldn't load" state instead of "All clear", Ctrl+K to find a person from any view, the Rail badge counting
-- everything in To do, phones reaching every To do view, Mod stats -> that mod's log.
-- Publish: update public.feature_flags set mode = 'everyone' where key = 'mod_center_v4';
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_center_v4', 'Mod Center v4', 'Confirm sheets, Undo toasts, pace line in Verification, error states, Ctrl+K find a person, full To do badge, phone chips.', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
