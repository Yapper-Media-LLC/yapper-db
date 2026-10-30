-- 685: flag polish_shell (test mode). Re-runnable. Data only (one row): no DDL, no schema reload, fine any time.
-- Small client features from the HQ suggestions:
--   1. On a computer, the mouse's back / forward buttons and Alt+Left / Alt+Right move between the chats you opened
--      (lib/navhistory.ts).
--   2. Minimised call: a small floating call card while you look at another channel, with mute, deafen, the stream
--      you watch (pop out to picture-in-picture) and a way back to the call (components/MiniCall.tsx).
--   3. A "Reconnecting…" / offline pill when the live connection drops (components/ConnBanner.tsx).
-- Test: Antic and the Yapin' HQ test server.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('polish_shell', 'Back/forward, mini call, reconnect pill',
  'Mouse back/forward buttons and Alt+Left/Right move between chats you opened (computer only). A small floating call card keeps your call in reach while you browse other channels. A Reconnecting pill when the live connection drops. Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
