// Raid protection: throwaway emails, new-account wait, @everyone, rapid fire.
export default async function (h) {
  const boss = await h.signup('boss@test.dev', 'boss');
  await h.as(boss);
  const hq = (await h.one(`select create_server('HQ', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [hq])).id;
  await h.admin();
  await h.q(`update app_settings set default_server_id = $1`, [hq]);

  await h.fails('throwaway email refused', `insert into auth.users (id, email) values (gen_random_uuid(), 'x@duckmail.sbs')`);
  await h.fails('any listed domain refused', `insert into auth.users (id, email) values (gen_random_uuid(), 'x@MAILINATOR.com')`);

  const newbie = await h.signup('new@test.dev', 'newbie');
  await h.as(newbie);
  await h.fails('new account must wait before posting in HQ', `insert into messages (channel_id, author_id, content) values ($1,$2,'hi')`, [gen, newbie]);
  const own = (await h.one(`select create_server('Mine', null) id`)).id;
  const og = (await h.one(`select id from channels where server_id=$1 and name='general'`, [own])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hello @everyone')`, [og, newbie]);
  h.eq('owner keeps @everyone', (await h.q(`select content from messages where channel_id=$1`, [og]))[0].content, 'hello @everyone');
  await h.fails('new accounts cannot rapid-fire', `insert into messages (channel_id, author_id, content) values ($1,$2,'again')`, [og, newbie]);

  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '2 hours' where id = $1`, [newbie]);
  await h.as(newbie);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'yo @everyone')`, [gen, newbie]);
  h.eq('@everyone neutered for plain members', (await h.q(`select content from messages where channel_id=$1 and author_id=$2`, [gen, newbie]))[0].content, 'yo @​everyone');
}
