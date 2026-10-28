-- 568: Community Helper badge (flag community_helper, test). For members who help people out without being staff.
-- admin_set_badge learns the key 'community_helper'. Who gives it: admins, Management (537's rule: any badge but
-- staff/developer/community_manager) and, like Artist, head mods while head_mod_badges is on for them. Mods can't.
-- Both changes are one-line patches into the live text (pg_get_functiondef), like 537: skipped where the function
-- isn't there (test databases) or already patched; a changed anchor stops the migration so nothing goes half in.
-- Nobody gets the badge here. Re-runnable.

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('community_helper', 'Community Helper badge', 'A badge for members who help people out in the community. Staff give it from the Mod Center',
        'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if position(old_text in f) = 0 then raise exception '568: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

-- The allow-list.
select pg_temp.patch_fn('public.admin_set_badge(uuid,text,boolean)', '''artist'', ''community_helper'')',
  '''creator_3'', ''artist'')',
  '''creator_3'', ''artist'', ''community_helper'')');
-- Head mods give it like Artist (flag head_mod_badges).
select pg_temp.patch_fn('public.admin_set_badge(uuid,text,boolean)', 'badge in (''artist'', ''community_helper'')',
  '(badge = ''artist'' and public.feature_on(''head_mod_badges'', null)',
  '(badge in (''artist'', ''community_helper'') and public.feature_on(''head_mod_badges'', null)');
