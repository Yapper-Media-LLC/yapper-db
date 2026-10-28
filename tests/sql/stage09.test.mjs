export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  const c = await h.signup('carol@test.dev', 'carol');
  await h.as(a);
  await h.q(`select send_friend_request('bob')`);
  await h.q(`select send_friend_request('carol')`);
  await h.as(b); await h.q(`select respond_friend_request($1, true)`, [a]);
  await h.as(c); await h.q(`select respond_friend_request($1, true)`, [a]);

  await h.as(a);
  const dmAB = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  const dmAC = (await h.one(`select get_or_create_dm($1) id`, [c])).id;
  const m1 = (await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,'pizza tonight?') returning id`, [dmAB, a])).id;
  const other = (await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,'secret') returning id`, [dmAC, a])).id;

  await h.as(b);
  const r1 = (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1,$2,'yes',$3) returning reply_to_id`, [dmAB, b, m1])).reply_to_id;
  h.eq('reply saved', r1, m1);
  const r2 = (await h.one(`insert into messages (channel_id, author_id, content, reply_to_id) values ($1,$2,'sneaky',$3) returning reply_to_id`, [dmAB, b, other])).reply_to_id;
  h.eq('cross-chat reply dropped', r2, null);

  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1,$2,'👍')`, [m1, b]);
  await h.fails('no duplicate reaction', `insert into reactions (message_id, user_id, emoji) values ($1,$2,'👍')`, [m1, b]);
  await h.fails('cannot react as someone else', `insert into reactions (message_id, user_id, emoji) values ($1,$2,'🔥')`, [m1, a]);
  await h.fails("cannot react in chats you're not in", `insert into reactions (message_id, user_id, emoji) values ($1,$2,'👀')`, [other, b]);

  await h.as(a);
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1,$2,'👍')`, [m1, a]);
  h.eq('two likes', (await h.one(`select count(*)::int n from reactions where message_id=$1`, [m1])).n, 2);
  await h.q(`delete from reactions where message_id=$1`, [m1]);
  h.eq("deleting only removes your own", (await h.one(`select count(*)::int n from reactions where message_id=$1`, [m1])).n, 1);

  await h.as(c);
  h.eq("outsiders can't see reactions", (await h.q(`select id from reactions`)).length, 0);

  await h.as(b);
  for (let i = 0; i < 19; i++) {
    await h.q(`insert into reactions (message_id, user_id, emoji) values ($1,$2,$3)`, [m1, b, `e${i}`]);
  }
  await h.fails('20 different emojis max', `insert into reactions (message_id, user_id, emoji) values ($1,$2,'one-more')`, [m1, b]);

  await h.as(a);
  await h.q(`delete from messages where id=$1`, [m1]);
  h.eq('reactions removed with message', (await h.one(`select count(*)::int n from reactions`)).n, 0);
  await h.as(b);
  h.eq('reply survives original deletion', (await h.q(`select reply_to_id from messages where content='yes'`))[0].reply_to_id, null);
}
