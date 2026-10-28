-- 386: publish command_target (pick which bot gets a shared slash command) to everyone. Antic said publish, Oct 22.
-- (381-384 left free for other chats' work in progress.) Re-runnable, data only.
update public.feature_flags set mode = 'everyone' where key = 'command_target';
