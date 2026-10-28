-- Import from Discord (flag discord_import): app/api/import/discord reads the Discord server with Yapper's
-- bot, stores checked pictures, then calls this as the signed-in person to build the server.

create or replace function public.import_discord_server(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); sid uuid; c jsonb; r jsonb; e jsonb; n int := 0; cats jsonb := '{}'::jsonb; cid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('discord_import', null) then raise exception 'Importing isn''t open yet'; end if;
  perform public.check_icon_path(p->>'icon_path');
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, description) values (left(btrim(p->>'name'), 100), p->>'icon_path', me, left(coalesce(p->>'description', ''), 300)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  for c in select * from jsonb_array_elements(coalesce(p->'categories', '[]'::jsonb)) loop
    insert into public.channel_categories (server_id, name, position) values (sid, left(c->>'name', 100), coalesce((c->>'position')::int, n)) returning id into cid;
    cats := cats || jsonb_build_object(c->>'key', cid);
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'channels', '[]'::jsonb)) loop
    insert into public.channels (kind, name, server_id, created_by, position, category_id)
      values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
              case when c->>'kind' = 'voice' then left(c->>'name', 100) else coalesce(public.slugify_channel(c->>'name'), 'channel') end,
              sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for r in select * from jsonb_array_elements(coalesce(p->'roles', '[]'::jsonb)) loop
    insert into public.roles (server_id, name, color, position, perms)
      values (sid, left(r->>'name', 32), nullif(r->>'color', ''), coalesce((r->>'position')::int, n), coalesce(r->'perms', '{}'::jsonb));
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for e in select * from jsonb_array_elements(coalesce(p->'emojis', '[]'::jsonb)) loop
    begin
      insert into public.emojis (owner_id, server_id, name, path, animated) values (me, sid, e->>'name', e->>'path', coalesce((e->>'animated')::boolean, false));
      n := n + 1;
    exception when others then null; -- one bad emoji (name clash, unscanned) shouldn't sink the import
    end;
    exit when n >= 50;
  end loop;
  return sid;
end; $$;
grant execute on function public.import_discord_server(jsonb) to authenticated;

insert into public.feature_flags (key, label, description, mode, users)
  values ('discord_import', 'Import from Discord', 'Create a server from a Discord server: channels, categories, roles, emojis, icon', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;

-- Auto roles ("everyone who joined before X") handed out by hand to later joiners were dropped by the app,
-- which skips auto-role rows and recomputes them. This hands it just those rows.
-- member_roles.manual marks a "joined before X" role given by hand to someone who joined after X, so the app can
-- fetch just those rows. (Two earlier versions of manual_auto_roles joined every member_roles row: 3 s a call, and
-- the cause of the Oct 15 afternoon lag.)
alter table public.member_roles add column if not exists manual boolean not null default false;
create index if not exists member_roles_manual_idx on public.member_roles (server_id) where manual;
create or replace function public.mark_manual_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.manual := exists (
    select 1 from public.roles r join public.server_members m on m.server_id = r.server_id and m.user_id = new.user_id
    where r.id = new.role_id and r.auto = 'before' and (r.auto_before is null or m.joined_at >= r.auto_before));
  return new;
end; $$;
create or replace trigger member_roles_mark_manual before insert on public.member_roles for each row execute function public.mark_manual_role();
update public.member_roles mr set manual = true
  from public.roles r join public.server_members m on m.server_id = r.server_id
  where r.id = mr.role_id and m.user_id = mr.user_id and r.auto = 'before' and (r.auto_before is null or m.joined_at >= r.auto_before) and not mr.manual;
create or replace function public.manual_auto_roles(sids uuid[]) returns table(server_id uuid, user_id uuid, role_id uuid)
language sql stable security definer set search_path = public as $$
  select mr.server_id, mr.user_id, mr.role_id
  from public.member_roles mr
  where mr.manual and mr.server_id = any(sids)
    and exists (select 1 from public.server_members sm where sm.server_id = mr.server_id and sm.user_id = auth.uid());
$$;
grant execute on function public.manual_auto_roles(uuid[]) to authenticated;

-- Private notes about people (profile card). Only the writer can read them.
create table if not exists public.user_notes (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  about_id uuid not null references public.profiles(id) on delete cascade,
  note text not null default '' check (char_length(note) <= 500),
  updated_at timestamptz not null default now(),
  primary key (owner_id, about_id)
);
alter table public.user_notes enable row level security;
grant select, insert, update, delete on public.user_notes to authenticated;
create policy "my notes" on public.user_notes for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Avatar decorations (public/deco/<key>.svg), picked in Settings → My Profile.
alter table public.profiles add column if not exists avatar_deco text;
alter table public.profiles add constraint avatar_deco_known check (avatar_deco is null or avatar_deco in ('flames','crown','halo','horns','cat','wings','headphones','laurel','snow','hearts','stars','lightning'));
grant select (avatar_deco) on public.profiles to anon, authenticated;
grant update (avatar_deco) on public.profiles to authenticated;
