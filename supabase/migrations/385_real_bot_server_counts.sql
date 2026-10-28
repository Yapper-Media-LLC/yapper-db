-- 385: bot server counts only count REAL servers, and one account can't farm a bot's count any more.
--
-- Before this, Community bots (bot_directory, public_bots, community_bots) showed and ranked bots by every bot_servers
-- row. A few bots were pumped by throwaway accounts that each made up to 50 empty servers holding only themselves + the
-- bot (growatree: 515 servers, 28 real).
--
-- One definition of a real server for a bot, public.bot_real_servers(bid):
--   the bot is in it, it isn't shut down (servers.shut_down_at is null), and it has at least 3 people who aren't bots
--   (server_members whose user is not public.is_bot_user: a bots row or a bot_accounts row).
-- servers.member_count can't be used for this: it drifts low (277 bot servers were 1 or 2 under the real count on Oct 22).
-- Counting that live for the whole directory takes 0.3 to 0.6 s, so the count is cached in bots.real_servers, refreshed
-- every 10 minutes by pg_cron (refresh_bot_real_servers) for bots that are public, private-verified or waiting for review.
-- A bot with no cached value yet is counted live (one bot is a few ms).
--
-- Uses: bot_directory, public_bots, community_bots (servers = real count, "popular" sorts by it), bot_verify_progress
-- (real_servers = the same definition minus servers the bot owner owns, as before), bot_review_queue (staff see both:
-- servers = total, real_servers = real; the return type grows, so it is re-created).
--
-- Anti-farming:
--   * bot_add_to_server: adding bots you don't own to more than 5 different servers in 24 hours is refused (adding more
--     bots to a server you already added one to today is fine). On Oct 22, user-days that added community bots to 6+
--     servers held 4 real servers out of 1267 adds; every real use fit in 5.
--   * servers: making more than 10 servers in 24 hours is refused (trigger, so create_server, templates and the Discord
--     import all count). 99.7% of user-days with a new server made 10 or fewer.
-- Owners adding their own bot, site admins, and service-role inserts (auth.uid() null) skip both limits.
--
-- Function bodies are based on the live text (pg_get_functiondef, Oct 22). Re-runnable.

set lock_timeout = '3s';

-- ---------- cache column ----------
alter table public.bots add column if not exists real_servers integer;
-- Indexes (run separately first, outside a transaction):
--   create index concurrently if not exists servers_owner_created_idx on public.servers (owner_id, created_at);
--   create index concurrently if not exists bot_servers_added_by_idx on public.bot_servers (added_by, added_at) where added_by is not null;

-- ---------- the one definition ----------
create or replace function public.bot_real_servers(bid uuid)
returns table(server_id uuid, owner_id uuid)
language sql stable security definer set search_path to 'public' as $$
  select s.id, s.owner_id
  from public.bot_servers bs
  join public.servers s on s.id = bs.server_id
  where bs.bot_id = bid
    and s.shut_down_at is null
    and (select count(*) from (select 1 from public.server_members m
                               where m.server_id = s.id and not public.is_bot_user(m.user_id)
                               limit 3) h) >= 3;
$$;
revoke all on function public.bot_real_servers(uuid) from public, anon, authenticated;

create or replace function public.bot_real_server_count(bid uuid)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select count(*) from public.bot_real_servers(bid);
$$;
revoke all on function public.bot_real_server_count(uuid) from public, anon, authenticated;

create or replace function public.refresh_bot_real_servers()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  with c as (
    select b.id, public.bot_real_server_count(b.id)::integer as real
    from public.bots b
    where b.public or b.unlisted or b.verified_at is not null
  )
  update public.bots b set real_servers = c.real from c where c.id = b.id and b.real_servers is distinct from c.real;
  get diagnostics n = row_count;
  -- Bots that left the directory and the queue: forget the number, so a stale one is never shown if they come back.
  update public.bots set real_servers = null
  where real_servers is not null and not (public or unlisted or verified_at is not null);
  return n;
end $$;
revoke all on function public.refresh_bot_real_servers() from public, anon, authenticated;

-- ---------- directory ----------
create or replace function public.bot_directory(q text default ''::text, cat text default ''::text, sort text default 'popular'::text)
returns table(id uuid, name text, description text, category text, owner_id uuid, owner_name text, owner_plus boolean, servers bigint, commands bigint, online boolean, created_at timestamptz, verified_at timestamptz, command_list jsonb)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, b.category, b.owner_id, coalesce(p.display_name, p.username), coalesce(p.plus_until > now(), false),
         r.n,
         (select count(*) from public.bot_commands c where c.bot_id = b.id),
         (b.last_poll_at > now() - interval '90 seconds' or b.last_event_at > now() - interval '5 minutes'),
         b.created_at, b.verified_at,
         coalesce((select jsonb_agg(jsonb_build_object('name', c.name, 'description', c.description) order by c.name)
                   from (select * from public.bot_commands c where c.bot_id = b.id order by c.name limit 25) c), '[]'::jsonb)
  from public.bots b join public.profiles p on p.id = b.owner_id
  cross join lateral (select coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)) as n) r
  where b.public and b.verified_at is not null
    and (coalesce(cat, '') = '' or b.category = cat)
    and (coalesce(q, '') = '' or b.name ilike '%' || q || '%' or b.description ilike '%' || q || '%'
         or exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name ilike '%' || q || '%'))
  order by case when sort = 'new' then extract(epoch from b.verified_at) else 0 end desc,
           case when sort = 'name' then lower(b.name) end asc,
           r.n desc, b.name
  limit 100;
$$;

create or replace function public.public_bots(q text default null::text, cat text default null::text, sort text default 'popular'::text, lim integer default 60, off integer default 0)
returns table(id uuid, name text, tag text, description text, category text, avatar_path text, support_invite text, servers bigint, verified_at timestamptz, created_at timestamptz, owner_name text)
language plpgsql stable security definer set search_path to 'public' as $$
declare
  term text := nullif(btrim(left(coalesce(q, ''), 64)), '');
  pat text;
  take int := least(greatest(coalesce(lim, 60), 1), 100);
  skip int := least(greatest(coalesce(off, 0), 0), 10000);
begin
  if not public.feature_on_for_me('bot_verified') then return; end if;
  if term is not null then
    pat := '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  return query
  select b.id, b.name, b.tag, b.description, coalesce(b.category, 'other'), coalesce(bp.avatar_path, b.avatar_path), b.support_invite,
         c.n, b.verified_at, b.created_at, coalesce(op.display_name, op.username)
  from public.bots b
  join public.profiles bp on bp.id = b.id
  left join public.profiles op on op.id = b.owner_id
  cross join lateral (select coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)) as n) c
  where b.public and b.verified_at is not null
    and (coalesce(cat, '') = '' or coalesce(b.category, 'other') = cat)
    and (pat is null or b.name ilike pat escape '\' or b.description ilike pat escape '\')
  order by case when sort = 'new' then b.verified_at end desc nulls last,
           case when sort = 'name' then lower(b.name) end asc,
           c.n desc, lower(b.name), b.id
  limit take offset skip;
end $$;

create or replace function public.community_bots()
returns table(id uuid, name text, description text, owner_name text, owner_plus boolean, servers bigint, commands bigint)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, p.username, coalesce(p.plus_until > now(), false),
         coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)),
         (select count(*) from public.bot_commands c where c.bot_id = b.id)
  from public.bots b join public.profiles p on p.id = b.owner_id
  where b.public and b.verified_at is not null
  order by coalesce(p.plus_until > now(), false) desc, 6 desc, b.name
  limit 100;
$$;

-- ---------- maker's verification checklist ----------
create or replace function public.bot_verify_progress(bid uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare b public.bots;
begin
  select * into b from public.bots where id = bid and owner_id = auth.uid();
  if b.id is null then raise exception 'Bot not found'; end if;
  return jsonb_build_object(
    'servers', (select count(*) from public.bot_servers bs where bs.bot_id = b.id),
    'real_servers', (select count(*) from public.bot_real_servers(b.id) r where r.owner_id <> b.owner_id),
    'need_servers', 3,
    'has_avatar', exists (select 1 from public.profiles p where p.id = b.id and p.avatar_path is not null),
    'commands', (select count(*) from public.bot_commands c where c.bot_id = b.id),
    'online', coalesce(greatest(b.last_poll_at, b.last_used_at) > now() - interval '7 days', false),
    'description_ok', char_length(btrim(coalesce(b.description, ''))) >= 20
  );
end $$;

-- ---------- staff review queue: total and real ----------
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'bot_review_queue'
               and not ('real_servers' = any(coalesce(p.proargnames, '{}')))) then
    execute 'dr' || 'op function public.bot_review_queue()';
  end if;
end $$;
create or replace function public.bot_review_queue()
returns table(id uuid, name text, description text, owner_id uuid, owner_name text, owner_plus boolean, submitted_at timestamptz, servers bigint, posts bigint, commands bigint, unlisted boolean, real_servers bigint)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.name, b.description, b.owner_id, p.username, coalesce(p.plus_until > now(), false), b.submitted_at,
         (select count(*) from public.bot_servers s where s.bot_id = b.id), b.posts,
         (select count(*) from public.bot_commands c where c.bot_id = b.id), b.unlisted,
         public.bot_real_server_count(b.id)
  from public.bots b join public.profiles p on p.id = b.owner_id
  where (b.public or b.unlisted) and b.verified_at is null and public.can_review_bots()
  order by coalesce(p.plus_until > now(), false) desc, b.submitted_at nulls last;
$$;
revoke all on function public.bot_review_queue() from public, anon;
grant execute on function public.bot_review_queue() to authenticated;

-- ---------- anti-farming: adding bots ----------
create or replace function public.bot_add_to_server(bid uuid, sid uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b public.bots;
begin
  if not public.feature_on('bot_api', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can add bots'; end if;
  select * into b from public.bots where id = bid;
  if b.id is null or not (b.owner_id = auth.uid() or ((b.public or b.unlisted) and b.verified_at is not null)) then
    if b.id is null or not b.shareable or not public.feature_on('bot_share_add', sid) or public.is_site_banned(b.owner_id) then
      raise exception 'That bot isn''t available (community bots must be verified by Yapper first)';
    end if;
    perform 1 from public.bots where id = bid for update;  -- one share of this bot at a time, so the cap holds
    if (select count(*) from public.bot_servers where bot_id = bid and added_by is distinct from b.owner_id) >= 10
       and not exists (select 1 from public.bot_servers where bot_id = bid and server_id = sid) then
      raise exception 'That bot is in 10 servers already. It needs to be verified by Yapper before more servers can add it';
    end if;
  end if;
  if (select count(*) from public.bot_servers where server_id = sid) >= 25 then raise exception 'That server has enough bots already'; end if;
  -- 385: bots you don't own go into at most 5 different servers a day (stops one account pumping a bot's count).
  if b.owner_id is distinct from auth.uid() and not public.is_site_admin()
     and not exists (select 1 from public.bot_servers where bot_id = bid and server_id = sid)
     and (select count(distinct x.server_id) from public.bot_servers x join public.bots xb on xb.id = x.bot_id
          where x.added_by = auth.uid() and x.added_at > now() - interval '24 hours'
            and xb.owner_id is distinct from auth.uid() and x.server_id <> sid) >= 5 then
    raise exception 'You already added bots to 5 servers today. Try again tomorrow';
  end if;
  insert into public.bot_servers (bot_id, server_id, added_by) values (bid, sid, auth.uid()) on conflict do nothing;
  perform set_config('yapper.bot', '1', true);
  insert into public.server_members (server_id, user_id) values (sid, bid) on conflict do nothing;
  perform set_config('yapper.bot', '', true);
end $$;

-- ---------- anti-farming: making servers ----------
create or replace function public.servers_daily_cap()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.owner_id = auth.uid() and not public.is_site_admin()
     and (select count(*) from public.servers s where s.owner_id = new.owner_id and s.created_at > now() - interval '24 hours') >= 10 then
    raise exception 'You can make 10 servers a day. Try again tomorrow';
  end if;
  return new;
end $$;
revoke all on function public.servers_daily_cap() from public, anon, authenticated;
create or replace trigger servers_daily_cap before insert on public.servers
  for each row execute function public.servers_daily_cap();

-- ---------- refresh every 10 minutes ----------
-- Fill the cache right after applying: select public.refresh_bot_real_servers();
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'bot-real-servers') then
      perform cron.schedule('bot-real-servers', '*/10 * * * *', 'select public.refresh_bot_real_servers()');
    end if;
  end if;
end $$;
