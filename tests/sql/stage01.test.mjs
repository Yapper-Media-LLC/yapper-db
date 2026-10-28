export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'Bob');
  const c = await h.signup('carol@test.dev', 'alice'); // taken -> alice1
  const d = await h.signup('d!@test.dev', ''); // falls back to email -> "d" too short -> yapper

  await h.as(a);
  h.eq('username fallback numbering', (await h.one(`select username from profiles where id=$1`, [c])).username, 'alice1');
  h.eq('short name fallback', (await h.one(`select username from profiles where id=$1`, [d])).username, 'yapper');
  h.eq('username_taken is case-insensitive', (await h.one(`select username_taken('BOB') t`)).t, true);

  const dm = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  const dm2 = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  h.eq('DM is reused', dm2, dm);
  await h.fails('cannot DM yourself', `select get_or_create_dm($1)`, [a]);

  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hi bob')`, [dm, a]);
  await h.fails('cannot send as someone else', `insert into messages (channel_id, author_id, content) values ($1,$2,'fake')`, [dm, b]);
  await h.fails('empty message rejected', `insert into messages (channel_id, author_id, content) values ($1,$2,'')`, [dm, a]);

  await h.as(b);
  h.eq('bob sees the DM', (await h.q(`select id from channels`)).length, 1);
  h.eq('bob reads the message', (await h.q(`select content from messages`)).map((r) => r.content), ['hi bob']);
  const reverse = (await h.one(`select get_or_create_dm($1) id`, [a])).id;
  h.eq('same DM from the other side', reverse, dm);

  await h.as(c);
  h.eq('outsider sees no channels', (await h.q(`select id from channels`)).length, 0);
  h.eq('outsider sees no messages', (await h.q(`select id from messages`)).length, 0);
  await h.fails('outsider cannot post', `insert into messages (channel_id, author_id, content) values ($1,$2,'sneaky')`, [dm, c]);
  await h.q(`update profiles set username='hacked' where id=$1`, [a]);
  await h.as(a);
  h.eq("can't rename others", (await h.one(`select username from profiles where id=$1`, [a])).username, 'alice');

  await h.as(null);
  h.eq('signed-out users see no profiles', (await h.q(`select id from profiles`)).length, 0);
}
