// Reporting a person attaches their recent messages as evidence.
export default async function (h) {
  const admin = await h.signup('admin@test.dev', 'admin');
  const troll = await h.signup('troll@test.dev', 'troll');
  const kid = await h.signup('kid@test.dev', 'kid');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.as(kid);
  const sid = (await h.one(`select create_server('Hangout', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('hang1234', $1, $2)`, [sid, kid]);
  await h.as(troll);
  await h.q(`select join_server('hang1234')`);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'one')`, [gen, troll]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'two')`, [gen, troll]);
  const priv = (await h.one(`select create_server('Secret', null) id`)).id;
  const pgen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [priv])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hidden')`, [pgen, troll]);

  await h.as(kid);
  await h.q(`select report_user($1, 'harassment', 'look at them')`, [troll]);
  await h.as(admin);
  const r = (await h.q(`select evidence from reports`))[0];
  h.eq('recent visible messages attached, newest first', r.evidence.map((e) => e.content), ['two', 'one']);
}
