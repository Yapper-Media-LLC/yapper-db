-- 490: flag discord_import_verify (test): Import from Discord asks you to sign in with Discord first and only reads a
-- Discord server you own or have Manage Server / Administrator in (security pass 2, N2). Before this, anyone signed in
-- could import any Discord server Yapin's bot is in by pasting its id. Needs DISCORD_CLIENT_SECRET in Vercel and the
-- /api/import/discord/callback redirects in the Discord app before it can be published. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('discord_import_verify', 'Discord import: prove you run it', 'Discord sign-in before importing; only servers you own or manage', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
