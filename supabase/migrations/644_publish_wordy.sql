-- 644: publish Wordy, the word game bot, to every server (Antic, Oct 28: "publish"). Row update only, no reload.
-- Apply after 630 (re-applied with the Wordy wording) and 633, so nobody meets the old name.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'wordle_bot' and mode <> 'everyone';
