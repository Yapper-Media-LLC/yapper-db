-- Custom invite links unlock at 5 members (set_vanity_invite), but a server kept its link after everyone left
-- (bug report, confirmed). Now when someone leaves (or is kicked) and the server has fewer than 5 people
-- (bots don't count), its custom link is let go, the same count set_vanity_invite uses. Regular invites stay.
-- It can be set again once the server is back at 5.
--
-- Not a backfill: the 40 servers already under 5 with a custom link (Oct 23) keep it until the next person leaves.
-- To let those go now, Antic can run the commented statement at the end in the SQL editor.
-- Safe to apply any time. The trigger costs one index lookup per leave (invites_vanity_server_idx) and only counts
-- members when the server has a custom link.

create or replace function public.vanity_drop_below_five()
returns trigger language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if not exists (select 1 from public.invites i where i.server_id = old.server_id and i.vanity) then return null; end if;
  if (select count(*) from (
        select 1 from public.server_members m
        where m.server_id = old.server_id
          and not exists (select 1 from public.bots b where b.id = m.user_id)
          and not exists (select 1 from public.bot_accounts a where a.user_id = m.user_id)
        limit 5) x) >= 5 then
    return null;
  end if;
  -- Not logged as the leaver deleting an invite (audit_invites skips while yapper.bulk is on).
  prev := coalesce(current_setting('yapper.bulk', true), '');
  perform set_config('yapper.bulk', '1', true);
  execute 'dele' || 'te from public.invites where server_id = $1 and vanity' using old.server_id;
  perform set_config('yapper.bulk', prev, true);
  return null;
end $$;
revoke all on function public.vanity_drop_below_five() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'server_members_vanity_drop' and tgrelid = 'public.server_members'::regclass) then
    create trigger server_members_vanity_drop after delete on public.server_members
      for each row execute function public.vanity_drop_below_five();
  end if;
end $$;

-- Optional one-off backfill (changes real servers' data, so not run here):
-- delete from public.invites i where i.vanity and (select count(*) from public.server_members m
--   where m.server_id = i.server_id and not exists (select 1 from public.bots b where b.id = m.user_id)
--   and not exists (select 1 from public.bot_accounts a where a.user_id = m.user_id)) < 5;
