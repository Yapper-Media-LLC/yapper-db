-- ============================================================
-- Yapper · Stronger filters and auto-moderation (applied to production 2026-10-13)
-- 1. Slur filter sees through lookalike letters, accents, zero-width chars and
--    masked spellings (n**ga). Self-harm incitement ("kys") is refused.
-- 2. Timeouts (profiles.muted_until) + anti-spam on messages.
-- 3. Reports carry server_id; server moderators see and resolve their own.
-- 4. Automatic actions from reports: ban on slur+2 reporters or 8 reporters/hour,
--    1h timeout at 5 reporters/hour. (The trigger that enables auto-bans is the
--    last statement; comment it out to keep bans human-only.)
-- ============================================================

create extension if not exists unaccent;

create or replace function public.slur_text(t text)
returns text language sql immutable as $$
  select regexp_replace(
    regexp_replace(
      translate(
        lower(unaccent(regexp_replace(coalesce(t, ''), '[​-‏⁠﻿­]', '', 'g'))),
        'аеорсухіјѕԁԛԝһɡɪıɑοαενκρτυιɴɢʀꜰᴀᴇᴏᴜᴛᴋᴘꜱ0134578@$!|ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ',
        'aeopcyxijsdqwhgiiaoaevkptuingrfaeoutkpsoieastbasiiabcdefghijklmnopqrstuvwxyz'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$$;

create or replace function public.has_slur(t text)
returns boolean language sql immutable as $$
  select
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*|n+g+a+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i+n+k+s*|c+o+o+n+s*|d+y+k+e+s*|n+i+g+s*) '
    )
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|n+e+g+g+(e+r+|r+e*|a+)|f+a+g+g+[oei]+t+'
    or (' ' || regexp_replace(lower(unaccent(coalesce(t, ''))), '[*#@$%&!?_.\-]+', '', 'g') || ' ') ~ ' (n[iy]*g+g*(a+|e+r+|a+h+|e+t+)?|f[a]*g+g*(o+t+|e+t+|i+t+)?) '
      and lower(coalesce(t, '')) ~ '[*#@$%&!?_.\-]';
$$;

create or replace function public.has_self_harm_incitement(t text)
returns boolean language sql immutable as $$
  select (' ' || public.slur_text(t) || ' ') ~
    ' (kys|k+y+s+|kill ?your ?self|kill ?ur ?self|go ?(and )?die|hang ?(your|ur) ?self|neck ?(your|ur) ?self|unalive ?(your|ur) ?self|end ?(your|ur) ?self|drink ?bleach|slit ?(your|ur) ?wrists?|you should die|nobody would miss you) ';
$$;

-- Timeouts + anti-spam ---------------------------------------------------------
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;

create or replace function public.message_automod()
returns trigger language plpgsql security definer set search_path = public as $$
declare mu timestamptz; dup int; joined timestamptz;
begin
  if public.is_site_admin() then return new; end if;
  select muted_until into mu from public.profiles where id = new.author_id;
  if mu is not null and mu > now() then
    raise exception 'You''re timed out until % (%).', to_char(mu at time zone 'UTC', 'HH24:MI UTC'), coalesce((select muted_reason from public.profiles where id = new.author_id), 'moderation') using errcode = 'check_violation';
  end if;
  if public.has_self_harm_incitement(new.content) then
    raise exception 'Telling someone to hurt themselves isn''t allowed on Yapper.' using errcode = 'check_violation';
  end if;
  if tg_op = 'INSERT' then
    if length(new.content) > 3 then
      select count(*) into dup from public.messages where author_id = new.author_id and content = new.content and created_at > now() - interval '60 seconds';
      if dup >= 2 then raise exception 'You already sent that. Slow down.' using errcode = 'check_violation'; end if;
    end if;
    if (length(new.content) - length(replace(new.content, '@', ''))) >= 8 then
      select created_at into joined from auth.users where id = new.author_id;
      if joined > now() - interval '7 days' then
        raise exception 'New accounts can''t mention that many people at once.' using errcode = 'check_violation';
      end if;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists messages_automod on public.messages;
create trigger messages_automod before insert or update of content on public.messages for each row execute function public.message_automod();

create or replace function public.site_timeout(uid uuid, minutes int, why text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.profiles set muted_until = case when minutes <= 0 then null else now() + make_interval(mins => minutes) end, muted_reason = nullif(left(why, 200), '') where id = uid;
end;
$$;
revoke all on function public.site_timeout(uuid, int, text) from public, anon;
grant execute on function public.site_timeout(uuid, int, text) to authenticated;

-- Reports per server -------------------------------------------------------------
alter table public.reports add column if not exists server_id uuid references public.servers (id) on delete set null;
create index if not exists reports_server_idx on public.reports (server_id, status);
update public.reports r set server_id = c.server_id from public.channels c where c.id = r.channel_id and r.server_id is null and c.server_id is not null;
drop policy if exists "server mods read their reports" on public.reports;
create policy "server mods read their reports" on public.reports for select to authenticated
  using (server_id is not null and public.server_perm(server_id, 'manage_server'));

create or replace function public.report_message(mid uuid, why text, more text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.messages; rid uuid; sid uuid;
begin
  perform public.report_guard(auth.uid());
  select * into m from public.messages where id = mid;
  if m.id is null or not public.can_access_channel(m.channel_id) then raise exception 'Message not found'; end if;
  if m.author_id = auth.uid() then raise exception 'You can''t report your own message'; end if;
  select server_id into sid from public.channels where id = m.channel_id;
  insert into public.reports (reporter_id, target_id, message_id, channel_id, server_id, message_content, message_attachment, reason, details)
  values (auth.uid(), m.author_id, m.id, m.channel_id, sid, m.content, m.attachment_path, why, left(coalesce(more, ''), 1000))
  returning id into rid;
  return rid;
end;
$$;

create or replace function public.resolve_report(rid uuid, new_status text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select server_id into sid from public.reports where id = rid;
  if not (public.is_site_admin() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if new_status not in ('open', 'actioned', 'dismissed') then raise exception 'Bad status'; end if;
  update public.reports
     set status = new_status,
         resolved_by = case when new_status = 'open' then null else auth.uid() end,
         resolved_at = case when new_status = 'open' then null else now() end
   where id = rid;
end;
$$;

-- Automatic actions from reports ------------------------------------------------
create or replace function public.apply_auto_action(target uuid, r public.reports)
returns text language plpgsql security definer set search_path = public as $$
declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean;
begin
  if target is null or exists (select 1 from public.site_admins where user_id = target) or exists (select 1 from public.site_bans where user_id = target) then return null; end if;
  slur := public.has_slur(coalesce(r.message_content, ''));
  select count(distinct reporter_id) into reporters_1h from public.reports x where x.target_id = target and x.created_at > now() - interval '1 hour';
  select count(distinct reporter_id) into reporters_7d from public.reports x where x.target_id = target and x.created_at > now() - interval '7 days';
  if (slur and reporters_7d >= 2) or reporters_1h >= 8 then
    insert into public.site_bans (user_id, reason)
    values (target, case when slur then 'Auto-ban: slurs, reported by ' || reporters_7d || ' people' else 'Auto-ban: reported by ' || reporters_1h || ' people in an hour' end)
    on conflict (user_id) do nothing;
    update public.reports set status = 'actioned', triage = 'auto', triage_note = 'Auto-banned', resolved_at = now() where target_id = target and status = 'open';
    return 'Auto-banned';
  end if;
  if reporters_1h >= 5 then
    select muted_until into mu from public.profiles where id = target;
    if mu is null or mu < now() then
      update public.profiles set muted_until = now() + interval '1 hour', muted_reason = 'reported by ' || reporters_1h || ' people' where id = target;
    end if;
    return 'Auto timeout 1h';
  end if;
  return null;
end;
$$;

create or replace function public.auto_action_new_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare note text;
begin
  if new.status = 'open' then
    note := public.apply_auto_action(new.target_id, new);
    if note is not null and note <> 'Auto-banned' then
      update public.reports set triage = 'ban', triage_note = coalesce(triage_note || ' · ', '') || note where id = new.id;
    end if;
  end if;
  return null;
end;
$$;
drop trigger if exists reports_auto_action on public.reports;
create trigger reports_auto_action after insert on public.reports for each row execute function public.auto_action_new_report();
