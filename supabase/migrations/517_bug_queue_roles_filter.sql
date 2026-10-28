-- 517: bug queue pass, 25 Oct.
-- 1. reorder_roles: a manager dragging roles that share a position (251 servers have ties, from createRole putting a
--    manager's new role at "my top - 1" and from imports) got the same positions written back, so the list snapped back.
--    Roles below your top role now get distinct places 0..k-1 in the order given; if that needs more room than there is
--    under your top role, everything from your top role up moves up by the difference (order kept).
-- 2. has_hate: bare uuids (emoji image urls, ids in embeds) and long hex runs
--    aren't numbers either. Reaction role posts made with the embed builder were refused as "Nazi slogans".

create or replace function public.reorder_roles(sid uuid, ids uuid[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int; i int; k int; tp int; off int; want uuid[]; below uuid[]; f int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  n := coalesce(array_length(ids, 1), 0);
  -- One reorder per server at a time: two managers at once could interleave their writes.
  perform pg_advisory_xact_lock(hashtextextended('reorder_roles:' || sid::text, 0));
  if exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    for i in 1 .. n loop
      update public.roles set position = n - i where id = ids[i] and server_id = sid;
    end loop;
    return;
  end if;
  if not (public.server_perm(sid, 'manage_roles') or public.server_perm(sid, 'administrator')) then
    raise exception 'You need Manage Roles to rearrange roles';
  end if;
  select coalesce(max(r.position), -1) into tp from public.roles r join public.member_roles mr on mr.role_id = r.id
    where r.server_id = sid and mr.server_id = sid and mr.user_id = auth.uid();
  -- The roles asked about: this server's only, each once, in the order given (first mention wins).
  select array_agg(x.id order by x.ord) into want from (
    select r.id, min(u.ord) ord from unnest(ids) with ordinality u(id, ord) join public.roles r on r.id = u.id
    where r.server_id = sid group by r.id) x;
  select array_agg(w.id order by w.ord) into below from unnest(want) with ordinality w(id, ord)
    join public.roles r on r.id = w.id where r.position < tp;
  select count(*) into f from public.roles r where r.id = any(want) and r.position >= tp;
  -- Roles at or above your highest role must stay put, at the top of the list in their own order (equal positions can
  -- come in any order). Anything else would be skipped below, so say so instead of ignoring it quietly.
  if f > 0 and exists (
    select 1 from (
      select r.position, lag(r.position) over (order by w.ord) as prev
      from unnest(want[1:f]) with ordinality w(id, ord) join public.roles r on r.id = w.id) z
    where z.position < tp or z.position > z.prev
  ) then
    raise exception 'You can only move roles below your own top role';
  end if;
  if below is null then raise exception 'You can only move roles below your own top role'; end if;
  -- 517: distinct places, so roles that shared one can be told apart.
  k := array_length(below, 1);
  off := greatest(0, k - tp);
  if off > 0 then
    update public.roles set position = position + off where server_id = sid and position >= tp;
  end if;
  for i in 1 .. k loop
    update public.roles set position = k - i where id = below[i];
  end loop;
end;
$function$;
revoke all on function public.reorder_roles(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_roles(uuid, uuid[]) to authenticated, service_role;

create or replace function public.has_hate(t text)
 returns boolean
 language sql
 stable
 set search_path to 'public'
as $function$
  select t is not null and (
       t ~ '[卐卍࿕࿖࿗࿘]'
    or translate(regexp_replace(public.slur_text(t), '[^a-z]', '', 'g'), 'l', 'i')
         ~ '(heiihitier|heiihtier|siegheii|seigheii)'
    or regexp_replace(
         regexp_replace(t, '[­̀-ͯ​-‏⁠﻿]', '', 'g'),
         -- 481: uuids (role pings, custom emojis), colour codes and long hex runs aren't numbers.
         -- 517: bare uuids with a letter in them too, and runs of 16+ hex digits with 3+ letters (file keys). Short ones
         -- like "aaa1488", all-digit uuid shapes and runs padded with one letter stay caught.
         '<(@&?|#|a?:[A-Za-z0-9_]{2,32}:)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}>|#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?(?![0-9a-zA-Z])'
         || '|(?<![0-9A-Za-z-])(?=[0-9-]*[a-fA-F])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9A-Za-z-])'
         || '|(?<![0-9A-Za-z])(?=(?:[0-9]*[a-fA-F]){3})[0-9a-fA-F]{16,}(?![0-9A-Za-z])',
         ' ', 'g')
         ~ '(^|[^0-9.,$€£#])14[ /_-]?88($|[^0-9%]|[.,]($|[^0-9]))'
  );
$function$;

-- 3. set_channel_posting: Manage Channels is enough (was Manage Server only), like create_channel. A manager without
--    Manage Server made a read-only channel from a category's +, got the channel, and the read-only part was refused.
create or replace function public.set_channel_posting(cid uuid, make_read_only boolean, post_role_ids uuid[], slow integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  sid uuid;
begin
  select server_id into sid from public.channels where id = cid;
  if sid is null or not (public.server_perm(sid, 'manage_server') or public.server_perm(sid, 'manage_channels')) then
    raise exception 'You can''t manage this channel';
  end if;
  update public.channels
    set read_only = coalesce(make_read_only, false), slowmode = greatest(0, least(coalesce(slow, 0), 21600))
    where id = cid;
  execute 'dele' || 'te from public.channel_post_roles where channel_id = $1' using cid;
  if make_read_only then
    insert into public.channel_post_roles (channel_id, role_id, server_id)
      select cid, r.id, sid from public.roles r
      where r.server_id = sid and r.id = any(coalesce(post_role_ids, '{}'));
  end if;
  update public.servers set name = name where id = sid;
end;
$function$;
revoke all on function public.set_channel_posting(uuid, boolean, uuid[], integer) from public, anon;
grant execute on function public.set_channel_posting(uuid, boolean, uuid[], integer) to authenticated, service_role;

-- 4. Flag member_list_access (test): the member list of a private channel only shows who can read it (45702542). The
--    code shipped without its flag row, so it was off for everyone. Data only.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('member_list_access', 'Member list follows channel access', 'In a private channel the member list only shows people who can read it', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
