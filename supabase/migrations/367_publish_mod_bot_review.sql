-- 367: publish mod_bot_review (Antic, Oct 21). Applied live with 366 around 16:40 UTC. Row update only, no reload.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'mod_bot_review';
