-- ============================================================
-- Yapper · Voice moderation (applied to production 2026-10-13)
-- Reports from voice channels, moderator voice mutes (listen-only, enforced on
-- the LiveKit server by /api/voice/moderate), and an automatic 10-minute voice
-- timeout when three different people report someone in the same call within
-- ten minutes. The voice token route also refuses timed-out, server-banned and
-- brand-new (community server) accounts.
-- ============================================================

alter table public.profiles add column if not exists voice_muted_until timestamptz;

create or replace function public.report_voice(uid uuid, vchannel uuid, why text, more text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; sid uuid;
begin
  perform public.report_guard(auth.uid());
  if uid = auth.uid() then raise exception 'You can''t report yourself'; end if;
  select server_id into sid from public.channels where id = vchannel and kind = 'voice';
  if sid is null or not public.can_access_channel(vchannel) then raise exception 'Voice channel not found'; end if;
  insert into public.reports (reporter_id, target_id, channel_id, server_id, reason, details)
  values (auth.uid(), uid, vchannel, sid, why, '[voice] ' || left(coalesce(more, ''), 980))
  returning id into rid;
  return rid;
end;
$$;
revoke all on function public.report_voice(uuid, uuid, text, text) from public, anon;
grant execute on function public.report_voice(uuid, uuid, text, text) to authenticated;

create or replace function public.voice_timeout(uid uuid, vchannel uuid, minutes int)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.channels where id = vchannel;
  if not (public.is_site_admin() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if exists (select 1 from public.site_admins where user_id = uid) then raise exception 'You can''t mute an admin'; end if;
  update public.profiles set voice_muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end where id = uid;
end;
$$;
revoke all on function public.voice_timeout(uuid, uuid, int) from public, anon;
grant execute on function public.voice_timeout(uuid, uuid, int) to authenticated;

create or replace function public.triage_new_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare t record; n int;
begin
  select * into t from public.triage_rules(new);
  new.triage := t.triage;
  new.triage_note := t.note;
  if t.status <> 'open' then
    new.status := t.status; new.resolved_at := now();
  end if;
  if new.status = 'open' and new.details like '[voice]%' and new.channel_id is not null then
    select count(distinct reporter_id) + 1 into n from public.reports x
      where x.target_id = new.target_id and x.channel_id = new.channel_id and x.reporter_id <> new.reporter_id and x.created_at > now() - interval '10 minutes';
    if n >= 3 and not exists (select 1 from public.site_admins where user_id = new.target_id) then
      update public.profiles set voice_muted_until = greatest(coalesce(voice_muted_until, now()), now() + interval '10 minutes') where id = new.target_id;
      new.triage := 'ban';
      new.triage_note := coalesce(new.triage_note || ' · ', '') || 'Reported in voice by ' || n || ' people · auto voice timeout 10m';
    end if;
  end if;
  return new;
end;
$$;
