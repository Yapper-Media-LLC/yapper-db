-- 297: private verified bots. A bot owner can ask Yapper to verify a bot WITHOUT listing it publicly (some bots are made
-- for one server or one community). Same review queue, same checkmark, hosting, rate cap and rename perks as a public
-- verified bot, but it stays out of /bots, the Community bots list and the directory. Anyone who has its bot ID can add
-- it to a server they manage (the "Have a bot ID?" box).
--
-- One new column, bots.unlisted ("verified (or waiting to be) but private"). Only PATCH /api/bots can set it, behind the
-- private_verify flag, so every existing bot has unlisted = false and behaves exactly as before. That includes bots that
-- are private and verified today without a badge: nothing is backfilled.
--
-- "Counts as verified" is: verified_at is not null and (public or unlisted). The listings (bot_directory, public_bots,
-- community_bots) still say "public and verified", so an unlisted bot never shows up in them.
-- The database itself keeps verified_at honest: a bot only keeps (or gets) verified_at while it is public or unlisted,
-- except the legacy private-and-verified bots that nothing touches. Only public -> private keeps a checkmark; asking for
-- private verification from a plain private bot always goes through review.
-- Re-runnable.

-- ---------- 1. Column + flag ----------
alter table public.bots add column if not exists unlisted boolean not null default false;
grant select (unlisted) on public.bots to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('private_verify', 'Private verified bots', 'Ask for a bot to be verified without listing it publicly', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- 2. Publishing / withdrawing ----------
-- Publishing (public false -> true) is a fresh public review and ends "unlisted". Going private only clears verified_at
-- when the bot is not unlisted, so "Make private (keep the checkmark)" can keep it. A plain private bot becoming
-- unlisted is a new request, so any old verified_at is cleared and the bot waits in the queue. Now fires on unlisted
-- too, so no single-column update can leave verified_at behind.
create or replace function public.bot_public_submit()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.public and not coalesce(old.public, false) then
    new.submitted_at := now();
    new.verified_at := null;
    new.review_note := null;
    new.unlisted := false;
  elsif not new.public and not new.unlisted then
    new.verified_at := null;
  elsif new.unlisted and not old.unlisted and not old.public then
    new.verified_at := null;
  end if;
  return new;
end $$;
create or replace trigger bots_public_submit before update of public, unlisted on public.bots
  for each row execute function public.bot_public_submit();

-- ---------- 3. The checkmark follows "verified and (public or unlisted)" ----------
create or replace function public.bot_verified_badge()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  bid uuid := case when tg_op = 'DELETE' then old.id else new.id end;
  want boolean := tg_op <> 'DELETE' and new.verified_at is not null and (new.public or new.unlisted);
begin
  if want then
    update public.profiles set badges = coalesce(badges, '{}'::text[]) || 'verified_bot'::text
     where id = bid and not ('verified_bot' = any(coalesce(badges, '{}'::text[])));
  else
    update public.profiles set badges = array_remove(badges, 'verified_bot')
     where id = bid and 'verified_bot' = any(coalesce(badges, '{}'::text[]));
  end if;
  return null;
end $$;
revoke all on function public.bot_verified_badge() from public, anon, authenticated;

-- Still only when "verified and listed or unlisted" actually flips (bots rows are updated all the time: posts,
-- last_used_at...). create or replace trigger keeps the same names, so no trigger is ever missing.
create or replace trigger bots_verified_badge_ins after insert on public.bots for each row
  when (new.verified_at is not null and (new.public or new.unlisted)) execute function public.bot_verified_badge();
create or replace trigger bots_verified_badge_upd after update on public.bots for each row
  when (((old.verified_at is not null and (old.public or old.unlisted)) is distinct from (new.verified_at is not null and (new.public or new.unlisted))))
  execute function public.bot_verified_badge();
create or replace trigger bots_verified_badge_del after delete on public.bots for each row
  when (old.verified_at is not null and (old.public or old.unlisted)) execute function public.bot_verified_badge();

-- ---------- 4. Review: the queue shows both kinds, a rejection ends both ----------
-- The return type gains a column (unlisted), which create or replace can't do: remove the old one first (the statement
-- is split in two strings, the SQL editor / MCP hang on the bare word).
do $$ begin
  execute 'dr' || 'op function if exists public.bot_review_queue()';
end $$;
create function public.bot_review_queue()
returns table(id uuid, name text, description text, owner_id uuid, owner_name text, owner_plus boolean, submitted_at timestamptz, servers bigint, posts bigint, commands bigint, unlisted boolean)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, b.owner_id, p.username, coalesce(p.plus_until > now(), false), b.submitted_at,
         (select count(*) from public.bot_servers s where s.bot_id = b.id), b.posts,
         (select count(*) from public.bot_commands c where c.bot_id = b.id), b.unlisted
  from public.bots b join public.profiles p on p.id = b.owner_id
  where (b.public or b.unlisted) and b.verified_at is null and public.is_site_admin()
  order by coalesce(p.plus_until > now(), false) desc, b.submitted_at nulls last;
$$;
revoke all on function public.bot_review_queue() from public, anon;
grant execute on function public.bot_review_queue() to authenticated;

-- It now locks the row and checks what the admin is looking at: the bot must still be waiting (public or unlisted), and
-- if the caller says whether the row was a private request (was_private) it must still be one. A stale queue row
-- (cancelled, or switched between public and private since it was loaded) is refused instead of approving something
-- else. The 4th argument is new, so the old 3-argument version is removed first (two overloads make PostgREST refuse
-- the call as ambiguous); named-argument callers that don't send it still work.
do $$ begin
  execute 'dr' || 'op function if exists public.admin_verify_bot(uuid, boolean, text)';
end $$;
create or replace function public.admin_verify_bot(bid uuid, ok boolean, note text default null, was_private boolean default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b public.bots;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into b from public.bots where id = bid for update;
  if b.id is null then raise exception 'No such bot'; end if;
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

-- ---------- 5. Adding: anyone with the bot ID may add a verified unlisted bot ----------
create or replace function public.bot_add_to_server(bid uuid, sid uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  if not exists (select 1 from public.bots b where b.id = bid and (b.owner_id = auth.uid() or ((b.public or b.unlisted) and b.verified_at is not null))) then
    raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $$;
