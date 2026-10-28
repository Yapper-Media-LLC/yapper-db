// 381: stolen-art check for community decorations. Builds on 345 + 360 with the same stand-ins, plus media_scans
// (the first-frame hash the look-alike search uses).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage345.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
create table if not exists public.media_scans (bucket text not null, path text not null, phash bigint, primary key (bucket, path));
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(mig('345_community_decos.sql'));
  await h.db.exec(mig('360_artist_badge.sql'));
  const MIG = mig('381_deco_autocheck.sql');
  await h.db.exec(MIG);
  await h.ok('381 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'deco_autocheck'`)).mode, 'test');

  const art = await h.signup('art@test.dev', 'artist');
  const copier = await h.signup('copy@test.dev', 'copier');
  const mod = await h.signup('mod@test.dev', 'mod');
  const fan = await h.signup('fan@test.dev', 'fan');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.q(`update feature_flags set mode = 'everyone' where key = 'community_decos'`);
  const submit = async (who, name, path, phash) => {
    await h.admin();
    await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [path]);
    await h.q(`insert into media_scans (bucket, path, phash) values ('avatars', $1, $2) on conflict do nothing`, [path, phash]);
    await h.as(who);
    const { id } = await h.one(`select submit_community_deco('deco', $1, $2) id`, [name, path]);
    await h.admin();
    return id;
  };
  // A busy hash (about half the bits set), one 3 bits away, one far off, and a near-blank one.
  const H = '6148914691236517205'; // 0x5555555555555555
  const H3 = '6148914691236517202'; // 3 low bits flipped
  const FAR = '-6148914691236517206'; // the other half of the bits
  const BLANK = '1';
  const orig = await submit(art, 'Leaf crown', `${art}/a.png`, H);
  await h.q(`update community_decos set created_at = now() - interval '2 days' where id = $1`, [orig]);
  const own = await submit(art, 'Leaf crown 2', `${art}/b.png`, H3);
  const copy = await submit(copier, 'Totally mine', `${copier}/a.png`, H3);
  const other = await submit(copier, 'Something else', `${copier}/b.png`, FAR);
  const blank = await submit(fan, 'Empty', `${fan}/a.png`, BLANK);

  // ---------- look-alikes ----------
  let near = await h.q(`select id, bits from deco_lookalikes($1)`, [copy]);
  h.eq('a copy finds the earlier uploads by another artist, nearest first', near.map((r) => [r.id, r.bits]), [[own, 0], [orig, 3]]);
  h.eq('...never the same artist\'s own (a fixed re-upload)', (await h.q(`select id from deco_lookalikes($1)`, [own])).length, 0);
  h.eq('...never later ones (the original is the earlier one)', (await h.q(`select id from deco_lookalikes($1)`, [orig])).length, 0);
  h.eq('far off: nothing', (await h.q(`select id from deco_lookalikes($1)`, [other])).length, 0);
  h.eq('near-blank hash: skipped (it matches everything)', (await h.q(`select id from deco_lookalikes($1, 64)`, [blank])).length, 0);

  // ---------- claiming, the to-do list, spending ----------
  const todo = async () => (await h.q(`select id from deco_checks_todo(50)`)).map((r) => r.id);
  h.eq('unchecked ones are on the list, waiting first', (await todo()).includes(copy), true);
  h.eq('claim once', (await h.one(`select deco_check_claim($1, false) ok`, [copy])).ok, true);
  h.eq('...not twice', (await h.one(`select deco_check_claim($1, false) ok`, [copy])).ok, false);
  h.eq('a check in progress is off the list', (await todo()).includes(copy), false);
  await h.q(`update community_deco_checks set checked_at = now() - interval '7 hours' where deco_id = $1`, [copy]);
  h.eq('a failed check is tried again after 6 hours', (await h.one(`select deco_check_claim($1, true) ok`, [copy])).ok, true);
  await h.q(`update community_deco_checks set verdict = 'stolen', source = 'yapper_copy', confidence = 0.9, reason = 'Same leaves as Leaf crown',
    match_id = $2, cost_usd = 0.02, backfill = false where deco_id = $1`, [copy, orig]);
  h.eq('a finished one stays off the list', (await todo()).includes(copy), false);
  // Failing over and over stops after 3 tries (timeouts still cost money).
  await h.q(`select deco_check_claim($1, true)`, [blank]);
  for (let i = 0; i < 3; i++) {
    await h.q(`update community_deco_checks set checked_at = now() - interval '7 hours' where deco_id = $1`, [blank]);
    if (i < 2) await h.q(`select deco_check_claim($1, true)`, [blank]);
  }
  h.eq('3 tries: no 4th', (await h.one(`select deco_check_claim($1, true) ok`, [blank])).ok, false);
  h.eq('...and off the list', (await todo()).includes(blank), false);
  h.eq('...and can\'t be claimed again', (await h.one(`select deco_check_claim($1, false) ok`, [copy])).ok, false);
  await h.q(`select deco_check_claim($1, true)`, [other]);
  await h.q(`update community_deco_checks set verdict = 'clean', cost_usd = 0.03 where deco_id = $1`, [other]);
  const spend = await h.one(`select deco_check_spend() s`);
  h.eq('spend: new today, one-time pass, total', [Number(spend.s.day), Number(spend.s.backfill), Number(spend.s.total)], [0.02, 0.03, 0.05]);

  // ---------- an artist can't burn the day's checks (send in, withdraw, again) ----------
  const many = [];
  for (let i = 0; i < 9; i++) {
    const id = await submit(fan, `Spam ${i}`, `${fan}/s${i}.png`, H);
    many.push(id);
    if (i < 8) {
      await h.q(`select deco_check_claim($1, false)`, [id]);
      await h.as(fan); await h.q(`select withdraw_community_deco($1)`, [id]); await h.admin();
    }
  }
  h.eq('8 new checks today for one artist', (await h.one(`select deco_artist_checks_today($1) n`, [fan])).n, 8);
  h.eq('the 9th waits for tomorrow', (await h.one(`select deco_check_claim($1, false) ok`, [many[8]])).ok, false);
  h.eq('...and stays off the to-do list meanwhile', (await todo()).includes(many[8]), false);
  h.eq('other artists are unaffected', (await todo()).includes(own), true);

  // ---------- nobody else gets at the results or the server functions ----------
  await h.as(copier);
  await h.fails('artists can\'t read check results', `select * from community_deco_checks`);
  await h.fails('artists can\'t claim', `select deco_check_claim($1, false)`, [own]);
  await h.fails('artists can\'t search look-alikes', `select * from deco_lookalikes($1)`, [copy]);
  await h.fails('artists can\'t read spending', `select deco_check_spend()`);
  await h.fails('artists can\'t list flagged ones', `select * from staff_flagged_decos()`);
  await h.as(fan);
  await h.fails('non-staff can\'t clear a flag', `select staff_clear_deco_check($1, 'looks fine')`, [copy]);

  // ---------- staff ----------
  await h.as(mod);
  const flagged = await h.q(`select id, verdict, match_id, match_name, match_artist_id, status from staff_flagged_decos()`);
  h.eq('staff see the flagged one with what it copies', flagged.map((r) => [r.id, r.verdict, r.match_id, r.match_name, r.match_artist_id, r.status]),
    [[copy, 'stolen', orig, 'Leaf crown', art, 'pending']]);
  await h.fails('a flagged one can\'t be approved straight away', `select review_community_deco($1, 'approved')`, [copy]);
  await h.fails('clearing needs a reason', `select staff_clear_deco_check($1, 'ok')`, [copy]);
  await h.ok('clear with a reason', () => h.q(`select staff_clear_deco_check($1, 'Same artist, second account')`, [copy]));
  h.eq('cleared: off the flagged list', (await h.q(`select id from staff_flagged_decos()`)).length, 0);
  await h.ok('...and now it can be approved', () => h.q(`select review_community_deco($1, 'approved')`, [copy]));
  await h.admin();
  h.eq('the clearing is logged', (await h.q(`select reason from mod_log where action = 'deco_check_cleared'`)).map((r) => r.reason), ['Totally mine: Same artist, second account']);
  h.eq('who cleared it is kept', (await h.one(`select cleared_by from community_deco_checks where deco_id = $1`, [copy])).cleared_by, mod);

  // Turning down or taking down a flagged one works as before (no clearing needed).
  await h.q(`select deco_check_claim($1, false)`, [own]);
  await h.q(`update community_deco_checks set verdict = 'suspect', source = 'discord', confidence = 0.6 where deco_id = $1`, [own]);
  await h.as(mod);
  await h.ok('turning down a flagged one needs no clearing', () => h.q(`select review_community_deco($1, 'rejected', 'Copied from Discord or another app')`, [own]));
  h.eq('turned down: off the flagged list', (await h.q(`select id from staff_flagged_decos()`)).length, 0);
  await h.as(art);
  await h.fails('an artist can\'t clear their own', `select staff_clear_deco_check($1, 'it is mine')`, [orig]);

  // Deleting a decoration takes its check with it; a match that's gone just leaves no match.
  await h.admin();
  await h.q(`delete from community_decos where id = $1`, [orig]);
  h.eq('match gone: match_id cleared', (await h.one(`select match_id from community_deco_checks where deco_id = $1`, [copy])).match_id, null);
  await h.q(`delete from community_decos where id = $1`, [copy]);
  h.eq('deco gone: its check goes too', (await h.q(`select 1 from community_deco_checks where deco_id = $1`, [copy])).length, 0);
}
