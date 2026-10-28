-- ============================================================
-- Yapper · Stage 2 (extra) · Crop and zoom for pictures and banners
-- Like Discord's "Edit Image": choose which part of the picture shows,
-- zoom in, and (for profile pictures) rotate. Nothing is re-encoded,
-- so GIFs keep moving; we only store how to frame them.
-- ============================================================

alter table public.profiles
  add column avatar_x real not null default 50 check (avatar_x between 0 and 100),
  add column avatar_y real not null default 50 check (avatar_y between 0 and 100),
  add column avatar_zoom real not null default 1 check (avatar_zoom between 1 and 4),
  add column avatar_rot smallint not null default 0 check (avatar_rot in (0, 90, 180, 270)),
  add column banner_zoom real not null default 1 check (banner_zoom between 1 and 4);

-- Finer banner positioning (it used to be whole percents).
alter table public.profiles
  alter column banner_x type real,
  alter column banner_y type real;
