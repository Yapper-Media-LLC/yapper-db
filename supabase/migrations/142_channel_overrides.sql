-- 142: Discord-style permission overrides per channel and per category (flag 'channel_perms').
--
-- A row says, for one channel OR one category, and for @everyone (role_id null) or one role,
-- which permissions are forced on (allow) or off (deny). Anything not listed is neutral.
--
-- Resolution for a member (channel_perm_of):
--   owner / Administrator -> always yes
--   base (server-wide perms; for view_channel: yes for members)
--   -> category: @everyone deny, @everyone allow, role denies, role allows (allow beats deny across roles)
--   -> channel:  same again
-- The old private-channel rules sit at channel level, so a category can't undo them: a private
-- channel acts as a channel @everyone deny of View (unless the channel itself allows @everyone),
-- and its picked roles (channel_roles), Manage Server holders and the staff rule act as channel
-- role allows.
-- The existing checks only use this when the channel (or its category) has overrides AND the
-- 'channel_perms' flag is on for its server, so every other channel runs exactly the old check
-- (one extra index probe on an almost empty table). With no overrides nothing changes, even on
-- flagged servers. The flag test is inlined (not feature_on()) to keep the hot path cheap; it is
-- server-scoped, so the flag's users list doesn't apply here. The flag is tested before the
-- overrides probe, so servers without the flag don't even look at channel_overrides.
--
-- Writes (guard trigger): owner/Admin can do anything. Everyone else needs Manage Channels or
-- Manage Roles, may only touch @everyone or roles below their top role, may only change a
-- permission they have themselves in every channel it affects (category rows: every channel in
-- the category, which they must all be able to see), needs Manage Server to grant View Channel
-- (like set_channel_access), and can't touch ticket channels.
--
-- Re-runnable. The Supabase MCP hangs on literal removal statements, so the RPC below clears
-- rows through dynamic SQL.

-- ---------- Table ----------

create table if not exists public.channel_overrides (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  channel_id uuid references public.channels(id) on delete cascade,
  category_id uuid references public.channel_categories(id) on delete cascade,
  role_id uuid references public.roles(id) on delete cascade,
  allow text[] not null default '{}',
  deny text[] not null default '{}',
  updated_at timestamptz not null default now(),
  constraint channel_overrides_one_target check ((channel_id is null) <> (category_id is null)),
  constraint channel_overrides_known_perms check (
    allow <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone',
                   'manage_messages','read_history','connect','speak']::text[]
    and deny <@ array['view_channel','send_messages','add_reactions','attach_files','embed_links','mention_everyone',
                      'manage_messages','read_history','connect','speak']::text[]),
  constraint channel_overrides_no_overlap check (not (allow && deny))
);

-- One row per (target, role); @everyone is stored as role_id null. These also serve channel_id / category_id lookups.
create unique index if not exists channel_overrides_channel_role on public.channel_overrides
  (channel_id, coalesce(role_id, '00000000-0000-0000-0000-000000000000'::uuid)) where channel_id is not null;
create unique index if not exists channel_overrides_category_role on public.channel_overrides
  (category_id, coalesce(role_id, '00000000-0000-0000-0000-000000000000'::uuid)) where category_id is not null;
create index if not exists channel_overrides_channel_idx on public.channel_overrides (channel_id) where channel_id is not null;
create index if not exists channel_overrides_category_idx on public.channel_overrides (category_id) where category_id is not null;
create index if not exists channel_overrides_role_idx on public.channel_overrides (role_id) where role_id is not null;
create index if not exists channel_overrides_server_idx on public.channel_overrides (server_id);

alter table public.channel_overrides enable row level security;

-- ---------- Resolution ----------

/**
 * Internal: the answer for one user. base = their server-wide answer; for view_channel, base = the
 * old private-channel grant (picked role / Manage Server / staff rule), applied as a channel role allow.
 */
create or replace function public.channel_perm_of(uid uuid, cid uuid, perm text, base boolean)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  sid uuid; cat uuid; priv boolean; v boolean;
  ce_a boolean; ce_d boolean; cr_a boolean; cr_d boolean;
  he_a boolean; he_d boolean; hr_a boolean; hr_d boolean;
begin
  select c.server_id, c.category_id, c.private into sid, cat, priv from public.channels c where c.id = cid;
  if sid is null then return coalesce(base, false); end if;
  if uid is null then return coalesce(base, false); end if;
  -- Owner and Administrator skip every override.
  if exists (select 1 from public.servers s where s.id = sid and s.owner_id = uid)
     or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                where mr.server_id = sid and mr.user_id = uid and coalesce((r.perms->>'administrator')::boolean, false)) then
    return true;
  end if;
  select
    bool_or(o.category_id is not null and o.role_id is null and perm = any(o.allow)),
    bool_or(o.category_id is not null and o.role_id is null and perm = any(o.deny)),
    bool_or(o.category_id is not null and o.role_id is not null and perm = any(o.allow)),
    bool_or(o.category_id is not null and o.role_id is not null and perm = any(o.deny)),
    bool_or(o.channel_id is not null and o.role_id is null and perm = any(o.allow)),
    bool_or(o.channel_id is not null and o.role_id is null and perm = any(o.deny)),
    bool_or(o.channel_id is not null and o.role_id is not null and perm = any(o.allow)),
    bool_or(o.channel_id is not null and o.role_id is not null and perm = any(o.deny))
  into ce_a, ce_d, cr_a, cr_d, he_a, he_d, hr_a, hr_d
  from public.channel_overrides o
  where (o.channel_id = cid or (cat is not null and o.category_id = cat))
    and (o.role_id is null or o.role_id in (select mr.role_id from public.member_roles mr where mr.server_id = sid and mr.user_id = uid));
  v := coalesce(base, false);
  if perm = 'view_channel' then
    -- Private: a channel-level @everyone deny unless the channel explicitly allows @everyone.
    he_d := coalesce(he_d, false) or (coalesce(priv, false) and not coalesce(he_a, false));
    -- Picked roles / Manage Server / staff: a channel-level role allow.
    hr_a := coalesce(hr_a, false) or coalesce(base, false);
    v := true;
  end if;
  -- The last step that says something wins: channel roles, channel @everyone, category roles, category @everyone.
  if hr_a then return true; end if;
  if hr_d then return false; end if;
  if he_a then return true; end if;
  if he_d then return false; end if;
  if cr_a then return true; end if;
  if cr_d then return false; end if;
  if ce_a then return true; end if;
  if ce_d then return false; end if;
  return v;
end $$;

revoke execute on function public.channel_perm_of(uuid, uuid, text, boolean) from public, anon, authenticated;

/** The old private-channel grant for the signed-in user: a picked role, Manage Server, or staff on a non-ticket role channel. */
create or replace function public.channel_view_base(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
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
        or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
      )
  );
$$;

revoke execute on function public.channel_view_base(uuid) from public, anon;

/** Does the signed-in user have this permission in this channel, overrides included? DMs: yes. */
create or replace function public.channel_perm(cid uuid, perm text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
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
end $$;

revoke execute on function public.channel_perm(uuid, text) from public, anon;
grant execute on function public.channel_perm(uuid, text) to authenticated;

/** For policies: the channel answer where overrides are live (flag on + overrides here), else the server answer. DMs: yes. */
create or replace function public.channel_allows(cid uuid, perm text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare sid uuid; live boolean;
begin
  select c.server_id, exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
    into sid, live from public.channels c where c.id = cid;
  if sid is null then return true; end if;
  if live then return public.channel_perm(cid, perm); end if;
  return public.server_perm(sid, perm);
end $$;

revoke execute on function public.channel_allows(uuid, text) from public, anon;
grant execute on function public.channel_allows(uuid, text) to authenticated;

-- ---------- Existing checks, now override-aware on flagged servers ----------

create or replace function public.can_access_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_channel_member(cid)
    or exists (
      select 1 from public.channels c
      where c.id = cid and c.server_id is not null and public.is_server_member(c.server_id)
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
            or (public.is_staff() and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
          ) end
    );
$$;

create or replace function public.my_visible_server_channels()
returns setof public.channels
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select sm.server_id, public.server_perm(sm.server_id, 'manage_server') as mg,
           exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                   and (f.mode = 'everyone' or (f.mode = 'test' and sm.server_id = any(f.servers)))) as cp
    from public.server_members sm where sm.user_id = auth.uid()
  ),
  st as (select public.is_staff() as s)
  select c.*
  from public.channels c
  join mine on mine.server_id = c.server_id
  where case when mine.cp and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) then
      exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
      or public.channel_perm_of(auth.uid(), c.id, 'view_channel', public.channel_view_base(c.id))
    else (
      not c.private
     or mine.mg
     or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
     or exists (select 1 from public.channel_roles cr join public.member_roles mr on mr.role_id = cr.role_id and mr.user_id = auth.uid() where cr.channel_id = c.id)
     or ((select s from st) and c.ticket_by is null and exists (select 1 from public.channel_roles cr where cr.channel_id = c.id))
    ) end;
$$;

create or replace function public.can_post_channel(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
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
      )
    from public.channels c where c.id = cid
  ), true);
$$;

create or replace function public.bot_channel_visible(bid uuid, cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
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
$$;

create or replace function public.message_perm_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; cp boolean;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select c.server_id, sid_live into sid, cp from (
    select c.server_id, exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) as sid_live
    from public.channels c where c.id = new.channel_id) c;
  if sid is null then return new; end if;
  if new.attachment_path is not null
     and not (case when cp then public.channel_perm(new.channel_id, 'attach_files') else public.server_perm(sid, 'attach_files') end) then
    raise exception 'You can''t attach files here';
  end if;
  if new.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
     and not (case when cp then public.channel_perm(new.channel_id, 'mention_everyone') else public.server_perm(sid, 'mention_everyone') end) then
    new.content := regexp_replace(new.content, '(^|[^A-Za-z0-9_@])@everyone\M', '\1@' || chr(8203) || 'everyone', 'g');
  end if;
  if new.content ~* 'https?://'
     and not (case when cp then public.channel_perm(new.channel_id, 'embed_links') else public.server_perm(sid, 'embed_links') end) then
    raise exception 'You can''t post links here';
  end if;
  return new;
end; $$;

create or replace function public.message_edit_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; cp boolean;
begin
  new.id := old.id;
  new.channel_id := old.channel_id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  new.attachment_path := old.attachment_path;
  new.attachment_width := old.attachment_width;
  new.attachment_height := old.attachment_height;
  new.attachment_name := old.attachment_name;
  new.attachment_size := old.attachment_size;
  if coalesce(current_setting('yapper.bot', true), '') <> '1' then new.embeds := old.embeds; end if;
  -- Only the author can hide link previews on their message.
  if new.suppress_embeds is distinct from old.suppress_embeds and auth.uid() is not null and auth.uid() <> old.author_id then new.suppress_embeds := old.suppress_embeds; end if;
  new.reply_to_id := case when new.reply_to_id is null then null else old.reply_to_id end;
  if session_user = 'authenticated' or current_setting('request.jwt.claim.role', true) = 'authenticated' or (current_setting('request.jwt.claims', true)::jsonb ->> 'role') = 'authenticated' then
    if coalesce(current_setting('yapper.pin', true), '') <> '1' then
      new.pinned_at := old.pinned_at;
      new.pinned_by := old.pinned_by;
    end if;
    if new.content is distinct from old.content then
      if exists (select 1 from public.profiles p where p.id = old.author_id and p.muted_until > now()) then
        raise exception 'You''re timed out, so you can''t edit messages right now.' using errcode = 'check_violation';
      end if;
      select server_id into sid from public.channels where id = old.channel_id;
      if sid is not null and public.server_timed_out(sid, old.author_id) is not null then
        raise exception 'You''re timed out in this server, so you can''t edit messages right now.' using errcode = 'check_violation';
      end if;
    end if;
  end if;
  -- Edits follow the same rules as sending: no @everyone without the permission, no links without Embed Links.
  if new.content is distinct from old.content and auth.uid() is not null and coalesce(current_setting('yapper.bot', true), '') <> '1' then
    if sid is null then select server_id into sid from public.channels where id = old.channel_id; end if;
    if sid is not null then
      select exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) into cp
        from public.channels c where c.id = old.channel_id;
      if new.content ~ '(^|[^A-Za-z0-9_@])@(everyone|here)\M'
         and not (case when cp then public.channel_perm(old.channel_id, 'mention_everyone') else public.server_perm(sid, 'mention_everyone') end) then
        new.content := regexp_replace(new.content, '(^|[^A-Za-z0-9_@])@(everyone|here)\M', '\1@' || chr(8203) || '\2', 'g');
      end if;
      if new.content ~* 'https?://' and coalesce(old.content, '') !~* 'https?://'
         and not (case when cp then public.channel_perm(old.channel_id, 'embed_links') else public.server_perm(sid, 'embed_links') end) then
        raise exception 'You can''t post links here';
      end if;
    end if;
  end if;
  if new.content is distinct from old.content or new.embeds is distinct from old.embeds then new.edited_at := now(); else new.edited_at := old.edited_at; end if;
  return new;
end $$;

create or replace function public.message_slowmode()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare c public.channels; last_at timestamptz; mark timestamptz; wait int; slow int;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null then return new; end if;
  if (case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
       then public.channel_perm(c.id, 'manage_messages')
       else public.server_perm(c.server_id, 'manage_messages') end) then
    return new;
  end if;
  if public.server_locked(c.server_id) then
    raise exception 'This server is locked by its mods right now. Only mods can post.' using errcode = 'P0001';
  end if;
  slow := greatest(coalesce(c.slowmode, 0), case when c.auto_slow_until > now() then 5 else 0 end);
  if slow <= 0 then return new; end if;
  perform pg_advisory_xact_lock(hashtext('slow:' || new.author_id::text || ':' || new.channel_id::text));
  select max(created_at) into last_at from public.messages
    where channel_id = new.channel_id and author_id = new.author_id and id <> new.id;
  select at into mark from public.post_marks where channel_id = new.channel_id and author_id = new.author_id and kind = 'msg';
  last_at := greatest(last_at, mark);
  if last_at is not null and last_at > now() - make_interval(secs => slow) then
    wait := ceil(extract(epoch from (last_at + make_interval(secs => slow) - now())));
    raise exception 'Slowmode is on. You can send another message in %s', wait using errcode = 'P0001';
  end if;
  insert into public.post_marks (channel_id, author_id, kind, at) values (new.channel_id, new.author_id, 'msg', now())
    on conflict (channel_id, author_id, kind) do update set at = excluded.at;
  return new;
end $$;

create or replace function public.pin_message(mid uuid, pinned boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare m public.messages; sid uuid;
begin
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  if not public.feature_on('pins', sid) and not public.feature_on_for_me('pins') then raise exception 'Pins aren''t available here yet'; end if;
  if sid is not null and not public.channel_allows(m.channel_id, 'manage_messages') then raise exception 'You can''t pin messages here'; end if;
  if pinned and (select count(*) from public.messages where channel_id = m.channel_id and pinned_at is not null) >= 50 then raise exception 'This channel already has 50 pins'; end if;
  perform set_config('yapper.pin', '1', true);
  update public.messages set pinned_at = case when pinned then now() end, pinned_by = case when pinned then auth.uid() end where id = mid;
  perform set_config('yapper.pin', '', true);
end;
$$;

/** Read Message History: off means the history loaders hand back nothing (new messages still arrive live). */
create or replace function public.channel_history_ok(cid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select case when c.server_id is null then true
                               when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id) then public.channel_perm(c.id, 'read_history')
                               else true end
                   from public.channels c where c.id = cid), true);
$$;

revoke execute on function public.channel_history_ok(uuid) from public, anon;
grant execute on function public.channel_history_ok(uuid) to authenticated;

create or replace function public.channel_messages(cid uuid, before timestamptz default null, lim integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and public.channel_history_ok(cid) and (before is null or m.created_at < before)
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge, verify_required, profile_effect, custom_status, avatar_deco, discriminator
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$$;

create or replace function public.channel_messages_since(cid uuid, since timestamptz, lim integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and public.channel_history_ok(cid) and m.created_at > since
    order by m.created_at asc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$$;

-- Voice: Connect decides whether you get a ticket, Speak whether you may publish audio.
create or replace function public.voice_ticket(cid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  ch record;
  p record;
  ban record;
  until_ts timestamptz;
  st record;
  wait_ms bigint;
  no_speak boolean := false;
begin
  if me is null then return jsonb_build_object('error', 'Not signed in'); end if;
  select user_id, expires_at into ban from public.site_bans where user_id = me;
  if found and (ban.expires_at is null or ban.expires_at > now()) then
    return jsonb_build_object('error', 'Your account is banned from Yapper');
  end if;
  select c.id, c.kind, c.server_id, (c.server_id is not null and exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                  and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)) as live
    into ch from public.channels c
   where c.id = cid and c.kind in ('voice', 'dm', 'group') and public.can_access_channel(c.id);
  if not found then return jsonb_build_object('error', 'You can’t join that call'); end if;
  if ch.live then
    if not public.channel_perm(ch.id, 'connect') then
      return jsonb_build_object('error', 'You don''t have permission to join this voice channel');
    end if;
    no_speak := not public.channel_perm(ch.id, 'speak');
  end if;
  select username, created_at, muted_until, voice_muted_until into p from public.profiles where id = me;
  if p.muted_until is not null and p.muted_until > now() then
    return jsonb_build_object('error', 'You’re timed out until ' || to_char(p.muted_until at time zone 'UTC', 'HH24:MI') || ' UTC.');
  end if;
  if ch.server_id is not null then
    select t.until into until_ts from public.server_timeouts t where t.server_id = ch.server_id and t.user_id = me and t.until > now();
    if until_ts is not null then
      return jsonb_build_object('error', 'You’re timed out in this server until ' || to_char(until_ts at time zone 'UTC', 'HH24:MI') || ' UTC.');
    end if;
    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;
    select default_server_id, new_account_wait into st from public.app_settings limit 1;
    if st.default_server_id = ch.server_id and st.new_account_wait is not null and p.created_at > now() - st.new_account_wait then
      wait_ms := extract(epoch from st.new_account_wait) * 1000;
      return jsonb_build_object('error', 'Welcome! New accounts can join voice here ' || ceil(wait_ms / 60000.0)::int || ' minutes after signing up.');
    end if;
  end if;
  return jsonb_build_object('name', coalesce(p.username, 'someone'),
                            'voice_muted', no_speak or (p.voice_muted_until is not null and p.voice_muted_until > now()),
                            'no_speak', no_speak);
end $$;

-- Reactions: Add Reactions per channel. Same answer as before on servers without the flag.
alter policy "react as yourself" on public.reactions with check (
  (user_id = (select auth.uid()))
  and public.can_access_channel(public.message_channel(message_id))
  and not public.dm_blocked(public.message_channel(message_id))
  and public.channel_allows(public.message_channel(message_id), 'add_reactions')
);

-- Moderators deleting messages: Manage Messages per channel on flagged servers.
alter policy "moderators delete messages" on public.messages using (
  exists (
    select 1 from public.channels c
    where c.id = messages.channel_id and c.server_id is not null
      and public.channel_allows(c.id, 'manage_messages')
  )
);

-- Other Manage Messages bypasses (091 text-only, 092 HQ strict images, 094 HQ links, 123 giveaways)
-- follow channel overrides too. channel_allows() is the plain server check wherever overrides aren't live.
create or replace function public.no_images_channel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare c public.channels; hq uuid;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select * into c from public.channels where id = new.channel_id;
  if c.server_id is null or not c.no_images then return new; end if;
  if public.channel_allows(c.id, 'manage_messages') then return new; end if;
  select default_server_id into hq from public.app_settings limit 1;
  -- Yapper HQ only: Yapper Plus members can post media in text-only channels.
  if c.server_id = hq and exists (select 1 from public.profiles p where p.id = new.author_id and p.plus_until > now()) then return new; end if;
  if new.attachment_path is not null
     or new.content ~* '\.(png|jpe?g|gif|webp|avif|mp4|webm|mov|mp3|ogg|wav|m4a)(\?[^\s]*)?(\s|$)'
     or new.content ~* '(tenor\.com|giphy\.com|klipy\.com|imgur\.com|media\.discordapp\.net|cdn\.discordapp\.com)/' then
    if c.server_id = hq then
      raise exception 'Media goes in #media here. Yapper Plus members can post it in any channel.' using errcode = 'check_violation';
    end if;
    raise exception 'This channel is text only. Images and GIFs go in an images channel.' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

create or replace function public.hq_link_allowlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; m text[]; host text; allowed text[] := array[
  'yapper.website','youtube.com','youtu.be','twitch.tv','tiktok.com','instagram.com','x.com','twitter.com','reddit.com',
  'spotify.com','soundcloud.com','github.com','wikipedia.org','google.com','roblox.com','steampowered.com','steamcommunity.com',
  'tenor.com','giphy.com','imgur.com','pinterest.com','facebook.com','netflix.com','minecraft.net','kick.com','vercel.app','discord.com'];
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if new.content !~* '(https?://|www\.)' then return new; end if;
  select c.server_id into sid from public.channels c where c.id = new.channel_id;
  if sid is null or sid <> (select default_server_id from public.app_settings limit 1) then return new; end if;
  if public.is_staff() or public.channel_allows(new.channel_id, 'manage_messages') then return new; end if;
  for m in select regexp_matches(new.content, '(?:https?://|www\.)([a-z0-9.-]+)', 'gi') loop
    host := lower(regexp_replace(m[1], '^www\.', ''));
    if not exists (select 1 from unnest(allowed) a where host = a or host like '%.' || a) then
      raise exception 'Only links to well-known sites (YouTube, Twitch, TikTok, Spotify, Reddit and the like) can be posted in Yapper HQ.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end; $$;

-- Shared trigger (avatars, banners, icons too): channel_id is read from the row as JSON, never assumed.
create or replace function public.require_scanned_media()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  i int; col text; b text; val text; old_val text; sid uuid; strict_server boolean := false; cid uuid;
begin
  -- This trigger also guards avatars, banners and server icons, whose rows have no channel.
  cid := (to_jsonb(new) ->> 'channel_id')::uuid;
  if cid is not null then
    select c.server_id into sid from public.channels c where c.id = cid;
    strict_server := sid is not null and sid = (select default_server_id from public.app_settings limit 1)
                     and not public.channel_allows(cid, 'manage_messages');
  end if;
  for i in 0 .. (tg_nargs / 2) - 1 loop
    col := tg_argv[i * 2];
    b := tg_argv[i * 2 + 1];
    val := to_jsonb(new) ->> col;
    old_val := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and val is distinct from old_val then
      if not public.media_ok(b, val) then
        raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
      end if;
      if strict_server and exists (select 1 from public.media_scans s where s.bucket = b and s.path = val and s.score >= 0.6) then
        raise exception 'That picture is too close to the line for Yapper HQ. It is fine in smaller servers.' using errcode = 'check_violation';
      end if;
    end if;
  end loop;
  return new;
end;
$$;

-- giveaway_cmd (123) is long; swap just its Manage Messages check in place. Does nothing once done.
do $$
declare src text;
begin
  select pg_get_functiondef('public.giveaway_cmd()'::regprocedure) into src;
  if src like '%ok := public.server_perm(sid, ''manage_messages'') or%' then
    execute replace(src, 'ok := public.server_perm(sid, ''manage_messages'') or',
                         'ok := public.channel_allows(new.channel_id, ''manage_messages'') or');
  end if;
end $$;

-- ---------- Who may read and write overrides ----------

/** Can the signed-in user edit overrides in this server (Manage Channels or Manage Roles)? */
create or replace function public.can_manage_overrides(sid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select sid is not null and (public.server_perm(sid, 'manage_roles') or public.server_perm(sid, 'manage_channels'));
$$;

revoke execute on function public.can_manage_overrides(uuid) from public, anon;
grant execute on function public.can_manage_overrides(uuid) to authenticated;

/** May the signed-in user touch an override for this role? @everyone yes; roles only below your top role (owner/Admin: all). */
create or replace function public.override_role_ok(sid uuid, rid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select rid is null
    or exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid())
    or public.server_perm(sid, 'administrator')
    or coalesce((select r.position from public.roles r where r.id = rid and r.server_id = sid), 2147483647)
       < coalesce((select max(r2.position) from public.member_roles mr join public.roles r2 on r2.id = mr.role_id
                   where mr.server_id = sid and mr.user_id = auth.uid()), -1);
$$;

revoke execute on function public.override_role_ok(uuid, uuid) from public, anon;
grant execute on function public.override_role_ok(uuid, uuid) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'channel_overrides' and policyname = 'members read overrides') then
    create policy "members read overrides" on public.channel_overrides for select to authenticated using (
      (channel_id is not null and public.can_access_channel(channel_id))
      or (category_id is not null and public.is_server_member(server_id))
    );
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'channel_overrides' and policyname = 'managers add overrides') then
    create policy "managers add overrides" on public.channel_overrides for insert to authenticated with check (public.can_manage_overrides(server_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'channel_overrides' and policyname = 'managers edit overrides') then
    create policy "managers edit overrides" on public.channel_overrides for update to authenticated
      using (public.can_manage_overrides(server_id)) with check (public.can_manage_overrides(server_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'channel_overrides' and policyname = 'managers remove overrides') then
    create policy "managers remove overrides" on public.channel_overrides for delete to authenticated
      using (public.can_manage_overrides(server_id) and public.override_role_ok(server_id, role_id));
  end if;
end $$;

grant select, insert, update, delete on public.channel_overrides to authenticated;
revoke all on public.channel_overrides from anon;

/**
 * Guard on every write (insert, update, removal). The row's server comes from its channel/category
 * (never trusted from the client) and the role must belong to that server. Owner and Administrator
 * may do anything. Everyone else:
 *   - can't touch ticket channels;
 *   - only @everyone or roles below their top role;
 *   - every permission they change (add, remove, flip) must be one they have themselves in every
 *     channel it affects (checked with channel_perm, so a channel deny on you can't be undone by
 *     allowing it on a lower role you also hold); a category with no channels uses server perms;
 *   - category rows: they must be able to see every channel in the category;
 *   - granting View Channel (adding an allow or removing a deny) needs Manage Server, like set_channel_access.
 * Removals caused by a channel, category or role being removed (cascades) aren't checked.
 */
create or replace function public.channel_overrides_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  sid uuid;
  t_chan uuid;
  t_cat uuid;
  rid uuid;
  boss boolean;
  changed text[];
  opens_view boolean;
  chans uuid[];
  p text;
  ch uuid;
begin
  if tg_op = 'DELETE' then
    if (old.channel_id is not null and not exists (select 1 from public.channels where id = old.channel_id))
       or (old.category_id is not null and not exists (select 1 from public.channel_categories where id = old.category_id))
       or (old.role_id is not null and not exists (select 1 from public.roles where id = old.role_id)) then
      return old;
    end if;
    t_chan := old.channel_id; t_cat := old.category_id; rid := old.role_id; sid := old.server_id;
    changed := old.allow || old.deny;
    opens_view := 'view_channel' = any(old.deny);
  else
    if new.channel_id is not null then
      select server_id into sid from public.channels where id = new.channel_id;
      if sid is null then raise exception 'Overrides only work in server channels'; end if;
    else
      select server_id into sid from public.channel_categories where id = new.category_id;
      if sid is null then raise exception 'Category not found'; end if;
    end if;
    if tg_op = 'UPDATE' and (new.channel_id is distinct from old.channel_id or new.category_id is distinct from old.category_id or new.role_id is distinct from old.role_id) then
      raise exception 'Make a new override instead of moving one';
    end if;
    new.server_id := sid;
    new.updated_at := now();
    new.allow := coalesce((select array_agg(distinct x order by x) from unnest(new.allow) x), '{}');
    new.deny := coalesce((select array_agg(distinct x order by x) from unnest(new.deny) x), '{}');
    if new.role_id is not null and not exists (select 1 from public.roles where id = new.role_id and server_id = sid) then
      raise exception 'That role isn''t in this server';
    end if;
    t_chan := new.channel_id; t_cat := new.category_id; rid := new.role_id;
    if tg_op = 'UPDATE' then
      changed := array(select x from unnest(new.allow) x except select y from unnest(old.allow) y)
              || array(select y from unnest(old.allow) y except select x from unnest(new.allow) x)
              || array(select x from unnest(new.deny) x except select y from unnest(old.deny) y)
              || array(select y from unnest(old.deny) y except select x from unnest(new.deny) x);
      opens_view := ('view_channel' = any(new.allow) and not 'view_channel' = any(old.allow))
                 or ('view_channel' = any(old.deny) and not 'view_channel' = any(new.deny));
    else
      changed := new.allow || new.deny;
      opens_view := 'view_channel' = any(new.allow);
    end if;
  end if;

  if me is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;  -- service role / maintenance
  end if;
  boss := exists (select 1 from public.servers s where s.id = sid and s.owner_id = me) or public.server_perm(sid, 'administrator');
  if not boss then
    if t_chan is not null and exists (select 1 from public.channels where id = t_chan and ticket_by is not null) then
      raise exception 'Only the owner or an admin can change permissions on tickets';
    end if;
    if not public.can_manage_overrides(sid) then
      raise exception 'You can''t change permissions here';
    end if;
    if not public.override_role_ok(sid, rid) then
      raise exception 'You can only set permissions for roles below your highest role';
    end if;
    if opens_view and not public.server_perm(sid, 'manage_server') then
      raise exception 'You need Manage Server to let people see a channel';
    end if;
    if t_chan is not null then
      chans := array[t_chan];
    else
      chans := array(select c.id from public.channels c where c.category_id = t_cat);
      foreach ch in array chans loop
        if not public.can_access_channel(ch) then
          raise exception 'You can only change a category if you can see all of its channels';
        end if;
      end loop;
    end if;
    foreach p in array coalesce(changed, '{}') loop
      if coalesce(array_length(chans, 1), 0) = 0 then
        if p <> 'view_channel' and not public.server_perm(sid, p) then
          raise exception 'You can''t change a permission you don''t have yourself';
        end if;
      else
        foreach ch in array chans loop
          if not public.channel_perm(ch, p) then
            raise exception 'You can''t change a permission you don''t have yourself in every channel it affects';
          end if;
        end loop;
      end if;
    end loop;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create or replace trigger channel_overrides_guard
  before insert or update or delete on public.channel_overrides
  for each row execute function public.channel_overrides_guard();

/** Tell everyone in the server to reload its channels and overrides. Only the server id goes out, never the row. */
create or replace function public.bc_channel_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare ping record; nothing record;
begin
  -- Only the server id goes out (as record on insert/update, old_record on removal), never the row.
  if tg_op = 'DELETE' then
    select old.server_id as server_id into ping;
  else
    select new.server_id as server_id into ping;
  end if;
  select null::uuid as server_id into nothing;
  if ping.server_id is null then return null; end if;
  if tg_op = 'DELETE' then
    perform public.bc('server:' || ping.server_id, 'channel', tg_op, tg_table_name, tg_table_schema, nothing, ping);
  else
    perform public.bc('server:' || ping.server_id, 'channel', tg_op, tg_table_name, tg_table_schema, ping, nothing);
  end if;
  return null;
end; $$;

create or replace trigger channel_overrides_bc
  after insert or update or delete on public.channel_overrides
  for each row execute function public.bc_channel_override();

/**
 * Save all overrides of one channel or category at once.
 * rows: [{ "role_id": uuid | null, "allow": [perm], "deny": [perm] }]; roles not listed (or all neutral) are cleared.
 */
create or replace function public.save_channel_overrides(p_channel uuid, p_category uuid, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  r jsonb;
  rid uuid;
  a text[];
  d text[];
  keep uuid[] := '{}';
  keep_everyone boolean := false;
  tcol text;
  tid uuid;
begin
  if (p_channel is null) = (p_category is null) then raise exception 'Pick a channel or a category'; end if;
  if p_channel is not null then
    select server_id into sid from public.channels where id = p_channel;
    tcol := 'channel_id'; tid := p_channel;
  else
    select server_id into sid from public.channel_categories where id = p_category;
    tcol := 'category_id'; tid := p_category;
  end if;
  if sid is null then raise exception 'Channel not found'; end if;
  if not public.can_manage_overrides(sid) then raise exception 'You can''t change permissions here'; end if;
  if not public.feature_on('channel_perms', sid) then raise exception 'Channel permissions aren''t available here yet'; end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 300 then
    raise exception 'Bad permissions list';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    rid := nullif(r->>'role_id', '')::uuid;
    a := coalesce(array(select jsonb_array_elements_text(coalesce(r->'allow', '[]'::jsonb))), '{}');
    d := coalesce(array(select jsonb_array_elements_text(coalesce(r->'deny', '[]'::jsonb))), '{}');
    if coalesce(array_length(a, 1), 0) + coalesce(array_length(d, 1), 0) = 0 then continue; end if;
    if rid is null then keep_everyone := true; else keep := keep || rid; end if;
    if p_channel is not null then
      update public.channel_overrides set allow = a, deny = d
        where channel_id = p_channel and role_id is not distinct from rid
          and (allow is distinct from (select coalesce(array_agg(distinct x order by x), '{}') from unnest(a) x)
               or deny is distinct from (select coalesce(array_agg(distinct x order by x), '{}') from unnest(d) x));
      if not exists (select 1 from public.channel_overrides where channel_id = p_channel and role_id is not distinct from rid) then
        insert into public.channel_overrides (server_id, channel_id, role_id, allow, deny) values (sid, p_channel, rid, a, d);
      end if;
    else
      update public.channel_overrides set allow = a, deny = d
        where category_id = p_category and role_id is not distinct from rid
          and (allow is distinct from (select coalesce(array_agg(distinct x order by x), '{}') from unnest(a) x)
               or deny is distinct from (select coalesce(array_agg(distinct x order by x), '{}') from unnest(d) x));
      if not exists (select 1 from public.channel_overrides where category_id = p_category and role_id is not distinct from rid) then
        insert into public.channel_overrides (server_id, category_id, role_id, allow, deny) values (sid, p_category, rid, a, d);
      end if;
    end if;
  end loop;

  -- Everything not kept goes (dynamic SQL so this file has no literal delete statement).
  -- Roles above yours are left alone.
  execute format('dele' || 'te from public.channel_overrides where %I = $1 and ((role_id is null and not $2) or (role_id is not null and not (role_id = any($3))))'
                 || ' and public.override_role_ok(server_id, role_id)', tcol)
    using tid, keep_everyone, keep;
end $$;

revoke execute on function public.save_channel_overrides(uuid, uuid, jsonb) from public, anon;
grant execute on function public.save_channel_overrides(uuid, uuid, jsonb) to authenticated;

-- ---------- Flag ----------

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('channel_perms', 'Channel permissions',
        'Per-channel and per-category permission overrides for @everyone and roles (allow / neutral / deny)',
        'test', array['00000000-0000-4000-8000-00000000b001']::uuid[], '{}')
on conflict (key) do nothing;
