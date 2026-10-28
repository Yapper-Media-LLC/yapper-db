// 153: server folders (per-account, private, shape-checked, flag-gated writes) and the two flag rows.
// The stand-ins can't run every migration up to 153, so: 001..024, then flags (031), flag users (041), and 153.
export const base = 24;
// 153 twice: it must be re-runnable.
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '154_server_folders.sql', '154_server_folders.sql'];

export default async function (h) {
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.as(amy);
  const hq = (await h.one(`select create_server('Folders HQ', null) id`)).id;
  const s2 = (await h.one(`select create_server('Second', null) id`)).id;
  const s3 = (await h.one(`select create_server('Third', null) id`)).id;

  await h.admin();
  const flags = await h.q(`select key, mode, servers from feature_flags where key in ('server_folders', 'banner_collapse') order by key`);
  h.eq('both flags exist in test mode with no servers', flags, [
    { key: 'banner_collapse', mode: 'test', servers: [] },
    { key: 'server_folders', mode: 'test', servers: [] },
  ]);

  const good = JSON.stringify([{ id: 'fa1', name: 'Games', color: '#5865f2', servers: [hq, s2] }]);

  // Flag still off for amy (no test servers): she can't write.
  await h.as(amy);
  await h.fails('no writes while the flag is off for you', `insert into user_server_folders (user_id, folders) values ($1, $2::jsonb)`, [amy, good]);

  await h.admin();
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'server_folders'`, [hq]);

  await h.as(amy);
  await h.ok('owner saves folders', async () => {
    await h.q(`insert into user_server_folders (user_id, folders, updated_at) values ($1, $2::jsonb, '2000-01-01')`, [amy, good]);
  });
  const row = await h.one(`select folders, updated_at > now() - interval '1 minute' fresh from user_server_folders where user_id = $1`, [amy]);
  h.eq('saved as sent', row.folders, JSON.parse(good));
  h.eq('updated_at comes from the server clock', row.fresh, true);

  await h.ok('owner updates (upsert)', async () => {
    await h.q(`insert into user_server_folders (user_id, folders) values ($1, $2::jsonb)
               on conflict (user_id) do update set folders = excluded.folders`,
      [amy, JSON.stringify([{ id: 'fa1', name: null, color: null, servers: [s2, s3] }])]);
  });
  h.eq('update applied', (await h.one(`select folders->0->'servers' s from user_server_folders where user_id = $1`, [amy])).s, [s2, s3]);

  await h.fails('cannot write a row for someone else', `insert into user_server_folders (user_id, folders) values ($1, '[]')`, [bob]);

  // Shape checks.
  const tooMany = JSON.stringify(Array.from({ length: 51 }, (_, i) => ({ id: `f${i}`, servers: [hq] })));
  await h.fails('max 50 folders', `update user_server_folders set folders = $2::jsonb where user_id = $1`, [amy, tooMany]);
  const fifty = JSON.stringify(Array.from({ length: 50 }, (_, i) => ({ id: `f${i}`, servers: [`00000000-0000-0000-0000-${String(i).padStart(12, '0')}`] })));
  await h.ok('50 folders is fine', async () => { await h.q(`update user_server_folders set folders = $2::jsonb where user_id = $1`, [amy, fifty]); });
  await h.fails('name max 32 chars', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', name: 'x'.repeat(33), servers: [hq] }])]);
  await h.ok('name of 32 chars is fine', async () => {
    await h.q(`update user_server_folders set folders = $2::jsonb where user_id = $1`, [amy, JSON.stringify([{ id: 'a', name: 'x'.repeat(32), servers: [hq] }])]);
  });
  await h.fails('colour must be #rrggbb', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', color: 'red; background:url(x)', servers: [hq] }])]);
  await h.fails('no extra keys', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', servers: [hq], html: '<b>' }])]);
  await h.fails('server ids must be uuids', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', servers: ['nope'] }])]);
  await h.fails('a server sits in one folder only', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', servers: [hq] }, { id: 'b', servers: [hq, s2] }])]);
  await h.fails('folder ids are unique', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', servers: [hq] }, { id: 'a', servers: [s2] }])]);
  await h.fails('no empty folders', `update user_server_folders set folders = $2::jsonb where user_id = $1`,
    [amy, JSON.stringify([{ id: 'a', servers: [] }])]);
  await h.fails('must be an array', `update user_server_folders set folders = '{}'::jsonb where user_id = $1`, [amy]);
  await h.fails('no null', `update user_server_folders set folders = null where user_id = $1`, [amy]);

  // Privacy: nobody else sees or changes it.
  await h.as(bob);
  h.eq('others cannot read it', (await h.q(`select * from user_server_folders`)).length, 0);
  await h.q(`update user_server_folders set folders = '[]' where user_id = $1`, [amy]);
  await h.as(amy);
  h.eq('others cannot change it', (await h.one(`select jsonb_array_length(folders) n from user_server_folders where user_id = $1`, [amy])).n, 1);
  await h.fails('no deletes through the API', `delete from user_server_folders where user_id = $1`, [amy]);
  await h.as(null);
  await h.fails('anon has no access', `select * from user_server_folders`);
}
