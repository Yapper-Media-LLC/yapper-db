-- 545: flag mobile_nav (test: Antic + HQ test server). Phones, classic look: swipe right from the left edge or the
-- header to leave a chat, swipe left from the right edge for the members sheet (full screen, swipe right to close),
-- and the Home / Servers / Mentions / You tab bar under the lists. Client: lib/phone.ts, app/mobile.css,
-- components/Shell.tsx, ChatView.tsx, MemberList.tsx. Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mobile_nav', 'Phone navigation', 'Swipe back and to members, bottom tab bar and a full-screen members sheet on phones', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
