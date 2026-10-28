// 183: at most 10 new channels per server per minute (the 11 #hi channels bug), with staff, tickets, DMs and the
// channels made with a server (create_server, templates, Discord import) left alone; and channels.ticket_by only
// set by open_ticket (pinned on insert and update), so managers can't mark channels as tickets to skip the limit.
// Like stage157 this starts from stage 24, adds small stand-ins for the live pieces it leans on, then the live
// definitions of the functions involved, copied verbatim from the live database (read-only, Oct 17), so the patch
// targets (channel_guard, open_ticket) are checked against the real text.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table public.channels add column if not exists ticket_by uuid references public.profiles(id) on delete set null;
alter table public.channels add column if not exists ticket_panel text;
alter table public.channels add column if not exists category_id uuid;
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}'::jsonb;
alter table public.servers add column if not exists description text not null default '';
alter table public.servers add column if not exists tickets_on boolean not null default false;
alter table public.servers add column if not exists ticket_seq int not null default 0;
alter table public.roles add column if not exists perms jsonb not null default '{}'::jsonb;
create table if not exists public.channel_categories (id uuid primary key default gen_random_uuid(), server_id uuid, name text, position int);
create table if not exists public.server_templates (code text primary key, data jsonb, uses int not null default 0);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod();
$$;
create or replace function public.feature_on(f text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.fancy_channel_slug(n text) returns text language sql stable as $$ select public.slugify_channel(n) $$;
-- open_ticket's helpers: no tickets bot config, no Plus (so no greeting, log or support role branch).
create or replace function public.bot_cfg(sid uuid, b text) returns jsonb language sql stable as $$ select null::jsonb $$;
create or replace function public.ticket_panel_cfg(cfg jsonb, pid text) returns jsonb language sql stable as $$ select '{}'::jsonb $$;
create or replace function public.server_plus_on(sid uuid) returns boolean language sql stable as $$ select false $$;
-- Test helpers: a burst of DMs (server_id null), and a channel insert that tries to set ticket_by without open_ticket.
create or replace function public.t_dm_burst(k int) returns void language plpgsql security definer set search_path = public as $$
begin
  for i in 1..k loop insert into public.channels (kind, created_by, dm_key) values ('dm', auth.uid(), gen_random_uuid()::text); end loop;
end $$;
create or replace function public.t_fake_ticket(sid uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  insert into public.channels (kind, name, server_id, created_by, private, ticket_by) values ('text', 'fake-ticket', sid, auth.uid(), true, auth.uid())
    returning id into cid;
  return cid;
end $$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 17. */
const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.create_server(server_name text, server_icon text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := auth.uid();
  sid uuid;
begin
  if me is null then raise exception 'Not signed in'; end if;
  perform public.check_icon_path(server_icon);
  if (select count(*) from public.servers where owner_id = me) >= 50 then
    raise exception 'You own a lot of servers already';
  end if;
  insert into public.servers (name, icon_path, owner_id) values (btrim(server_name), server_icon, me) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0);
  insert into public.channels (kind, name, server_id, created_by, position) values ('voice', 'General', sid, me, 1);
  return sid;
end;
$function$;
CREATE OR REPLACE FUNCTION public.create_server_from_template(tcode text, server_name text, server_icon text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.server_templates; sid uuid; me uuid := auth.uid(); ch jsonb; r jsonb; n int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select * into t from public.server_templates where code = lower(btrim(tcode));
  if t.code is null then raise exception 'That template doesn''t exist'; end if;
  perform public.check_icon_path(server_icon);
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, everyone_perms) values (btrim(server_name), server_icon, me, coalesce(t.data -> 'everyone_perms', '{}'::jsonb)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  for ch in select * from jsonb_array_elements(t.data -> 'channels') loop
    insert into public.channels (kind, name, server_id, created_by, position, read_only, slowmode)
      values (ch ->> 'kind', ch ->> 'name', sid, me, n, coalesce((ch ->> 'read_only')::boolean, false), coalesce((ch ->> 'slowmode')::int, 0));
    n := n + 1;
    exit when n >= 100;
  end loop;
  if n = 0 then insert into public.channels (kind, name, server_id, created_by, position) values ('text', 'general', sid, me, 0); end if;
  n := 0;
  for r in select * from jsonb_array_elements(t.data -> 'roles') loop
    insert into public.roles (server_id, name, color, position, manage_server, manage_messages, perms)
      values (sid, left(r ->> 'name', 32), r ->> 'color', coalesce((r ->> 'position')::int, n), coalesce((r ->> 'manage_server')::boolean, false), coalesce((r ->> 'manage_messages')::boolean, false), coalesce(r -> 'perms', '{}'::jsonb));
    n := n + 1;
    exit when n >= 50;
  end loop;
  update public.server_templates set uses = uses + 1 where code = t.code;
  return sid;
end; $function$;
CREATE OR REPLACE FUNCTION public.import_discord_server(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := auth.uid(); sid uuid; c jsonb; r jsonb; e jsonb; n int := 0; cats jsonb := '{}'::jsonb; cid uuid; pos int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('discord_import', null) then raise exception 'Importing isn''t open yet'; end if;
  perform public.check_icon_path(p->>'icon_path');
  if (select count(*) from public.servers where owner_id = me) >= 50 then raise exception 'You own a lot of servers already'; end if;
  insert into public.servers (name, icon_path, owner_id, description) values (left(btrim(p->>'name'), 100), p->>'icon_path', me, left(coalesce(p->>'description', ''), 300)) returning id into sid;
  insert into public.server_members (server_id, user_id) values (sid, me);
  for c in select * from jsonb_array_elements(coalesce(p->'categories', '[]'::jsonb)) loop
    begin
      insert into public.channel_categories (server_id, name, position) values (sid, left(btrim(coalesce(c->>'name', '')), 40), coalesce((c->>'position')::int, n)) returning id into cid;
    exception when others then -- refused name: fallback name
      insert into public.channel_categories (server_id, name, position) values (sid, 'category', coalesce((c->>'position')::int, n)) returning id into cid;
    end;
    cats := cats || jsonb_build_object(c->>'key', cid);
    n := n + 1;
    exit when n >= 50;
  end loop;
  n := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'channels', '[]'::jsonb)) loop
    begin
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
                case when c->>'kind' = 'voice' then left(c->>'name', 100) else coalesce(public.slugify_channel(c->>'name'), 'channel') end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    exception when check_violation or raise_exception then -- refused name: fallback name
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end, case when c->>'kind' = 'voice' then 'Voice' else 'channel' end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    end;
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
end; $function$;
CREATE OR REPLACE FUNCTION public.create_channel(sid uuid, channel_name text, channel_kind text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cid uuid; k text := coalesce(channel_kind, 'text'); n text;
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if k = 'voice' then
    n := left(nullif(regexp_replace(btrim(channel_name), '\s+', ' ', 'g'), ''), 100);
  else
    n := case when public.feature_on('fancy_names', sid) then public.fancy_channel_slug(channel_name) else public.slugify_channel(channel_name) end;
  end if;
  if n is null then raise exception 'Channels need a name'; end if;
  if (select count(*) from public.channels where server_id = sid) >= 100 then raise exception 'Too many channels'; end if;
  insert into public.channels (kind, name, server_id, created_by, position)
    values (k, n, sid, auth.uid(), coalesce((select max(position) + 1 from public.channels where server_id = sid), 0))
    returning id into cid;
  return cid;
end;
$function$;
CREATE OR REPLACE FUNCTION public.channel_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  new.id := old.id;
  new.server_id := old.server_id;
  new.kind := old.kind;
  new.dm_key := old.dm_key;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  if new.server_id is not null and (new.name is null or char_length(btrim(new.name)) = 0) then
    raise exception 'Channels need a name';
  end if;
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.open_ticket(sid uuid, topic text, pid text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := auth.uid(); cid uuid; cat uuid; n int; t text := left(btrim(coalesce(topic, '')), 300); r record;
  cfg jsonb; p jsonb; plus boolean; support uuid; greet text; logc uuid; pings text; maxo int; prefix text; multi boolean; pname text;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if not public.is_server_member(sid) then raise exception 'You''re not in that server'; end if;
  if not public.feature_on('tickets', sid) then raise exception 'Tickets aren''t available here yet'; end if;
  cfg := public.bot_cfg(sid, 'tickets');
  if not coalesce((select tickets_on from public.servers where id = sid), false) and cfg is null then raise exception 'This server doesn''t take tickets'; end if;
  cfg := coalesce(cfg, '{}'::jsonb);
  p := public.ticket_panel_cfg(cfg, pid);
  multi := jsonb_typeof(cfg -> 'panels') = 'array' and jsonb_array_length(cfg -> 'panels') > 1;
  pname := nullif(btrim(p ->> 'name'), '');
  plus := public.server_plus_on(sid);
  if t = '' then raise exception 'Say what the ticket is about'; end if;
  -- How many open tickets one person may have: 2 by default, up to 3 free, up to 10 with Tickets+.
  maxo := least(greatest(coalesce(nullif(cfg ->> 'max_open', '')::int, 2), 1), case when plus then 10 else 3 end);
  if (select count(*) from public.channels where server_id = sid and ticket_by = me) >= maxo then
    raise exception '%', case when maxo = 1 then 'You already have an open ticket here' else 'You already have ' || maxo || ' open tickets here. Close one first.' end;
  end if;
  if (select count(*) from public.channels where server_id = sid) >= 100 then raise exception 'This server has too many channels for a new ticket'; end if;
  select id into cat from public.channel_categories where id = nullif(p ->> 'category_id', '')::uuid and server_id = sid;
  if cat is null then select id into cat from public.channel_categories where server_id = sid and lower(name) = 'tickets' limit 1; end if;
  if cat is null then
    insert into public.channel_categories (server_id, name, position)
      values (sid, 'Tickets', coalesce((select max(position) + 1 from public.channel_categories where server_id = sid), 0)) returning id into cat;
  end if;
  -- Channel names: ticket-0007, or the panel's name when there are several (support-0007, report-0008).
  prefix := case when multi and pname is not null then left(trim(both '-' from lower(regexp_replace(pname, '[^A-Za-z0-9]+', '-', 'g'))), 20) else 'ticket' end;
  if coalesce(prefix, '') = '' then prefix := 'ticket'; end if;
  update public.servers set ticket_seq = ticket_seq + 1 where id = sid returning ticket_seq into n;
  insert into public.channels (kind, name, server_id, created_by, position, private, category_id, ticket_by, ticket_panel)
    values ('text', prefix || '-' || lpad(n::text, 4, '0'), sid, me, coalesce((select max(position) + 1 from public.channels where server_id = sid), 0), true, cat, me, p ->> 'id')
    returning id into cid;
  insert into public.channel_members (channel_id, user_id) values (cid, me) on conflict do nothing;
  if plus then select id into support from public.roles where id = nullif(p ->> 'support_role_id', '')::uuid and server_id = sid; end if;
  if support is not null then
    insert into public.channel_roles (channel_id, role_id, server_id) values (cid, support, sid) on conflict do nothing;
  else
    for r in select id from public.roles where server_id = sid and (manage_messages or manage_server or coalesce((perms ->> 'manage_messages')::boolean, false) or coalesce((perms ->> 'administrator')::boolean, false)) loop
      insert into public.channel_roles (channel_id, role_id, server_id) values (cid, r.id, sid) on conflict do nothing;
    end loop;
  end if;
  insert into public.messages (channel_id, author_id, content, created_at)
    values (cid, me, '🎫 **' || case when multi and pname is not null then pname || ' ticket' else 'Ticket' end || ' opened**' || E'\n' || t, clock_timestamp());
  if public.bot_cfg(sid, 'tickets') is not null then
    greet := case when plus and nullif(btrim(p ->> 'welcome'), '') is not null then left(p ->> 'welcome', 500)
                  else 'Thanks for opening a ticket. Staff will be with you soon. Close it from the top of the channel when you''re done.' end;
    if support is not null then
      select string_agg('<@' || mr.user_id || '>', ' ') into pings from (select user_id from public.member_roles where role_id = support and user_id <> me limit 10) mr;
    end if;
    perform set_config('yapper.bot', '1', true);
    insert into public.messages (channel_id, author_id, content, created_at)
      values (cid, public.bot_id('tickets'), left(case when position('{user}' in greet) > 0 then replace(greet, '{user}', '<@' || me || '>') when plus and nullif(btrim(p ->> 'welcome'), '') is not null then '<@' || me || '> ' || greet else 'Hi <@' || me || '>! ' || greet end || coalesce(E'\n' || pings, ''), 2000), clock_timestamp() + interval '1 millisecond');
    perform set_config('yapper.bot', '', true);
    logc := nullif(p ->> 'log_channel_id', '')::uuid;
    if logc is not null and exists (select 1 from public.channels where id = logc and server_id = sid) then
      perform public.bot_say(logc, 'tickets', '🎫 <#' || cid || '> opened by **' || public.log_name(me) || '**'
        || case when multi and pname is not null then ' (' || pname || ')' else '' end || ': ' || public.log_clean(t, 300));
    end if;
  end if;
  return cid;
end; $function$;
`;

const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '183_channel_create_limit.sql'), 'utf8');

export default async function (h) {
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIGRATION);
  await h.ok('183 re-runs cleanly', () => h.db.exec(MIGRATION));
  const marks = await h.one(`select
    (select count(*) from regexp_matches(pg_get_functiondef('public.channel_guard()'::regprocedure), '183:', 'g'))::int g,
    (select count(*) from regexp_matches(pg_get_functiondef('public.open_ticket(uuid,text,text)'::regprocedure), 'yapper.ticket', 'g'))::int t,
    (select count(*) from regexp_matches(pg_get_functiondef('public.create_server(text,text)'::regprocedure), 'yapper', 'g'))::int s`);
  h.eq('channel_guard patched once, open_ticket sets and clears once, create_server untouched', [marks.g, marks.t, marks.s], [1, 2, 0]);
  h.eq('one limit trigger', (await h.one(`select count(*)::int n from pg_trigger where tgname = 'channels_create_limit'`)).n, 1);

  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e.message; } };
  const count = async (sid) => { await h.admin(); return (await h.one(`select count(*)::int n from channels where server_id = $1`, [sid])).n; };
  const ticketBy = async (cid) => { await h.admin(); return (await h.one(`select ticket_by from channels where id = $1`, [cid])).ticket_by; };

  const owner = await h.signup('owner@test.dev', 'owner');
  const staff = await h.signup('staff@test.dev', 'staff');
  const admin = await h.signup('admin@test.dev', 'admin');
  const member = await h.signup('member@test.dev', 'member');
  await h.admin();
  await h.q(`insert into site_moderators (user_id) values ($1)`, [staff]);
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);

  // ---- the limit: 10 a minute through create_channel (the app and the bot API both call it) ----
  await h.as(owner);
  const sid = (await h.one(`select create_server('Spam test', null) id`)).id;
  h.eq('create_server: 2 channels', await count(sid), 2);
  await h.admin();
  await h.q(`update servers set tickets_on = true where id = $1`, [sid]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, member]);
  // (Stage 24 lets brand-new accounts post once every 3 seconds; each ticket posts its opening message.)
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [member]);
  await h.as(owner);
  for (let i = 1; i <= 10; i++) await h.q(`select create_channel($1, 'hi', 'text')`, [sid]);
  h.eq('10 by hand right after creating the server (its own 2 do not count)', await count(sid), 12);
  await h.as(owner);
  h.eq('the 11th in a minute is refused', await err(`select create_channel($1, 'hi', 'text')`, [sid]), 'Slow down, too many channels at once');
  h.eq('nothing was added', await count(sid), 12);
  h.eq('voice channels count too', await (async () => { await h.as(owner); return err(`select create_channel($1, 'Lounge', 'voice')`, [sid]); })(), 'Slow down, too many channels at once');

  // ---- tickets (through open_ticket) aren't limited and don't count ----
  await h.as(member);
  const tid = (await h.one(`select open_ticket($1, 'help pls', null) id`, [sid])).id;
  h.eq('a ticket still opens while the limit is hit, and keeps ticket_by', await ticketBy(tid), member);
  await h.as(member);
  await h.db.exec('begin');
  await h.q(`select open_ticket($1, 'second one', null)`, [sid]);
  h.eq('open_ticket clears yapper.ticket before it returns', (await h.one(`select coalesce(current_setting('yapper.ticket', true), '') v`)).v, '');
  await h.db.exec('rollback');

  // ---- ticket_by can't be set on insert outside open_ticket ----
  await h.as(owner);
  h.eq('an insert with ticket_by set elsewhere is limited like any channel', await err(`select t_fake_ticket($1)`, [sid]), 'Slow down, too many channels at once');

  // ---- a minute later it works again ----
  await h.admin();
  // (channels_guard keeps created_at as it was on updates, so it's switched off for this one.)
  await h.db.exec(`alter table channels disable trigger channels_guard`);
  await h.q(`update servers set created_at = created_at - interval '5 minutes' where id = $1`, [sid]);
  await h.q(`update channels set created_at = created_at - interval '61 seconds' where server_id = $1`, [sid]);
  await h.db.exec(`alter table channels enable trigger channels_guard`);
  await h.as(owner);
  await h.ok('works again after a minute', () => h.q(`select create_channel($1, 'later', 'text')`, [sid]));
  await h.as(owner);
  const fid = (await h.one(`select t_fake_ticket($1) id`, [sid])).id;
  h.eq('insert pin: ticket_by cleared when not made by open_ticket', await ticketBy(fid), null);

  // ---- ticket_by can't be changed by an update (managers / bots with manage_channels) ----
  await h.as(owner);
  const plain = (await h.one(`select id from channels where server_id = $1 and name = 'later'`, [sid])).id;
  await h.q(`update channels set ticket_by = $2 where id = $1`, [plain, owner]);
  h.eq('update pin: a manager can\'t mark a channel as a ticket', await ticketBy(plain), null);
  await h.as(owner);
  await h.q(`update channels set ticket_by = $2 where id = $1`, [tid, owner]);
  h.eq('update pin: a manager can\'t hand a ticket to someone else', await ticketBy(tid), member);
  await h.as(owner);
  await h.q(`update channels set ticket_by = null, name = 'renamed-ticket' where id = $1`, [tid]);
  h.eq('update pin: a manager can\'t un-ticket it, other columns still save', await (async () => { await h.admin(); return h.one(`select ticket_by, name from channels where id = $1`, [tid]); })(), { ticket_by: member, name: 'renamed-ticket' });
  await h.admin();
  await h.q(`update channels set ticket_by = $2 where id = $1`, [plain, owner]);
  h.eq('update pin holds without a signed-in user too', await ticketBy(plain), null);
  // The opener's account going away still clears it (ON DELETE SET NULL goes through channel_guard). The ticket is
  // made by someone else here because channel_guard also pins created_by, which blocks that delete on its own.
  const gone = await h.signup('gone@test.dev', 'gone');
  await h.admin();
  await h.db.exec('begin');
  await h.q(`select set_config('yapper.ticket', '1', true)`);
  const gid = (await h.one(`insert into channels (kind, name, server_id, created_by, private, ticket_by) values ('text', 'ticket-gone', $1, $2, true, $3) returning id`, [sid, owner, gone])).id;
  await h.db.exec('commit');
  h.eq('with yapper.ticket set, the insert keeps ticket_by', await ticketBy(gid), gone);
  await h.admin();
  await h.q(`delete from auth.users where id = $1`, [gone]);
  h.eq('deleted opener: ticket_by goes null', await ticketBy(gid), null);

  // ---- 379: open_ticket takes a per-server lock (two at once both passed the count and both made the category) ----
  const M379 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '379_open_ticket_lock.sql'), 'utf8');
  await h.admin();
  await h.db.exec(M379);
  await h.ok('379 re-runs cleanly', () => h.db.exec(M379));
  h.eq('open_ticket has the lock once, and still sets and clears yapper.ticket',
    await h.one(`select (select count(*) from regexp_matches(pg_get_functiondef('public.open_ticket(uuid,text,text)'::regprocedure), 'pg_advisory_xact_lock', 'g'))::int l,
      (select count(*) from regexp_matches(pg_get_functiondef('public.open_ticket(uuid,text,text)'::regprocedure), 'yapper.ticket', 'g'))::int t`),
    { l: 1, t: 2 });
  await h.as(member);
  const tid2 = (await h.one(`select open_ticket($1, 'after the lock', null) id`, [sid])).id;
  h.eq('a ticket still opens with the lock, and keeps ticket_by', await ticketBy(tid2), member);
  await h.as(member);
  h.eq('the max-open check still counts (2 by default)', await err(`select open_ticket($1, 'one too many', null)`, [sid]), 'You already have 2 open tickets here. Close one first.');

  // ---- staff aren't limited ----
  await h.as(staff);
  const ssid = (await h.one(`select create_server('Staff server', null) id`)).id;
  await h.as(staff);
  for (let i = 1; i <= 12; i++) await h.q(`select create_channel($1, 'x', 'text')`, [ssid]);
  h.eq('moderator: 12 in a minute', await count(ssid), 14);
  await h.as(admin);
  const asid = (await h.one(`select create_server('Admin server', null) id`)).id;
  await h.as(admin);
  for (let i = 1; i <= 11; i++) await h.q(`select create_channel($1, 'x', 'text')`, [asid]);
  h.eq('admin: 11 in a minute', await count(asid), 13);
  await h.admin();
  await h.q(`update site_moderators set suspended_at = now() where user_id = $1`, [staff]);
  await h.as(staff);
  h.eq('a suspended moderator is limited like anyone', await err(`select create_channel($1, 'x', 'text')`, [ssid]), 'Slow down, too many channels at once');

  // ---- a fresh server's channels (template, Discord import) are made in its own transaction and don't count ----
  await h.admin();
  const chans = Array.from({ length: 15 }, (_, i) => ({ kind: i % 3 ? 'text' : 'voice', name: `c${i}` }));
  await h.q(`insert into server_templates (code, data) values ('big', $1::jsonb)`, [JSON.stringify({ channels: chans, roles: [] })]);
  await h.as(owner);
  const tsid = (await h.one(`select create_server_from_template('big', 'From template', null) id`)).id;
  h.eq('template: all 15 channels', await count(tsid), 15);
  await h.as(owner);
  for (let i = 1; i <= 10; i++) await h.q(`select create_channel($1, 'extra', 'text')`, [tsid]);
  h.eq('10 by hand right after the template', await count(tsid), 25);
  await h.as(owner);
  h.eq('then limited as usual', await err(`select create_channel($1, 'extra', 'text')`, [tsid]), 'Slow down, too many channels at once');

  await h.as(owner);
  const isid = (await h.one(`select import_discord_server($1::jsonb) id`, [JSON.stringify({ name: 'Imported', channels: Array.from({ length: 30 }, (_, i) => ({ kind: 'text', name: `ch-${i}` })) })])).id;
  h.eq('import: all 30 channels', await count(isid), 30);
  await h.as(owner);
  await h.ok('a channel by hand right after the import', () => h.q(`select create_channel($1, 'extra', 'text')`, [isid]));

  // ---- DMs and groups (no server) are untouched ----
  await h.as(owner);
  await h.ok('15 DMs in a burst', () => h.q(`select t_dm_burst(15)`));
  await h.admin();
  h.eq('all 15 made', (await h.one(`select count(*)::int n from channels where server_id is null and created_by = $1`, [owner])).n, 15);

  // The trigger function isn't callable by users.
  await h.as(owner);
  h.eq('no execute for users', (await h.one(`select has_function_privilege('authenticated', 'public.channel_create_limit()', 'execute') v`)).v, false);
}
