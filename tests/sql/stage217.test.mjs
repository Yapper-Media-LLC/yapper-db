// 217: admins can pause sign-ups for a while; while paused no account is created (bots excepted), and it ends by itself.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

export default async function (h) {
  const admin = await h.signup('admin@test.dev', 'boss');
  const user = await h.signup('user@test.dev', 'someone');
  await h.admin();
  await h.q(`insert into public.app_settings (id) values (true) on conflict do nothing`);
  await h.q(`insert into public.site_admins (user_id) values ($1) on conflict do nothing`, [admin]);

  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '217_signup_pause.sql'), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable
  h.eq('one guard trigger', (await h.one(`select count(*)::int n from pg_trigger where tgname = 'signup_pause_guard'`)).n, 1);

  h.eq('open by default', (await h.one(`select public.signups_paused() v`)).v, null);

  await h.as(user);
  await h.fails('a normal user cannot pause sign-ups', `select public.set_signups_paused(60)`);
  await h.as(null);
  await h.fails('nobody logged out can pause sign-ups', `select public.set_signups_paused(60)`);

  await h.as(admin);
  await h.fails('more than 7 days is refused', `select public.set_signups_paused(20000)`);
  await h.fails('negative is refused', `select public.set_signups_paused(-1)`);
  const until = (await h.one(`select public.set_signups_paused(60) v`)).v;
  h.eq('admin pause returns when it ends', until !== null, true);
  await h.as(null);
  h.eq('anyone can see it is paused', (await h.one(`select public.signups_paused() is not null v`)).v, true);

  await h.admin();
  let refused = false;
  try { await h.signup('new@test.dev', 'newbie'); } catch (e) { refused = /paused/.test(e.message); }
  h.eq('a new account is refused while paused', refused, true);
  let forged = false;
  try { await h.signup('fake@bots.yapper.website', 'faker'); } catch (e) { forged = /paused/.test(e.message); }
  h.eq('a made-up bot email is refused while paused', forged, true);
  await h.q(`insert into public.pending_bot_emails (email) values ('bot-1@bots.yapper.website')`);
  h.eq('a bot account our server noted is still made', typeof (await h.signup('bot-1@bots.yapper.website', 'botty')), 'string');
  await h.q(`insert into public.pending_bot_emails (email, created_at) values ('bot-2@bots.yapper.website', now() - interval '1 hour')`);
  let stale = false;
  try { await h.signup('bot-2@bots.yapper.website', 'botty2'); } catch (e) { stale = /paused/.test(e.message); }
  h.eq('an old note no longer lets an account through', stale, true);
  await h.as(user);
  await h.fails('users cannot read or add pending bot emails', `insert into public.pending_bot_emails (email) values ('x@bots.yapper.website')`);
  await h.admin();

  // The pause ends by itself.
  await h.q(`update public.app_settings set signups_paused_until = now() - interval '1 second'`);
  h.eq('an expired pause reads as open', (await h.one(`select public.signups_paused() v`)).v, null);
  h.eq('accounts are made again after it ends', typeof (await h.signup('later@test.dev', 'later')), 'string');

  // Reopening early.
  await h.as(admin);
  await h.q(`select public.set_signups_paused(30)`);
  h.eq('0 reopens', (await h.one(`select public.set_signups_paused(0) v`)).v, null);
  await h.admin();
  h.eq('open after reopening', typeof (await h.signup('again@test.dev', 'again')), 'string');
}
