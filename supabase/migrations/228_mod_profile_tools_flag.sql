-- Mod tools on profiles (flag mod_profile_tools): staff see someone's standing and active warnings (with Remove)
-- in the profile "..." menu, plus Clear timeout / Unban from Yapper / Unban from server; mod tools jump to a
-- message on click. Client only: uses user_warnings (staff RLS), mod_user_case, mod_remove_warning,
-- admin_clear_timeout, site_unban and unban_member as they are.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_profile_tools', 'Mod tools on profiles', 'Warnings with Remove, unban and clear timeout right from a profile, and click a reported message to jump to it.', 'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
