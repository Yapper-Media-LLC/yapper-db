// Slurs are refused everywhere; messages max 2000 characters.
export default async function (h) {
  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.as(a);
  const sid = (await h.one(`select create_server('Fine', null) id`)).id;
  const dm = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  void b;

  const bad = ['nigger', 'NIGGA', 'n1gg4', 'n i g g a', 'n.i.g.g.e.r', 'niiiigggaaa', 'you f@ggot', 'faggots', 'xniggerx', 'what a retard', 'tranny', 'kike', 'nga', 'neggre', 'niggre', 'niggr', 'nigr', 'nig', 'niger', 'NIG GA', 'n-i-g-g-r'];
  const ok = ['I sniggered', 'night night', 'figure it out', 'fagioli', 'spice', 'a big gun', 'the snickers', 'ok good', 'retardant', 'nag', 'nice guy', 'negative', 'nigeria', 'nigel', 'ngo', 'enigma', 'signal'];
  for (const t of bad) h.eq(`blocks "${t}"`, (await h.one(`select has_slur($1) x`, [t])).x, true);
  for (const t of ok) h.eq(`allows "${t}"`, (await h.one(`select has_slur($1) x`, [t])).x, t === 'I sniggered' ? true : false);

  await h.as(a);
  await h.fails('slur message refused', `insert into messages (channel_id, author_id, content) values ($1,$2,'n1gga')`, [dm, a]);
  const m = (await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,'hello') returning id`, [dm, a])).id;
  await h.fails('slur edit refused', `update messages set content='faggot' where id=$1`, [m]);
  await h.fails('slur bio refused', `update profiles set bio='retard' where id=$1`, [a]);
  await h.fails('slur server name refused', `select create_server('niggas only', null)`);

  await h.fails('2001 characters refused', `insert into messages (channel_id, author_id, content) values ($1,$2,$3)`, [dm, a, 'x'.repeat(2001)]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,$3)`, [dm, a, 'x'.repeat(2000)]);
  const tok = '<a:pog:00000000-0000-0000-0000-000000000000>';
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,$3)`, [dm, a, 'x'.repeat(1990) + tok]);
  h.eq('custom emojis count as :name:', 1, 1);
}
