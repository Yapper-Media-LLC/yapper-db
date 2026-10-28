-- 489: flag embed_builder published to everyone (Antic, Oct 25: "Publish, publish, publish"). Make a post in Edit channel
-- -> Webhooks, link buttons on webhook URLs and :name: emoji mapping (483) for every server. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('embed_builder', 'Embed builder', 'Make a post with embeds and link buttons as a webhook from Edit channel, plus link buttons on webhook URLs', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do update set mode = 'everyone', updated_at = now();
