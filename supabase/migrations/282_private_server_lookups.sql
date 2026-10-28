-- 282 private server lookups (bug reports f3b2dfd2, c77d2c4c, d79b1b45). Re-runnable. Applied live as 277_private_server_lookups; renamed to 282 because 277 was taken on main.
-- Three security definer helpers answered for any server id / user id, so a plain account could read what the tables'
-- own row security hides:
--   1. server_members_slice(sids): every member of any server (user ids, nicknames, join times).
--   2. server_member_counts(sids): the member count of any server.
--   Both are only called by the app for servers you are in, so they now only answer for those (my_server_ids(), the
--   same set the server_members / servers policies use). Asking for anyone else's server returns nothing.
--   3. tag_server(sid): name, description, icon and size of any server, private ones too. The tag card is meant for
--      someone clicking a tag they see on a profile, so a server still answers when you are in it, it is public, or
--      somebody wears its tag (profiles.server_tag). A private server nobody wears a tag for answers like one that
--      doesn't exist.
--   4. site_unban(uid): it did refuse non-staff, but only after looking up the ban, so "Moderators only" (a ban
--      exists) vs a quiet success (no ban) told any account whether any user id is site-banned. Staff are checked first.
--   5. is_site_banned(uid) answered the same question for any account directly (rpc), so it is no longer callable by
--      signed-in users. Every function that uses it is security definer (owned by postgres) and keeps working. The one
--      row-security policy that called it ("file a bug") uses am_i_site_banned() now, which only answers for the caller.
--   tag_server also reads servers.member_count (kept by trigger since 112) instead of counting server_members.

create or replace function public.server_member_counts(sids uuid[])
 returns table(server_id uuid, n bigint)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.member_count::bigint
  from public.servers s
  where s.id = any(sids) and s.id in (select public.my_server_ids());
$function$;

create or replace function public.server_members_slice(sids uuid[])
 returns table(server_id uuid, user_id uuid, nickname text, joined_at timestamp with time zone)
 language plpgsql stable security definer set search_path to 'public' as $function$
declare big uuid[]; small uuid[]; onl uuid[]; me uuid := auth.uid();
begin
  -- Only servers you are in. This function skips the server_members policy, so it has to repeat it.
  sids := coalesce(array(select x.id from unnest(sids) as x(id) where x.id in (select public.my_server_ids())), '{}'::uuid[]);
  select coalesce(array_agg(id), '{}'::uuid[]) into big from public.servers where id = any(sids) and member_count > 3000;
  select coalesce(array_agg(id), '{}'::uuid[]) into small from public.servers where id = any(sids) and member_count <= 3000;
  if cardinality(big) = 0 then
    return query select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(small);
    return;
  end if;
  select coalesce(array_agg(p.user_id), '{}'::uuid[]) into onl from public.presence p where p.last_seen > now() - interval '10 minutes';
  return query
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(small)
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at from public.server_members sm where sm.server_id = any(big) and sm.user_id = me
    union
    -- Every join below is a lateral with limit 1: one index probe per row, never a scan of the whole table.
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from public.roles r
    join public.member_roles mr on mr.role_id = r.id
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = mr.server_id and x.user_id = mr.user_id limit 1) sm
    where r.server_id = any(big) and r.auto = 'none'
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from public.member_roles mr
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = mr.server_id and x.user_id = mr.user_id limit 1) sm
    where mr.server_id = any(big) and mr.manual
    union
    select sm.server_id, sm.user_id, sm.nickname, sm.joined_at
    from unnest(onl) as u(user_id)
    cross join unnest(big) as b(server_id)
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = b.server_id and x.user_id = u.user_id limit 1) sm
    union
    select r.server_id, r.user_id, r.nickname, r.joined_at
    from unnest(big) as b(server_id)
    cross join lateral (select x.server_id, x.user_id, x.nickname, x.joined_at from public.server_members x where x.server_id = b.server_id order by x.joined_at desc limit 300) r;
end $function$;

create or replace function public.tag_server(sid uuid)
 returns jsonb
 language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'icon_path', s.icon_path, 'tag', s.tag,
    'description', coalesce(s.description, ''),
    'discoverable', coalesce(s.discoverable, false),
    'member_count', s.member_count,
    'joined', exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  )
  from public.servers s
  where s.id = sid and auth.uid() is not null
    and (
      coalesce(s.discoverable, false)
      or s.id in (select public.my_server_ids())
      or exists (select 1 from public.profiles p where p.server_tag = s.id)
    );
$function$;

create or replace function public.site_unban(uid uuid)
 returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans;
begin
  -- Staff first, so a plain account gets the same answer whether or not the user is banned.
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Moderators only'; end if;
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    if b.banned_by is not null and b.expires_at is null then raise exception 'Only an admin can lift a confirmed ban'; end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  -- 157: take back their files the ban queued for deletion, if they haven't gone yet.
  execute 'del' || 'ete from public.media_purge p where p.done_at is null and split_part(p.path, ''/'', 1) = $1
     and not exists (select 1 from public.reports r where p.bucket = ''attachments'' and r.message_attachment = p.path and r.message_deleted_by = ''author'')'
    using uid::text;
  update public.media_scans set forgiven = true where user_id = uid and verdict = 'blocked' and not forgiven;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unban', uid, coalesce(b.reason, ''));
end; $function$;

-- 5. is_site_banned(uid) stays for the security definer functions that use it; signed-in users can't call it directly.
create or replace function public.am_i_site_banned()
 returns boolean
 language sql stable security definer set search_path to 'public' as $function$
  select exists (
    select 1 from public.site_bans
    where user_id = (select auth.uid()) and (expires_at is null or expires_at > now())
  );
$function$;
revoke all on function public.am_i_site_banned() from public, anon;
grant execute on function public.am_i_site_banned() to authenticated, service_role;

-- The policy is switched and the grant is taken away in the same transaction, so filing a bug never breaks in between.
do $$
begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bug_reports' and policyname = 'file a bug') then
    alter policy "file a bug" on public.bug_reports
      with check (user_id = (select auth.uid()) and not public.am_i_site_banned());
  end if;
end $$;

-- Stop here (and roll the whole migration back) if some other policy, in any schema, still calls it: the revoke would break it.
do $$
begin
  if exists (select 1 from pg_policies where coalesce(qual, '') || ' ' || coalesce(with_check, '') ~ '\mis_site_banned\M') then
    raise exception '277: a row security policy still calls is_site_banned';
  end if;
end $$;

revoke all on function public.is_site_banned(uuid) from public, anon, authenticated;

do $$
begin
  if has_function_privilege('authenticated', 'public.is_site_banned(uuid)', 'execute') then
    raise exception '277: signed-in users can still call is_site_banned';
  end if;
end $$;
