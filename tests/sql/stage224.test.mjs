// 224: pinned DMs (per-account, private, capped, flag-gated writes) and the flag row.
// The stand-ins can't run every migration up to 222, so: 001..024, then flags (031), flag users (041), and 222 twice
// (it must be re-runnable).
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '224_dm_pins.sql', '224_dm_pins.sql'];

const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

export default async function (h) {
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');

  await h.admin();
  const flag = await h.one(`select mode, cardinality(users) u, cardinality(servers) s from feature_flags where key = 'pin_dms'`);
  h.eq('flag exists in test mode (Antic + his test server)', flag, { mode: 'test', u: 1, s: 1 });

  await h.as(amy);
  await h.fails('no writes while the flag is off for you', `insert into user_dm_pins (user_id, pins) values ($1, $2::uuid[])`, [amy, [id(1)]]);

  await h.admin();
  await h.q(`update feature_flags set users = array[$1]::uuid[] where key = 'pin_dms'`, [amy]);

  await h.as(amy);
  await h.ok('owner saves pins', async () => {
    await h.q(`insert into user_dm_pins (user_id, pins, updated_at) values ($1, $2::uuid[], '2000-01-01')`, [amy, [id(1), id(2)]]);
  });
  const row = await h.one(`select pins, updated_at > now() - interval '1 minute' fresh from user_dm_pins where user_id = $1`, [amy]);
  h.eq('saved as sent, in order', row.pins, [id(1), id(2)]);
  h.eq('updated_at comes from the server clock', row.fresh, true);
  await h.ok('owner updates (upsert)', async () => {
    await h.q(`insert into user_dm_pins (user_id, pins) values ($1, $2::uuid[]) on conflict (user_id) do update set pins = excluded.pins`, [amy, [id(3)]]);
  });
  h.eq('update applied', (await h.one(`select pins from user_dm_pins where user_id = $1`, [amy])).pins, [id(3)]);
  const many = Array.from({ length: 51 }, (_, i) => id(i + 10));
  await h.fails('max 50 pins', `update user_dm_pins set pins = $2::uuid[] where user_id = $1`, [amy, many]);
  await h.fails('no null', `update user_dm_pins set pins = null where user_id = $1`, [amy]);
  await h.fails('cannot write a row for someone else', `insert into user_dm_pins (user_id, pins) values ($1, '{}')`, [bob]);

  await h.as(bob);
  h.eq('others cannot read it', (await h.q(`select * from user_dm_pins`)).length, 0);
  await h.q(`update user_dm_pins set pins = '{}' where user_id = $1`, [amy]);
  await h.as(amy);
  h.eq('others cannot change it', (await h.one(`select cardinality(pins) n from user_dm_pins where user_id = $1`, [amy])).n, 1);
  await h.fails('no deletes through the API', `delete from user_dm_pins where user_id = $1`, [amy]);

  await h.admin();
  await h.q(`update feature_flags set users = '{}' where key = 'pin_dms'`);
  await h.as(amy);
  await h.fails('no changes once the flag is off again', `update user_dm_pins set pins = '{}' where user_id = $1 returning user_id`, [amy]);
  h.eq('reading still works with the flag off', (await h.one(`select cardinality(pins) n from user_dm_pins where user_id = $1`, [amy])).n, 1);

  await h.as(null);
  await h.fails('anon has no access', `select * from user_dm_pins`);
}
