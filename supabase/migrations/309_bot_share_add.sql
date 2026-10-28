-- 309: share an unverified bot by its ID (flag bot_share_add).
-- To be listed, a bot has to be in 3 servers its maker doesn't own (3+ members each). Until now only the maker could add
-- an unverified bot, and only to servers where they have Manage Server, so makers had to ask strangers for admin in
-- their servers (and DM-spammed people to find them). Now any server manager can add it from Server settings -> Bots ->
-- "Have a bot ID?" while the flag is on for that server, up to 10 servers its maker didn't add it to. After that it needs
-- Yapper's review. The maker has to turn it on first (bots.shareable, set with bot_set_shareable): a bot's ID is its
-- profile ID, so without that anyone could pull someone's private bot into their server or use up its 10 slots.
-- A bot whose maker is site-banned can't be added this way.
-- In bot_add_to_server only the unverified branch is new; the rest is the live text (Oct 20). Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_share_add', 'Share unverified bots', 'Server managers can add an unverified bot by its ID (up to 10 servers)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.bots add column if not exists shareable boolean not null default false;
grant select (shareable) on public.bots to authenticated;

create or replace function public.bot_set_shareable(bid uuid, on_off boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.feature_on_for_me('bot_share_add') then raise exception 'Not available yet'; end if;
  update public.bots set shareable = on_off where id = bid and owner_id = auth.uid();
  if not found then raise exception 'Bot not found'; end if;
end $$;
revoke all on function public.bot_set_shareable(uuid, boolean) from public, anon;
grant execute on function public.bot_set_shareable(uuid, boolean) to authenticated;

create or replace function public.bot_add_to_server(bid uuid, sid uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b public.bots;
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  select * into b from public.bots where id = bid;
  if b.id is null or not (b.owner_id = auth.uid() or ((b.public or b.unlisted) and b.verified_at is not null)) then
    if b.id is null or not b.shareable or not public.feature_on('bot_share_add', sid) or public.is_site_banned(b.owner_id) then
      raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
    end if;
    perform 1 from public.bots where id = bid for update;  -- one share of this bot at a time, so the cap holds
    if (select count(*) from public.bot_servers where bot_id = bid and added_by is distinct from b.owner_id) >= 10
       and not exists (select 1 from public.bot_servers where bot_id = bid and server_id = sid) then
      raise exception 'That bot is in 10 servers already. It needs to be verified by Yapper before more servers can add it';
    end if;
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $$;
