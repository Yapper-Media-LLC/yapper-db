// 613: staff applications round two (no account age minimum, 18+, longer form in answers). Same base and stand-ins
// as stage589, then 589 and 613 on top.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const WHY = 'I am on every day and I keep seeing spam slip through in the big servers.';
const ANS = {
  hours_week: '4-7', languages: 'English, Nepali',
  scenario_raid: 'Lock the channels, delete the gore, ban the raiders, then tell the owner.',
  scenario_friend: 'Same rules for everyone, I would warn them like anyone else.',
  scenario_grey: 'Look at context first, maybe a friendly nudge, no punishment.',
  scenario_minor: 'Remove it right away, ban, and send it to an admin for the report.',
  scenario_appeal: 'Point them to the appeal form, I do not decide bans in DMs.',
  scenario_mistake: 'Undo it, apologise, and tell the other mods what happened.',
  good_mod: 'Fair, calm, and the same rules for everyone, friends included.',
  extra: 'I also make bots.', sneaky: 'dropped',
};

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('589_staff_applications.sql'));
  await h.db.exec(mig('613_staff_apply_v2.sql'));
  await h.ok('613 re-runs cleanly', () => h.db.exec(mig('613_staff_apply_v2.sql')));

  const head = await h.signup('head613@test.dev', 'head613');
  const kid = await h.signup('kid613@test.dev', 'kid613');
  const ann = await h.signup('ann613@test.dev', 'ann613');
  await h.q(`insert into site_moderators (user_id, head) values ($1, true)`, [head]);
  const SID = '00000000-0000-4000-8000-00000000b001';
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'Test', $2)`, [SID, head]);
  await h.q(`insert into server_members (server_id, user_id) select $1, unnest($2::uuid[]) on conflict do nothing`, [SID, [head, kid, ann]]);
  await h.q(`update feature_flags set mode = 'test', servers = $1 where key = 'staff_applications'`, [[SID]]);

  const apply = (adult, ans) => h.q(`select apply_for_staff($1, 'CET, evenings', '', true, $2, $3::jsonb)`, [WHY, adult, JSON.stringify(ans)]);

  // A brand new account may apply now.
  await h.as(kid);
  h.eq('new account is not blocked', (await h.one(`select my_staff_application() j`)).j.block, null);

  // Form checks.
  await h.as(ann);
  await h.fails('must be 18+', `select apply_for_staff($1, 'UTC', '', true, false, $2::jsonb)`, [WHY, JSON.stringify(ANS)]);
  await h.fails('old 4 argument call still needs 18+', `select apply_for_staff($1, 'UTC', '', true)`, [WHY]);
  await h.fails('hours a week must be one of the choices', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, hours_week: '100' })]);
  await h.fails('languages needed', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, languages: ' ' })]);
  await h.fails('scenario too short', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, scenario_friend: 'ban' })]);
  await h.fails('good mod answer missing', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, good_mod: '' })]);
  await h.fails('new situation missing', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, scenario_minor: 'no' })]);
  await h.fails('scenario missing', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify({ ...ANS, scenario_grey: undefined })]);
  await h.fails('answers must be an object', `select apply_for_staff($1, 'UTC', '', true, true, '[1]'::jsonb)`, [WHY]);

  await h.as(kid);
  await h.ok('new account applies with the full form', () => apply(true, ANS));
  await h.admin();
  const row = await h.one(`select adult, answers from staff_applications where user_id = $1`, [kid]);
  h.eq('18+ stored', row.adult, true);
  h.eq('unknown keys dropped', row.answers.sneaky, undefined);
  h.eq('answers stored', row.answers.languages, 'English, Nepali');

  // Reviewers see the answers; others can't list.
  await h.as(ann);
  await h.fails('member cannot list', `select * from staff_applications_list()`);
  await h.as(head);
  const list = await h.q(`select * from staff_applications_list()`);
  h.eq('head mod sees it', list.length, 1);
  h.eq('with the answers', list[0].answers.scenario_raid, ANS.scenario_raid);
  h.eq('and the 18+ flag', list[0].adult, true);

  // Decline wait still holds.
  const id = list[0].id;
  await h.ok('head mod declines', () => h.q(`select decide_staff_application($1, false, 'not yet')`, [id]));
  await h.as(kid);
  await h.fails('30 days after a decline', `select apply_for_staff($1, 'UTC', '', true, true, $2::jsonb)`, [WHY, JSON.stringify(ANS)]);

  await h.as(null);
  await h.fails('anon cannot apply', `select apply_for_staff($1, 'UTC', '', true, true, '{}'::jsonb)`, [WHY]);
}
