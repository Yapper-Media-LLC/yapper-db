// 330: hourly ban limit for moderators 40 or 60 -> 80. mod_guard's live text (Oct 20) is copied below, since no migration
// file has it; the migration patches only the ban number.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '330_mod_ban_limit_80.sql'), 'utf8');

const STANDINS = `
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target uuid, created_at timestamptz not null default now());
create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
create or replace function public.is_site_mod() returns boolean language sql stable as $$ select true $$;
create or replace function public.is_staff_user(uid uuid) returns boolean language sql stable as $$ select false $$;
CREATE OR REPLACE FUNCTION public.mod_guard(action text, target uuid, why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int; lim int; logged text[];
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if target is not null and public.is_staff_user(target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
  if action in ('ban', 'timeout', 'takedown', 'purge') and length(trim(coalesce(why, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  lim := case action
    when 'ban' then 60 when 'takedown' then 5 when 'purge' then 20 when 'timeout' then 60 when 'reset' then 20
    when 'unban' then 10 when 'badge' then 10 when 'untimeout' then 30 when 'verify' then 60
    when 'unwarn' then 30 when 'mark_bot' then 20 when 'server_hide' then 10 else 60 end;
  logged := case action
    when 'badge' then array['badge_given', 'badge_removed']
    when 'takedown' then array['server_takedown']
    when 'untimeout' then array['timeout_cleared']
    when 'verify' then array['verify', 'verify_reject', 'verify_ask_proof']
    when 'mark_bot' then array['marked_bot', 'unmarked_bot']
    when 'reset' then array['reset', 'profile_reset']
    else array[action] end;
  select count(*) into n from public.mod_log where actor = auth.uid() and mod_log.action = any(logged) and created_at > now() - interval '1 hour';
  if n >= lim then
    raise exception 'You''ve hit the hourly limit for that (% an hour). Wait a bit or ask an admin to do it.', lim;
  end if;
end; $function$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('330 re-runs cleanly', () => h.db.exec(MIG));
  const mod = await h.signup('mod@test.dev', 'mod');
  const target = await h.signup('t@test.dev', 'target');
  await h.admin();
  const fill = async (action, k) => h.q(`insert into mod_log (actor, action) select $1, $2 from generate_series(1, $3)`, [mod, action, k]);
  await fill('ban', 79);
  await h.as(mod);
  await h.ok('79 bans in the last hour: one more is fine', () => h.q(`select mod_guard('ban', $1, 'spam bot')`, [target]));
  await h.admin(); await fill('ban', 1); await h.as(mod);
  await h.fails('80 bans in the last hour: stopped', `select mod_guard('ban', $1, 'spam bot')`, [target]);
  await h.admin(); await h.q(`update mod_log set created_at = now() - interval '61 minutes'`); await h.as(mod);
  await h.ok('older than an hour: counts again from zero', () => h.q(`select mod_guard('ban', $1, 'spam bot')`, [target]));
  await h.admin(); await fill('timeout', 60); await h.as(mod);
  await h.fails('other limits unchanged (timeouts still 60)', `select mod_guard('timeout', $1, 'flooding')`, [target]);
  await h.admin();
  h.eq('the live function now reads 80 for bans', (await h.q(`select position('when ''ban'' then 80 ' in pg_get_functiondef('public.mod_guard(text, uuid, text)'::regprocedure)) > 0 as ok`))[0].ok, true);
}
