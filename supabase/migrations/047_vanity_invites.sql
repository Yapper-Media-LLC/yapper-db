-- Custom invite links (yapper.website/invite/yourname) for servers with 5+ members. Codes are case-insensitive.
alter table public.invites drop constraint if exists invites_code_check;
alter table public.invites add constraint invites_code_check check (code ~ '^[A-Za-z0-9_-]{3,32}$');
alter table public.invites add column if not exists vanity boolean not null default false;
create unique index if not exists invites_code_lower_idx on public.invites (lower(code));
create unique index if not exists invites_vanity_server_idx on public.invites (server_id) where vanity;
create or replace function public.set_vanity_invite(sid uuid, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := btrim(coalesce(p_code, ''));
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if c !~ '^[A-Za-z0-9_-]{3,32}$' then raise exception 'Links are 3–32 letters, numbers, dashes or underscores'; end if;
  if public.bad_name(c) or public.brand_name(c) then raise exception 'That link isn''t allowed'; end if;
  if (select count(*) from public.server_members where server_id = sid) < 5 then raise exception 'Custom links unlock at 5 members'; end if;
  if exists (select 1 from public.invites where lower(code) = lower(c) and server_id <> sid) then raise exception 'That link is taken'; end if;
  if exists (select 1 from public.invites where server_id = sid and vanity) then
    update public.invites set code = c where server_id = sid and vanity;
  else
    insert into public.invites (code, server_id, created_by, vanity) values (c, sid, auth.uid(), true);
  end if;
  return c;
end;
$$;
revoke all on function public.set_vanity_invite(uuid, text) from public, anon;
grant execute on function public.set_vanity_invite(uuid, text) to authenticated;
-- get_invite / join_server now match codes case-insensitively (same bodies as before otherwise).
create or replace function public.get_invite(invite_code text)
returns table (server_id uuid, name text, icon_path text, member_count int, already_member boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.icon_path,
         (select count(*)::int from public.server_members m where m.server_id = s.id),
         public.is_server_member(s.id)
  from public.invites i join public.servers s on s.id = i.server_id
  where lower(i.code) = lower(invite_code);
$$;
