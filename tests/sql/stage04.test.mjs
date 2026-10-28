export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  await h.as(a);
  const dm = (await h.one(`select get_or_create_dm($1) id`, [b])).id;
  const m = (await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,'teh typo') returning id`, [dm, a])).id;

  await h.q(`update messages set content='the typo' where id=$1`, [m]);
  const row = await h.one(`select content, edited_at from messages where id=$1`, [m]);
  h.eq('edit saved', row.content, 'the typo');
  h.eq('edited stamp set', row.edited_at !== null, true);

  await h.q(`update messages set edited_at=null, created_at='2000-01-01' where id=$1`, [m]);
  const row2 = await h.one(`select edited_at, extract(year from created_at)::int y from messages where id=$1`, [m]);
  h.eq("can't hide edits or backdate", [row2.edited_at !== null, row2.y > 2000], [true, true]);

  await h.as(b);
  await h.q(`update messages set content='hacked' where id=$1`, [m]);
  await h.q(`delete from messages where id=$1`, [m]);
  h.eq("others can't edit or delete", (await h.one(`select content from messages where id=$1`, [m])).content, 'the typo');

  await h.as(a);
  await h.q(`delete from messages where id=$1`, [m]);
  h.eq('author can delete', (await h.q(`select id from messages where id=$1`, [m])).length, 0);
}
