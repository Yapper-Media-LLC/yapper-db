-- 337: flag home_dark, published. The homepage (/home, and / logged out) is dark by default with a light mode
-- toggle in the nav that brings back the orange look. The code no longer checks the flag (no flash while it loads);
-- the row is the record that it shipped. Data only, so no schema reload. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('home_dark', 'Dark homepage', 'Homepage is dark by default, with a light mode toggle in the nav that brings back the orange look.', 'everyone', '{}', '{}')
on conflict (key) do update set mode = 'everyone', description = excluded.description;
