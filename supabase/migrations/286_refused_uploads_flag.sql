-- Refused uploads in the Mod file (flag refused_uploads_view). The "3 refused uploads" pill in the mod file header was
-- only a count: the pictures could be opened only on a ban appeal (Show evidence), so for an account that isn't banned
-- there was no way to look at what the image check refused. With the flag on, the pill opens them, each one hidden
-- until clicked. Client only: it uses staff_ban_evidence (233) and /api/media/appeals?scanBucket=&scanPath= as they
-- are (staff only, 5 minute signed address for the private quarantine copy). Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('refused_uploads_view', 'Refused uploads in the Mod file', 'Click the "refused uploads" pill on a user in the Mod Center to look at the pictures the image check refused, even when they are not banned.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
