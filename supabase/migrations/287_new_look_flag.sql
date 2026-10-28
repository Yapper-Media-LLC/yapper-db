-- 287: flag for Yapper's "new look" (warm palette, floating cards, Bricolage + Figtree, bubbles). Test mode for
-- Antic's account only: servers stays empty on purpose, since a listed server would turn it on for all its members
-- (flagOn). The look lives in app/newlook.css under html.new-look, set by Shell when this flag is on.
-- Only a row: no schema change. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('new_look', 'New look', 'Warm colours, floating cards, new fonts and chat bubbles', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
