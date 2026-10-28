-- 415: flag gif_ads (test): a sponsored slot from KLIPY in the GIF picker (their Ads API, paid per view). The
-- /api/gifs request then carries the person's user agent, an anonymous stable id and the picker width; KLIPY
-- answers with an "ad" item whose HTML goes in a sandboxed frame above the results. Phones only (KLIPY's rule).
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gif_ads', 'GIF picker ads', 'A sponsored KLIPY slot above the GIF results (phones)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
