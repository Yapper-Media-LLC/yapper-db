-- 366: site moderators can review bot verification requests (flag mod_bot_review, test). Until now only admins could
-- see the Bot review queue (bot_review_queue) and approve or send back a bot (admin_verify_bot); creator verification
-- has been open to mods since 090. With the flag on for a mod (feature_on(.., null): their user id is in the flag's
-- users list, or the flag is published) both functions accept them. A mod can't approve or reject their own bot.
-- Everything else is unchanged from 297. Re-runnable.

create or replace function public.can_review_bots()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.is_site_admin() or (public.is_site_mod() and public.feature_on('mod_bot_review', null));
$$;
revoke all on function public.can_review_bots() from public, anon;
grant execute on function public.can_review_bots() to authenticated;

create or replace function public.bot_review_queue()
returns table(id uuid, name text, description text, owner_id uuid, owner_name text, owner_plus boolean, submitted_at timestamptz, servers bigint, posts bigint, commands bigint, unlisted boolean)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, b.owner_id, p.username, coalesce(p.plus_until > now(), false), b.submitted_at,
         (select count(*) from public.bot_servers s where s.bot_id = b.id), b.posts,
         (select count(*) from public.bot_commands c where c.bot_id = b.id), b.unlisted
  from public.bots b join public.profiles p on p.id = b.owner_id
  where (b.public or b.unlisted) and b.verified_at is null and public.can_review_bots()
  order by coalesce(p.plus_until > now(), false) desc, b.submitted_at nulls last;
$$;
revoke all on function public.bot_review_queue() from public, anon;
grant execute on function public.bot_review_queue() to authenticated;

create or replace function public.admin_verify_bot(bid uuid, ok boolean, note text default null, was_private boolean default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b public.bots;
begin
  if not public.can_review_bots() then raise exception 'Moderators only'; end if;
  select * into b from public.bots where id = bid for update;
  if b.id is null then raise exception 'No such bot'; end if;
  if b.owner_id = auth.uid() and not public.is_site_admin() then raise exception 'You can''t review your own bot'; end if;
  if not (b.public or b.unlisted) then raise exception 'That bot isn''t waiting for review any more'; end if;
  if was_private is not null and was_private <> b.unlisted then raise exception 'That bot changed since you opened the queue. Reload it and look again'; end if;
  if ok then
    update public.bots set verified_at = now(), review_note = null where id = bid;
  else
    update public.bots set public = false, unlisted = false, verified_at = null, review_note = left(coalesce(note, 'Not approved'), 300) where id = bid;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid,
            left(coalesce(nullif(btrim(note), ''), case when ok then 'Approved' else 'Not approved' end) || case when b.unlisted then ' (private)' else '' end
                 || ' [' || b.name || ']', 500));
end $$;
revoke all on function public.admin_verify_bot(uuid, boolean, text, boolean) from public, anon;
grant execute on function public.admin_verify_bot(uuid, boolean, text, boolean) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_bot_review', 'Mods review bots', 'Site moderators can review bot verification requests in Mod Center', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
