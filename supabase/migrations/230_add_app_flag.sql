-- "Add App" on a bot's profile card: pick a server and add the bot right there (flag add_app). Client only.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('add_app', 'Add App on bot profiles', 'An Add App button on bot profiles that adds the bot to one of your servers in the app.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
