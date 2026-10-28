-- 401: flag flips, applied live Oct 22 2026 ~16:40 UTC (data only, no schema reload).
--   * plus_4000 published: every Yapper Plus member gets 4000 character messages (399).
--   * halloween_decos off: the /halloween upload page is closed for now (397). Approved event decorations stay
--     wearable; turning it back to 'test' or 'everyone' reopens the page.
-- Re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'plus_4000' and mode <> 'everyone';
update public.feature_flags set mode = 'off', updated_at = now() where key = 'halloween_decos' and mode <> 'off';
