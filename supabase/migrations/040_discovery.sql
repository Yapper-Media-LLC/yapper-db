-- Server Discovery (behind the 'discovery' flag): owners opt their server in with a
-- blurb and tags; everyone can browse/search and join without an invite.
insert into public.feature_flags (key, label, description, mode) values
  ('discovery', 'Server discovery', 'Browse and join public servers from the compass button', 'off')
on conflict (key) do nothing;

alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.servers add column if not exists description text not null default '' check (char_length(description) <= 300);
alter table public.servers add column if not exists tags text[] not null default '{}' check (array_length(tags, 1) is null or array_length(tags, 1) <= 5);
create index if not exists servers_discoverable_idx on public.servers (discoverable) where discoverable;

create or replace function public.set_server_discovery(sid uuid, p_on boolean, p_description text, p_tags text[])
returns void language plpgsql security definer set search_path = public as $$
declare t text; clean text[] := '{}';
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if public.bad_name(coalesce(p_description, '')) then raise exception 'That description isn''t allowed'; end if;
  foreach t in array coalesce(p_tags, '{}') loop
    t := lower(regexp_replace(btrim(t), '[^a-z0-9 ]', '', 'gi'));
    if t <> '' and char_length(t) <= 20 and not (t = any(clean)) then clean := clean || t; end if;
    exit when array_length(clean, 1) >= 5;
  end loop;
  update public.servers set discoverable = p_on, description = left(btrim(coalesce(p_description, '')), 300), tags = clean where id = sid;
end;
$$;

-- Public listing: name, icon, banner, blurb, tags, member count, whether I'm in it.
create or replace function public.discover_servers(q text default '', lim int default 48)
returns table (id uuid, name text, icon_path text, banner_path text, description text, tags text[], members int, joined boolean)
language sql stable security definer set search_path = public as $$
  select * from (
    select s.id, s.name, s.icon_path, s.banner_path, s.description, s.tags,
           (select count(*)::int from public.server_members m where m.server_id = s.id) as members,
           exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid()) as joined
    from public.servers s
    where s.discoverable
      and not public.is_site_banned(s.owner_id)
      and not public.bad_name(s.name)
      and (coalesce(q, '') = '' or s.name ilike '%' || q || '%' or s.description ilike '%' || q || '%' or lower(q) = any(s.tags))
  ) x
  where x.members >= 5
  order by x.members desc
  limit least(coalesce(lim, 48), 100);
$$;

create or replace function public.join_public_server(sid uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  if not (select discoverable from public.servers where id = sid) then raise exception 'That server isn''t public'; end if;
  if exists (select 1 from public.server_bans b where b.server_id = sid and b.user_id = auth.uid()) then raise exception 'You''re banned from that server'; end if;
  if (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then raise exception 'You''re in too many servers'; end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  return sid;
end;
$$;

revoke all on function public.set_server_discovery(uuid, boolean, text, text[]), public.discover_servers(text, int), public.join_public_server(uuid) from public, anon;
grant execute on function public.set_server_discovery(uuid, boolean, text, text[]), public.discover_servers(text, int), public.join_public_server(uuid) to authenticated;

-- Servers are public by default (owners opt out); the listing only shows servers with 5+ members.
alter table public.servers alter column discoverable set default true;
update public.servers set discoverable = true where discoverable = false;
