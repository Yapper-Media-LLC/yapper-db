-- Server tags (like Discord): a server sets a 2-4 character tag; its members can wear it
-- next to their name everywhere. profiles.tag is a copy of the text so it shows even to
-- people who aren't in that server.

alter table public.servers add column if not exists tag text
  check (tag is null or tag ~ '^[A-Za-z0-9]{2,4}$');
alter table public.profiles add column if not exists server_tag uuid references public.servers(id) on delete set null;
alter table public.profiles add column if not exists tag text;
grant select (server_tag, tag) on public.profiles to anon, authenticated;

-- People pick a tag through this, never by editing the columns directly.
create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user = 'authenticated' and not public.is_site_admin() then
    new.id := old.id; new.created_at := old.created_at; new.verified_as := old.verified_as; new.plus_until := old.plus_until;
    new.muted_until := old.muted_until; new.muted_reason := old.muted_reason; new.voice_muted_until := old.voice_muted_until;
    new.stripe_customer := old.stripe_customer; new.badges := old.badges;
    new.server_tag := old.server_tag; new.tag := old.tag;
  end if;
  return new;
end; $$;

-- Wear a server's tag (null = none). You must be in the server and it must have a tag.
create or replace function public.set_server_tag(sid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); t text;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if sid is null then
    update public.profiles set server_tag = null, tag = null where id = me;
    return;
  end if;
  if not exists (select 1 from public.server_members where server_id = sid and user_id = me) then raise exception 'You’re not in that server'; end if;
  select tag into t from public.servers where id = sid;
  if t is null then raise exception 'That server has no tag'; end if;
  update public.profiles set server_tag = sid, tag = t where id = me;
end; $$;
grant execute on function public.set_server_tag(uuid) to authenticated;

-- The server changes or drops its tag: everyone wearing it follows.
create or replace function public.sync_server_tag()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tag is distinct from old.tag then
    update public.profiles set tag = new.tag, server_tag = case when new.tag is null then null else server_tag end where server_tag = new.id;
  end if;
  return null;
end; $$;
create trigger servers_sync_tag after update of tag on public.servers for each row execute function public.sync_server_tag();

-- Leaving (or being kicked from) the server takes the tag off.
create or replace function public.drop_tag_on_leave()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set server_tag = null, tag = null where id = old.user_id and server_tag = old.server_id;
  return null;
end; $$;
create trigger server_members_drop_tag after delete on public.server_members for each row execute function public.drop_tag_on_leave();

-- Managers set the server's tag (2-4 letters/numbers, or none).
create or replace function public.set_server_tag_text(sid uuid, p_tag text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare t text := nullif(trim(coalesce(p_tag, '')), '');
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set the tag'; end if;
  if t is not null and t !~ '^[A-Za-z0-9]{2,4}$' then raise exception 'Tags are 2 to 4 letters or numbers'; end if;
  if t is not null and public.bad_name(t) then raise exception 'That tag isn’t allowed'; end if;
  update public.servers set tag = t where id = sid;
end; $$;
grant execute on function public.set_server_tag_text(uuid, text) to authenticated;

-- Drag servers into your own order in the rail (kept on the account, so it follows you across devices).
alter table public.profiles add column if not exists server_order uuid[];
grant select (server_order) on public.profiles to anon, authenticated;

-- Gradient role colours: an optional second colour the name fades into.
alter table public.roles add column if not exists color2 text check (color2 is null or color2 ~ '^#[0-9a-fA-F]{6}$');
