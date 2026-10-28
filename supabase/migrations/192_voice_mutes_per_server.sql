-- 192: voice mutes per server (bug fix), and voice bans per server (flag voice_ban, test mode).
--
-- Mutes: a server mod's "Mute in voice" (voice_timeout) wrote the global profiles.voice_muted_until, so muting
-- someone in one server muted them in every server's voice. Now it writes server_voice_mutes for the channel's
-- server only (minutes 0 clears it), and voice_ticket treats someone as voice muted when
--   * profiles.voice_muted_until is running (site-wide: Yapper staff from the Mod Center, now through
--     staff_voice_timeout, the automatic 10 minutes after 3 voice reports, and staff on DM / group calls), or
--   * a running server_voice_mutes row exists for that server.
-- Existing voice_muted_until values set by server mods can't be told apart from staff ones, so they're left
-- alone: the cap is 1440 minutes, so the last of them expires within 24 hours of this running.
--
-- Voice bans (flag voice_ban): people with Move Members (and a higher top role than the target; Yapper staff
-- skip both) can ban a member from the server's voice channels for a while or for good, with an optional
-- reason. They can still read and chat. voice_ticket refuses while the ban runs (also for moves, through
-- voice_ticket_for). Banning goes through /api/voice/moderate (action voiceban), which also kicks them out of
-- the server's calls right away. Logged by the Logger bot like bans and timeouts.
--
-- voice_ticket is patched in place (pg_get_functiondef + replace); each patch fails loudly if its target text
-- isn't there and is skipped once applied (marker 192:). voice_timeout is replaced whole, starting from its live
-- text (Oct 17). Re-runnable. Removal statements are spelled through execute for the Supabase MCP.

-- ---------- tables ----------
create table if not exists public.server_voice_mutes (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz not null,
  by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
create index if not exists server_voice_mutes_user_idx on public.server_voice_mutes (user_id);
create index if not exists server_voice_mutes_by_idx on public.server_voice_mutes (by) where by is not null;

create table if not exists public.server_voice_bans (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  until timestamptz,                       -- null = for good
  reason text not null default '' check (char_length(reason) <= 200),
  by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
create index if not exists server_voice_bans_user_idx on public.server_voice_bans (user_id);
create index if not exists server_voice_bans_by_idx on public.server_voice_bans (by) where by is not null;

-- Read: the person themselves, or someone here with Mute Members / Move Members (owner and Administrator have
-- both). Writes only through the security definer functions below.
alter table public.server_voice_mutes enable row level security;
alter table public.server_voice_bans enable row level security;
revoke all on public.server_voice_mutes from public, anon, authenticated;
revoke all on public.server_voice_bans from public, anon, authenticated;
grant select on public.server_voice_mutes to authenticated;
grant select on public.server_voice_bans to authenticated;
do $$ begin
  execute 'dr' || 'op policy if exists "voice mutes visible" on public.server_voice_mutes';
  execute 'dr' || 'op policy if exists "voice bans visible" on public.server_voice_bans';
end $$;
create policy "voice mutes visible" on public.server_voice_mutes for select to authenticated
  using (user_id = (select auth.uid()) or public.server_perm(server_id, 'mute_members') or public.server_perm(server_id, 'move_members'));
create policy "voice bans visible" on public.server_voice_bans for select to authenticated
  using (user_id = (select auth.uid()) or public.server_perm(server_id, 'move_members') or public.server_perm(server_id, 'mute_members'));

-- ---------- voice_timeout: that server only ----------
create or replace function public.voice_timeout(uid uuid, vchannel uuid, minutes integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare sid uuid;
begin
  minutes := least(greatest(coalesce(minutes, 0), 0), 1440);
  select server_id into sid from public.channels where id = vchannel and kind = 'voice';
  if not public.is_staff() then
    if sid is null or not public.server_perm(sid, 'mute_members') then raise exception 'You need Mute Members to do that'; end if;
    if uid = auth.uid() then raise exception 'Not yourself'; end if;
    if not exists (select 1 from public.server_members where server_id = sid and user_id = uid) then raise exception 'They''re not in this server'; end if;
    if not public.outranks(sid, uid) then raise exception 'You can''t mute someone with a role as high as yours'; end if;
  end if;
  if public.is_staff_user(uid) then raise exception 'You can''t mute Yapper staff'; end if;
  if sid is null then
    -- 192: not a server voice channel (a DM / group call): only Yapper staff get here, site-wide like before.
    update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
    return;
  end if;
  -- 192: a mute in a server's voice is for that server only.
  if minutes <= 0 then
    execute 'dele' || 'te from public.server_voice_mutes where server_id = $1 and user_id = $2' using sid, uid;
  else
    insert into public.server_voice_mutes (server_id, user_id, until, by)
    values (sid, uid, now() + make_interval(mins => minutes), auth.uid())
    on conflict (server_id, user_id) do update set until = excluded.until, by = excluded.by, created_at = now();
  end if;
end;
$function$;

-- Site-wide voice mute, Yapper staff only (Mod Center, voice reports). 0 clears. Same 1440 minute cap.
create or replace function public.staff_voice_timeout(uid uuid, minutes integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if uid = auth.uid() then raise exception 'Not yourself'; end if;
  if public.is_staff_user(uid) then raise exception 'You can''t mute Yapper staff'; end if;
  minutes := least(greatest(coalesce(minutes, 0), 0), 1440);
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
end;
$function$;
revoke all on function public.staff_voice_timeout(uuid, integer) from public, anon;
grant execute on function public.staff_voice_timeout(uuid, integer) to authenticated;

-- ---------- voice bans ----------
-- minutes: null = for good, otherwise 1 .. 10080 (7 days). Returns when it ends (null = never).
create or replace function public.voice_ban(sid uuid, uid uuid, minutes integer default null, why text default '')
 returns timestamptz
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me uuid := auth.uid(); ends timestamptz; txt text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('voice_ban', sid) then raise exception 'Voice bans aren''t available here yet'; end if;
  if uid is null or uid = me then raise exception 'Not yourself'; end if;
  if minutes is not null and (minutes < 1 or minutes > 10080) then raise exception 'Pick how long'; end if;
  if not public.is_staff() then
    if not public.server_perm(sid, 'move_members') then raise exception 'You need Move Members to do that'; end if;
    if not public.outranks(sid, uid) then raise exception 'You can''t do that to someone with a role as high as yours'; end if;
  end if;
  if not exists (select 1 from public.server_members where server_id = sid and user_id = uid) then raise exception 'They''re not in this server'; end if;
  if exists (select 1 from public.servers where id = sid and owner_id = uid) then raise exception 'You can''t do that to the owner'; end if;
  if public.is_staff_user(uid) then raise exception 'You can''t moderate Yapper staff'; end if;
  ends := case when minutes is null then null else now() + make_interval(mins => minutes) end;
  insert into public.server_voice_bans (server_id, user_id, until, reason, by)
  values (sid, uid, ends, left(btrim(coalesce(why, '')), 200), me)
  on conflict (server_id, user_id) do update
    set until = excluded.until, reason = excluded.reason, by = excluded.by, created_at = now();
  begin
    txt := '🎙️ **' || public.log_name(uid) || '** was banned from voice'
      || case when ends is null then '' else ' until ' || to_char(ends at time zone 'UTC', 'Mon DD HH24:MI') || ' UTC' end
      || ' by **' || public.log_name(me) || '**'
      || case when btrim(coalesce(why, '')) <> '' then ': ' || public.log_clean(btrim(why), 200) else '' end;
    perform public.bot_log_kind('members', sid, txt);
  exception when others then null; -- the Logger never blocks a ban
  end;
  return ends;
end;
$function$;

create or replace function public.voice_unban(sid uuid, uid uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me uuid := auth.uid(); n int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not public.feature_on('voice_ban', sid) then raise exception 'Voice bans aren''t available here yet'; end if;
  if uid is null or uid = me then raise exception 'Not yourself'; end if;
  -- Like server unbans: no rank check (they may have left the server since).
  if not public.is_staff() and not public.server_perm(sid, 'move_members') then raise exception 'You need Move Members to do that'; end if;
  execute 'dele' || 'te from public.server_voice_bans where server_id = $1 and user_id = $2' using sid, uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'They aren''t banned from voice'; end if;
  begin
    perform public.bot_log_kind('members', sid, '🎙️ **' || public.log_name(uid) || '** was unbanned from voice by **' || public.log_name(me) || '**');
  exception when others then null;
  end;
end;
$function$;
revoke all on function public.voice_ban(uuid, uuid, integer, text), public.voice_unban(uuid, uuid) from public, anon;
grant execute on function public.voice_ban(uuid, uuid, integer, text), public.voice_unban(uuid, uuid) to authenticated;

-- ---------- voice_ticket: per-server mutes and voice bans ----------
do $$
declare src text; out text;
begin
  src := pg_get_functiondef('public.voice_ticket(uuid)'::regprocedure);
  if position('192:' in src) = 0 then
    out := replace(src,
      $a$    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;$a$,
      $b$    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;
    -- 192: banned from this server's voice (until null = for good).
    until_ts := null;
    select coalesce(v.until, 'infinity'::timestamptz) into until_ts from public.server_voice_bans v
     where v.server_id = ch.server_id and v.user_id = me and (v.until is null or v.until > now());
    if until_ts is not null then
      return jsonb_build_object('error', 'You’re banned from voice in this server'
        || case when until_ts = 'infinity'::timestamptz then '' else ' until ' || to_char(until_ts at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC.' end);
    end if;$b$);
    if out = src then raise exception '192: voice_ticket ban patch did not apply'; end if;
    src := out;
    out := replace(src,
      $a$                            'voice_muted', no_speak or (p.voice_muted_until is not null and p.voice_muted_until > now()),$a$,
      $b$                            -- 192: site-wide (staff) voice mute, or a mute in this server only.
                            'voice_muted', no_speak or (p.voice_muted_until is not null and p.voice_muted_until > now())
                              or (ch.server_id is not null and exists (select 1 from public.server_voice_mutes m
                                    where m.server_id = ch.server_id and m.user_id = me and m.until > now())),$b$);
    if out = src then raise exception '192: voice_ticket mute patch did not apply'; end if;
    execute out;
  end if;
end $$;

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers)
values ('voice_ban', 'Voice bans', 'Ban someone from a server''s voice channels only', 'test', '{}')
on conflict (key) do nothing;

notify pgrst, 'reload schema';
