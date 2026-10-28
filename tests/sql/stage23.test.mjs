// unread_counts reports how many unread messages mention you.
export default async function (h) {
  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.as(a);
  const sid = (await h.one(`select create_server('S', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('ment1234', $1, $2)`, [sid, a]);
  await h.as(b); await h.q(`select join_server('ment1234')`);
  await h.as(a);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hello')`, [gen, a]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,$3)`, [gen, a, `hey <@${b}> look`]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'@everyone party')`, [gen, a]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'mail me@everyone.com')`, [gen, a]);
  await h.as(b);
  const r = (await h.q(`select * from unread_counts_v2() where channel_id=$1`, [gen]))[0];
  h.eq('unread counts everything', r.unread, 4);
  h.eq('mentions count direct + @everyone only', r.mentions, 2);
  await h.q(`select mark_read($1)`, [gen]);
  const r2 = (await h.q(`select * from unread_counts_v2() where channel_id=$1`, [gen]))[0];
  h.eq('cleared after reading', [r2.unread, r2.mentions], [0, 0]);
}
