// Read-only channels, slowmode and bans.
export default async function (h) {
  const owner = await h.signup('own@test.dev', 'owner');
  const staff = await h.signup('staff@test.dev', 'staff');
  const pleb = await h.signup('pleb@test.dev', 'pleb');

  await h.as(owner);
  const sid = (await h.one(`select create_server('Official', null) id`)).id;
  const ann = (await h.one(`select create_channel($1, 'announcements', 'text') id`, [sid])).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('offi1234', $1, $2)`, [sid, owner]);
  const role = (await h.one(`insert into roles (server_id, name) values ($1, 'Staff') returning id`, [sid])).id;
  await h.as(staff); await h.q(`select join_server('offi1234')`);
  await h.as(pleb); await h.q(`select join_server('offi1234')`);
  await h.as(owner);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, staff, role]);

  await h.as(pleb);
  await h.fails("members can't change channel posting", `select set_channel_posting($1, true, null, 0)`, [ann]);

  await h.as(owner);
  await h.q(`select set_channel_posting($1, true, array[$2]::uuid[], 0)`, [ann, role]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'welcome!')`, [ann, owner]);

  await h.as(staff);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'staff post')`, [ann, staff]);

  await h.as(pleb);
  h.eq('everyone can read announcements', (await h.q(`select id from messages where channel_id=$1`, [ann])).length, 2);
  await h.fails("members can't post in a read-only channel", `insert into messages (channel_id, author_id, content) values ($1,$2,'hi')`, [ann, pleb]);
  const mid = (await h.one(`select id from messages where channel_id=$1 limit 1`, [ann])).id;
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1,$2,'🎉')`, [mid, pleb]);
  h.eq('but can react', (await h.q(`select id from reactions where message_id=$1`, [mid])).length, 1);

  // Slowmode
  await h.as(owner);
  await h.q(`select set_channel_posting($1, false, null, 30)`, [gen]);
  await h.as(pleb);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'one')`, [gen, pleb]);
  await h.fails('slowmode blocks a quick second message', `insert into messages (channel_id, author_id, content) values ($1,$2,'two')`, [gen, pleb]);
  await h.as(owner);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'a')`, [gen, owner]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'b')`, [gen, owner]);
  h.eq('managers skip slowmode', (await h.q(`select id from messages where author_id=$1 and channel_id=$2`, [owner, gen])).length, 2);

  // Bans
  await h.as(staff);
  await h.fails("plain roles can't ban", `select ban_member($1, $2)`, [sid, pleb]);
  await h.as(owner);
  await h.fails("can't ban the owner", `select ban_member($1, $2)`, [sid, owner]);
  await h.q(`select ban_member($1, $2)`, [sid, pleb]);
  h.eq('ban list shows them', (await h.q(`select user_id from server_bans where server_id=$1`, [sid])).length, 1);
  await h.as(pleb);
  h.eq('banned person is out', (await h.q(`select id from servers where id=$1`, [sid])).length, 0);
  await h.fails("banned person can't rejoin", `select join_server('offi1234')`);
  h.eq("and can't see the ban list", (await h.q(`select * from server_bans`)).length, 0);
  await h.as(owner);
  await h.q(`select unban_member($1, $2)`, [sid, pleb]);
  await h.as(pleb);
  h.eq('unbanned person can rejoin', (await h.one(`select join_server('offi1234') id`)).id, sid);

  // DMs are unaffected
  const friendCheck = await h.one(`select public.can_post_channel(gen_random_uuid()) ok`);
  h.eq('unknown/DM channels are postable', friendCheck.ok, true);
}
