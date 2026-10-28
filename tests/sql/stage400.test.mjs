// 400: flagged decorations that are still waiting get turned down automatically. Builds on 381's setup.
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
  await h.db.exec(mig('381_deco_autocheck.sql'));
  const MIG = mig('400_deco_autoreject.sql');
  await h.db.exec(MIG);
  await h.ok('400 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag seeded in test', (await h.one(`select mode from feature_flags where key = 'deco_autoreject'`)).mode, 'test');

  const art = await h.signup('art@test.dev', 'artist');
  const art2 = await h.signup('art2@test.dev', 'artist2');
  const tester = await h.signup('tester@test.dev', 'tester');
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'community_decos'`);
  await h.q(`update feature_flags set users = array[$1]::uuid[], servers = '{}' where key = 'deco_autoreject'`, [tester]);
  const submit = async (who, name, path) => {
    await h.admin();
    await h.q(`insert into media_ok_paths values ($1) on conflict do nothing`, [path]);
    await h.as(who);
    const { id } = await h.one(`select submit_community_deco('deco', $1, $2) id`, [name, path]);
    await h.admin();
    return id;
  };
  const flag = async (id, verdict, source) => {
    await h.q(`select deco_check_claim($1, false)`, [id]);
    await h.q(`update community_deco_checks set verdict = $2, source = $3, confidence = 0.8 where deco_id = $1`, [id, verdict, source]);
  };
  const reject = async (id) => (await h.one(`select deco_check_autoreject($1) ok`, [id])).ok;
  const status = async (id) => (await h.one(`select status, review_note from community_decos where id = $1`, [id]));

  // ---------- test mode: only artists in the test group ----------
  const outside = await submit(art, 'Nitro ring', `${art}/a.png`);
  await flag(outside, 'stolen', 'discord');
  h.eq('test mode: someone outside the test group is left alone', await reject(outside), false);
  h.eq('...still waiting', (await status(outside)).status, 'pending');

  const inside = await submit(tester, 'Nitro ring', `${tester}/a.png`);
  await flag(inside, 'stolen', 'discord');
  h.eq('test mode: tester\'s flagged one is turned down', await reject(inside), true);
  h.eq('...with the Discord reason', await status(inside),
    { status: 'rejected', review_note: 'Looks like this was taken from Discord\'s shop. Only send in art you made yourself.' });
  h.eq('...logged with no actor', (await h.q(`select actor, reason from mod_log where action = 'deco_rejected'`)),
    [{ actor: null, reason: 'Auto: Nitro ring: Looks like this was taken from Discord\'s shop. Only send in art you made yourself.' }]);
  h.eq('turning it down twice does nothing', await reject(inside), false);

  // ---------- everyone ----------
  await h.q(`update feature_flags set mode = 'everyone' where key = 'deco_autoreject'`);
  h.eq('on for everyone: the outside one goes too', await reject(outside), true);
  const sus = await submit(art, 'Pika frame', `${art}/b.png`);
  await flag(sus, 'suspect', 'character_or_brand');
  h.eq('suspect ones too', await reject(sus), true);
  h.eq('...character reason', (await status(sus)).review_note, 'Uses a character or brand you don\'t own. Only send in your own original art.');
  h.eq('unknown source: the general reason', (await h.one(`select deco_autoreject_note('other') n`)).n,
    'Our check thinks this isn\'t your own art. Only send in art you made yourself.');

  const clean = await submit(art, 'My stars', `${art}/c.png`);
  await flag(clean, 'clean', 'none');
  h.eq('clean ones stay', await reject(clean), false);
  const err = await submit(art, 'Timed out', `${art}/d.png`);
  await h.q(`select deco_check_claim($1, false)`, [err]);
  h.eq('a failed check stays', await reject(err), false);
  const unchecked = await submit(art, 'Not yet', `${art}/e.png`);
  h.eq('unchecked ones stay', await reject(unchecked), false);

  const cleared = await submit(art2, 'Cleared', `${art2}/f.png`);
  await flag(cleared, 'stolen', 'internet');
  await h.q(`update community_deco_checks set cleared_at = now(), cleared_note = 'mine' where deco_id = $1`, [cleared]);
  h.eq('one staff cleared stays', await reject(cleared), false);

  const live = await submit(art2, 'Live one', `${art2}/g.png`);
  await h.q(`update community_decos set status = 'approved' where id = $1`, [live]);
  await flag(live, 'stolen', 'internet');
  h.eq('live ones are left for staff', await reject(live), false);
  h.eq('...still live', (await status(live)).status, 'approved');

  await h.q(`update feature_flags set mode = 'off' where key = 'deco_autoreject'`);
  const off = await submit(art2, 'Off', `${art2}/h.png`);
  await flag(off, 'stolen', 'other_app');
  h.eq('flag off: nothing happens', await reject(off), false);

  // ---------- nobody else can call it ----------
  await h.as(art);
  await h.fails('artists can\'t call it', `select deco_check_autoreject($1)`, [off]);
}
