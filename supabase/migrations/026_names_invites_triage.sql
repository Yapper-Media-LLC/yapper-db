-- ============================================================
-- Yapper · Raid cleanup, part 2 (applied to production 2026-10-13)
-- 1. Names (usernames, servers, channels) are held to a higher bar than chat.
-- 2. In the community server, invite links only go in the promotion channel.
-- 3. Reports are reviewed automatically: already-handled ones close, ones with
--    clear evidence are flagged "needs a ban" for the admin panel.
-- 4. An (unwired) pause switch: app_settings.paused + block_while_paused().
-- ============================================================

-- 1. Names -------------------------------------------------------------------
create or replace function public.bad_name(t text)
returns boolean language sql immutable as $$
  select public.has_slur(t)
    or replace(public.slur_text(t), ' ', '') ~ ('(porn|hentai|nsfw|rape|rapist|pedo|paedo|cheesepizza|childp|sexoffen|hitler|nazi|kkk|lynch|onlyfans|nudes|sexting|pussy|vagina|penis|cocks?uck|blowjob|cumshot|cumslut|whore|slut|jailbait|loli|shota|kys|killyourself|suicide|selfharm)')
    or (' ' || public.slur_text(t) || ' ') ~ ' (sex|sexy|cum|dick|cock|fuck|fucking|fucked|shit|bitch|anal|boobs|tits|horny|nude|nigga|cp|csam) ';
$$;

create or replace function public.no_bad_names()
returns trigger language plpgsql as $$
declare col text; val text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    if val is not null and public.bad_name(val) then
      raise exception 'That name isn''t allowed on Yapper. Pick another.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists profiles_no_bad_names on public.profiles;
create trigger profiles_no_bad_names before insert or update of username on public.profiles for each row execute function public.no_bad_names('username');
drop trigger if exists servers_no_bad_names on public.servers;
create trigger servers_no_bad_names before insert or update of name on public.servers for each row execute function public.no_bad_names('name');
drop trigger if exists channels_no_bad_names on public.channels;
create trigger channels_no_bad_names before insert or update of name on public.channels for each row execute function public.no_bad_names('name');

-- 2. Invite links ------------------------------------------------------------
create or replace function public.invites_only_in_promo()
returns trigger language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  if new.content !~* '(yapper\.website/invite/|discord\.gg/|discord(app)?\.com/invite/|t\.me/|guilded\.gg/)' then return new; end if;
  select c.name, c.server_id into ch from public.channels c where c.id = new.channel_id;
  if ch.server_id is not null
     and ch.server_id = (select default_server_id from public.app_settings limit 1)
     and ch.name !~* 'promot'
     and not public.is_site_admin() then
    raise exception 'Invite links only go in #promote-your-server.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists messages_invites_only_in_promo on public.messages;
create trigger messages_invites_only_in_promo before insert or update of content on public.messages
  for each row execute function public.invites_only_in_promo();

-- 3. Report triage -----------------------------------------------------------
alter table public.reports add column if not exists triage text check (triage in ('ban', 'auto'));
alter table public.reports add column if not exists triage_note text;
create index if not exists reports_triage_idx on public.reports (triage, status);

create or replace function public.triage_rules(r public.reports)
returns table (status text, triage text, note text)
language plpgsql stable security definer set search_path = public as $$
declare reporters int;
begin
  if exists (select 1 from public.site_bans b where b.user_id = r.target_id) then
    return query select 'actioned', 'auto', 'Already banned'; return;
  end if;
  if exists (select 1 from public.site_admins a where a.user_id = r.target_id) then
    return query select 'dismissed', 'auto', 'Report against an admin'; return;
  end if;
  if r.message_id is not null and not exists (select 1 from public.messages m where m.id = r.message_id) then
    return query select 'actioned', 'auto', 'Message already removed'; return;
  end if;
  if public.has_slur(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Slur in message'; return;
  end if;
  if public.has_adult_link(coalesce(r.message_content, '')) then
    return query select 'open', 'ban', 'Link to porn site'; return;
  end if;
  if r.reason in ('sexual', 'minor_safety', 'illegal') and r.message_attachment is not null then
    return query select 'open', 'ban', 'Image reported as ' || r.reason; return;
  end if;
  if r.reason = 'minor_safety' then
    return query select 'open', 'ban', 'Minor-safety report'; return;
  end if;
  select count(distinct reporter_id) into reporters from public.reports x where x.target_id = r.target_id and x.created_at > now() - interval '7 days';
  if reporters >= 3 then
    return query select 'open', 'ban', 'Reported by ' || reporters || ' different people'; return;
  end if;
  return query select 'open', null::text, null::text;
end;
$$;

create or replace function public.triage_new_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public.triage_rules(new);
  new.triage := t.triage;
  new.triage_note := t.note;
  if t.status <> 'open' then
    new.status := t.status; new.resolved_at := now();
  end if;
  return new;
end;
$$;
drop trigger if exists reports_triage on public.reports;
create trigger reports_triage before insert on public.reports for each row execute function public.triage_new_report();

create or replace function public.triage_open_reports()
returns table (closed int, flagged int)
language plpgsql security definer set search_path = public as $$
declare r public.reports; t record; c int := 0; f int := 0;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  for r in select * from public.reports where status = 'open' loop
    select * into t from public.triage_rules(r);
    if t.status <> 'open' then
      update public.reports set status = t.status, triage = 'auto', triage_note = t.note, resolved_at = now() where id = r.id;
      c := c + 1;
    else
      update public.reports set triage = t.triage, triage_note = t.note where id = r.id and (triage is distinct from t.triage or triage_note is distinct from t.note);
      if t.triage = 'ban' then f := f + 1; end if;
    end if;
  end loop;
  return query select c, f;
end;
$$;
revoke all on function public.triage_open_reports() from public, anon;
grant execute on function public.triage_open_reports() to authenticated;

-- 4. Pause switch (not wired to any table; see the triggers in the admin notes) --
alter table public.app_settings add column if not exists paused boolean not null default false;
alter table public.app_settings add column if not exists paused_message text not null default 'Yapper is paused for a short cleanup. Back soon.';
create or replace function public.site_paused()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select paused from public.app_settings limit 1), false);
$$;
create or replace function public.block_while_paused()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.site_paused() and not public.is_site_admin() then
    raise exception '%', coalesce((select paused_message from public.app_settings limit 1), 'Yapper is paused for a short cleanup.') using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end;
$$;
