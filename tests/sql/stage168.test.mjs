// 168-170 (member/role/bot sweep): kicked bots leave bot_servers, timeout messages carry a date,
// Logger logs role edits and pins.
// PGlite can't replay migrations 025+, so this starts from stage 24 and adds stand-ins for the live pieces
// these migrations patch or call (copied from the live definitions where it matters), then runs 168-170 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const MIGS = ['168_bot_kick_cleanup.sql', '169_timeout_message.sql', '170_logger_more.sql'];

const LIVE_STANDINS = `
alter table public.roles add column if not exists perms jsonb;
alter table public.messages add column if not exists pinned_at timestamptz;
alter table public.messages add column if not exists pinned_by uuid;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists muted_reason text;
alter table public.profiles add column if not exists display_name text;
create table if not exists public.server_timeouts (server_id uuid, user_id uuid, until timestamptz);
create table if not exists public.bots (id uuid primary key, owner_id uuid);
create table if not exists public.bot_servers (bot_id uuid references public.bots(id) on delete cascade, server_id uuid references public.servers(id) on delete cascade, primary key (bot_id, server_id));
create table if not exists public.test_log (kind text, server_id uuid, body text, at timestamptz default clock_timestamp());
create table if not exists public.test_cfg (server_id uuid primary key, cfg jsonb);

create or replace function public.server_timed_out(sid uuid, uid uuid) returns timestamptz language sql stable security definer set search_path = public as $$
  select max(until) from public.server_timeouts where server_id = sid and user_id = uid and until > now();
$$;
-- The timeout lines of the live guards, verbatim.
create or replace function public.block_server_timeouts() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare sid uuid; u timestamptz;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  u := public.server_timed_out(sid, new.author_id);
  if u is not null then
    raise exception 'You''re timed out in this server until %.', to_char(u at time zone 'UTC', 'HH24:MI UTC') using errcode = 'check_violation';
  end if;
  return new;
end; $function$;
drop trigger if exists messages_block_server_timeouts on public.messages;
create trigger messages_block_server_timeouts before insert on public.messages for each row execute function public.block_server_timeouts();
create or replace function public.message_automod() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare mu timestamptz;
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  select muted_until into mu from public.profiles where id = new.author_id;
  if mu is not null and mu > now() then
    raise exception 'You''re timed out until % (%).', to_char(mu at time zone 'UTC', 'HH24:MI UTC'), coalesce((select muted_reason from public.profiles where id = new.author_id), 'moderation') using errcode = 'check_violation';
  end if;
  return new;
end; $function$;
drop trigger if exists messages_automod on public.messages;
create trigger messages_automod before insert on public.messages for each row execute function public.message_automod();
create or replace function public.voice_ticket(cid uuid) returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare p record; until_ts timestamptz;
begin
  select muted_until into p from public.profiles where id = auth.uid();
  if p.muted_until is not null and p.muted_until > now() then
    return jsonb_build_object('error', 'You’re timed out until ' || to_char(p.muted_until at time zone 'UTC', 'HH24:MI') || ' UTC.');
  end if;
  select t.until into until_ts from public.server_timeouts t join public.channels c on c.server_id = t.server_id where c.id = cid and t.user_id = auth.uid() and t.until > now();
  if until_ts is not null then
    return jsonb_build_object('error', 'You’re timed out in this server until ' || to_char(until_ts at time zone 'UTC', 'HH24:MI') || ' UTC.');
  end if;
  return jsonb_build_object('ok', true);
end $function$;

-- Logger pieces 170 calls.
create or replace function public.bot_cfg(sid uuid, b text) returns jsonb language sql stable as $$ select cfg from public.test_cfg where server_id = sid and b = 'logger' $$;
create or replace function public.bot_log(sid uuid, body text) returns void language sql as $$ insert into public.test_log (kind, server_id, body) values ('main', sid, body) $$;
create or replace function public.bot_log_kind(kind text, sid uuid, body text) returns void language sql as $$ insert into public.test_log (kind, server_id, body) values (kind, sid, body) $$;
create or replace function public.log_name(uid uuid) returns text language sql stable as $$ select coalesce((select coalesce(display_name, username) from public.profiles where id = uid), 'someone') $$;
create or replace function public.log_clean(t text, maxlen integer default 600) returns text language sql stable as $$ select left(coalesce(t, ''), maxlen) $$;
create or replace function public.server_plus_on(sid uuid) returns boolean language sql stable as $$ select false $$;
create table if not exists public.test_live_overrides (channel_id uuid primary key);
create or replace function public.channel_overrides_live(cid uuid) returns boolean language sql stable as $$ select exists (select 1 from public.test_live_overrides where channel_id = cid) $$;
`;

export const base = 24;

export default async function (h) {
  await h.admin();
  await h.db.exec(LIVE_STANDINS);
  for (let i = 0; i < 2; i++) {
    for (const m of MIGS) {
      try { await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', m), 'utf8')); }
      catch (e) { throw new Error(`Migration ${m} (run ${i + 1}) failed: ${e.message}`); }
    }
  }
  h.eq('migrations are re-runnable', true, true);

  const boss = await h.signup('boss@test.dev', 'boss');
  const mod = await h.signup('mod@test.dev', 'mod');
  const kid = await h.signup('kid@test.dev', 'kid');
  await h.as(boss);
  const sid = (await h.one(`select create_server('Sweep HQ', null) id`)).id;
  await h.admin();
  const gen = (await h.one(`select id from channels where server_id = $1 limit 1`, [sid]))?.id
    ?? (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'general', $1, $2) returning id`, [sid, boss])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, mod, kid]);

  // ---- 168: kicked bots leave bot_servers; leftovers cleaned ----
  const botA = await h.signup('bota@bots.dev', 'bota');
  const botB = await h.signup('botb@bots.dev', 'botb');
  await h.q(`insert into bots (id, owner_id) values ($1, $3), ($2, $3)`, [botA, botB, boss]);
  await h.q(`insert into bot_servers (bot_id, server_id) values ($1, $3), ($2, $3)`, [botA, botB, sid]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, botA, botB]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, botA]);
  h.eq('kicking a bot removes its bot_servers row', (await h.q(`select bot_id from bot_servers where server_id = $1 order by bot_id`, [sid])).map((r) => r.bot_id), [botB]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, kid]);
  h.eq('a person leaving touches no bot rows', (await h.one(`select count(*)::int n from bot_servers where server_id = $1`, [sid])).n, 1);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, kid]);
  // An old leftover (from before 168): a bot_servers row without membership.
  await h.q(`alter table server_members disable trigger server_members_bot_left`);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [sid, botB]);
  await h.q(`alter table server_members enable trigger server_members_bot_left`);
  h.eq('leftover is there before the cleanup', (await h.one(`select count(*)::int n from bot_servers`)).n, 1);
  await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', '168b_bot_kick_cleanup_data.sql'), 'utf8'));
  h.eq('cleanup removes bot_servers rows without a membership', (await h.one(`select count(*)::int n from bot_servers`)).n, 0);

  // ---- 169: timeout messages carry the date ----
  const ends = new Date(Date.now() + 26 * 3600_000);
  const want = `${ends.toISOString().slice(0, 10)} ${ends.toISOString().slice(11, 16)} UTC`;
  await h.q(`insert into server_timeouts (server_id, user_id, until) values ($1, $2, $3)`, [sid, kid, ends.toISOString()]);
  let msg = '';
  try { await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [gen, kid]); } catch (e) { msg = e.message; }
  h.eq('server timeout message has the date', msg.includes(`until ${want}.`), true);
  await h.q(`update profiles set muted_until = $2, muted_reason = 'spam' where id = $1`, [mod, ends.toISOString()]);
  msg = '';
  try { await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [gen, mod]); } catch (e) { msg = e.message; }
  h.eq('site timeout message has the date', msg.includes(`until ${want} (spam)`), true);
  await h.as(mod);
  h.eq('voice: site timeout has the date', (await h.one(`select voice_ticket($1) t`, [gen])).t.error, `You’re timed out until ${want}.`);
  await h.as(kid);
  h.eq('voice: server timeout has the date', (await h.one(`select voice_ticket($1) t`, [gen])).t.error, `You’re timed out in this server until ${want}.`);
  await h.admin();
  await h.q(`update profiles set muted_until = null where id = $1`, [mod]);
  await h.q(`delete from server_timeouts`);

  // ---- 170: Logger logs role edits and pins ----
  const logc = (await h.one(`insert into channels (kind, name, server_id, created_by) values ('text', 'logs', $1, $2) returning id`, [sid, boss])).id;
  await h.q(`insert into test_cfg (server_id, cfg) values ($1, $2)`, [sid, JSON.stringify({ channel_id: logc })]);
  await h.q(`delete from test_log`);
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [boss]);
  const helper = (await h.one(`insert into roles (server_id, name, position, perms) values ($1, 'Helper', 1, '{"send_messages": true}') returning id`, [sid])).id;
  await h.q(`update roles set perms = '{"send_messages": true, "ban_members": true, "kick_members": true}' where id = $1`, [helper]);
  await h.q(`update roles set perms = '{"ban_members": true, "kick_members": true}', name = 'Helpers' where id = $1`, [helper]);
  await h.q(`update roles set color = '#ff0000' where id = $1`, [helper]);
  await h.q(`delete from roles where id = $1`, [helper]);
  const logs = (await h.q(`select kind, body from test_log order by at`)).map((r) => r.body);
  h.eq('role made, perms on, renamed + perm off, deleted (colour alone is not logged)', logs, [
    '🏷️ **boss** made the **Helper** role',
    '🛡️ **boss** changed the **Helper** role\nTurned on: Ban Members, Kick Members',
    '🛡️ **boss** changed the **Helpers** role\nRenamed from **Helper**\nTurned off: Send Messages',
    '🏷️ **boss** deleted the **Helpers** role',
  ]);
  await h.q(`delete from test_log`);
  await h.q(`select set_config('request.jwt.claim.sub', '', false)`);
  const m1 = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'read the rules') returning id`, [gen, kid])).id;
  await h.q(`update messages set pinned_at = now(), pinned_by = $2 where id = $1`, [m1, boss]);
  await h.q(`update messages set content = 'read the rules!' where id = $1`, [m1]);
  await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [boss]);
  await h.q(`update messages set pinned_at = null, pinned_by = null where id = $1`, [m1]);
  await h.q(`select set_config('request.jwt.claim.sub', '', false)`);
  h.eq('pin and unpin are logged, edits are not', (await h.q(`select body from test_log order by at`)).map((r) => r.body), [
    '📌 **boss** pinned a message by **kid** in **#general**\nread the rules',
    '📌 **boss** unpinned a message by **kid** in **#general**\nread the rules!',
  ]);
  // Bots pinning (yapper.bot) aren't logged.
  await h.q(`delete from test_log`);
  await h.q(`select set_config('yapper.bot', '1', false)`);
  await h.q(`update messages set pinned_at = now() where id = $1`, [m1]);
  await h.q(`select set_config('yapper.bot', '', false)`);
  h.eq('bot pins are not logged', (await h.one(`select count(*)::int n from test_log`)).n, 0);
  await h.q(`update messages set pinned_at = null where id = $1`, [m1]);
  // Channel with live permission overrides (may hide it with view_channel) and a public log: not logged.
  await h.q(`delete from test_log`);
  await h.q(`insert into test_live_overrides values ($1)`, [gen]);
  await h.q(`update messages set pinned_at = now() where id = $1`, [m1]);
  h.eq('pins in a channel with live overrides stay out of a public log', (await h.one(`select count(*)::int n from test_log`)).n, 0);
  await h.q(`delete from test_live_overrides`);
  await h.q(`update messages set pinned_at = null where id = $1`, [m1]);
  // Private channel with a public log: not logged.
  await h.q(`delete from test_log`);
  await h.q(`update channels set private = true where id = $1`, [gen]);
  await h.q(`update messages set pinned_at = now() where id = $1`, [m1]);
  h.eq('pins in a private channel stay out of a public log', (await h.one(`select count(*)::int n from test_log`)).n, 0);
}
