-- ============================================================
-- Mod Center: warnings, staff notes, user case files, bulk cleanup, profile reset.
-- Everything a moderator does is still checked by mod_guard() (rate limits, can't touch
-- staff) and written to mod_log.
-- ============================================================

-- Warnings: a formal "knock it off" the person sees once and acknowledges.
create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  by uuid references public.profiles (id) on delete set null,
  reason text not null check (char_length(reason) between 3 and 500),
  created_at timestamptz not null default now(),
  seen_at timestamptz
);
create index if not exists user_warnings_user_idx on public.user_warnings (user_id, created_at desc);
alter table public.user_warnings enable row level security;
drop policy if exists "own warnings; staff see all" on public.user_warnings;
create policy "own warnings; staff see all" on public.user_warnings for select to authenticated
  using (user_id = auth.uid() or public.is_staff());

-- Staff notes about a person (never shown to them).
create table if not exists public.mod_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  author uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists mod_notes_user_idx on public.mod_notes (user_id, created_at desc);
alter table public.mod_notes enable row level security;
drop policy if exists "staff read notes" on public.mod_notes;
create policy "staff read notes" on public.mod_notes for select to authenticated using (public.is_staff());
drop policy if exists "staff add notes" on public.mod_notes;
create policy "staff add notes" on public.mod_notes for insert to authenticated with check (public.is_staff() and author = auth.uid());
drop policy if exists "remove own notes" on public.mod_notes;
create policy "remove own notes" on public.mod_notes for delete to authenticated using (author = auth.uid() or public.is_site_admin());

-- Moderators see the whole log (what other staff did to someone matters when deciding).
alter policy "admins read the mod log" on public.mod_log using (public.is_staff() or actor = auth.uid());

-- For case files and bulk cleanup.
create index if not exists messages_author_created_idx on public.messages (author_id, created_at desc);

create or replace function public.mod_warn(uid uuid, why text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(trim(coalesce(why, ''))) < 3 then raise exception 'Say what the warning is for'; end if;
  if uid = auth.uid() then raise exception 'Not yourself'; end if;
  perform public.mod_guard('warn', uid, why);
  insert into public.user_warnings (user_id, by, reason) values (uid, auth.uid(), left(trim(why), 500));
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'warn', uid, left(trim(why), 300));
  update public.reports set status = 'actioned', resolved_by = auth.uid(), resolved_at = now() where target_id = uid and status = 'open';
end;
$$;

create or replace function public.ack_warning(wid uuid)
returns void language sql security definer set search_path = public as $$
  update public.user_warnings set seen_at = now() where id = wid and user_id = auth.uid() and seen_at is null;
$$;

-- The warned person hears about it live.
create or replace function public.bc_warning()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('user:' || new.user_id, 'warning', tg_op, tg_table_name, tg_table_schema, new, null);
  return null;
end;
$$;
drop trigger if exists user_warnings_bc on public.user_warnings;
create trigger user_warnings_bc after insert on public.user_warnings for each row execute function public.bc_warning();

-- Everything staff need about one person, in one call.
create or replace function public.mod_user_case(uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select jsonb_build_object(
    'joined', p.created_at,
    'muted_until', p.muted_until,
    'muted_reason', p.muted_reason,
    'voice_muted_until', p.voice_muted_until,
    'ban', (select to_jsonb(b) from public.site_bans b where b.user_id = uid),
    'is_admin', exists (select 1 from public.site_admins where user_id = uid),
    'is_mod', exists (select 1 from public.site_moderators where user_id = uid and suspended_at is null),
    'servers', (select count(*) from public.server_members where user_id = uid),
    'messages_7d', (select count(*) from public.messages where author_id = uid and created_at > now() - interval '7 days'),
    'reports_total', (select count(*) from public.reports where target_id = uid),
    'reports_open', (select count(*) from public.reports where target_id = uid and status = 'open'),
    'reporters', (select count(distinct reporter_id) from public.reports where target_id = uid),
    'reports_made', (select count(*) from public.reports where reporter_id = uid),
    'refused_uploads', (select count(*) from public.media_scans where user_id = uid and verdict = 'blocked'),
    'warnings', coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from public.user_warnings w where w.user_id = uid), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc)
                         from (select * from public.mod_log where target_id = uid order by created_at desc limit 60) l), '[]'::jsonb)
  ) into out from public.profiles p where p.id = uid;
  return out;
end;
$$;

-- Their recent messages in servers (not DMs: those stay private unless someone reports them).
create or replace function public.mod_user_messages(uid uuid, lim int default 50, before timestamptz default null)
returns table (id uuid, channel_id uuid, content text, attachment_path text, created_at timestamptz,
               channel_name text, server_id uuid, server_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return query
    select m.id, m.channel_id, m.content, m.attachment_path, m.created_at, c.name, s.id, s.name
      from public.messages m
      join public.channels c on c.id = m.channel_id
      join public.servers s on s.id = c.server_id
     where m.author_id = uid and (before is null or m.created_at < before)
     order by m.created_at desc
     limit least(greatest(coalesce(lim, 50), 1), 100);
end;
$$;

-- Bulk cleanup counts as one action, not one per message.
create or replace function public.log_mod_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('yapper.bulk', true), '') = '1' then return old; end if;
  if auth.uid() is not null and old.author_id <> auth.uid() and public.is_site_mod() and not public.is_site_admin() then
    perform public.mod_guard('delete', old.author_id, '');
    insert into public.mod_log (actor, action, target_id, message_id, reason) values (auth.uid(), 'delete', old.author_id, old.id, left(coalesce(old.content, ''), 120));
  end if;
  return old;
end;
$$;

-- Spam raid cleanup: everything they posted in the last N hours (moderators: up to 24 h).
create or replace function public.mod_purge_messages(uid uuid, hours int, why text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if length(trim(coalesce(why, ''))) < 3 then raise exception 'Give a reason'; end if;
  perform public.mod_guard('purge', uid, why);
  if hours < 1 or hours > 720 or (hours > 24 and not public.is_site_admin()) then raise exception 'Pick 1 to 24 hours'; end if;
  perform set_config('yapper.bulk', '1', true);
  delete from public.messages where author_id = uid and created_at > now() - make_interval(hours => hours);
  get diagnostics n = row_count;
  perform set_config('yapper.bulk', '', true);
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'purge', uid, n || ' messages from the last ' || hours || ' h: ' || left(trim(why), 250));
  return n;
end;
$$;

-- Offensive name/picture/bio: wipe just those parts.
create or replace function public.mod_reset_profile(uid uuid, parts text[], why text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(trim(coalesce(why, ''))) < 3 then raise exception 'Give a reason'; end if;
  if parts is null or cardinality(parts) = 0 then raise exception 'Pick what to reset'; end if;
  perform public.mod_guard('reset', uid, why);
  update public.profiles set
    avatar_path  = case when 'avatar' = any(parts) then null else avatar_path end,
    banner_path  = case when 'banner' = any(parts) then null else banner_path end,
    bio          = case when 'bio' = any(parts) then '' else bio end,
    display_name = case when 'display_name' = any(parts) then null else display_name end,
    pronouns     = case when 'pronouns' = any(parts) then null else pronouns end,
    links        = case when 'links' = any(parts) then '[]'::jsonb else links end,
    username     = case when 'username' = any(parts) then 'user' || substr(md5(random()::text || uid::text), 1, 8) else username end
  where id = uid;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'profile_reset', uid, array_to_string(parts, ', ') || ': ' || left(trim(why), 250));
end;
$$;

grant execute on function public.mod_warn(uuid, text), public.ack_warning(uuid), public.mod_user_case(uuid),
  public.mod_user_messages(uuid, int, timestamptz), public.mod_purge_messages(uuid, int, text),
  public.mod_reset_profile(uuid, text[], text) to authenticated;
revoke execute on function public.bc_warning() from authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_center', 'Mod Center', 'New moderation panel: queue by person, user lookup, warnings, notes, bulk cleanup.', 'test', '{}',
        array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

-- Admins: gift (or take away) Plus, on the record so it's never mistaken for a self-grant.
create or replace function public.admin_set_plus(uid uuid, p_until timestamptz, why text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.profiles set plus_until = p_until where id = uid;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), case when p_until is null then 'plus_removed' else 'plus_gift' end, uid,
            case when p_until is null then left(coalesce(why, ''), 300) else 'Until ' || to_char(p_until, 'YYYY-MM-DD') || coalesce(nullif(': ' || left(why, 250), ': '), '') end);
end;
$$;
grant execute on function public.admin_set_plus(uuid, timestamptz, text) to authenticated;
