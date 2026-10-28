-- 547: head mods and Management can raise the moderators' hourly limits (flag mod_limit_boost, test: Antic).
-- Antic, Oct 26: a mod hit "You've hit the hourly limit for that (60 an hour)"; head mods and managers should be able
-- to raise the caps by 1.5x, 2x or 2.5x. The limits are Yapper-wide (mod_guard counts a staff mod's mod_log rows,
-- whatever server they acted in), so the setting is one site-wide multiplier in app_settings.mod_limit_boost
-- (1, 1.5, 2 or 2.5; the check constraint refuses anything else). mod_guard multiplies every cap it knows by it
-- (rounded up), inside the database, so the toast shows the raised number ("90 an hour" at 1.5x). 1x = today.
-- Only admins, head mods and managers can change it (set_mod_limit_boost; head mods and managers need the flag on
-- for them, and get 10 changes an hour), and every change is in the Log as mod_limit_boost ("1x -> 2x"). Regular mods can read it (the Mod Center
-- shows how much they have left this hour) but not set it. mod_guard is patched into its live text (pg_get_functiondef)
-- like 522/535/537: one line added, nothing else touched. Re-runnable.

set lock_timeout = '3s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mod_limit_boost', 'Mod limit boost', 'Head mods and Management can raise the mods'' hourly limits (1.5x, 2x, 2.5x)', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

alter table public.app_settings add column if not exists mod_limit_boost numeric not null default 1;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_settings_mod_limit_boost_check') then
    alter table public.app_settings add constraint app_settings_mod_limit_boost_check check (mod_limit_boost in (1, 1.5, 2, 2.5));
  end if;
end $$;

-- The current multiplier. Anyone signed in may read it (mods see their scaled limits); app_settings itself stays closed.
create or replace function public.mod_limit_boost()
returns numeric
language plpgsql
stable security definer
set search_path = public
as $$
declare b numeric;
begin
  select mod_limit_boost into b from public.app_settings where id limit 1;
  return coalesce(b, 1);
end;
$$;
revoke all on function public.mod_limit_boost() from public, anon;
grant execute on function public.mod_limit_boost() to authenticated;

-- Set it. Admins always; head mods and managers while the flag is on for them. Logged as mod_limit_boost.
create or replace function public.set_mod_limit_boost(boost numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare was numeric;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not public.is_site_admin() then
    if not (public.is_head_mod() or public.is_site_manager()) then raise exception 'Head mods and Management only'; end if;
    if not public.feature_on('mod_limit_boost', null) then raise exception 'Not available yet'; end if;
  end if;
  if boost is null or boost not in (1, 1.5, 2, 2.5) then raise exception 'Pick 1x, 1.5x, 2x or 2.5x'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mod_limit_boost', 0));
  -- Not a lever to flick all day: 10 changes an hour for head mods and managers (admins have no cap).
  if not public.is_site_admin() and (select count(*) from public.mod_log where actor = auth.uid() and action = 'mod_limit_boost'
      and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'You''ve changed the limits 10 times this hour. Wait a bit';
  end if;
  select mod_limit_boost into was from public.app_settings where id;
  if was = boost then return; end if;
  update public.app_settings set mod_limit_boost = boost where id;
  insert into public.mod_log (actor, action, reason)
  values (auth.uid(), 'mod_limit_boost', rtrim(rtrim(coalesce(was, 1)::text, '0'), '.') || 'x -> ' || rtrim(rtrim(boost::text, '0'), '.') || 'x');
end;
$$;
revoke all on function public.set_mod_limit_boost(numeric) from public, anon;
grant execute on function public.set_mod_limit_boost(numeric) to authenticated;

-- mod_guard: scale the cap before the check. Patched into the live text; a changed anchor stops the migration.
create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  -- Exactly one anchor: replace() would otherwise put the line before every copy and scale twice.
  if (length(f) - length(replace(f, old_text, ''))) / length(old_text) <> 1 then raise exception '547: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

select pg_temp.patch_fn('public.mod_guard(text,uuid,text)', 'mod_limit_boost',
  'if n >= lim then',
  'lim := ceil(lim * public.mod_limit_boost())::int;' || chr(10) || '  if n >= lim then');
