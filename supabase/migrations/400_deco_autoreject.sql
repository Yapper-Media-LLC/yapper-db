-- 400: turn down flagged decorations automatically (flag deco_autoreject, test). When the stolen-art check (381) says
-- a waiting decoration is suspect or stolen, the server turns it down straight away with a reason that fits what the
-- check found, instead of leaving it in Mod Center -> Decorations -> Flagged (Antic, Oct 22: he turned down all 173
-- waiting flagged ones by hand with these reasons). Live ones that get flagged stay for staff to look at.
-- lib/server/decoCheck.ts calls deco_check_autoreject after saving a suspect or stolen verdict.
-- Logged in mod_log as deco_rejected with no actor and "Auto: " in front of the reason. Re-runnable.

set lock_timeout = '5s';

-- The reason the artist sees, by where the check thinks it came from.
create or replace function public.deco_autoreject_note(p_source text)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_source
    when 'discord' then 'Looks like this was taken from Discord''s shop. Only send in art you made yourself.'
    when 'other_app' then 'Looks like this was taken from another app. Only send in art you made yourself.'
    when 'character_or_brand' then 'Uses a character or brand you don''t own. Only send in your own original art.'
    when 'internet' then 'Looks like this was taken from the internet. Only send in art you made yourself.'
    when 'yapper_copy' then 'Looks like a copy of another Yapper artist''s decoration. Only send in your own art.'
    else 'Our check thinks this isn''t your own art. Only send in art you made yourself.'
  end;
$$;

-- Turn down one waiting decoration if its check flagged it and nobody cleared it. True when it was turned down.
-- In test mode only for artists in the flag's users or a member of one of its servers.
create or replace function public.deco_check_autoreject(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare d public.community_decos; c public.community_deco_checks; note text; got int;
begin
  select * into d from public.community_decos where id = p_id for update;
  if not found or d.status <> 'pending' then return false; end if;
  if not coalesce((select f.mode = 'everyone' or (f.mode = 'test' and (d.artist_id = any(f.users)
      or exists (select 1 from public.server_members m where m.user_id = d.artist_id and m.server_id = any(f.servers))))
    from public.feature_flags f where f.key = 'deco_autoreject'), false) then
    return false;
  end if;
  select * into c from public.community_deco_checks
    where deco_id = p_id and verdict in ('suspect', 'stolen') and cleared_at is null for update;
  if not found then return false; end if;
  note := public.deco_autoreject_note(c.source);
  update public.community_decos set status = 'rejected', review_note = note, reviewed_by = null, reviewed_at = now()
    where id = p_id and status = 'pending';
  get diagnostics got = row_count;
  if got = 0 then return false; end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values (null, 'deco_rejected', d.artist_id, left('Auto: ' || d.name || ': ' || note, 300));
  return true;
end; $$;

revoke all on function public.deco_autoreject_note(text) from public, anon, authenticated;
revoke all on function public.deco_check_autoreject(uuid) from public, anon, authenticated;
grant execute on function public.deco_autoreject_note(text) to service_role;
grant execute on function public.deco_check_autoreject(uuid) to service_role;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_autoreject', 'Decorations: auto turn down flagged', 'Waiting decorations the stolen art check flags get turned down right away with a reason.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

reset lock_timeout;
