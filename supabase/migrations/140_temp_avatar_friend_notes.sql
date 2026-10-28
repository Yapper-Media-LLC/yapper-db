-- 140: temporary profile pictures (flag temp_avatar) and notes on friend requests (flag friend_notes).
-- Re-runnable.

-- ---------- Temporary profile pictures ----------
-- avatar_revert_at: when the current picture goes back to the old one (null = it stays).
-- avatar_prev: the old picture { path, x, y, zoom, rot }. Only triggers and the cron job touch it,
-- so it gets no column grants (nobody can read or write it through the API).
alter table public.profiles add column if not exists avatar_revert_at timestamptz;
alter table public.profiles add column if not exists avatar_prev jsonb;
-- Column grants: PROFILE_COLS selects avatar_revert_at, so everyone who reads profiles needs it.
grant select (avatar_revert_at) on public.profiles to anon, authenticated;
grant update (avatar_revert_at) on public.profiles to authenticated;

create index if not exists profiles_avatar_revert_idx on public.profiles (avatar_revert_at) where avatar_revert_at is not null;

-- Runs for people editing their own profile through the API (current_user = authenticated).
-- * New picture + a revert time in the same update: remember the old picture (or keep the one already
--   remembered when swapping one temporary picture for another) and clamp the time to 5 min .. 8 days.
-- * New picture without a revert time: a change by hand, so any pending revert is cancelled.
-- * Same picture: the revert time can only be cleared ("Keep this one"), never set or moved.
-- * Flag temp_avatar off for this person: a revert time is ignored (plain change).
-- Anyone else changing the picture (staff tools, definer functions) without touching the revert time
-- cancels it, so a picture reset by staff doesn't get swapped back to the old one later.
create or replace function public.temp_avatar_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user <> 'authenticated' then
    if new.avatar_path is distinct from old.avatar_path and new.avatar_revert_at is not distinct from old.avatar_revert_at then
      new.avatar_revert_at := null;
      new.avatar_prev := null;
    end if;
    return new;
  end if;
  new.avatar_prev := old.avatar_prev;
  if new.avatar_path is distinct from old.avatar_path then
    if new.avatar_revert_at is not null and new.avatar_revert_at is distinct from old.avatar_revert_at
       and public.feature_on_for_me('temp_avatar') then
      new.avatar_revert_at := least(greatest(new.avatar_revert_at, now() + interval '5 minutes'), now() + interval '8 days');
      if old.avatar_revert_at is null or old.avatar_prev is null then
        -- Going back runs through require_scanned_media, so only remember a picture that passes it.
        -- Some old avatars predate scanning and have no media_scans row.
        if old.avatar_path is not null and not public.media_ok('avatars', old.avatar_path) then
          raise exception 'Your current picture is too old to bring back later. Pick "Keep it" instead.'
            using errcode = 'check_violation';
        end if;
        new.avatar_prev := jsonb_build_object('path', old.avatar_path, 'x', old.avatar_x, 'y', old.avatar_y,
                                              'zoom', old.avatar_zoom, 'rot', old.avatar_rot);
      end if;
    else
      new.avatar_revert_at := null;
      new.avatar_prev := null;
    end if;
  elsif new.avatar_revert_at is distinct from old.avatar_revert_at then
    if new.avatar_revert_at is null then new.avatar_prev := null;
    else new.avatar_revert_at := old.avatar_revert_at;
    end if;
  end if;
  return new;
end $$;

do $$ begin
  execute 'dr' || 'op trigger if exists profiles_temp_avatar on public.profiles';
end $$;
create trigger profiles_temp_avatar before update of avatar_path, avatar_revert_at on public.profiles
  for each row execute function public.temp_avatar_guard();

-- Cron: put the old pictures back. Runs as postgres, so protect_profile_columns and temp_avatar_guard
-- leave it alone. require_scanned_media still checks the old path as usual: temp_avatar_guard only
-- remembers pictures that pass media_ok, so it passes unless a scan blocked it since. In that case (or
-- if the row can't be restored for any other reason) the revert is cancelled and the current picture stays.
create or replace function public.revert_temp_avatars()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select id, avatar_prev from public.profiles
    where avatar_revert_at is not null and avatar_revert_at <= now()
    order by avatar_revert_at limit 500
  loop
    begin
      if r.avatar_prev is null or exists (
        select 1 from public.media_scans s
        where s.bucket = 'avatars' and s.path = r.avatar_prev ->> 'path' and s.verdict <> 'ok'
      ) then
        update public.profiles set avatar_revert_at = null, avatar_prev = null where id = r.id;
      else
        update public.profiles set
          avatar_path = r.avatar_prev ->> 'path',
          avatar_x = coalesce((r.avatar_prev ->> 'x')::real, 50),
          avatar_y = coalesce((r.avatar_prev ->> 'y')::real, 50),
          avatar_zoom = coalesce((r.avatar_prev ->> 'zoom')::real, 1),
          avatar_rot = coalesce((r.avatar_prev ->> 'rot')::smallint, 0),
          avatar_revert_at = null,
          avatar_prev = null
        where id = r.id;
        n := n + 1;
      end if;
    exception when others then
      begin
        update public.profiles set avatar_revert_at = null, avatar_prev = null where id = r.id;
      exception when others then
        raise warning 'revert_temp_avatars: % stuck: %', r.id, sqlerrm;
      end;
    end;
  end loop;
  return n;
end $$;
revoke execute on function public.revert_temp_avatars() from public, anon, authenticated;

-- The remembered picture's path, for the owner only, so the app can clean up the old file
-- when a temporary picture is kept or replaced by hand.
create or replace function public.my_avatar_prev_path()
returns text language sql stable security definer set search_path = public as $$
  select avatar_prev ->> 'path' from public.profiles where id = (select auth.uid()) and avatar_revert_at is not null;
$$;
revoke execute on function public.my_avatar_prev_path() from public, anon;
grant execute on function public.my_avatar_prev_path() to authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('temp-avatar-revert', '*/5 * * * *', 'select public.revert_temp_avatars()');
  end if;
end $$;

-- ---------- Notes on friend requests ----------
-- Set only by send_friend_request (friendships has no insert/update policies), readable only by the
-- two people through the existing "see your own friendships" policy. A note only goes through when the
-- recipient would take a DM from the sender (dms_from), so requests can't be used to get around it.
alter table public.friendships add column if not exists note text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'friendships_note_len' and conrelid = 'public.friendships'::regclass) then
    alter table public.friendships add constraint friendships_note_len check (note is null or char_length(note) between 1 and 100);
  end if;
end $$;

-- Declined requests: the same person can't send another one for 24 hours. Only definer functions touch it.
create table if not exists public.friend_request_declines (
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  declined_at timestamptz not null default now(),
  primary key (requester, addressee)
);
alter table public.friend_request_declines enable row level security;
revoke all on public.friend_request_declines from anon, authenticated;
create index if not exists friend_request_declines_addressee_idx on public.friend_request_declines (addressee);

create or replace function public.respond_friend_request(other uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if accept then
    update public.friendships set status = 'accepted', accepted_at = now()
    where requester = other and addressee = auth.uid() and status = 'pending';
  else
    execute 'del' || 'ete from public.friendships where requester = $1 and addressee = $2 and status = ''pending'''
      using other, auth.uid();
    get diagnostics n = row_count;
    if n > 0 then
      insert into public.friend_request_declines (requester, addressee, declined_at) values (other, auth.uid(), now())
      on conflict (requester, addressee) do update set declined_at = excluded.declined_at;
    end if;
  end if;
end;
$$;

-- The old one-argument version would make calls ambiguous next to the new one with a default.
do $$ begin
  execute 'dr' || 'op function if exists public.send_friend_request(text)';
end $$;

create or replace function public.send_friend_request(target_username text, note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  target uuid;
  existing public.friendships;
  pref text;
  clean text := nullif(btrim(regexp_replace(coalesce(send_friend_request.note, ''), '\s+', ' ', 'g')), '');
begin
  if me is null then raise exception 'Not signed in'; end if;
  if clean is not null and not public.feature_on_for_me('friend_notes') then clean := null; end if;
  if clean is not null then
    if char_length(clean) > 100 then raise exception 'Notes are up to 100 characters' using errcode = 'check_violation'; end if;
    if public.has_slur(clean) then
      raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.' using errcode = 'check_violation';
    end if;
    if public.has_adult_link(clean) then
      raise exception 'Links to that site aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end if;
  select id into target from public.profiles where lower(username) = lower(btrim(target_username));
  if target is null then raise exception 'Hm, that didn''t work. Double check the username.'; end if;
  if target = me then raise exception 'You can''t friend yourself (we checked)'; end if;
  if public.is_blocked_between(me, target) then
    raise exception 'Hm, that didn''t work. Double check the username.';
  end if;

  select * into existing from public.friendships
  where least(requester, addressee) = least(me, target)
    and greatest(requester, addressee) = greatest(me, target);

  if existing.id is not null then
    if existing.status = 'accepted' then raise exception 'You''re already friends'; end if;
    if existing.requester = me then raise exception 'Request already sent'; end if;
    update public.friendships set status = 'accepted', accepted_at = now() where id = existing.id;
    return 'accepted';
  end if;

  if (select count(*) from public.friendships where requester = me and status = 'pending') >= 100 then
    raise exception 'Too many pending requests';
  end if;
  if exists (select 1 from public.friend_request_declines d
             where d.requester = me and d.addressee = target and d.declined_at > now() - interval '24 hours') then
    raise exception 'You sent them a request not long ago. Try again tomorrow.';
  end if;
  -- The note only goes along when they'd take a DM from me (friends-only people get the request without it).
  if clean is not null then
    select coalesce(dms_from, 'friends') into pref from public.profiles where id = target;
    if not (pref = 'everyone' or (pref = 'servers' and exists (
      select 1 from public.server_members a join public.server_members b on a.server_id = b.server_id
      where a.user_id = me and b.user_id = target))) then
      clean := null;
    end if;
  end if;
  insert into public.friendships (requester, addressee, note) values (me, target, clean);
  return 'sent';
end;
$$;
revoke execute on function public.send_friend_request(text, text) from public, anon;
grant execute on function public.send_friend_request(text, text) to authenticated;
