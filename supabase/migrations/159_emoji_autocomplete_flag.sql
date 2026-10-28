-- Flag for ":name" emoji autocomplete in the message box (client-only feature, no schema change).
insert into public.feature_flags (key, label, description, mode, servers)
values ('emoji_autocomplete', 'Emoji autocomplete', 'Type : and 2+ letters in the message box to get emoji suggestions; a full :name: turns into the emoji.', 'test', '{}')
on conflict (key) do nothing;
