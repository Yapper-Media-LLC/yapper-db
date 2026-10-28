// 420: poll ballots are private. You can select only your own ballot, and the live 'poll' broadcast
// to the channel (or to the other DM members) goes out without the voter's id.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '420_poll_ballots_private.sql'), 'utf8');

// Polls and ballots as live (032 + 151), the old open read policy, and bc() writing to a log instead of publishing.
const STANDINS = `
alter table public.channels add column if not exists server_id uuid;
alter table public.channels drop constraint if exists channels_kind_check;
alter table public.channels drop constraint if exists channels_server_id_fkey;
alter table public.channels drop constraint if exists channels_dm_key_check;
create table if not exists public.polls (id uuid primary key default gen_random_uuid(), channel_id uuid not null references public.channels (id) on delete cascade);
create table if not exists public.poll_ballots (
  poll_id uuid not null references public.polls (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  option_ids text[] not null default '{}', created_at timestamptz not null default now(),
  primary key (poll_id, user_id));
alter table public.poll_ballots enable row level security;
grant select on public.poll_ballots to anon, authenticated;
drop policy if exists "members read ballots" on public.poll_ballots;
create policy "members read ballots" on public.poll_ballots for select
  using (exists (select 1 from public.polls p where p.id = poll_ballots.poll_id and public.can_access_channel(p.channel_id)));
create table if not exists public.bc_log (topic text, op text, rec jsonb, old jsonb);
create or replace function public.bc(topic_name text, event_name text, operation text, table_name text, table_schema text, new record, old record)
returns void language plpgsql security definer set search_path = public as $f$
begin
  insert into public.bc_log values (topic_name, operation,
    case when new is null then null else to_jsonb(new) end, case when old is null then null else to_jsonb(old) end);
end $f$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('420 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create trigger poll_ballots_broadcast after insert or update or delete on public.poll_ballots
    for each row execute function public.broadcast_poll_ballot();`);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  const srv = (await h.one(`insert into channels (kind, server_id) values ('text', gen_random_uuid()) returning id`)).id;
  const dm = (await h.one(`insert into channels (kind) values ('dm') returning id`)).id;
  await h.q(`insert into channel_members values ($1, $2), ($1, $3), ($4, $2), ($4, $3)`, [srv, amy, bob, dm]);
  const p1 = (await h.one(`insert into polls (channel_id) values ($1) returning id`, [srv])).id;
  const p2 = (await h.one(`insert into polls (channel_id) values ($1) returning id`, [dm])).id;
  await h.q(`insert into poll_ballots (poll_id, user_id, option_ids) values ($1, $3, '{1}'), ($1, $4, '{2}'), ($2, $3, '{1}'), ($2, $4, '{1}')`, [p1, p2, amy, bob]);

  await h.as(amy);
  h.eq('amy sees only her own ballots', (await h.q(`select user_id from poll_ballots order by poll_id`)).map((r) => r.user_id), [amy, amy]);
  h.eq('filtering by bob gives nothing', (await h.q(`select 1 from poll_ballots where user_id = $1`, [bob])).length, 0);
  await h.as(null);
  await h.fails('anon cannot read ballots at all', `select 1 from poll_ballots`);

  // Broadcasts: server poll -> chan topic without user_id + the voter's own topic with it.
  await h.admin();
  await h.q(`delete from bc_log`);
  await h.q(`update poll_ballots set option_ids = '{2}' where poll_id = $1 and user_id = $2`, [p1, amy]);
  let log = await h.q(`select topic, rec ->> 'user_id' r, old ->> 'user_id' o, rec ->> 'poll_id' pid from bc_log order by topic`);
  h.eq('server vote: chan copy has no voter, own topic does', log.map((l) => [l.topic, l.r, l.o, l.pid]),
    [['chan:' + srv, null, null, p1], ['user:' + amy, amy, amy, p1]]);

  await h.q(`delete from bc_log`);
  await h.q(`delete from poll_ballots where poll_id = $1 and user_id = $2`, [p2, bob]);
  log = await h.q(`select topic, rec is null nul, old ->> 'user_id' o, old ->> 'option_ids' opts from bc_log order by topic = 'user:' || $1 desc`, [bob]);
  h.eq('DM unvote: bob gets his id, amy gets the ballot without it', log.map((l) => [l.topic, l.nul, l.o, l.opts]),
    [['user:' + bob, true, bob, '["1"]'], ['user:' + amy, true, null, '["1"]']]);

  await h.q(`delete from bc_log`);
  await h.q(`insert into poll_ballots (poll_id, user_id, option_ids) values ($1, $2, '{2}')`, [p2, bob]);
  log = await h.q(`select topic, rec ->> 'user_id' r, old is null onul from bc_log where topic = 'user:' || $1`, [amy]);
  h.eq('DM vote: other member gets no voter id, no old row', log.map((l) => [l.r, l.onul]), [[null, true]]);
}
