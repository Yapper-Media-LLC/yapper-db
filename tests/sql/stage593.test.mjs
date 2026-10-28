// 593: forum channels and threads. PGlite can't replay every migration, so like stage193 this starts from stage 24
// (+ flags 031/041), adds stand-ins for what the live permission helpers call, then the live bodies of the functions 593
// patches in place, copied from the live database (pg_get_functiondef, Oct 25), so the patches are checked against the
// real text. Then 593 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export const STANDINS = String.raw`
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists no_images boolean not null default false;
alter table public.channels add column if not exists no_gifs boolean not null default false;
alter table public.channels add column if not exists ticket_by uuid;
create table if not exists public.roles (id uuid primary key default gen_random_uuid(), server_id uuid, name text);
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text;
alter table public.roles add column if not exists auto_before timestamptz;
create table if not exists public.member_roles (server_id uuid, user_id uuid, role_id uuid);
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), channel_id uuid, category_id uuid, role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}');
create table if not exists public.channel_post_roles (channel_id uuid, role_id uuid);
create table if not exists public.channel_categories (id uuid primary key default gen_random_uuid(), name text, position int);
create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create table if not exists public.test_perms (server_id uuid, user_id uuid, perm text);
create table if not exists public.test_timeouts (server_id uuid, user_id uuid, until timestamptz);
create table if not exists public.bc_log (topic text, event text, payload jsonb);
create or replace function public.is_site_mod() returns boolean language sql stable as $$ select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
create or replace function public.is_staff() returns boolean language sql stable as $$ select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid())
      or (exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = auth.uid())
          and (perm in ('send_messages', 'read_history', 'view_channel')
               or exists (select 1 from public.test_perms t where t.server_id = sid and t.user_id = auth.uid() and t.perm = perm)));
$$;
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean) returns boolean language sql stable as $$ select base $$;
create or replace function public.auto_role_applies(rid uuid, uid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.staff_peek_ok(sid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.fancy_channel_slug(t text) returns text language sql immutable as $$ select public.slugify_channel(t) $$;
create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable as $$
  select max(until) from public.test_timeouts where server_id = sid and user_id = uid and until > now() $$;
create or replace function public.bc(t text, e text, op text, tbl text, sch text, n public.messages, o public.messages) returns void language sql as $$
  insert into public.bc_log values (t, e, jsonb_build_object('op', op)) $$;
create or replace function public.bc(t text, e text, op text, tbl text, sch text, n public.channels, o public.channels) returns void language sql as $$
  insert into public.bc_log values (t, e, jsonb_build_object('op', op)) $$;
create or replace function public.bc_notice(t text, e text, payload jsonb) returns void language sql as $$
  insert into public.bc_log values (t, e, payload) $$;
-- Like the live table grant: members can update channel rows (RLS decides which).
create policy "test: update any channel" on public.channels for update to authenticated using (true) with check (true);
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 25. */
export const LIVE = String.raw`
CREATE OR REPLACE FUNCTION public.can_access_channel(cid uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return (
  select
    not public.is_site_banned(auth.uid())
    and (
      public.is_channel_member(cid)
      or exists (
        select 1 from public.channels c
        where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
          and not exists (select 1 from public.servers sd where sd.id = c.server_id and sd.shut_down_at is not null and not public.is_staff())
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                                and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                    and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
            else (
              not c.private
              or public.server_perm(c.server_id, 'manage_server')
              or exists (
                select 1 from public.channel_roles cr
                join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
                where cr.channel_id = c.id
              )
              or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
              or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id) and (public.is_site_admin() or public.staff_peek_ok(c.server_id)))
            ) end
      )
    )
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.can_post_channel(cid uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return (
  select coalesce((
    select
      (c.server_id is null
        or case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
             then public.channel_perm(c.id, 'send_messages')
             else public.server_perm(c.server_id, 'send_messages') end)
      and (
        not c.read_only
        or public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_post_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_post_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
      )
    from public.channels c where c.id = cid
  ), true)
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.channel_allows(cid uuid, perm text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; live boolean;
begin
  select c.server_id, exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    into sid, live from public.channels c where c.id = cid;
  if sid is null then return true; end if;
  if live then return public.channel_perm(cid, perm); end if;
  return public.server_perm(sid, perm);
end $function$;
CREATE OR REPLACE FUNCTION public.channel_history_ok(cid uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return (
  select coalesce((select case when c.server_id is null then true
                               when c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id) then false
                               when c.kind = 'voice' and public.channel_overrides_live(c.id) and not public.channel_perm(c.id, 'connect') then false
                               else public.channel_allows(c.id, 'read_history') end
                   from public.channels c where c.id = cid), true)
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.channel_perm(cid uuid, perm text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = cid;
  if not found then return false; end if;
  if sid is null then return true; end if;
  if not public.is_server_member(sid) and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid()) then
    return false;
  end if;
  if perm = 'view_channel' then
    return public.channel_perm_of(auth.uid(), cid, perm, public.channel_view_base(cid));
  end if;
  return public.channel_perm_of(auth.uid(), cid, perm, public.server_perm(sid, perm));
end $function$;
CREATE OR REPLACE FUNCTION public.channel_view_base(cid uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return (
  select exists (
    select 1 from public.channels c
    where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
      and (
        public.server_perm(c.server_id, 'manage_server')
        or exists (
          select 1 from public.channel_roles cr
          join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid()
          where cr.channel_id = c.id
        )
        or exists (select 1 from public.channel_roles cr where cr.channel_id = c.id and public.auto_role_applies(cr.role_id, auth.uid()))
        or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id) and (public.is_site_admin() or public.staff_peek_ok(c.server_id)))
      )
  )
  );
end;
$function$;
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
CREATE OR REPLACE FUNCTION public.bot_channel_visible(bid uuid, cid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.channels c
    where c.id = cid
      and (
        (c.server_id is not null and exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = c.server_id)
          and case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
            then public.channel_perm_of(bid, c.id, 'view_channel',
                   exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
                   or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id))
            else (not c.private
               or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid)
               or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = bid where cr.channel_id = c.id))
          end)
        or (c.server_id is null and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = bid))
      )
  );
$function$;
CREATE OR REPLACE FUNCTION public.bot_visible_channels(bid uuid, sid uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, name text, type text, server_id uuid, category_id uuid, category_name text, category_position integer, "position" integer, private boolean, read_only boolean, slowmode integer, nsfw boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.name, c.kind::text, c.server_id, c.category_id, cc.name, cc.position, c.position, c.private, coalesce(c.read_only, false), coalesce(c.slowmode, 0), false
  from public.channels c
  join public.bot_servers bs on bs.bot_id = bid and bs.server_id = c.server_id
  left join public.channel_categories cc on cc.id = c.category_id
  where (sid is null or c.server_id = sid)
    and ((not c.private and not public.channel_overrides_live(c.id)) or public.bot_channel_visible(bid, c.id))
  order by c.server_id, cc.position nulls first, c.position, c.name;
$function$;
CREATE OR REPLACE FUNCTION public.broadcast_message_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cid uuid; sid uuid; uid uuid; o public.messages;
  body text; targets uuid[]; open_ boolean; vis boolean; restricted boolean; old_claims text; old_sub text;
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  cid := coalesce(new.channel_id, old.channel_id);
  if tg_op = 'DELETE' then
    o := jsonb_populate_record(null::public.messages, jsonb_build_object('id', old.id, 'channel_id', old.channel_id, 'author_id', old.author_id));
  else
    o := old;
  end if;
  select ch.server_id,
         coalesce(ch.private, false)
         or exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
    into sid, restricted from public.channels ch where ch.id = cid;
  restricted := coalesce(restricted, true);
  open_ := not restricted;
  if sid is not null then
    perform public.bc('chan:' || cid, 'message', tg_op, tg_table_name, tg_table_schema, new, o);
    body := coalesce(new.content, '');
    if tg_op in ('INSERT', 'DELETE') and exists (
         select 1 from public.feature_flags f
         where f.key = 'live_badges' and (f.mode = 'everyone' or (f.mode = 'test' and sid = any(f.servers)))) then
      perform public.bc_notice('server:' || sid, 'unread', jsonb_build_object(
        'operation', tg_op,
        'id', coalesce(new.id, old.id),
        'channel_id', cid,
        'author_id', coalesce(new.author_id, old.author_id),
        'created_at', coalesce(new.created_at, old.created_at),
        'everyone', false,
        'restricted', restricted));
    end if;
  end if;
  return null;
end; $function$;
CREATE OR REPLACE FUNCTION public.visible_server_channels_fast(sids uuid[])
 RETURNS SETOF channels
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return query
  with me as materialized (select auth.uid() as uid, public.is_staff() as staff),
  mine as materialized (
    select sm.server_id, sm.joined_at, false as cp
    from public.server_members sm, me
    where sm.user_id = me.uid and (sids is null or sm.server_id = any(sids))
  ),
  ch as materialized (
    select l.c, mine.server_id, mine.joined_at, false as ovr
    from mine cross join lateral (select c from public.channels c where c.server_id = mine.server_id offset 0) l
  )
  select (ch.c).* from ch where not (ch.c).private;
end
$function$;
`;
export const LIVE2 = String.raw`
CREATE OR REPLACE FUNCTION public.channel_overrides_live(cid uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return (
  select coalesce((
    select exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
       and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    from public.channels c where c.id = cid), false)
  );
end;
$function$;
create or replace function public.bot_server_perm(bid uuid, sid uuid, perm text) returns boolean language sql stable as $$ select true $$;
CREATE OR REPLACE FUNCTION public.bot_channel_history_ok(bid uuid, cid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select case when c.server_id is null then true
                               when c.kind = 'voice' and not public.feature_on('voice_chat', c.server_id) then false
                               else public.bot_server_perm(bid, c.server_id, 'read_history') end
                   from public.channels c where c.id = cid), false);
$function$;
CREATE OR REPLACE FUNCTION public.bc_channel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  sid := coalesce(new.server_id, old.server_id);
  if sid is not null then perform public.bc_notice('server:' || sid, 'channel', jsonb_build_object('id', coalesce(new.id, old.id))); end if;
  return null;
end; $function$;
CREATE OR REPLACE FUNCTION public.channel_create_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  if new.server_id is null or new.ticket_by is not null then return new; end if;
  if auth.uid() is null then return new; end if;
  select count(*) into n from public.channels c where c.server_id = new.server_id and c.created_at > now() - interval '1 minute';
  if n >= 10 then raise exception 'Slow down, too many channels at once'; end if;
  return new;
end $function$;
create or replace function public.fancy_clean_name(t text) returns text language sql immutable as $$ select t $$;
CREATE OR REPLACE FUNCTION public.channel_fancy_name()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.server_id is null or new.name is null or not public.feature_on('fancy_names', new.server_id) then return new; end if;
  new.name := case when new.kind = 'voice' then left(public.fancy_clean_name(new.name), 100) else public.fancy_channel_slug(new.name) end;
  if new.name is null then raise exception 'Channels need a name'; end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.audit_channels()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d jsonb;
begin
  if coalesce(new.ticket_by, old.ticket_by) is not null then return null; end if;
  insert into public.bc_log values ('audit', tg_op, jsonb_build_object('kind', coalesce(new.kind, old.kind)));
  return null;
end $function$;
CREATE OR REPLACE FUNCTION public.message_perm_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; cp boolean; vk text;
begin
  select c.server_id, sid_live, c.kind into sid, cp, vk from (
    select c.server_id, c.kind, false as sid_live
    from public.channels c where c.id = new.channel_id) c;
  return new;
end; $function$;
CREATE OR REPLACE FUNCTION public.message_edit_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; cp boolean;
begin
  if new.content is distinct from old.content then
      select exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) into cp
        from public.channels c where c.id = old.channel_id;
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.message_slowmode()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.channels;
begin
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null then return new; end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.invites_only_in_promo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ch record;
begin
  select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.submit_suggestion(cid uuid, p_title text, p_area text, p_body text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.channels;
begin
  select * into c from public.channels where id = cid;
  if c.id is null or c.server_id is null or c.name not in ('suggestions-new', 'suggestions') then
    raise exception 'Not a suggestions channel';
  end if;
  return cid;
end $function$;
`;
// broadcast_message_change and visible_server_channels_fast above keep the live text around the patched anchors; the
// parts that need tables PGlite doesn't have (pings, override evaluation) are trimmed.

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(LIVE2);
  await h.db.exec(`create trigger test_broadcast after insert on public.messages for each row execute function public.broadcast_message_change();`);
  await h.db.exec(`create trigger test_channels_bc after insert or update or delete on public.channels for each row execute function public.bc_channel();
    create trigger test_channels_audit after insert or update or delete on public.channels for each row execute function public.audit_channels();
    create trigger test_channels_limit before insert on public.channels for each row execute function public.channel_create_limit();`);
  const MIG = mig('593_forums.sql');
  await h.ok('593 runs', () => h.db.exec(MIG));
  await h.ok('593 re-runs cleanly', () => h.db.exec(MIG));
  for (const p of ['can_access_channel(uuid)', 'can_post_channel(uuid)', 'channel_history_ok(uuid)', 'channel_view_base(uuid)', 'channel_allows(uuid,text)',
    'channel_perm(uuid,text)', 'create_channel(uuid,text,text)', 'visible_server_channels_fast(uuid[])', 'bot_visible_channels(uuid,uuid)',
    'bot_channel_visible(uuid,uuid)', 'broadcast_message_change()', 'channel_overrides_live(uuid)', 'bot_channel_history_ok(uuid,uuid)',
    'bc_channel()', 'channel_create_limit()', 'channel_fancy_name()', 'audit_channels()', 'message_perm_guard()', 'message_edit_guard()',
    'message_slowmode()', 'invites_only_in_promo()', 'submit_suggestion(uuid,text,text,text)']) {
    const def = (await h.one(`select pg_get_functiondef('public.${p}'::regprocedure) d`)).d;
    h.eq(`${p} patched once`, def.split('593:').length - 1 >= 1 && def.split('593:').length - 1 <= 2, true);
  }

  const u = {};
  for (const n of ['owner', 'mem', 'mod', 'out', 'priv']) u[n] = await h.signup(`${n}@test.dev`, n);
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Hub', $1) returning id`, [u.owner])).id;
  for (const n of ['owner', 'mem', 'mod', 'priv']) await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, u[n]]);
  await h.q(`insert into test_perms values ($1, $2, 'manage_messages')`, [sid, u.mod]);
  const T = (await h.one(`insert into channels (kind, name, server_id, created_by, position) values ('text', 'general', $1, $2, 0) returning id`, [sid, u.owner])).id;
  const P = (await h.one(`insert into channels (kind, name, server_id, created_by, position, private) values ('text', 'secret', $1, $2, 1, true) returning id`, [sid, u.owner])).id;
  const role = (await h.one(`insert into roles (server_id, name) values ($1, 'insiders') returning id`, [sid])).id;
  await h.q(`insert into channel_roles (channel_id, role_id, server_id) values ($1, $2, $3)`, [P, role, sid]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, u.priv, role]);

  // ---------- forum channels ----------
  await h.as(u.owner);
  await h.fails('forum needs the flag', `select create_channel($1, 'help', 'forum')`, [sid]);
  await h.fails('unknown kinds refused', `select create_channel($1, 'x', 'thread')`, [sid]);
  await h.admin();
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'forums'`, [sid]);
  await h.as(u.owner);
  const F = (await h.one(`select create_channel($1, 'help desk', 'forum') id`, [sid])).id;
  h.eq('forum created', (await h.one(`select kind from channels where id = $1`, [F])).kind, 'forum');
  const tags = (await h.one(`select set_forum_tags($1, $2::jsonb) t`, [F, JSON.stringify([{ name: 'Bug' }, { name: 'Idea' }, { name: '' }, { name: 'x'.repeat(30) }])])).t;
  h.eq('tags: empty and too long dropped', tags.map((t) => t.name), ['Bug', 'Idea']);
  await h.as(u.mem);
  await h.fails('only managers set tags', `select set_forum_tags($1, '[]'::jsonb)`, [F]);
  h.eq('nobody posts in the forum itself', (await h.one(`select can_post_channel($1) ok`, [F])).ok, false);

  // ---------- posts ----------
  const post = (await h.one(`select create_thread($1, '  My   app crashes ', $2, null, 'it crashes when I open it') id`, [F, [tags[0].id, 'nope']])).id;
  await h.admin();
  const row = await h.one(`select kind, name, parent_id, tags, server_id from channels where id = $1`, [post]);
  h.eq('post is a thread under the forum', [row.kind, row.name, row.parent_id, row.tags], ['thread', 'My app crashes', F, [tags[0].id]]);
  await h.admin();
  h.eq('thread rows are stored private', (await h.one(`select private from channels where id = $1`, [post])).private, true);
  h.eq('no server-wide broadcast or audit line for a thread', (await h.one(`select count(*)::int n from bc_log where (topic like 'server:%' and event = 'channel' and payload->>'id' = $1) or (topic = 'audit' and payload->>'kind' = 'thread')`, [post])).n, 0);
  await h.as(u.mem);
  await h.fails('a post needs a first message', `select create_thread($1, 'empty')`, [F]);
  await h.fails('a refused first message leaves no thread', `select create_thread($1, 'too long', '{}', null, $2)`, [F, 'x'.repeat(5000)]);
  await h.admin();
  h.eq('...and no thread was made', (await h.one(`select count(*)::int n from channels where name in ('empty', 'too long')`)).n, 0);
  await h.as(u.mem);
  h.eq('member can post in a post', (await h.one(`select can_post_channel($1) ok`, [post])).ok, true);
  h.eq('member sees the post', (await h.one(`select can_access_channel($1) ok`, [post])).ok, true);
  await h.as(u.mem);
  let list = (await h.one(`select list_threads($1) l`, [F])).l;
  h.eq('list shows the post with its first message', [list.length, list[0].name, list[0].messages, list[0].first.content], [1, 'My app crashes', 1, 'it crashes when I open it']);
  h.eq('tag filter', (await h.one(`select jsonb_array_length(list_threads($1, 'activity', $2)) n`, [F, tags[1].id])).n, 0);
  await h.fails('a forum post doesn\'t start from a message', `select create_thread($1, 'x', '{}', $2)`, [F, (await h.one(`select id from messages limit 1`)).id]);
  await h.as(u.out);
  await h.fails('outsider can\'t post', `select create_thread($1, 'hi')`, [F]);
  h.eq('outsider lists nothing', (await h.one(`select list_threads($1) l`, [F])).l, []);

  // ---------- threads from messages ----------
  await h.admin();
  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'what does everyone think about the new update') returning id`, [T, u.owner])).id;
  await h.as(u.mem);
  const th = (await h.one(`select create_thread($1, '', '{}', $2, 'good question') id`, [T, msg])).id;
  await h.admin();
  h.eq('thread title from the message', (await h.one(`select name, starter_message_id from channels where id = $1`, [th])), { name: 'what does everyone think about the new update', starter_message_id: msg });
  await h.as(u.owner);
  await h.fails('one thread per message', `select create_thread($1, 'again', '{}', $2, 'hi')`, [T, msg]);
  await h.fails('message must be in that channel', `select create_thread($1, 'x', '{}', $2, 'hi')`, [P, msg]);
  const msg2 = (await (async () => { await h.admin(); return h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'another one') returning id`, [T, u.owner]); })()).id;
  await h.as(u.mem);
  await h.fails('from a message, a first message is still needed', `select create_thread($1, 'x', '{}', $2)`, [T, msg2]);
  await h.as(u.owner);

  // ---------- private parents ----------
  await h.as(u.owner);
  const pth = (await h.one(`select create_thread($1, 'plans', '{}', null, 'first') id`, [P])).id;
  await h.as(u.mem);
  h.eq('a thread in a private channel is private too', (await h.one(`select can_access_channel($1) ok`, [pth])).ok, false);
  h.eq('the history check alone stays true (access decides)', (await h.one(`select channel_history_ok($1) ok`, [pth])).ok, true);
  h.eq('private channel threads not listed', (await h.one(`select list_threads($1) l`, [P])).l, []);
  await h.fails('can\'t start one there', `select create_thread($1, 'sneaky')`, [P]);
  await h.as(u.priv);
  h.eq('the role that sees the channel sees its threads', (await h.one(`select can_access_channel($1) ok`, [pth])).ok, true);
  await h.admin();
  await h.q(`delete from bc_log`);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'live_badges'`).catch(() => undefined);
  await h.q(`insert into feature_flags (key, label, mode) values ('live_badges', 'x', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'secret stuff')`, [pth, u.owner]);
  h.eq('live badge notice for a private thread is restricted', (await h.one(`select (payload->>'restricted')::boolean r from bc_log where event = 'unread'`)).r, true);

  // ---------- closing and deleting ----------
  await h.as(u.mem);
  await h.q(`select close_thread($1, true)`, [post]);
  await h.admin();
  h.eq('a close goes to the thread\'s own topic', (await h.one(`select count(*)::int n from bc_log where topic = $1 and event = 'channel'`, [`chan:${post}`])).n >= 1, true);
  await h.as(u.mem);
  h.eq('closed: no posting for members', (await h.one(`select can_post_channel($1) ok`, [post])).ok, false);
  await h.as(u.mod);
  h.eq('closed: mods still post', (await h.one(`select can_post_channel($1) ok`, [post])).ok, true);
  await h.as(u.mem);
  await h.q(`select close_thread($1, false)`, [post]);
  await h.as(u.mod);
  await h.q(`select close_thread($1, true)`, [post]);
  await h.as(u.mem);
  await h.fails('reopening what a mod closed takes a mod', `select close_thread($1, false)`, [post]);
  await h.q(`select close_thread($1, true)`, [post]);
  await h.admin();
  h.eq('closing again keeps who closed it', (await h.one(`select closed_by from channels where id = $1`, [post])).closed_by, u.mod);
  await h.as(u.mem);
  await h.fails('...so the owner still can\'t reopen it', `select close_thread($1, false)`, [post]);
  await h.admin();
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'a reply from a mod')`, [post, u.mod]);
  await h.as(u.mem);
  await h.fails('the owner can\'t delete once others replied', `select delete_thread($1)`, [post]);
  await h.admin();
  await h.q(`update channels set slowmode = 30, no_images = true where id = $1`, [P]);
  h.eq('a parent\'s settings reach its threads', (await h.one(`select slowmode, no_images from channels where id = $1`, [pth])), { slowmode: 30, no_images: true });
  await h.as(u.priv);
  const own = (await h.one(`select create_thread($1, 'mine to close', '{}', null, 'hi') id`, [T])).id;
  await h.q(`select close_thread($1, true)`, [own]);
  await h.as(u.mod);
  await h.q(`select close_thread($1, true)`, [own]);
  await h.as(u.priv);
  await h.fails('a mod closing an owner-closed thread keeps it closed', `select close_thread($1, false)`, [own]);
  await h.as(u.owner);
  await h.fails('a thread can\'t be made public directly', `update channels set private = false where id = $1`, [pth]);
  await h.as(u.out);
  await h.fails('others can\'t close', `select close_thread($1, true)`, [th]);
  await h.fails('others can\'t delete', `select delete_thread($1)`, [th]);
  await h.as(u.mem);
  await h.q(`select delete_thread($1)`, [th]);
  await h.admin();
  h.eq('deleted', (await h.one(`select count(*)::int n from channels where id = $1`, [th])).n, 0);

  // ---------- guard, limits, timeouts ----------
  await h.as(u.owner);
  await h.fails('parent_id can\'t be set directly', `update channels set parent_id = $2 where id = $1`, [T, F]);
  // channel_guard (live, and in this base) puts kind back on every update, so this is undone rather than refused.
  await h.q(`update channels set kind = 'forum' where id = $1`, [T]).catch(() => undefined);
  h.eq('kind can\'t become forum directly', (await h.one(`select kind from channels where id = $1`, [T])).kind, 'text');
  await h.fails('closed_at can\'t be set directly', `update channels set closed_at = now() where id = $1`, [post]);
  await h.q(`update channels set name = 'renamed post' where id = $1`, [post]);
  h.eq('other edits still work', (await h.one(`select name from channels where id = $1`, [post])).name, 'renamed post');
  await h.admin();
  await h.q(`insert into test_timeouts values ($1, $2, now() + interval '1 hour')`, [sid, u.mem]);
  await h.as(u.mem);
  await h.fails('timed out: no new posts', `select create_thread($1, 'hi', '{}', null, 'hello')`, [F]);
  await h.admin();
  await h.q(`delete from test_timeouts`);
  await h.as(u.mem);
  for (let i = 0; i < 9; i++) await h.q(`select create_thread($1, $2, '{}', null, 'hello')`, [F, `post ${i}`]);
  await h.fails('10 in 10 minutes, then wait', `select create_thread($1, 'one more', '{}', null, 'hello')`, [F]);
  await h.as(u.mem);
  h.eq('newest sort', (await h.one(`select list_threads($1, 'new', null, null, 3) l`, [F])).l.map((t) => t.name), ['post 8', 'post 7', 'post 6']);

  // ---------- start-up lists, bots, channel limit ----------
  await h.as(u.mem);
  const vis = await h.q(`select kind from visible_server_channels_fast(array[$1]::uuid[])`, [sid]);
  h.eq('start-up list has no threads', vis.some((c) => c.kind === 'thread'), false);
  h.eq('start-up list has the forum', vis.some((c) => c.kind === 'forum'), true);
  await h.admin();
  const bot = await h.signup('bot@test.dev', 'robot');
  await h.q(`insert into bot_servers values ($1, $2)`, [bot, sid]);
  const bv = await h.q(`select type from bot_visible_channels($1, $2)`, [bot, sid]);
  h.eq('bots see text and voice only', bv.every((c) => c.type === 'text' || c.type === 'voice'), true);
  h.eq('bot can\'t read a private channel\'s thread', (await h.one(`select bot_channel_visible($1, $2) ok`, [bot, pth])).ok, false);
  h.eq('threads don\'t count toward 100 channels', (await h.one(`select pg_get_functiondef('public.create_channel(uuid,text,text)'::regprocedure) like '%kind <> ''thread''%' ok`)).ok, true);
  // Deleting the parent takes its threads along.
  await h.q(`delete from channels where id = $1`, [F]);
  h.eq('threads go with their forum', (await h.one(`select count(*)::int n from channels where parent_id = $1`, [F])).n, 0);
}
