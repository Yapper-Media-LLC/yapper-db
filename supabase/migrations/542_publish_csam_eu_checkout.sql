-- 542: publish the CSAM match queue (536, admins only in the UI) and EU checkout (539) to everyone. Antic, Oct 26.
-- Data only (no schema reload). Re-runnable.
update public.feature_flags set mode = 'everyone' where key in ('csam_queue', 'eu_checkout') and mode <> 'everyone';
