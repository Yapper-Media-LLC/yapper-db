-- 579: mod action burst alerts (flag mod_burst_alerts, test).
-- When one moderator does many moderation actions in a short window, the database writes one
-- mod_burst_alerts row and tells head mods and admins live (bc_notice on user:<id>, event mod_burst).
-- Thresholds live in mod_burst_rules (one place): which actions count, how many, in how many minutes.
-- One alert per moderator per hour (any rule). Admins' own actions never alert.
-- Re-runnable.

set lock_timeout = '3s';

-- ---------- Rules: the one place thresholds live ----------
create table if not exists public.mod_burst_rules (
  kind text primary key,
  actions text[] not null,
  threshold int not null check (threshold > 0),
  window_minutes int not null check (window_minutes between 1 and 1440),
  enabled boolean not null default true
);
alter table public.mod_burst_rules enable row level security;
revoke all on public.mod_burst_rules from public, anon, authenticated;
grant select on public.mod_burst_rules to authenticated;
drop policy if exists "leads read burst rules" on public.mod_burst_rules;
create policy "leads read burst rules" on public.mod_burst_rules for select to authenticated
  using ((select public.is_site_admin()) or (select public.is_head_mod()));

-- Bans, kicks, timeouts, warnings and the like: 10 in 10 minutes. Deletes are routine in bursts (spam clean-ups), so 40.
insert into public.mod_burst_rules (kind, actions, threshold, window_minutes) values
  ('actions', '{ban,kick,timeout,warn,purge,profile_reset,server_takedown,voice_mute}', 10, 10),
  ('deletes', '{delete}', 40, 10)
on conflict (kind) do nothing;

-- ---------- Alerts ----------
create table if not exists public.mod_burst_alerts (
  id uuid primary key default gen_random_uuid(),
  actor uuid not null references public.profiles (id) on delete cascade,
  kind text not null references public.mod_burst_rules (kind) on delete cascade,
  action_count int not null,
  window_start timestamptz not null,
  window_end timestamptz not null,
  actions text[] not null default '{}',
  log_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  dismissed_at timestamptz,
  dismissed_by uuid references public.profiles (id) on delete set null,
  note text not null default ''
);
create index if not exists mod_burst_alerts_actor_idx on public.mod_burst_alerts (actor, created_at desc);
create index if not exists mod_burst_alerts_open_idx on public.mod_burst_alerts (created_at desc) where dismissed_at is null;
create index if not exists mod_burst_alerts_dismissed_by_idx on public.mod_burst_alerts (dismissed_by) where dismissed_by is not null;
alter table public.mod_burst_alerts enable row level security;
revoke all on public.mod_burst_alerts from public, anon, authenticated;
grant select on public.mod_burst_alerts to authenticated;
-- Head mods and admins read them where the flag is on for them; a head mod never sees an alert about themself.
drop policy if exists "leads read burst alerts" on public.mod_burst_alerts;
create policy "leads read burst alerts" on public.mod_burst_alerts for select to authenticated
  using ((select public.feature_on('mod_burst_alerts', null))
     and ((select public.is_site_admin()) or ((select public.is_head_mod()) and actor <> (select auth.uid()))));

-- ---------- Who gets told ----------
-- Admins and active head mods, minus the actor, and only people the flag is on for (in test mode just the listed users,
-- so nobody gets a ping for a tab they cannot open).
create or replace function public.mod_burst_recipients(skip uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select r.user_id from (
    select user_id from public.site_admins
    union
    select user_id from public.site_moderators where head and suspended_at is null
  ) r
  join public.feature_flags f on f.key = 'mod_burst_alerts'
  where r.user_id <> skip and (f.mode = 'everyone' or r.user_id = any(f.users));
$$;
revoke execute on function public.mod_burst_recipients(uuid) from public, anon, authenticated;

-- ---------- The check: AFTER INSERT on mod_log ----------
create or replace function public.mod_burst_alert_check()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int;
  ids uuid[];
  acts text[];
  since timestamptz;
  a public.mod_burst_alerts;
  who text;
  note jsonb;
  uid uuid;
begin
  if new.actor is null then return null; end if;
  -- Flag off entirely: nothing. In test mode alerts are still written and sent; only the readers are gated.
  if not exists (select 1 from public.feature_flags where key = 'mod_burst_alerts' and mode in ('test', 'everyone')) then
    return null;
  end if;
  if exists (select 1 from public.site_admins where user_id = new.actor) then return null; end if;

  for r in select * from public.mod_burst_rules where enabled and new.action = any(actions) loop
    since := now() - make_interval(mins => r.window_minutes);
    -- Two actions landing together: the second one skips (never waits), the next action re-checks anyway.
    if not pg_try_advisory_xact_lock(hashtext('mod_burst_alert:' || new.actor::text)) then return null; end if;
    -- One alert per moderator per hour, whatever the rule.
    if exists (select 1 from public.mod_burst_alerts where actor = new.actor and created_at > now() - interval '1 hour') then
      return null;
    end if;
    select count(*), array_agg(id order by created_at desc), array_agg(distinct action)
      into n, ids, acts
      from (select id, action, created_at from public.mod_log
             where actor = new.actor and action = any(r.actions) and created_at > since
             order by created_at desc limit 500) m;
    if coalesce(n, 0) < r.threshold then continue; end if;

    insert into public.mod_burst_alerts (actor, kind, action_count, window_start, window_end, actions, log_ids)
    values (new.actor, r.kind, n, since, now(), acts, ids[1:200])
    returning * into a;

    select username into who from public.profiles where id = new.actor;
    note := jsonb_build_object('id', a.id, 'actor', a.actor, 'actor_name', who, 'kind', a.kind,
      'count', a.action_count, 'window_minutes', r.window_minutes, 'actions', to_jsonb(a.actions));
    -- The alert row stays even when the realtime server is unreachable.
    begin
      for uid in select public.mod_burst_recipients(new.actor) loop
        perform public.bc_notice('user:' || uid::text, 'mod_burst', note);
      end loop;
    exception when others then
      raise warning 'mod_burst_alert_check notify: %', sqlerrm;
    end;
    return null;
  end loop;
  return null;
exception when others then
  -- Never let the alarm break the moderation action it is watching.
  raise warning 'mod_burst_alert_check: %', sqlerrm;
  return null;
end $$;
revoke execute on function public.mod_burst_alert_check() from public, anon, authenticated;

drop trigger if exists mod_log_burst_check on public.mod_log;
create trigger mod_log_burst_check after insert on public.mod_log
  for each row execute function public.mod_burst_alert_check();

-- ---------- Dismiss ----------
create or replace function public.mod_burst_dismiss(aid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare a public.mod_burst_alerts;
begin
  if not public.feature_on('mod_burst_alerts', null) then raise exception 'Not available yet'; end if;
  if not (public.is_site_admin() or public.is_head_mod()) then raise exception 'Head mods only'; end if;
  select * into a from public.mod_burst_alerts where id = aid for update;
  if a.id is null then raise exception 'No such alert'; end if;
  if a.actor = auth.uid() then raise exception 'Someone else has to look at your own alert'; end if;
  if a.dismissed_at is not null then return; end if;
  update public.mod_burst_alerts
     set dismissed_at = now(), dismissed_by = auth.uid(), note = left(coalesce(p_note, ''), 300)
   where id = aid;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), 'burst_reviewed', a.actor, left(a.kind || ' x' || a.action_count || case when coalesce(p_note, '') = '' then '' else ': ' || p_note end, 300));
end $$;
revoke execute on function public.mod_burst_dismiss(uuid, text) from public, anon;
grant execute on function public.mod_burst_dismiss(uuid, text) to authenticated;

-- ---------- Flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_burst_alerts', 'Mod burst alerts',
        'When a moderator does many bans, kicks, timeouts or deletes in a few minutes, head mods and admins get an alert in Mod Center.',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
