export default async function (h) {
  const owner = await h.signup('owner@test.dev', 'owner');
  const member = await h.signup('member@test.dev', 'member');
  const outsider = await h.signup('out@test.dev', 'outsider');

  await h.as(owner);
  const sid = (await h.one(`select create_server('Yapper Corporation', null) id`)).id;
  h.eq('new servers get a voice channel', (await h.q(`select kind, name from channels where server_id=$1 order by position`, [sid])),
    [{ kind: 'text', name: 'general' }, { kind: 'voice', name: 'General' }]);
  const lounge = (await h.one(`select create_channel($1, '  Gaming   Lounge ', 'voice') id`, [sid])).id;
  h.eq('voice names keep spaces', (await h.one(`select name from channels where id=$1`, [lounge])).name, 'Gaming Lounge');
  await h.fails('no voice channels outside servers', `select create_channel($1, 'x', 'stage')`, [sid]);
  await h.q(`insert into invites (code, server_id, created_by) values ('voice123', $1, $2)`, [sid, owner]);

  // The token route checks access by selecting the channel as the user.
  await h.as(member);
  h.eq('non-member cannot see voice channel', (await h.q(`select id from channels where id=$1 and kind='voice'`, [lounge])).length, 0);
  await h.q(`select join_server('voice123')`);
  h.eq('member can see voice channel', (await h.q(`select id from channels where id=$1 and kind='voice'`, [lounge])).length, 1);
  await h.fails("member can't create voice channels", `select create_channel($1, 'mine', 'voice')`, [sid]);
  h.eq('voice channels have no unread counts', (await h.q(`select channel_id from unread_counts()`)).length, 1);

  await h.as(outsider);
  h.eq('outsider cannot see it', (await h.q(`select id from channels where id=$1`, [lounge])).length, 0);
}
