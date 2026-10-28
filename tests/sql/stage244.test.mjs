// 244: channels select policy pre-check (same visibility, no per-row check on unrelated channels) and the
// 5-a-day username change limit.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
create table if not exists public.staff_standin (user_id uuid primary key);
grant select on public.staff_standin to authenticated;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public
  as $$ select exists (select 1 from public.staff_standin where user_id = auth.uid()) $$;
create or replace function public.my_server_ids() returns setof uuid language sql stable security definer set search_path = public
  as $$ select server_id from public.server_members where user_id = auth.uid() $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const a = await h.signup('a@x.com', 'alice');
  const b = await h.signup('b@x.com', 'bob');
  await h.admin();
  const before = async (uid) => { await h.as(uid); const r = (await h.q(`select id from public.channels order by id`)).map((x) => x.id); await h.admin(); return r; };
  const sid = (await h.one(`insert into public.servers (name, owner_id) values ('S', $1) returning id`, [a])).id;
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [sid, a]);
  await h.q(`insert into public.channels (server_id, name, kind) values ($1, 'general', 'text')`, [sid]);
  const c = await h.signup('c@x.com', 'carol');
  await h.admin();
  const dm = (await h.one(`insert into public.channels (kind, created_by, dm_key) values ('dm', $1, $2) returning id`, [a, [a, c].sort().join(':')])).id;
  await h.q(`insert into public.channel_members (channel_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [dm, a, c]);
  const aBefore = await before(a);
  const bBefore = await before(b);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '244_channels_policy_rename_limit.sql'), 'utf8');
  await h.db.exec(sql);
  await h.ok('migration runs twice', () => h.db.exec(sql));
  h.eq('alice sees the same channels', await before(a), aBefore);
  h.eq('bob sees the same channels', await before(b), bBefore);
  h.eq('bob (not a member) sees none of the server or the DM', (await before(b)).length, 0);
  h.eq('carol sees only the DM she is in', await before(c), [dm]);
  h.eq('alice sees her DM too', (await before(a)).includes(dm), true);

  await h.as(b);
  for (let i = 1; i <= 5; i++) await h.ok(`rename ${i}`, () => h.q(`update public.profiles set username = $1 where id = $2`, [`bobby${i}`, b]));
  await h.ok('changing only the capitals is free', () => h.q(`update public.profiles set username = 'BOBBY5' where id = $1`, [b]));
  await h.fails('6th rename in a day is refused', `update public.profiles set username = 'bobby6' where id = $1`, [b]);
  await h.admin();
  await h.ok('service role can still rename', () => h.q(`update public.profiles set username = 'bobby7' where id = $1`, [b]));
}
