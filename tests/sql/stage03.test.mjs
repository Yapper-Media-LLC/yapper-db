export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');

  await h.as(a);
  await h.q(`insert into emojis (owner_id, name, path, animated) values ($1, 'rat', $2, false)`, [a, `${a}/rat.png`]);
  await h.q(`insert into emojis (owner_id, name, path, animated) values ($1, 'ratdance', $2, true)`, [a, `${a}/rat.gif`]);
  await h.fails('duplicate name for same owner', `insert into emojis (owner_id, name, path) values ($1, 'RAT', $2)`, [a, `${a}/x.png`]);
  await h.fails('bad emoji name', `insert into emojis (owner_id, name, path) values ($1, 'r a t', $2)`, [a, `${a}/x.png`]);
  await h.fails('path must be own folder', `insert into emojis (owner_id, name, path) values ($1, 'cat', $2)`, [a, `${b}/x.png`]);
  await h.fails('cannot add as someone else', `insert into emojis (owner_id, name, path) values ($1, 'cat', $2)`, [b, `${b}/x.png`]);

  await h.as(b);
  h.eq('others can see emojis', (await h.q(`select name from emojis order by name`)).map((r) => r.name), ['rat', 'ratdance']);
  await h.q(`insert into emojis (owner_id, name, path) values ($1, 'rat', $2)`, [b, `${b}/rat.png`]);
  h.eq('same name allowed for different owners', (await h.q(`select id from emojis`)).length, 3);
  await h.q(`delete from emojis where owner_id = $1`, [a]);
  h.eq("can't delete others' emojis", (await h.q(`select id from emojis where owner_id=$1`, [a])).length, 2);

  await h.as(a);
  await h.admin();
  for (let i = 0; i < 98; i++) {
    await h.q(`insert into emojis (owner_id, name, path) values ($1, $2, $3)`, [a, `e${i}`, `${a}/e${i}.png`]);
  }
  await h.fails('100 emoji limit', `insert into emojis (owner_id, name, path) values ($1, 'one_more', $2)`, [a, `${a}/x.png`]);
}
