// 635: Art / Dev Manager applications. 537's stand-ins, 634's deco and bot stand-ins, then 634 and 635. The channel
// block is skipped here (no channel_categories at stage 24), so the channels are only checked by eye after applying.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage537.test.mjs';
import { MORE } from './stage634.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('635_area_applications.sql');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`635 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(`alter table public.profiles add column if not exists muted_until timestamptz;
    create table if not exists public.notices (topic text, event text, payload jsonb);
    create or replace function public.bc_notice(topic_name text, event_name text, payload jsonb) returns void language sql as $$
      insert into public.notices values (topic_name, event_name, payload) $$;`);
  await h.q(`insert into feature_flags (key, label, mode) values ('head_mods', 'x', 'everyone'), ('head_mod_badges', 'x', 'everyone'), ('mod_bot_review', 'x', 'everyone') on conflict (key) do nothing`);
  await h.db.exec(mig('634_area_managers.sql'));
  await h.ok('635 runs', () => h.db.exec(MIG));
  await h.ok('635 re-runs cleanly', () => h.db.exec(MIG));

  const admin = await h.signup('admin@test.dev', 'boss');
  const art = await h.signup('art@test.dev', 'artmgr');
  const mod = await h.signup('mod@test.dev', 'modder');
  const u = await h.signup('u@test.dev', 'someone');
  const fresh = await h.signup('fresh@test.dev', 'newbie');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`update profiles set created_at = now() - interval '60 days' where id in ($1, $2, $3)`, [u, art, mod]);
  await h.q(`update feature_flags set users = users || $1::uuid || $2::uuid || $3::uuid where key = 'area_managers'`, [admin, u, art]);
  await h.q(`insert into site_area_managers (user_id, area) values ($1, 'art')`, [art]);
  await h.q(`insert into community_decos (name, artist_id, path, status) values ('A', $1, 'a/a.png', 'approved'), ('B', $1, 'a/b.png', 'pending')`, [u]);
  const err = (sql, params) => h.q(sql, params).then(() => 'ok', (e) => e.message);

  // Who may apply.
  await h.as(fresh);
  h.eq('flag off for them: off', (await h.one(`select my_area_application('art') j`)).j.on, false);
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'area_managers'`, [fresh]);
  await h.as(fresh);
  h.eq('new account blocked', (await h.one(`select my_area_application('art') j`)).j.block, 'Your account needs to be at least 14 days old to apply');
  h.eq('new account cannot apply', await err(`select apply_area_manager('art', 'I draw a lot of decorations and would love to help review', 'https://x.test/me', '', true)`), 'Your account needs to be at least 14 days old to apply');
  await h.as(art);
  h.eq('already an art manager', (await h.one(`select my_area_application('art') j`)).j.block, 'You\'re an Art Manager already');
  h.eq('but can apply for dev', (await h.one(`select my_area_application('dev') j`)).j.block, null);
  await h.as(admin);
  h.eq('admins need no role', (await h.one(`select my_area_application('dev') j`)).j.block, 'You\'re an admin already');
  await h.as(u);
  h.eq('unknown area', await err(`select apply_area_manager('ops', 'I draw a lot of decorations and would love to help review', '', '', true)`), 'Unknown role');
  h.eq('must agree', await err(`select apply_area_manager('art', 'I draw a lot of decorations and would love to help review', '', '', false)`), 'You need to agree to the rules');
  h.eq('short why', await err(`select apply_area_manager('art', 'pls', '', '', true)`), 'Tell us a bit more about why (30 characters at least)');
  h.eq('long links', await err(`select apply_area_manager('art', 'I draw a lot of decorations and would love to help review', $1, '', true)`, ['x'.repeat(501)]), 'Keep the links under 500 characters');
  await h.ok('applies for art', () => h.q(`select apply_area_manager('art', 'I draw a lot of decorations and would love to help review', 'https://x.test/me', 'Reviewed art for a small server', true)`));
  h.eq('one at a time', await err(`select apply_area_manager('art', 'I draw a lot of decorations and would love to help review', '', '', true)`), 'You already have an application waiting');
  await h.ok('and for dev at the same time', () => h.q(`select apply_area_manager('dev', 'I build bots and know the API inside out, happy to review', '', '', true)`));
  h.eq('mine shows pending', (await h.one(`select my_area_application('art') j`)).j.app.status, 'pending');
  await h.fails('table has no grants', `select * from area_applications`);

  // Reading the list.
  await h.as(fresh);
  h.eq('plain user cannot list', await err(`select * from area_applications_list()`), 'Staff only');
  await h.as(mod);
  h.eq('mod reads both', (await h.one(`select count(*)::int n from area_applications_list()`)).n, 2);
  h.eq('work counts for art', await h.one(`select work, work_ok from area_applications_list() where area = 'art'`), { work: 2, work_ok: 1 });
  h.eq('mod cannot decide', await err(`select decide_area_application((select id from area_applications_list() limit 1), true)`), 'Admins only');
  await h.as(art);
  h.eq('art manager reads art only', (await h.q(`select area from area_applications_list()`)).map((r) => r.area), ['art']);
  h.eq('art manager cannot decide', await err(`select decide_area_application((select id from area_applications_list() limit 1), true)`), 'Admins only');

  // Deciding.
  await h.admin();
  const artApp = (await h.one(`select id from area_applications where user_id = $1 and area = 'art'`, [u])).id;
  const devApp = (await h.one(`select id from area_applications where user_id = $1 and area = 'dev'`, [u])).id;
  await h.as(admin);
  await h.ok('admin declines dev', () => h.q(`select decide_area_application($1, false, 'No verified bots yet')`, [devApp]));
  h.eq('deciding twice', await err(`select decide_area_application($1, true)`, [devApp]), 'Someone already decided that one');
  await h.ok('admin accepts art', () => h.q(`select decide_area_application($1, true)`, [artApp]));
  await h.admin();
  h.eq('they are an art manager now', (await h.one(`select count(*)::int n from site_area_managers where user_id = $1 and area = 'art'`, [u])).n, 1);
  h.eq('badge on', (await h.one(`select 'art_manager' = any(badges) b from profiles where id = $1`, [u])).b, true);
  h.eq('decline logged with the area', (await h.one(`select reason from mod_log where action = 'area_app_declined'`)).reason, 'dev: No verified bots yet');
  h.eq('two notices sent', (await h.one(`select count(*)::int n from notices where event = 'area_application' and topic = 'user:' || $1`, [u])).n, 2);
  await h.as(u);
  h.eq('unseen decision is the latest', (await h.one(`select status, area from my_area_decision()`)), { status: 'accepted', area: 'art' });
  const seen = (await h.one(`select id from my_area_decision()`)).id;
  await h.ok('ack', () => h.q(`select ack_area_decision($1)`, [seen]));
  h.eq('next unseen: the decline', (await h.one(`select status from my_area_decision()`)).status, 'declined');
  h.eq('declined: wait 30 days', (await h.one(`select my_area_application('dev') j`)).j.block.startsWith('You can apply again'), true);
  h.eq('art manager now: blocked for art', (await h.one(`select my_area_application('art') j`)).j.block, 'You\'re an Art Manager already');

  // Withdraw.
  await h.admin();
  await h.q(`update feature_flags set users = users || $1::uuid where key = 'area_managers'`, [mod]);
  await h.as(mod);
  await h.ok('mod applies for dev', () => h.q(`select apply_area_manager('dev', 'I build bots and know the API inside out, happy to review', '', '', true)`));
  await h.ok('takes it back', () => h.q(`select withdraw_area_application('dev')`));
  h.eq('withdrawn: wait a day', (await h.one(`select my_area_application('dev') j`)).j.block, 'You took one back recently. Try again tomorrow');
  await h.as(null);
  await h.fails('anon cannot ask', `select my_area_application('art')`);
}
