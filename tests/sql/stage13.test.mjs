// New accounts join the community server; kicking removes the kicked person's invites.
export default async function (h) {
  const owner = await h.signup('hq@test.dev', 'boss');
  await h.as(owner);
  const sid = (await h.one(`select create_server('Yapper Headquarters', null) id`)).id;
  await h.admin();
  await h.q(`update app_settings set default_server_id = $1`, [sid]);
  await h.as(owner);
  h.eq('nobody can read app settings', (await h.q(`select * from app_settings`)).length, 0);
  await h.admin();

  const newbie = await h.signup('new@test.dev', 'newbie');
  await h.as(newbie);
  h.eq('new account is in HQ', (await h.q(`select id from servers where id=$1`, [sid])).length, 1);
  await h.q(`insert into invites (code, server_id, created_by) values ('mine1234', $1, $2)`, [sid, newbie]);

  await h.as(owner);
  await h.q(`select kick_member($1, $2)`, [sid, newbie]);
  await h.admin();
  h.eq("kicked person's invites are gone", (await h.q(`select code from invites where created_by=$1`, [newbie])).length, 0);
}
