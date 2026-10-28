set lock_timeout = '3s';
-- 270: Supercharge after launch (Antic, Oct 18).
--  1. Banners stay free: 264's "a new banner needs Lv1" check comes out of set_server_banner (live definition from
--     before 264). Animated icons are still a Lv1 perk.
--  2. Animated icons: 264 only looked at ".gif". The upload check now records whether a server icon moves (GIF,
--     animated WebP, APNG) in media_scans.animated, and update_server asks that too. New servers (create, template)
--     start at level 0, so they can't start with an animated icon either (the Discord import takes the still one).
--  3. Big files: a file over your own limit, allowed only because a supercharged server gives more, is recorded with
--     that server (media_scans.for_server). It can be sent there and nowhere else (not in DMs, not in other servers).
-- Re-runnable.

alter table public.media_scans add column if not exists animated boolean;
alter table public.media_scans add column if not exists for_server uuid;

-- Supercharge is live for everyone (new servers aren't on a test list, so this is what decides for them).
create or replace function public.supercharge_live()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select mode = 'everyone' from public.feature_flags where key = 'supercharge'), false);
$$;
revoke all on function public.supercharge_live() from public, anon;
grant execute on function public.supercharge_live() to authenticated, service_role;

-- Does this server icon move?
create or replace function public.icon_is_animated(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p is not null and (p ~* '\.gif$' or exists (select 1 from public.media_scans m where m.bucket = 'icons' and m.path = p and m.animated));
$$;
revoke all on function public.icon_is_animated(text) from public, anon;
grant execute on function public.icon_is_animated(text) to authenticated, service_role;

-- 1. Live definition from before 264 (Oct 18).
create or replace function public.set_server_banner(sid uuid, p text, bx numeric default 50, by numeric default 50, bz numeric default 1)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if p is not null then
    if p !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad banner'; end if;
    if not public.media_ok('banners', p) then raise exception 'That image hasn''t been checked yet'; end if;
  end if;
  update public.servers set banner_path = p, banner_x = least(100, greatest(0, coalesce(bx, 50))), banner_y = least(100, greatest(0, coalesce(by, 50))), banner_zoom = least(3, greatest(1, coalesce(bz, 1))) where id = sid;
end;
$$;

-- 2. 264's definition with the animated check instead of ".gif" only.
create or replace function public.update_server(sid uuid, server_name text, server_icon text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if server_icon is distinct from (select icon_path from public.servers where id = sid) then
    perform public.check_icon_path(server_icon);
    if public.supercharge_on(sid) and public.server_level(sid) < 1 and public.icon_is_animated(server_icon) then
      raise exception 'Animated icons unlock at Supercharge level 1';
    end if;
  end if;
  update public.servers set name = btrim(server_name), icon_path = server_icon where id = sid;
end;
$$;

-- New servers: patched in place after their icon check (whatever else they do live stays).
do $$
declare f text; d text; anchor text := 'perform public.check_icon_path(server_icon);';
begin
  foreach f in array array['public.create_server(text, text)', 'public.create_server_from_template(text, text, text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('icon_is_animated' in d) > 0 then continue; end if;
    if position(anchor in d) = 0 then raise exception '270: % has no icon check to hook into', f; end if;
    d := replace(d, anchor, anchor || E'\n  if public.supercharge_live() and public.icon_is_animated(server_icon) then raise exception ''Animated icons unlock at Supercharge level 1. Pick a still picture for now''; end if;');
    execute d;
  end loop;
end $$;

-- 3. Before the DM early return in the send guard, so DMs are checked too. Bots skip the guard (their own uploads).
do $$
declare d text; anchor text := E'  if sid is null then new.content := public.fix_role_pings(null, new.channel_id, false, new.content); return new; end if;\n';
begin
  d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('for_server' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception '270: message_perm_guard anchor not found'; end if;
  d := replace(d, anchor,
    E'  if new.attachment_path is not null and exists (select 1 from public.media_scans ms where ms.bucket = ''attachments'' and ms.path = new.attachment_path\n' ||
    E'       and ms.for_server is not null and ms.for_server is distinct from sid) then\n' ||
    E'    raise exception ''That file is over your upload limit, so it can only be sent in the supercharged server it was uploaded for'' using errcode = ''check_violation'';\n' ||
    E'  end if;\n' || anchor);
  execute d;
end $$;

reset lock_timeout;
