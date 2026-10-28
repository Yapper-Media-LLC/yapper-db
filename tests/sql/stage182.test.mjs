// 182: bot hosting. Owners read only their own row and never the token hash; clients can't write or call the
// service-only functions; stop reasons (blocked, flag, verified, banned, paid + 3 day grace, free Plus slot);
// runner reports only touch that runner's bots; payments and renewals by subscription id; the rate limit.
// PGlite can't replay every migration, so: 001..024, flags (031, 041), small stand-ins for bots and Plus, then 182 twice.
export const base = 24;

const STANDINS = `
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null default 'bot', token_hash text, verified_at timestamptz
);
`;

export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  const { readFileSync } = await import('node:fs');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const mig = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase', 'migrations', '182_bot_hosting.sql'), 'utf8');
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig);
  await h.db.exec(mig); // re-runnable

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const ab = await h.signup('ab@test.dev', 'amybot');
  const bb = await h.signup('bb@test.dev', 'bobbot');
  const bc = await h.signup('bc@test.dev', 'bobbot2');
  await h.admin();
  await h.q(`insert into bots (id, owner_id, name, verified_at) values ($1, $2, 'amybot', now()), ($3, $4, 'bobbot', null), ($5, $4, 'bobbot2', now())`, [ab, amy, bb, bob, bc]);

  h.eq('flag row in test mode, no servers', await h.one(`select mode, servers from feature_flags where key = 'bot_hosting'`), { mode: 'test', servers: [] });

  const service = async () => { await h.admin(); await h.db.exec('set role service_role'); };

  // Payments (service role).
  await service();
  const paid = await h.one(`select bot_hosting_paid($1, $2, 'small', 'cus_1', 'sub_1', 31) r`, [ab, amy]);
  h.eq('first payment: no old sub', paid.r.old_sub, null);
  await h.fails('payment for a bot you do not own', `select bot_hosting_paid($1, $2, 'small', 'cus_x', 'sub_x', 31)`, [ab, bob]);
  await h.fails('bad tier', `select bot_hosting_paid($1, $2, 'huge', 'cus_1', 'sub_1', 31)`, [ab, amy]);
  await h.admin();
  const r0 = await h.one(`select tier, until > now() + interval '30 days' and until < now() + interval '32 days' ok, owner_id from bot_hosting where bot_id = $1`, [ab]);
  h.eq('row made with 31 days', [r0.tier, r0.ok, r0.owner_id], ['small', true, amy]);

  // Upgrade to Large adds on top and reports the old sub to cancel.
  await service();
  const up = await h.one(`select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_2', 31) r`, [ab, amy]);
  h.eq('upgrade returns the old sub', up.r.old_sub, 'sub_1');
  await h.admin();
  h.eq('upgrade converts the Small time left at the price ratio (31 * 0.5 + 31)', (await h.one(`select tier, until between now() + interval '46 days' and now() + interval '47 days' ok, stripe_sub from bot_hosting where bot_id = $1`, [ab])), { tier: 'large', ok: true, stripe_sub: 'sub_2' });
  await service();
  await h.fails('days are bounded', `select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_2', 100000)`, [ab, amy]);
  await h.fails('ratio is bounded', `select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_2', 31, 5)`, [ab, amy]);
  // Stacking Small then buying Large once can't turn every Small day into Large.
  await h.admin();
  await h.q(`update bot_hosting set tier = 'small', until = now() + interval '310 days' where bot_id = $1`, [ab]);
  await service();
  await h.q(`select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_3', 31, 0.5)`, [ab, amy]);
  await h.admin();
  h.eq('stacked Small converted, not copied', (await h.one(`select until between now() + interval '185 days' and now() + interval '187 days' ok from bot_hosting where bot_id = $1`, [ab])).ok, true);
  await h.q(`update bot_hosting set until = now() + interval '31 days' where bot_id = $1`, [ab]);
  await service();
  await h.q(`select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_4', 31, 0.5)`, [ab, amy]);
  await h.admin();
  h.eq('same tier stacks in full', (await h.one(`select until between now() + interval '61 days' and now() + interval '63 days' ok from bot_hosting where bot_id = $1`, [ab])).ok, true);

  // The same subscription booked twice (completed + async_payment_succeeded) adds nothing and cancels nothing.
  const before = (await h.one(`select until from bot_hosting where bot_id = $1`, [ab])).until;
  await service();
  const again = await h.one(`select bot_hosting_paid($1, $2, 'large', 'cus_1', 'sub_4', 31, 0.5) r`, [ab, amy]);
  h.eq('same sub again: no old sub to cancel', again.r.old_sub, null);
  await h.admin();
  h.eq('same sub again: no days added', String((await h.one(`select until from bot_hosting where bot_id = $1`, [ab])).until), String(before));
  await service();
  const nosub = await h.one(`select bot_hosting_paid($1, $2, 'large', 'cus_1', null, 1, 0.5) r`, [ab, amy]);
  h.eq('no subscription id: never cancels the current one', nosub.r.old_sub, null);
  await h.admin();
  h.eq('no subscription id: keeps the current one', (await h.one(`select stripe_sub from bot_hosting where bot_id = $1`, [ab])).stripe_sub, 'sub_4');
  await h.q(`update bot_hosting set stripe_sub = 'sub_2' where bot_id = $1`, [ab]);

  // Renewal by subscription id only.
  await service();
  h.eq('unknown sub renews nothing', (await h.one(`select bot_hosting_renew('sub_1', 31) u`)).u, null);
  h.eq('renewal by sub id', (await h.one(`select bot_hosting_renew('sub_2', 31) is not null ok`)).ok, true);

  // Stop reasons.
  const why = async (bid, free = false) => { await service(); return (await h.one(`select bot_hosting_stop_reason($1, $2) w`, [bid, free])).w; };
  h.eq('flag off for amy', await why(ab), 'flag off');
  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'bot_hosting'`, [amy, bob]);
  h.eq('paid, verified, flag on: may run', await why(ab), null);
  h.eq('no row: not set up', await why(bb), 'not set up');
  await h.admin();
  await h.q(`insert into bot_hosting (bot_id, owner_id, until) values ($1, $2, now() + interval '5 days')`, [bb, bob]);
  h.eq('unverified bot', await why(bb), 'not verified');
  await h.q(`update bots set verified_at = now() where id = $1`, [bb]);
  await h.q(`update bot_hosting set until = now() - interval '2 days' where bot_id = $1`, [bb]);
  h.eq('inside the 3 day grace', await why(bb), null);
  await h.admin();
  await h.q(`update bot_hosting set until = now() - interval '4 days' where bot_id = $1`, [bb]);
  h.eq('past the grace: not paid', await why(bb), 'not paid');
  await h.admin();
  await h.q(`update bot_hosting set until = null, free_slot = true where bot_id = $1`, [bb]);
  await h.q(`update profiles set plus_until = now() + interval '10 days' where id = $1`, [bob]);
  h.eq('free slot ignored while BOTHOST_PLUS_FREE is off', await why(bb, false), 'not paid');
  h.eq('free slot with Plus', await why(bb, true), null);
  await h.admin();
  await h.q(`update bot_hosting set tier = 'large' where bot_id = $1`, [bb]);
  h.eq('free slot is Small only', await why(bb, true), 'not paid');
  await h.q(`update bot_hosting set tier = 'small' where bot_id = $1`, [bb]);
  await h.q(`update profiles set plus_until = now() - interval '1 day' where id = $1`, [bob]);
  h.eq('free slot needs active Plus', await why(bb, true), 'not paid');
  await h.admin();
  await h.fails('one free slot per owner', `insert into bot_hosting (bot_id, owner_id, free_slot) values ($1, $2, true)`, [bc, bob]);
  await h.ok('a second, non-free row is fine', async () => { await h.q(`insert into bot_hosting (bot_id, owner_id) values ($1, $2)`, [bc, bob]); });
  await h.q(`insert into site_bans (user_id, reason) values ($1, 'test')`, [amy]);
  h.eq('banned owner', await why(ab), 'banned');
  await h.admin();
  await h.q(`delete from site_bans where user_id = $1`, [amy]);
  await h.q(`update bot_hosting set blocked = true, blocked_reason = 'spam' where bot_id = $1`, [ab]);
  h.eq('blocked', await why(ab), 'blocked');
  await h.admin();
  await h.q(`update bot_hosting set blocked = false, blocked_reason = null where bot_id = $1`, [ab]);

  // Clients: own row only, safe columns only, no writes, no service functions.
  await h.admin();
  await h.q(`update bot_hosting set host_token_hash = 'abc', host_token_prefix = 'yb_h', runner_id = 'hel1', want_running = true where bot_id = $1`, [ab]);
  await h.as(amy);
  h.eq('owner sees her row', (await h.q(`select bot_id, tier from bot_hosting`)).map((r) => r.bot_id), [ab]);
  await h.fails('token hash is not readable', `select host_token_hash from bot_hosting`);
  await h.fails('stripe ids are not readable', `select stripe_sub from bot_hosting`);
  await h.fails('select * is refused', `select * from bot_hosting`);
  await h.fails('no updates', `update bot_hosting set until = now() + interval '1 year' where bot_id = $1`, [ab]);
  await h.fails('no inserts', `insert into bot_hosting (bot_id, owner_id) values ($1, $2)`, [bb, amy]);
  await h.fails('no deletes', `delete from bot_hosting where bot_id = $1`, [ab]);
  await h.fails('no paid() for clients', `select bot_hosting_paid($1, $2, 'large', null, null, 3650)`, [ab, amy]);
  await h.fails('no renew() for clients', `select bot_hosting_renew('sub_2', 3650)`);
  await h.fails('no stop_reason() for clients', `select bot_hosting_stop_reason($1, true)`, [ab]);
  await h.fails('no apply_report() for clients', `select bot_hosting_apply_report('hel1', '[]'::jsonb, false)`);
  await h.fails('no hit() for clients', `select bot_hosting_hit($1, 'start', 10, 600)`, [ab]);
  await h.fails('no action log for clients', `select * from bot_hosting_actions`);
  await h.as(bob);
  h.eq('others see nothing of amy', (await h.q(`select bot_id from bot_hosting where bot_id = $1`, [ab])).length, 0);
  await h.as(null);
  await h.fails('anon reads nothing', `select bot_id from bot_hosting`);

  // Runner reports.
  await service();
  const rep = (runner, bots) => h.one(`select bot_hosting_apply_report($1, $2::jsonb, false) s`, [runner, JSON.stringify(bots)]);
  let s = await rep('hel1', [{ id: ab, status: 'running', crash_count: 2, oom_count: 1, started_at: '2026-10-17T10:00:00Z' }]);
  h.eq('a wanted, paid bot keeps running', s.s, []);
  await h.admin();
  h.eq('sweep keeps the token of a bot that may run', (await h.one(`select host_token_hash from bot_hosting where bot_id = $1`, [ab])).host_token_hash, 'abc');
  // Sweep: bob's unpaid bot on another runner loses its token when any runner reports.
  await h.q(`update bot_hosting set host_token_hash = 'xyz', host_token_prefix = 'yb_h', runner_id = 'fsn1', want_running = true where bot_id = $1`, [bc]);
  await service();
  h.eq('sweep does not add other runners\' bots to the stop list', (await rep('hel1', [])).s, []);
  await h.admin();
  h.eq('sweep: unpaid bot on another runner loses its token', await h.one(`select host_token_hash, host_token_prefix, want_running from bot_hosting where bot_id = $1`, [bc]),
    { host_token_hash: null, host_token_prefix: null, want_running: false });
  await service();
  await h.admin();
  h.eq('report stored', await h.one(`select status, crash_count, oom_count, started_at = '2026-10-17T10:00:00Z' ok from bot_hosting where bot_id = $1`, [ab]),
    { status: 'running', crash_count: 2, oom_count: 1, ok: true });
  await service();
  s = await rep('fsn1', [{ id: ab, status: 'crashed' }]);
  h.eq('another runner can not touch it and is told to stop it', s.s, [ab]);
  await h.admin();
  h.eq('status untouched by the other runner', (await h.one(`select status from bot_hosting where bot_id = $1`, [ab])).status, 'running');
  await service();
  s = await rep('hel1', [{ id: 'nope' }, { id: ab, status: 'evil', crash_count: 'x', started_at: '2026-99-99T00:00:00Z' }, { id: '00000000-0000-0000-0000-000000000000', status: 'running' }]);
  h.eq('junk ignored, unknown bot told to stop', s.s, ['00000000-0000-0000-0000-000000000000']);
  await h.admin();
  h.eq('bad values ignored', await h.one(`select status, crash_count from bot_hosting where bot_id = $1`, [ab]), { status: 'running', crash_count: 2 });
  await h.q(`update bot_hosting set want_running = false where bot_id = $1`, [ab]);
  await service();
  s = await rep('hel1', [{ id: ab, status: 'running' }]);
  h.eq('owner pressed Stop: told to stop', s.s, [ab]);
  await h.admin();
  h.eq('token kept on a plain stop', (await h.one(`select host_token_hash from bot_hosting where bot_id = $1`, [ab])).host_token_hash, 'abc');
  await h.q(`update bot_hosting set want_running = true, blocked = true where bot_id = $1`, [ab]);
  await service();
  s = await rep('hel1', [{ id: ab, status: 'running' }]);
  h.eq('blocked: told to stop', s.s, [ab]);
  await h.admin();
  h.eq('blocked: token cleared, not wanted', await h.one(`select host_token_hash, want_running from bot_hosting where bot_id = $1`, [ab]), { host_token_hash: null, want_running: false });

  // Rate limit.
  await service();
  for (let i = 0; i < 3; i++) h.eq(`hit ${i + 1} allowed`, (await h.one(`select bot_hosting_hit($1, 'start', 3, 600) ok`, [ab])).ok, true);
  h.eq('4th hit refused', (await h.one(`select bot_hosting_hit($1, 'start', 3, 600) ok`, [ab])).ok, false);
  h.eq('other actions counted apart', (await h.one(`select bot_hosting_hit($1, 'upload', 3, 600) ok`, [ab])).ok, true);

  // Deleting the bot removes its hosting row.
  await h.admin();
  await h.q(`delete from bots where id = $1`, [ab]);
  h.eq('cascade', (await h.q(`select 1 from bot_hosting where bot_id = $1`, [ab])).length, 0);
  await h.admin();
}
