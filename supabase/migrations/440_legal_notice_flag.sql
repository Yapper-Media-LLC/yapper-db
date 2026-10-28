-- 440: flag legal_notice: a one-time "We updated our Terms and Privacy Policy" card (components/LegalUpdateNotice.tsx)
-- for accounts made before TERMS_UPDATED (Terms 16). Published right away: the Terms already say people are told.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('legal_notice', 'Terms update card', 'One-time card telling existing accounts the Terms and Privacy Policy changed', 'everyone',
        '{}', '{}')
on conflict (key) do nothing;
