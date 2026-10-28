-- 183: at most 10 new channels per server per minute, and channels.ticket_by only set by open_ticket.
--
-- The create dialogs only disabled their button through React state, so Enter in the form (or a fast double click)
-- ran create_channel again while the first call was still saving: one person got 11 #hi channels in 3 seconds.
-- The app fix ships with this file (lib/useSubmitOnce.ts); this is the safety net behind it, for old tabs, other
-- clients and bots (the bot API's POST /channels calls create_channel as the bot's own user, so it lands here too).
--
-- A BEFORE INSERT trigger on channels, for server channels only (DMs and groups have server_id null and are left
-- alone). It takes a per-server advisory lock so parallel inserts can't both see 9, then counts the server's
-- channels made in the last minute. Not limited or not counted:
--   * staff (is_staff()), and inserts with no signed-in user (maintenance, service role);
--   * tickets (ticket_by set): members open those, and open_ticket already caps them per person;
--   * channels made together with the server (create_server, create_server_from_template, import_discord_server):
--     they're inserted in the same transaction as the server, so their created_at (now()) equals servers.created_at,
--     and the count only looks at channels newer than the server. Those functions aren't touched.
--
-- ticket_by is what exempts a ticket, and it also hides a role-locked channel from staff (can_access_channel and
-- friends skip the staff view for tickets). It used to be writable: managers (and bots with manage_channels) could
-- PATCH channels.ticket_by through the "managers edit channels" policy, since channel_guard didn't pin it. Now:
--   * on INSERT this trigger clears ticket_by unless the transaction-local setting yapper.ticket = '1' is set;
--   * on UPDATE channel_guard keeps old.ticket_by unless yapper.ticket = '1', except that it may go null when the
--     opener's profile is gone (the ON DELETE SET NULL foreign key);
--   * open_ticket, the only function that sets ticket_by, sets yapper.ticket around its insert and clears it after.
--     (close_ticket deletes the channel, it never changes ticket_by.)
-- channel_guard and open_ticket are patched in place (pg_get_functiondef + replace) so nothing else in them is
-- clobbered; each patch fails loudly if its target text isn't there exactly once, and is skipped once applied
-- (marker 183:). A user can't set yapper.ticket themselves: PostgREST doesn't expose set_config, and channels has
-- no INSERT policy, so users only insert channels through security definer functions.
--
-- Index: none added. The count uses channels_server_idx (server_id), and a server has at most 100 channels
-- (create_channel / open_ticket / the bulk paths all cap it there), so the created_at filter runs over <= 100 rows.

create or replace function public.channel_create_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  -- 183: only open_ticket makes tickets. Runs first, so the ticket exemption below can't be claimed by anyone else.
  if new.ticket_by is not null and coalesce(current_setting('yapper.ticket', true), '') <> '1' then
    new.ticket_by := null;
  end if;
  if new.server_id is null or new.ticket_by is not null then return new; end if;
  if auth.uid() is null then return new; end if;
  if public.is_staff() then return new; end if;
  -- Serialise channel creation per server so two inserts at once can't both slip under the limit.
  perform pg_advisory_xact_lock(hashtextextended('channel_create:' || new.server_id::text, 0));
  -- Channels made with the server itself (create_server / template / import: same transaction, so created_at equals
  -- the server's) don't count, so adding one right after importing 30 isn't refused.
  select count(*) into n from public.channels c
    where c.server_id = new.server_id and c.ticket_by is null
      and c.created_at > greatest(now() - interval '1 minute', (select s.created_at from public.servers s where s.id = new.server_id));
  if n >= 10 then
    raise exception 'Slow down, too many channels at once' using hint = 'Try again in a minute.';
  end if;
  return new;
end $$;
revoke execute on function public.channel_create_limit() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists channels_create_limit on public.channels'; end $$;
create trigger channels_create_limit
  before insert on public.channels
  for each row execute function public.channel_create_limit();

-- ---------- in-place patches: channel_guard pins ticket_by, open_ticket is allowed to set it ----------
do $$
declare
  src text;
  old_guard constant text := $a$  new.created_at := old.created_at;
$a$;
  new_guard constant text := $b$  new.created_at := old.created_at;
  -- 183: ticket_by only changes inside open_ticket (yapper.ticket), or goes null when the opener's profile is deleted.
  if new.ticket_by is distinct from old.ticket_by and coalesce(current_setting('yapper.ticket', true), '') <> '1'
     and not (new.ticket_by is null and not exists (select 1 from public.profiles p where p.id = old.ticket_by)) then
    new.ticket_by := old.ticket_by;
  end if;
$b$;
  old_ins constant text := $a$  insert into public.channels (kind, name, server_id, created_by, position, private, category_id, ticket_by, ticket_panel)
$a$;
  new_ins constant text := $b$  -- 183: channels.ticket_by is only kept when this is set (channel_create_limit / channel_guard).
  perform set_config('yapper.ticket', '1', true);
  insert into public.channels (kind, name, server_id, created_by, position, private, category_id, ticket_by, ticket_panel)
$b$;
  old_ret constant text := $a$    returning id into cid;
$a$;
  new_ret constant text := $b$    returning id into cid;
  perform set_config('yapper.ticket', '', true);
$b$;
begin
  src := pg_get_functiondef('public.channel_guard()'::regprocedure);
  if position('183:' in src) = 0 then
    if (length(src) - length(replace(src, old_guard, ''))) / length(old_guard) <> 1 then
      raise exception '183: channel_guard patch did not match exactly once';
    end if;
    execute replace(src, old_guard, new_guard);
  end if;

  src := pg_get_functiondef('public.open_ticket(uuid, text, text)'::regprocedure);
  if position('183:' in src) = 0 then
    if (length(src) - length(replace(src, old_ins, ''))) / length(old_ins) <> 1 then
      raise exception '183: open_ticket patch (set) did not match exactly once';
    end if;
    if (length(src) - length(replace(src, old_ret, ''))) / length(old_ret) <> 1 then
      raise exception '183: open_ticket patch (reset) did not match exactly once';
    end if;
    execute replace(replace(src, old_ins, new_ins), old_ret, new_ret);
  end if;
end $$;
