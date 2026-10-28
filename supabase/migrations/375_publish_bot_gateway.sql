-- 375: publish the bot gateway (flag bot_gateway, migration 355) to everyone. Only a row: no schema change.
-- Bots with the new yapper.js (Node 22+, Bun, Deno) use wss://rt.yapper.website/bot; anything else keeps long polling.
update public.feature_flags set mode = 'everyone' where key = 'bot_gateway';
