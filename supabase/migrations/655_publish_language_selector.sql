-- 655: Antic said publish (Oct 28): the language selector goes to everyone. Applied live as a row update (data only).
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'language_selector';
