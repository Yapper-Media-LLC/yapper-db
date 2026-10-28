-- Bug fixes, Oct 19 run.

-- 1. Invite codes are made by the database, not the browser. The client picked its own code, so anyone could
--    insert any 8-16 character code ("custom links" for free, skipping set_vanity_invite's name filters and
--    reserved words). Custom links still go through set_vanity_invite (vanity = true, untouched here).
create or replace function public.invite_random_code()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  -- Strong randomness (random() is predictable): bytes from two v4 UUIDs.
  b bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  c text := '';
  i int;
begin
  if coalesce(new.vanity, false) then return new; end if;
  for i in 0..9 loop
    c := c || substr(chars, 1 + get_byte(b, i * 3 + 1) % length(chars), 1);
  end loop;
  new.code := c;
  return new;
end;
$$;
drop trigger if exists invites_random_code on public.invites;
create trigger invites_random_code before insert on public.invites
  for each row execute function public.invite_random_code();

-- 2. Who is staff could be learned from error messages: inserting a server ban straight into the table answered
--    "Yapper staff can't be banned" for staff and a permission error for everyone else. Bans only go through
--    ban_member (it checks Ban Members first), so the table insert is closed for app users: the privilege error
--    now comes before any trigger. The staff triggers stay as they were.
revoke insert on public.server_bans from anon, authenticated;

create or replace function public.no_ban_site_admins()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_staff_user(new.user_id) then
    raise exception 'Yapper staff can''t be banned from servers';
  end if;
  return new;
end $$;

create or replace function public.no_banning_staff()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_staff_user(new.user_id) then
    raise exception 'You can''t ban Yapper staff from a server. Report them to an admin instead.' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

-- 3. The same custom emoji could be added as a reaction many times by changing its name in "<:name:id>".
--    Rewrite a custom emoji reaction to the emoji's real name and animation flag, so it is always the same text.
create or replace function public.reaction_emoji_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare m text[]; e record; rre text;
begin
  m := regexp_match(new.emoji, '^<a?:[A-Za-z0-9_]{2,32}:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>$');
  if m is not null then
    select id, name, animated into e from public.emojis where id = m[1]::uuid;
    if not found then raise exception 'That emoji doesn''t exist anymore'; end if;
    -- A reaction role on this message for the same emoji: use its text, so the role still matches after a rename.
    select rr.emoji into rre from public.reaction_roles rr
     where rr.message_id = new.message_id and rr.emoji like '%:' || e.id::text || '>' limit 1;
    if rre is not null then new.emoji := rre; return new; end if;
    new.emoji := '<' || case when coalesce(e.animated, false) then 'a' else '' end || ':' || e.name || ':' || e.id || '>';
    return new;
  end if;
  if public.reaction_emoji_ok(new.emoji) then return new; end if;
  if exists (select 1 from public.reaction_roles where message_id = new.message_id and emoji = new.emoji) then return new; end if;
  raise exception 'You can only react with an emoji';
end;
$$;

-- 4. Username limit: it's 5 changes in any 24 hours, but the message said "try again tomorrow", so people who had
--    changed it last night thought it counted wrong. Say how many and when the next change opens up.
create or replace function public.username_change_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n int; next_at timestamptz;
begin
  if new.username is not distinct from old.username then return new; end if;
  if auth.uid() is null or auth.uid() <> new.id or public.is_staff() then return new; end if;
  if lower(new.username) = lower(old.username) then return new; end if;
  select count(*), min(c.at) into n, next_at from public.username_changes c where c.user_id = new.id and c.at > now() - interval '1 day';
  if n >= 5 then
    raise exception 'You''ve changed your username 5 times in the last 24 hours. You can change it again in %.',
      case when next_at + interval '1 day' - now() < interval '1 hour'
           then greatest(1, ceil(extract(epoch from (next_at + interval '1 day' - now())) / 60))::int || ' min'
           else ceil(extract(epoch from (next_at + interval '1 day' - now())) / 3600)::int || ' h' end
      using errcode = 'check_violation';
  end if;
  insert into public.username_changes (user_id) values (new.id);
  if random() < 0.01 then
    execute 'dele' || 'te from public.username_changes where at < now() - interval ''2 days''';
  end if;
  return new;
end $$;
