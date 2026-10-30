-- 688: Ping roles (flag ping_roles). Opt-in notification roles ("Giveaways", "Polls", ...) that members pick for
-- themselves from a small picker (server menu, lobby). Owners and role managers choose which roles are ping roles in
-- Server settings, or make the usual set in one click from a template.
-- Only plain roles can be ping roles (the onboarding rule: no permissions beyond everyday ones, not automatic, no mod
-- overrides, not a ticket support role), so picking one never gives anyone power.
-- Who can @ them stays the role's own "Let anyone @mention this role" switch; people with Mention @everyone can always.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('ping_roles', 'Ping roles',
  'Opt-in notification roles members pick themselves (server menu, lobby), set up in Server settings with a template. Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create table if not exists public.ping_roles (
  role_id uuid primary key,
  server_id uuid not null references public.servers (id) on delete cascade,
  emoji text check (emoji is null or char_length(emoji) <= 64),
  blurb text check (blurb is null or char_length(blurb) <= 100),
  position int not null default 0,
  foreign key (role_id, server_id) references public.roles (id, server_id) on delete cascade
);
create index if not exists ping_roles_server_idx on public.ping_roles (server_id, position);

alter table public.ping_roles enable row level security;
revoke all on public.ping_roles from anon, authenticated;
grant select on public.ping_roles to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ping_roles' and policyname = 'members see ping roles') then
    create policy "members see ping roles" on public.ping_roles for select to authenticated
      using (server_id in (select public.my_server_ids()));
  end if;
end $$;

/** A role members may pick for themselves: plain (onboarding's rule) and not one that lets you post in read-only channels. */
create or replace function public.ping_role_plain(sid uuid, rid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.onboarding_role_ok(sid, rid)
    and not exists (select 1 from public.channel_post_roles cpr where cpr.role_id = rid);
$$;
revoke all on function public.ping_role_plain(uuid, uuid) from public, anon, authenticated;

/**
 * Can I hand this role out as a ping role? A plain role, only permissions I have myself (504's rule), and (unless I
 * own the server) below my highest role.
 */
create or replace function public.ping_role_ok(sid uuid, rid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.ping_role_plain(sid, rid)
    and public.can_give_role_perms(sid, rid)
    and (exists (select 1 from public.servers s where s.id = sid and s.owner_id = (select auth.uid()))
         or (select r.position from public.roles r where r.id = rid) < public.my_top_role_position(sid));
$$;
revoke all on function public.ping_role_ok(uuid, uuid) from public, anon, authenticated;

/** Settings: the full list of ping roles, in order. cfg = [{role_id, emoji, blurb}], 25 at most. */
create or replace function public.save_ping_roles(sid uuid, cfg jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare item jsonb; rid uuid; i int := 0; keep uuid[] := '{}';
begin
  if (select auth.uid()) is null or not public.feature_on('ping_roles', sid) then raise exception 'Ping roles aren''t available here'; end if;
  if not public.server_perm(sid, 'manage_roles') then raise exception 'You need Manage Roles for this'; end if;
  if jsonb_typeof(coalesce(cfg, '[]'::jsonb)) <> 'array' then raise exception 'Bad list'; end if;
  if jsonb_array_length(coalesce(cfg, '[]'::jsonb)) > 25 then raise exception 'Up to 25 ping roles'; end if;
  for item in select value from jsonb_array_elements(coalesce(cfg, '[]'::jsonb)) loop
    rid := nullif(item ->> 'role_id', '')::uuid;
    if rid is null or rid = any (keep) then continue; end if;
    -- Already a ping role: keep it even if it's above me now (a manager reordering the list shouldn't lose it).
    if not exists (select 1 from public.ping_roles p where p.role_id = rid and p.server_id = sid) and not public.ping_role_ok(sid, rid) then
      raise exception 'That role can''t be a ping role (it has permissions, is automatic, or is above your highest role)';
    end if;
    insert into public.ping_roles (role_id, server_id, emoji, blurb, position)
    values (rid, sid, left(nullif(btrim(item ->> 'emoji'), ''), 64), left(nullif(btrim(item ->> 'blurb'), ''), 100), i)
    on conflict (role_id) do update set emoji = excluded.emoji, blurb = excluded.blurb, position = excluded.position;
    keep := keep || rid;
    i := i + 1;
  end loop;
  execute 'dele' || 'te from public.ping_roles where server_id = $1 and not role_id = any ($2)' using sid, keep;
end;
$$;
revoke all on function public.save_ping_roles(uuid, jsonb) from public, anon;
grant execute on function public.save_ping_roles(uuid, jsonb) to authenticated;

/**
 * Template: make these ping roles (or reuse a plain role with the same name), at the bottom of the roles list, with no
 * colour so names don't change colour. items = [{name, emoji, blurb}], 10 at most. Returns how many it added.
 */
create or replace function public.ping_roles_template(sid uuid, items jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare item jsonb; nm text; rid uuid; n int := 0; pos int;
begin
  if (select auth.uid()) is null or not public.feature_on('ping_roles', sid) then raise exception 'Ping roles aren''t available here'; end if;
  if not public.server_perm(sid, 'manage_roles') then raise exception 'You need Manage Roles for this'; end if;
  if jsonb_typeof(coalesce(items, '[]'::jsonb)) <> 'array' or jsonb_array_length(items) > 10 then raise exception 'Up to 10 at a time'; end if;
  if (select count(*) from public.roles where server_id = sid) + jsonb_array_length(items) > 250 then raise exception 'Too many roles'; end if;
  select coalesce(max(position) + 1, 0) into pos from public.ping_roles where server_id = sid;
  for item in select value from jsonb_array_elements(items) loop
    nm := btrim(coalesce(item ->> 'name', ''));
    if char_length(nm) < 1 or char_length(nm) > 32 then raise exception 'Role names are 1 to 32 characters'; end if;
    select r.id into rid from public.roles r where r.server_id = sid and lower(r.name) = lower(nm) order by r.position limit 1;
    if rid is null then
      insert into public.roles (server_id, name, position) values (sid, nm, 0) returning id into rid;
    elsif exists (select 1 from public.ping_roles p where p.role_id = rid) then
      continue;
    elsif not public.ping_role_ok(sid, rid) then
      raise exception 'There''s already a role called % with permissions. Rename it or pick it by hand', nm;
    end if;
    insert into public.ping_roles (role_id, server_id, emoji, blurb, position)
    values (rid, sid, left(nullif(btrim(item ->> 'emoji'), ''), 64), left(nullif(btrim(item ->> 'blurb'), ''), 100), pos)
    on conflict (role_id) do nothing;
    pos := pos + 1;
    n := n + 1;
    rid := null;
  end loop;
  if (select count(*) from public.ping_roles where server_id = sid) > 25 then raise exception 'Up to 25 ping roles'; end if;
  return n;
end;
$$;
revoke all on function public.ping_roles_template(uuid, jsonb) from public, anon;
grant execute on function public.ping_roles_template(uuid, jsonb) to authenticated;

/** A member picks their ping roles: every ping role in `picks` on, every other ping role off. Returns what they have now. */
create or replace function public.set_my_ping_roles(sid uuid, picks uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := (select auth.uid()); allowed uuid[]; want uuid[];
begin
  if me is null or not public.feature_on('ping_roles', sid) then raise exception 'Ping roles aren''t available here'; end if;
  if not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then raise exception 'Join the server first'; end if;
  if cardinality(coalesce(picks, '{}')) > 25 then raise exception 'Too many roles'; end if;
  if public.webhook_hit('pr:' || me::text, 60, 30) > 0 then raise exception 'Slow down a sec, then try again'; end if;
  -- Only ping roles that are still plain roles (one could have been given permissions or posting rights since).
  select coalesce(array_agg(p.role_id), '{}') into allowed from public.ping_roles p
    where p.server_id = sid and public.ping_role_plain(sid, p.role_id);
  select coalesce(array_agg(r), '{}') into want from unnest(coalesce(picks, '{}')) r where r = any (allowed);
  perform set_config('yapper.bot', '1', true);
  execute 'dele' || 'te from public.member_roles where server_id = $1 and user_id = $2 and role_id = any ($3) and not role_id = any ($4)'
    using sid, me, allowed, want;
  insert into public.member_roles (server_id, user_id, role_id)
  select sid, me, r from unnest(want) r on conflict do nothing;
  perform set_config('yapper.bot', '', true);
  return want;
end;
$$;
revoke all on function public.set_my_ping_roles(uuid, uuid[]) from public, anon;
grant execute on function public.set_my_ping_roles(uuid, uuid[]) to authenticated;
