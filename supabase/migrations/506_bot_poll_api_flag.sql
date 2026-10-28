-- 506: flag bot_poll_api (test: Antic). The bot API's events long poll reads bot_events through our own PostgREST
-- (api.yapper.website) instead of Supabase's gateway, like the rest of the bot API under api_hetzner_server. It was
-- ~117 requests a second on Oct 25, a third of Supabase's API traffic. Test = bots owned by the listed users; publish
-- with mode 'everyone'; 'off' sends every poll back to Supabase at once (no deploy). app/api/bot/v1, lib/server/apiAdmin.ts.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_poll_api', 'Bot polling on our API', 'Bot event polling goes through api.yapper.website instead of Supabase', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
