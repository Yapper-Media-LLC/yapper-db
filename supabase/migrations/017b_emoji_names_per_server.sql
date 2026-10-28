-- ============================================================
-- Yapper · Emoji names are unique per server, not per person
-- (so a moderator can add :pog: to two different servers).
-- ============================================================
drop index if exists public.emojis_owner_name_idx;
