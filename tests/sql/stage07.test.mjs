export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  const c = await h.signup('carol@test.dev', 'carol');

  await h.as(a);
  await h.fails('no DM before friends', `select get_or_create_dm($1)`, [b]);
  h.eq('request sent', (await h.one(`select send_friend_request('BOB') r`)).r, 'sent');
  await h.fails('no duplicate requests', `select send_friend_request('bob')`);
  await h.fails("can't friend yourself", `select send_friend_request('alice')`);
  await h.fails('unknown user', `select send_friend_request('nobody')`);
  await h.fails('no direct inserts', `insert into friendships (requester, addressee, status) values ($1,$2,'accepted')`, [a, c]);

  await h.as(b);
  h.eq('bob sees incoming', (await h.q(`select status from friendships`)).map((r) => r.status), ['pending']);
  await h.as(c);
  h.eq("carol can't see it", (await h.q(`select id from friendships`)).length, 0);

  await h.as(b);
  await h.q(`select respond_friend_request($1, true)`, [a]);
  await h.as(a);
  h.eq('now friends', (await h.one(`select status from friendships`)).status, 'accepted');
  const dm = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hey friend')`, [dm, a]);

  // Requests both ways = accept
  await h.as(c);
  await h.q(`select send_friend_request('alice')`);
  await h.as(a);
  h.eq('mutual request accepts', (await h.one(`select send_friend_request('carol') r`)).r, 'accepted');

  // Block
  await h.as(b);
  await h.q(`select block_user($1)`, [a]);
  h.eq('block removes friendship', (await h.q(`select id from friendships`)).length, 0);
  await h.fails('blocked user cannot message', `insert into messages (channel_id, author_id, content) values ($1,$2,'hi?')`, [dm, b]);
  await h.as(a);
  await h.fails('blocked person cannot message back', `insert into messages (channel_id, author_id, content) values ($1,$2,'hello?')`, [dm, a]);
  await h.fails('blocked person cannot re-request', `select send_friend_request('bob')`);
  h.eq('old chat still readable', (await h.q(`select id from messages where channel_id=$1`, [dm])).length, 1);
  h.eq("alice can't see bob's block list", (await h.q(`select id from blocks`)).length, 0);

  await h.as(b);
  h.eq('bob sees his block', (await h.q(`select blocked from blocks`)).map((r) => r.blocked), [a]);
  await h.q(`select unblock_user($1)`, [a]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'ok fine')`, [dm, b]);
  h.eq('unblock restores messaging', (await h.q(`select id from messages where channel_id=$1`, [dm])).length, 2);
  h.eq('existing DM reopens without friendship', (await h.one(`select get_or_create_dm($1) id`, [a])).id, dm);

  await h.as(a);
  await h.q(`select remove_friend($1)`, [c]);
  h.eq('remove friend', (await h.q(`select id from friendships`)).length, 0);
}
