-- Community bots are reviewed by hand. Switching a bot to public submits it; only a verified public bot
-- can be added by other servers or shows in the Community list. Yapper Plus owners are reviewed first.

alter table public.bots add column if not exists submitted_at timestamptz;
alter table public.bots add column if not exists verified_at timestamptz;
alter table public.bots add column if not exists review_note text;
grant select (submitted_at, verified_at, review_note) on public.bots to authenticated;

create or replace function public.bot_public_submit() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.public and not coalesce(old.public, false) then
    new.submitted_at := now();
    new.verified_at := null;
    new.review_note := null;
  elsif not new.public then
    new.verified_at := null;
  end if;
  return new;
end $$;
create or replace trigger bots_public_submit before update of public on public.bots for each row execute function public.bot_public_submit();

create or replace function public.bot_add_to_server(bid uuid, sid uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  if not exists (select 1 from public.bots b where b.id = bid and (b.owner_id = auth.uid() or (b.public and b.verified_at is not null))) then
    raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $$;

/** Admins: the review queue, Plus owners first, then oldest submission. */
create or replace function public.bot_review_queue()
returns table(id uuid, name text, description text, owner_id uuid, owner_name text, owner_plus boolean, submitted_at timestamptz, servers bigint, posts bigint, commands bigint)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, b.owner_id, p.username, coalesce(p.plus_until > now(), false), b.submitted_at,
         (select count(*) from public.bot_servers s where s.bot_id = b.id), b.posts,
         (select count(*) from public.bot_commands c where c.bot_id = b.id)
  from public.bots b join public.profiles p on p.id = b.owner_id
  where b.public and b.verified_at is null and public.is_site_admin()
  order by coalesce(p.plus_until > now(), false) desc, b.submitted_at nulls last;
$$;
grant execute on function public.bot_review_queue() to authenticated;

create or replace function public.admin_verify_bot(bid uuid, ok boolean, note text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if ok then
    update public.bots set verified_at = now(), review_note = null where id = bid;
  else
    update public.bots set public = false, verified_at = null, review_note = left(coalesce(note, 'Not approved'), 300) where id = bid;
  end if;
  insert into public.mod_log (actor, action, target_id, note) values (auth.uid(), case when ok then 'bot_verified' else 'bot_rejected' end, bid, note);
exception when undefined_table or undefined_column then null;
end $$;
grant execute on function public.admin_verify_bot(uuid, boolean, text) to authenticated;

/** Everyone: verified community bots, Plus owners first, then by how many servers use them. */
create or replace function public.community_bots()
returns table(id uuid, name text, description text, owner_name text, owner_plus boolean, servers bigint, commands bigint)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, p.username, coalesce(p.plus_until > now(), false),
         (select count(*) from public.bot_servers s where s.bot_id = b.id),
         (select count(*) from public.bot_commands c where c.bot_id = b.id)
  from public.bots b join public.profiles p on p.id = b.owner_id
  where b.public and b.verified_at is not null
  order by coalesce(p.plus_until > now(), false) desc, 6 desc, b.name
  limit 100;
$$;
grant execute on function public.community_bots() to authenticated;
