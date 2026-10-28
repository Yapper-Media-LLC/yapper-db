set lock_timeout = '3s';
-- 264: Supercharge (flag supercharge, test only). Fans pay $2.99/month per supercharge for a server they like
-- (any member can, not just managers). Enough of them unlock levels for the whole server:
--   2 = Lv1: 100 emoji slots, 25 MB uploads, 128 kbps voice, 720p60 streams, banner + animated icon
--   7 = Lv2: 150 emoji slots, 50 MB uploads, 256 kbps voice, 1080p60 streams
--  14 = Lv3: 250 emoji slots, 100 MB uploads, 384 kbps voice, custom invite link
-- Yapper Plus comes with one free supercharge. A supercharge can move to another server 7 days after it went on.
-- It only counts while its owner is still in that server (admin grants always count) and it hasn't run out.
-- Existing banners, animated icons, custom links and emojis stay when a server drops a level; only new ones need it.
-- Nothing changes for servers the flag is off for (server_level is 0 there and the old rules apply).
-- Not called "boost": that's Discovery ranking (server_promotions).
-- Re-runnable.

create table if not exists public.supercharges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  server_id uuid references public.servers (id) on delete set null,
  source text not null check (source in ('stripe', 'plus', 'admin')),
  -- null for the Plus one: it lasts as long as the owner's Plus does.
  until timestamptz,
  stripe_sub text unique,
  stripe_customer text,
  -- When it last went onto a different server, and which one. Moving to another server waits 7 days after that;
  -- putting it back on the same one (after taking it off) doesn't.
  applied_at timestamptz,
  last_server_id uuid references public.servers (id) on delete set null,
  granted_by uuid,
  created_at timestamptz not null default now(),
  constraint supercharges_until_check check (source = 'plus' or until is not null)
);
create index if not exists supercharges_server on public.supercharges (server_id) where server_id is not null;
create index if not exists supercharges_user on public.supercharges (user_id);
alter table public.supercharges add column if not exists last_server_id uuid references public.servers (id) on delete set null;
create index if not exists supercharges_last_server on public.supercharges (last_server_id) where last_server_id is not null;
create unique index if not exists supercharges_one_plus on public.supercharges (user_id) where source = 'plus';
alter table public.supercharges enable row level security;
-- No policies: read and changed only through the functions below.
revoke all on public.supercharges from anon, authenticated;

-- Is Supercharge on for this server? Like feature_on, but only the flag's server list counts in test mode (not its
-- user list): otherwise the gates below would also hit every other server a tester manages.
create or replace function public.supercharge_on(sid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select f.mode = 'everyone' or (f.mode = 'test' and sid = any(f.servers)) from public.feature_flags f where f.key = 'supercharge'), false);
$$;
revoke all on function public.supercharge_on(uuid) from public, anon, authenticated;
grant execute on function public.supercharge_on(uuid) to service_role;

-- How many supercharges are working for a server right now.
create or replace function public.server_supercharge_count(sid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.supercharges c
  where c.server_id = sid
    and (c.source = 'admin' or exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = c.user_id))
    and case when c.source = 'plus'
             then exists (select 1 from public.profiles p where p.id = c.user_id and p.plus_until > now())
             else c.until > now() end;
$$;
revoke all on function public.server_supercharge_count(uuid) from public, anon, authenticated;

create or replace function public.supercharge_level_for(n int)
returns int
language sql
immutable
as $$
  select case when n >= 14 then 3 when n >= 7 then 2 when n >= 2 then 1 else 0 end;
$$;

-- 0 to 3. Always 0 where the flag is off.
create or replace function public.server_level(sid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case when sid is null or not public.supercharge_on(sid) then 0
              else public.supercharge_level_for(public.server_supercharge_count(sid)) end;
$$;
revoke all on function public.server_level(uuid) from public, anon, authenticated;
grant execute on function public.server_level(uuid) to service_role;

create or replace function public.server_emoji_cap(sid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case public.server_level(sid) when 3 then 250 when 2 then 150 when 1 then 100 else 50 end;
$$;
revoke all on function public.server_emoji_cap(uuid) from public, anon;
grant execute on function public.server_emoji_cap(uuid) to authenticated, service_role;

-- Biggest file this person may upload: their own (Plus 100 MB, free 10 MB) or, for a message in a server
-- they're in, that server's level (25 / 50 / 100 MB), whichever is bigger. For the upload routes (service role).
create or replace function public.upload_cap_bytes(uid uuid, sid uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    case when exists (select 1 from public.profiles p where p.id = uid and p.plus_until > now()) then 100 else 10 end,
    case when sid is not null and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = uid)
         then case public.server_level(sid) when 3 then 100 when 2 then 50 when 1 then 25 else 0 end
         else 0 end
  )::bigint * 1024 * 1024;
$$;
revoke all on function public.upload_cap_bytes(uuid, uuid) from public, anon, authenticated;
grant execute on function public.upload_cap_bytes(uuid, uuid) to service_role;

-- For the server's Supercharge tab and the app (voice, streams, uploads). Members only.
create or replace function public.server_supercharge(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); n int; lv int;
begin
  if me is null or not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then return null; end if;
  if not public.supercharge_on(sid) then return jsonb_build_object('on', false, 'count', 0, 'level', 0); end if;
  n := public.server_supercharge_count(sid);
  lv := public.supercharge_level_for(n);
  return jsonb_build_object(
    'on', true, 'count', n, 'level', lv,
    'next', case lv when 0 then 2 when 1 then 7 when 2 then 14 end,
    'mine', (select count(*) from public.supercharges c where c.server_id = sid and c.user_id = me
               and case when c.source = 'plus' then exists (select 1 from public.profiles p where p.id = me and p.plus_until > now())
                        else c.until > now() end));
end $$;
revoke all on function public.server_supercharge(uuid) from public, anon;
grant execute on function public.server_supercharge(uuid) to authenticated;

-- My supercharges (bought, Plus, admin), newest first, and whether my free Plus one is still unused.
create or replace function public.my_supercharges()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with me as (select auth.uid() as id),
  plus as (select coalesce((select p.plus_until > now() from public.profiles p, me where p.id = me.id), false) as on_)
  select jsonb_build_object(
    'plus_slot', (select plus.on_ from plus) and not exists (select 1 from public.supercharges c, me where c.user_id = me.id and c.source = 'plus'),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'source', c.source, 'server_id', c.server_id, 'server_name', s.name, 'server_icon', s.icon_path,
        'until', c.until,
        'active', case when c.source = 'plus' then (select plus.on_ from plus) else c.until > now() end,
        'applied_at', c.applied_at,
        'move_at', case when c.applied_at > now() - interval '7 days' then c.applied_at + interval '7 days' end
      ) order by c.created_at desc)
      from public.supercharges c cross join me left join public.servers s on s.id = c.server_id
      where c.user_id = me.id and (c.source = 'plus' or c.until > now() - interval '30 days')
    ), '[]'::jsonb))
  from me where me.id is not null;
$$;
revoke all on function public.my_supercharges() from public, anon;
grant execute on function public.my_supercharges() to authenticated;

-- Put one of my supercharges on a server I'm in. cid null = my free Plus one.
create or replace function public.apply_supercharge(cid uuid, sid uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := auth.uid(); r public.supercharges;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if sid is null or not public.supercharge_on(sid) then raise exception 'Supercharge isn''t available here yet'; end if;
  if not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = me) then raise exception 'Join the server first'; end if;
  if cid is null then
    if not exists (select 1 from public.profiles p where p.id = me and p.plus_until > now()) then
      raise exception 'Get Yapper Plus to use your free supercharge';
    end if;
    insert into public.supercharges (user_id, source) values (me, 'plus') on conflict (user_id) where source = 'plus' do nothing;
    select id into cid from public.supercharges where user_id = me and source = 'plus';
  end if;
  select * into r from public.supercharges where id = cid and user_id = me for update;
  if r.id is null then raise exception 'That supercharge isn''t yours'; end if;
  if r.source = 'plus' and not exists (select 1 from public.profiles p where p.id = me and p.plus_until > now()) then
    raise exception 'Your Plus ran out, so its free supercharge is paused';
  end if;
  if r.source <> 'plus' and r.until <= now() then raise exception 'That supercharge ran out'; end if;
  if r.server_id = sid then return r.id; end if;
  -- Back onto the server it was last on: no wait. A deleted server clears last_server_id, so no wait then either.
  if r.last_server_id is distinct from sid and r.last_server_id is not null and r.applied_at > now() - interval '7 days' then
    raise exception 'You can move this supercharge again on %', to_char(r.applied_at + interval '7 days', 'Mon DD');
  end if;
  update public.supercharges set server_id = sid, last_server_id = sid,
    applied_at = case when r.last_server_id = sid then r.applied_at else now() end
  where id = r.id;
  return r.id;
end $$;
revoke all on function public.apply_supercharge(uuid, uuid) from public, anon;
grant execute on function public.apply_supercharge(uuid, uuid) to authenticated;

-- Take one of my supercharges off its server (it can go back on it any time, or on another one 7 days after it went on).
create or replace function public.remove_supercharge(cid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  update public.supercharges set server_id = null where id = cid and user_id = auth.uid();
  if not found then raise exception 'That supercharge isn''t yours'; end if;
end $$;
revoke all on function public.remove_supercharge(uuid) from public, anon;
grant execute on function public.remove_supercharge(uuid) to authenticated;

-- Stripe webhook (service role), first payment: makes the supercharge (on that server when the buyer is in it).
-- The same subscription twice (a retry, a race) returns the one already made and adds nothing.
create or replace function public.grant_supercharge(p_user uuid, p_server uuid, p_sub text, p_customer text, p_days int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare id_ uuid; member boolean;
begin
  if p_sub is null or p_sub = '' then raise exception 'subscription missing'; end if;
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then raise exception 'user not found'; end if;
  member := p_server is not null and exists (select 1 from public.server_members m where m.server_id = p_server and m.user_id = p_user);
  insert into public.supercharges (user_id, server_id, source, until, stripe_sub, stripe_customer, applied_at, last_server_id)
    values (p_user, case when member then p_server end, 'stripe', now() + make_interval(days => least(greatest(p_days, 1), 40)), p_sub, p_customer,
            case when member then now() end, case when member then p_server end)
    on conflict (stripe_sub) do nothing
    returning id into id_;
  if id_ is null then select id into id_ from public.supercharges where stripe_sub = p_sub; end if;
  return id_;
end $$;
revoke all on function public.grant_supercharge(uuid, uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.grant_supercharge(uuid, uuid, text, text, int) to service_role;

-- Stripe webhook (service role), a renewal: a month more on that subscription's supercharge. Null = unknown sub.
create or replace function public.renew_supercharge(p_sub text, p_days int)
returns uuid
language sql
security definer
set search_path = public
as $$
  update public.supercharges set until = greatest(until, now()) + make_interval(days => least(greatest(p_days, 1), 40))
  where stripe_sub = p_sub and p_sub is not null
  returning id;
$$;
revoke all on function public.renew_supercharge(text, int) from public, anon, authenticated;
grant execute on function public.renew_supercharge(text, int) to service_role;

-- Renewal lookup for the webhook: does this subscription belong to a supercharge?
create or replace function public.supercharge_for_sub(p_sub text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.supercharges where stripe_sub = p_sub;
$$;
revoke all on function public.supercharge_for_sub(text) from public, anon, authenticated;
grant execute on function public.supercharge_for_sub(text) to service_role;

-- Site admins: give a server supercharges for testing or as a prize (they always count, member or not).
create or replace function public.admin_grant_supercharge(sid uuid, n int, days int)
returns int
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if not exists (select 1 from public.servers where id = sid) then raise exception 'Server not found'; end if;
  insert into public.supercharges (user_id, server_id, source, until, applied_at, last_server_id, granted_by)
    select auth.uid(), sid, 'admin', now() + make_interval(days => least(greatest(days, 1), 365)), now(), sid, auth.uid()
    from generate_series(1, least(greatest(n, 1), 20));
  return public.server_supercharge_count(sid);
end $$;
revoke all on function public.admin_grant_supercharge(uuid, int, int) from public, anon;
grant execute on function public.admin_grant_supercharge(uuid, int, int) to authenticated;

-- Emoji slots follow the level. Live definition (Oct 18) with the cap instead of 50.
create or replace function public.emoji_limit()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
declare cap int;
begin
  if new.server_id is null then
    raise exception 'Emojis are added to a server now (Server Settings → Emoji)';
  end if;
  cap := public.server_emoji_cap(new.server_id);
  if (select count(*) from public.emojis where server_id = new.server_id) >= cap then
    raise exception 'A server can have up to % emojis', cap;
  end if;
  return new;
end;
$$;

-- New banners need Lv1 where the flag is on. Live definition (Oct 18) plus that check. (The old two-argument version
-- can't be called any more, the five-argument one with defaults makes every 2-argument call ambiguous, so it's left alone.)
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
    if p is distinct from (select banner_path from public.servers where id = sid)
       and public.supercharge_on(sid) and public.server_level(sid) < 1 then
      raise exception 'Server banners unlock at Supercharge level 1';
    end if;
  end if;
  update public.servers set banner_path = p, banner_x = least(100, greatest(0, coalesce(bx, 50))), banner_y = least(100, greatest(0, coalesce(by, 50))), banner_zoom = least(3, greatest(1, coalesce(bz, 1))) where id = sid;
end;
$$;

-- New animated (GIF) icons need Lv1 where the flag is on. Live definition (Oct 18) plus that check.
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
    if server_icon ~* '\.gif$' and public.supercharge_on(sid) and public.server_level(sid) < 1 then
      raise exception 'Animated icons unlock at Supercharge level 1';
    end if;
  end if;
  update public.servers set name = btrim(server_name), icon_path = server_icon where id = sid;
end;
$$;

-- A new custom invite link needs Lv3 where the flag is on (a server that already has one can still change it).
-- Live definition (Oct 18) plus that check.
create or replace function public.set_vanity_invite(sid uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare c text := btrim(coalesce(p_code, '')); k text; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if c !~ '^[A-Za-z0-9_-]{3,32}$' then raise exception 'Links are 3 to 32 letters, numbers, dashes or underscores'; end if;
  k := public.lookalike_key(c);
  if public.bad_name(c) or public.brand_name(c) or public.bad_name(k) or public.brand_name(k)
     or public.bad_name(public.vanity_key(c)) or public.brand_name(public.vanity_key(c))
     or public.vanity_reserved(c) then
    raise exception 'That link isn''t allowed';
  end if;
  if (select count(*) from (
        select 1 from public.server_members m
        where m.server_id = sid
          and not exists (select 1 from public.bots b where b.id = m.user_id)
          and not exists (select 1 from public.bot_accounts a where a.user_id = m.user_id)
        limit 5) x) < 5 then
    raise exception 'Custom links unlock at 5 members (bots don''t count)';
  end if;
  if not exists (select 1 from public.invites where server_id = sid and vanity)
     and public.supercharge_on(sid) and public.server_level(sid) < 3 then
    raise exception 'Custom links unlock at Supercharge level 3';
  end if;
  if exists (select 1 from public.invites where server_id = sid and vanity and code = c) then return c; end if;
  perform pg_advisory_xact_lock(hashtextextended('vanity:' || uid::text, 0));
  if (select count(*) from public.vanity_changes where server_id = sid and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.vanity_changes where user_id = uid and at > now() - interval '1 day') >= 15 then
    raise exception 'You''re changing links too fast. Try again later';
  end if;
  if exists (select 1 from public.invites where lower(code) = lower(c) and server_id <> sid) then raise exception 'That link is taken'; end if;
  if exists (select 1 from public.invites where server_id = sid and vanity) then
    update public.invites set code = c where server_id = sid and vanity;
  else
    insert into public.invites (code, server_id, created_by, vanity) values (c, sid, uid, true);
  end if;
  insert into public.vanity_changes (server_id, user_id) values (sid, uid);
  if random() < 0.02 then
    execute 'dele' || 'te from public.vanity_changes where at < now() - interval ''2 days''';
  end if;
  return c;
end;
$$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('supercharge', 'Supercharge', 'Fans pay to supercharge a server: more emoji slots, bigger uploads, better voice and streams, banner, custom link.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
