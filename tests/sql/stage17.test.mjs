// Emojis belong to servers; only people who manage a server can add them.
export default async function (h) {
  const owner = await h.signup('own@test.dev', 'owner');
  const mod = await h.signup('mod@test.dev', 'mod');
  const pleb = await h.signup('pleb@test.dev', 'pleb');

  await h.as(owner);
  const sid = (await h.one(`select create_server('Emoji Land', null) id`)).id;
  const other = (await h.one(`select create_server('Other', null) id`)).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('emoj1234', $1, $2)`, [sid, owner]);
  const role = (await h.one(`insert into roles (server_id, name, manage_server) values ($1, 'Mods', true) returning id`, [sid])).id;
  await h.as(mod); await h.q(`select join_server('emoj1234')`);
  await h.as(pleb); await h.q(`select join_server('emoj1234')`);
  await h.as(owner);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, mod, role]);

  await h.q(`insert into emojis (owner_id, server_id, name, path) values ($1,$2,'pog',$3)`, [owner, sid, `${owner}/pog.png`]);
  await h.fails('personal emojis are gone', `insert into emojis (owner_id, name, path) values ($1,'mine',$2)`, [owner, `${owner}/m.png`]);
  await h.fails('names are unique per server', `insert into emojis (owner_id, server_id, name, path) values ($1,$2,'POG',$3)`, [owner, sid, `${owner}/p2.png`]);
  await h.q(`insert into emojis (owner_id, server_id, name, path) values ($1,$2,'pog',$3)`, [owner, other, `${owner}/pog2.png`]);

  await h.as(mod);
  await h.q(`insert into emojis (owner_id, server_id, name, path) values ($1,$2,'modmoji',$3)`, [mod, sid, `${mod}/m.png`]);
  await h.q(`update emojis set name='poggers' where server_id=$1 and name='pog'`, [sid]);
  h.eq('managers can rename any server emoji', (await h.q(`select id from emojis where name='poggers'`)).length, 1);

  await h.as(pleb);
  await h.fails("members can't add emojis", `insert into emojis (owner_id, server_id, name, path) values ($1,$2,'nope',$3)`, [pleb, sid, `${pleb}/n.png`]);
  await h.q(`delete from emojis where server_id=$1`, [sid]);
  h.eq("members can't delete them", (await h.q(`select id from emojis where server_id=$1`, [sid])).length, 2);
  h.eq('but everyone can see them (to show them in messages)', (await h.q(`select id from emojis`)).length, 3);

  await h.as(owner);
  await h.q(`delete from emojis where name='modmoji'`);
  h.eq('managers can delete anyone’s server emoji', (await h.q(`select id from emojis where server_id=$1`, [sid])).length, 1);

  await h.admin();
  for (let i = 0; i < 49; i++) {
    await h.q(`insert into emojis (owner_id, server_id, name, path) values ($1,$2,$3,$4)`, [owner, sid, `e${i}`, `${owner}/e${i}.png`]);
  }
  await h.fails('50 per server', `insert into emojis (owner_id, server_id, name, path) values ($1,$2,'too_many',$3)`, [owner, sid, `${owner}/x.png`]);
}
