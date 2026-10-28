export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  const c = await h.signup('carol@test.dev', 'carol');
  await h.as(a);
  const dm = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'one'),($1,$2,'two'),($1,$2,'three')`, [dm, a]);

  await h.as(b);
  let rows = await h.q(`select * from unread_counts()`);
  h.eq('bob has 3 unread', rows.map((r) => [r.unread, r.muted]), [[3, false]]);
  await h.as(a);
  h.eq("own messages don't count", (await h.one(`select unread from unread_counts()`)).unread, 0);

  await h.as(b);
  await h.q(`select mark_read($1)`, [dm]);
  h.eq('read clears count', (await h.one(`select unread from unread_counts()`)).unread, 0);
  await h.q(`select set_muted($1, true)`, [dm]);
  h.eq('muted saved', (await h.one(`select muted from unread_counts()`)).muted, true);

  await h.as(c);
  await h.fails("can't mute a chat you're not in", `select set_muted($1, true)`, [dm]);
  await h.q(`select mark_read($1)`, [dm]);
  h.eq('outsider mark_read is a no-op', (await h.q(`select * from channel_reads`)).length, 0);
  await h.fails("can't insert read state for others' chats",
    `insert into channel_reads (user_id, channel_id) values ($1, $2)`, [c, dm]);
}
