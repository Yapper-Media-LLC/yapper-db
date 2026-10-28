async function befriend(h, x, y, yName) {
  await h.as(x);
  await h.q(`select send_friend_request($1)`, [yName]);
  await h.as(y);
  await h.q(`select respond_friend_request($1, true)`, [x]);
}

export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  const c = await h.signup('carol@test.dev', 'carol');
  const d = await h.signup('dave@test.dev', 'dave');
  await befriend(h, a, b, 'bob');
  await befriend(h, a, c, 'carol');

  await h.as(a);
  await h.fails('only friends can be added', `select create_group('HQ', null, $1)`, [[b, d]]);
  await h.fails('icon must be own upload', `select create_group('HQ', $1, $2)`, [`${b}/x.png`, [b, c]]);
  const g = (await h.one(`select create_group('Yapper HQ', $1, $2) id`, [`${a}/hq.png`, [b, c]])).id;
  h.eq('3 members', (await h.q(`select user_id from channel_members where channel_id=$1`, [g])).length, 3);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'welcome to HQ')`, [g, a]);

  await h.as(b);
  h.eq('bob sees group message', (await h.q(`select content from messages where channel_id=$1`, [g])).map((r) => r.content), ['welcome to HQ']);
  await h.q(`select update_group($1, 'Yapper Corp', $2)`, [g, `${a}/hq.png`]);
  h.eq('member can rename (keeping icon)', (await h.one(`select name, icon_path from channels where id=$1`, [g])), { name: 'Yapper Corp', icon_path: `${a}/hq.png` });
  await h.fails("bob can't add dave (not his friend)", `select add_group_members($1, $2)`, [g, [d]]);
  await h.q(`update channels set name='direct edit' where id=$1`, [g]);
  h.eq('no direct channel updates', (await h.one(`select name from channels where id=$1`, [g])).name, 'Yapper Corp');

  await h.as(d);
  h.eq('outsider sees nothing', (await h.q(`select id from channels where id=$1`, [g])).length, 0);
  await h.fails('outsider cannot rename', `select update_group($1, 'pwned', null)`, [g]);

  await h.as(c);
  await h.q(`select leave_group($1)`, [g]);
  h.eq('carol left', (await h.q(`select id from channels where id=$1`, [g])).length, 0);
  await h.as(a);
  h.eq('2 members remain', (await h.q(`select user_id from channel_members where channel_id=$1`, [g])).length, 2);
  await h.q(`select add_group_members($1, $2)`, [g, [c]]);
  h.eq('carol re-added', (await h.q(`select user_id from channel_members where channel_id=$1`, [g])).length, 3);

  await h.q(`select leave_group($1)`, [g]);
  await h.as(b); await h.q(`select leave_group($1)`, [g]);
  await h.as(c); await h.q(`select leave_group($1)`, [g]);
  await h.admin();
  h.eq('empty group is deleted', (await h.q(`select id from channels where id=$1`, [g])).length, 0);
}
