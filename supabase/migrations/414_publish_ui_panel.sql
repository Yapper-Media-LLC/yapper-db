-- 414: ui_panel published to everyone (412), applied live Oct 23 2026 after Antic tried it. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'ui_panel' and mode <> 'everyone';
