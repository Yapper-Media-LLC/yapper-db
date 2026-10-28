// People can delete their own account; everything of theirs goes with it.
export default async function (h) {
  const hq = await h.signup('hq@test.dev', 'boss');
  await h.as(hq);
  const hqId = (await h.one(`select create_server('Yapper Headquarters', null) id`)).id;
  await h.admin();
  await h.q(`update app_settings set default_server_id = $1`, [hqId]);

  const leaver = await h.signup('leave@test.dev', 'leaver');
  const friend = await h.signup('friend@test.dev', 'friend');

  await h.as(leaver);
  const own = (await h.one(`select create_server('My Place', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [hqId])).id;
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'bye all')`, [gen, leaver]);
  await h.admin();
  await h.q(`insert into friendships (requester, addressee) values ($1,$2)`, [leaver, friend]);

  await h.as(null);
  await h.fails("logged-out visitors can't call it", `select delete_my_account()`);

  await h.as(hq);
  await h.fails("the community server owner can't delete from the app", `select delete_my_account()`);

  await h.as(leaver);
  await h.q(`select delete_my_account()`);

  await h.admin();
  h.eq('login is gone', (await h.q(`select id from auth.users where id=$1`, [leaver])).length, 0);
  h.eq('profile is gone', (await h.q(`select id from profiles where id=$1`, [leaver])).length, 0);
  h.eq('their messages are gone', (await h.q(`select id from messages where author_id=$1`, [leaver])).length, 0);
  h.eq('their server is gone', (await h.q(`select id from servers where id=$1`, [own])).length, 0);
  h.eq('friendships are gone', (await h.q(`select * from friendships where requester=$1 or addressee=$1`, [leaver])).length, 0);
  h.eq('everyone else is untouched', (await h.q(`select id from profiles`)).length, 2);
}
