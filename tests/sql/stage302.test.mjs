// 302: a banned account that deletes itself leaves a hashed email and its recent networks until the ban would have
// ended; sign-up checks (ip_banned_recently, email_banned) still catch it. Unbanned accounts leave nothing.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '302_delete_while_banned.sql'), 'utf8');

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now()));
$$;
create table if not exists public.login_attempts (username text, ip text, ok boolean, at timestamptz default now());
create table if not exists public.app_settings (default_server_id uuid);
create or replace function public.reauth_check(p_password text) returns text language sql stable as $$ select case when p_password = 'right' then null else 'Wrong password' end $$;
create or replace function public.is_frozen(uid uuid) returns boolean language sql stable as $$ select false $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('302 re-runs cleanly', () => h.db.exec(MIG));

  const bad = await h.signup('bad@test.dev', 'bad');
  const fine = await h.signup('fine@test.dev', 'fine');
  await h.admin();
  await h.q(`insert into login_attempts (username, ip, ok, at) values ('bad', '1.1.1.1', true, now() - interval '1 day'), ('bad', '2.2.2.2', true, now() - interval '9 days'), ('fine', '3.3.3.3', true, now())`);
  await h.q(`insert into site_bans (user_id, reason, expires_at) values ($1, 'test', now() + interval '3 days')`, [bad]);
  h.eq('before: banned network blocked', (await h.one(`select ip_banned_recently('1.1.1.1') v`)).v, true);

  await h.as(bad);
  h.eq('wrong password refuses', (await h.one(`select delete_my_account('nope') v`)).v, 'Wrong password');
  await h.ok('a banned account can delete itself', () => h.q(`select delete_my_account('right')`));
  await h.admin();
  h.eq('account gone', (await h.one(`select count(*)::int n from auth.users where id = $1`, [bad])).n, 0);
  h.eq('network still blocked after delete', (await h.one(`select ip_banned_recently('1.1.1.1') v`)).v, true);
  h.eq('old network (9 days) not kept', (await h.one(`select ip_banned_recently('2.2.2.2') v`)).v, false);
  h.eq('email still blocked (any case)', (await h.one(`select email_banned(' BAD@test.dev') v`)).v, true);
  h.eq('gmail dot/plus/googlemail variants match', (await h.one(`select ban_email_hash('b.a.d+x@googlemail.com') = ban_email_hash('bad@gmail.com') v`)).v, true);
  h.eq('other domains keep dots', (await h.one(`select ban_email_hash('b.ad@test.dev') = ban_email_hash('bad@test.dev') v`)).v, false);
  let msg = null;
  try { await h.q(`insert into auth.users (id, email) values (gen_random_uuid(), 'Bad@test.dev')`); } catch (e) { msg = e.message; }
  h.eq('a direct sign-up with that email is refused (trigger)', /can't be used/.test(msg || '') ? 'refused' : msg, 'refused');
  msg = null;
  const other = await h.signup('other@test.dev', 'other');
  await h.admin();
  try { await h.q(`update auth.users set email = 'bad@test.dev' where id = $1`, [other]); } catch (e) { msg = e.message; }
  h.eq('changing an email to it is refused too', /can't be used/.test(msg || '') ? 'refused' : msg, 'refused');
  h.eq('nothing but hash, ip, until kept', (await h.one(`select count(*)::int n from ban_leftovers where email_hash is not null and email_hash <> ban_email_hash('bad@test.dev')`)).n, 0);
  h.eq('leftovers end with the ban', (await h.one(`select bool_and(until <= now() + interval '3 days 1 minute') v from ban_leftovers`)).v, true);

  await h.as(fine);
  await h.ok('an unbanned account deletes normally', () => h.q(`select delete_my_account('right')`));
  await h.admin();
  h.eq('unbanned leaves nothing', (await h.one(`select email_banned('fine@test.dev') a, ip_banned_recently('3.3.3.3') b`)), { a: false, b: false });

  await h.q(`update ban_leftovers set until = now() - interval '1 minute'`);
  h.eq('after the ban would have ended: free again', (await h.one(`select email_banned('bad@test.dev') a, ip_banned_recently('1.1.1.1') b`)), { a: false, b: false });

  await h.as(fine);
  await h.fails('users can\'t read leftovers', `select * from ban_leftovers`);
  await h.fails('users can\'t call email_banned', `select email_banned('x@y.z')`);
  await h.fails('users can\'t call keep_ban_leftovers', `select keep_ban_leftovers(gen_random_uuid())`);
}
