-- 220: flag for the "Leaving Yapper" link check (components/LinkGuard.tsx, lib/linkguard.ts). Test mode: Antic's test
-- server and Antic only. Client-side only, no other SQL. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('link_warning', 'Link safety check', 'Links show where they really go before opening, with warnings for fake look-alike sites',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
