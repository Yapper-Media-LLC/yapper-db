// Links to porn / hentai sites are refused.
export default async function (h) {
  const a = await h.signup('a@test.dev', 'alice');
  await h.as(a);
  const sid = (await h.one(`select create_server('Fine', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;

  const bad = ['https://pornhub.com/view?x=1', 'www.xvideos.com', 'nhentai.net/g/123', 'check https://www.rule34.xxx/index.php',
    'PORNHUB.COM lol', 'cdn.pornhub.com/x', 'reddit.com/r/hentai/top', 'https://e621.net'];
  const ok = ['https://youtube.com/watch?v=1', 'yapper.website/invite/abc', 'reddit.com/r/gaming', 'hello.world', 'notpornhub.com', 'e6210.net'];
  for (const t of bad) h.eq(`blocks ${t}`, (await h.one(`select has_adult_link($1) x`, [t])).x, true);
  for (const t of ok) h.eq(`allows ${t}`, (await h.one(`select has_adult_link($1) x`, [t])).x, false);

  await h.fails('adult link message refused', `insert into messages (channel_id, author_id, content) values ($1,$2,'look pornhub.com')`, [gen, a]);
  await h.fails('adult link bio refused', `update profiles set bio='onlyfans.com/me' where id=$1`, [a]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'look youtube.com')`, [gen, a]);
  h.eq("admin list isn't public", (await h.q(`select * from blocked_domains`)).length, 0);
}
