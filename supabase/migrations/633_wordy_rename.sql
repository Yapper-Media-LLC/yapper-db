-- 633: the word game bot is called Wordy, not Wordle (Antic, Oct 28: "change name to something that won't get us
-- sued"; Wordle is a New York Times trademark). 630 carries the new wording for every function and the "/" menu
-- (re-applied live right after this); this one renames the live profile and the flag label. Internal keys
-- (`wordle` bot key, wordle_* tables and functions, flag `wordle_bot`, /bots/wordle.svg) stay as they are, nobody sees
-- them. Re-runnable.
update public.profiles set display_name = 'Wordy', username = 'Wordy',
  bio = 'One five letter word a day. Type /wordy in my channel and guess away.'
where id = (select user_id from public.bot_accounts where bot = 'wordle')
  and (display_name is distinct from 'Wordy' or username is distinct from 'Wordy');
update auth.users set raw_user_meta_data = raw_user_meta_data || '{"username":"Wordy"}'::jsonb
where id = (select user_id from public.bot_accounts where bot = 'wordle') and raw_user_meta_data ->> 'username' is distinct from 'Wordy';
update public.feature_flags set label = 'Wordy (word game bot)',
  description = 'In-house word game bot: a daily five letter word, guesses in one channel, stats and a recap.'
where key = 'wordle_bot' and label is distinct from 'Wordy (word game bot)';
