-- 583: DM privacy defaults (flags dm_privacy and dm_card, test). From AutumnChills' safety list (Oct 27, 2026):
--   1. "Who can message you" should default to Friends only, to cut spam DMs, bots and sus links.
--   2. Nobody, not even a friend, can put you in a group chat until you allow it (profiles.group_adds).
-- This file only adds the setting and the check. The defaults for NEW accounts flip in the publish migration
-- (dms_from 'friends', group_adds 'nobody'), so test accounts can try it first; existing rows keep 'friends' for
-- group_adds (today's behaviour: any friend can add you). Rolling existing accounts over is a separate, batched update.
-- The group check only bites while the flag is on for the person doing the adding, so test servers see it first.
-- Re-runnable.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('dm_privacy', 'DM privacy defaults', 'Settings > Privacy: "Who can add you to group chats" (Friends / Nobody). Publishing flips new accounts to Friends only DMs and Nobody for group adds.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- The safety card at the start of a DM: avatar, name, a staff label (from the badges only staff can hold), how many
-- servers you share, and Add | Block, Unadd | Block or Unblock. Client only.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('dm_card', 'DM safety card', 'Card at the start of a DM: who they are, staff label, mutual servers, Add | Block / Unadd | Block / Unblock.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Who may put me in a group chat. 'friends' = any friend (how it always worked), 'nobody' = no one.
alter table public.profiles add column if not exists group_adds text not null default 'friends'
  check (group_adds in ('friends', 'nobody'));
-- Read by the Settings page on its own (not in PROFILE_COLS, so the client can ship before this is live); only your own row is updatable (policy "you can edit your own profile").
grant select (group_adds) on public.profiles to anon, authenticated;
grant update (group_adds) on public.profiles to authenticated;

-- check_addable (008) runs inside create_group and add_group_members (582), as the caller. Now it also refuses
-- people who don't take group adds, with their name in the message.
create or replace function public.check_addable(people uuid[])
returns void
language plpgsql
set search_path = public
as $$
declare
  p uuid;
  who text;
  guard boolean := public.feature_on_for_me('dm_privacy');
begin
  foreach p in array coalesce(people, '{}') loop
    if p = auth.uid() then continue; end if;
    if not public.are_friends(auth.uid(), p) or public.is_blocked_between(auth.uid(), p) then
      raise exception 'You can only add friends';
    end if;
    if guard then
      select username into who from public.profiles where id = p and group_adds = 'nobody';
      if who is not null then
        raise exception '% doesn''t let people add them to group chats.', who;
      end if;
    end if;
  end loop;
end;
$$;
