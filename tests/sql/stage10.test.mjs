export default async function (h) {
  const owner = await h.signup('owner@test.dev', 'owner');
  const mod = await h.signup('mod@test.dev', 'mod');
  const member = await h.signup('member@test.dev', 'member');
  const outsider = await h.signup('out@test.dev', 'outsider');

  await h.as(owner);
  const sid = (await h.one(`select create_server('Yapper Corporation', null) id`)).id;
  const general = (await h.one(`select id from channels where server_id=$1`, [sid])).id;
  h.eq('general channel created', (await h.one(`select name from channels where id=$1`, [general])).name, 'general');
  const memes = (await h.one(`select create_channel($1, 'Memes!!', 'text') id`, [sid])).id;
  await h.q(`select create_channel($1, 'gaming', 'text')`, [sid]);
  await h.q(`select create_channel($1, 'announcements', 'text')`, [sid]);
  h.eq('channels slugified and ordered', (await h.q(`select name from channels where server_id=$1 order by position`, [sid])).map((r) => r.name),
    ['general', 'memes', 'gaming', 'announcements']);
  await h.q(`insert into invites (code, server_id, created_by) values ('abc12345', $1, $2)`, [sid, owner]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'meme')`, [memes, owner]);

  // Hijack attempt: pre-claiming someone's DM key
  await h.fails('no direct channel inserts', `insert into channels (kind, name, server_id, dm_key) values ('text','x',$1,'a:b')`, [sid]);

  await h.as(outsider);
  h.eq('outsider sees no server', (await h.q(`select id from servers`)).length, 0);
  h.eq('outsider sees no messages', (await h.q(`select id from messages where channel_id=$1`, [memes])).length, 0);
  await h.fails('outsider cannot post', `insert into messages (channel_id, author_id, content) values ($1,$2,'hi')`, [general, outsider]);
  h.eq('invite preview works for non-members', (await h.one(`select name, member_count from get_invite('abc12345')`)), { name: 'Yapper Corporation', member_count: 1 });

  await h.as(member);
  await h.fails('bad invite', `select join_server('nope0000')`);
  h.eq('join with invite', (await h.one(`select join_server('abc12345') id`)).id, sid);
  h.eq('member sees channels', (await h.q(`select id from channels where server_id=$1`, [sid])).length, 4);
  h.eq('messages stay in their channel', (await h.q(`select content from messages where channel_id=$1`, [general])).length, 0);
  h.eq('member reads memes', (await h.q(`select content from messages where channel_id=$1`, [memes])).map((r) => r.content), ['meme']);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'hello server')`, [general, member]);
  await h.fails("member can't create channels", `select create_channel($1, 'mine', 'text')`, [sid]);
  await h.q(`delete from channels where id=$1`, [memes]);
  h.eq("member can't delete channels", (await h.q(`select id from channels where id=$1`, [memes])).length, 1);
  await h.q(`update channels set name='hacked' where id=$1`, [general]);
  h.eq("member can't rename channels", (await h.one(`select name from channels where id=$1`, [general])).name, 'general');
  await h.fails("member can't make roles", `insert into roles (server_id, name) values ($1, 'admin')`, [sid]);
  await h.fails("member can't delete server", `select delete_server($1)`, [sid]);
  await h.q(`delete from messages where channel_id=$1`, [memes]);
  h.eq("member can't delete others' messages", (await h.q(`select id from messages where channel_id=$1`, [memes])).length, 1);
  await h.q(`insert into invites (code, server_id, created_by) values ('member01', $1, $2)`, [sid, member]);

  // Mod joins and gets a moderator role
  await h.as(mod);
  await h.q(`select join_server('member01')`);
  await h.as(owner);
  const ownerRole = (await h.one(`insert into roles (server_id, name, color, position, manage_server) values ($1,'Owner','#9b59ff',2,true) returning id`, [sid])).id;
  const modRole = (await h.one(`insert into roles (server_id, name, color, position, manage_messages) values ($1,'Mod','#2ecc71',1,true) returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, owner, ownerRole]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, mod, modRole]);
  await h.fails('role must belong to the server', `insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, outsider, modRole]);
  await h.fails('bad color', `insert into roles (server_id, name, color) values ($1,'x','purple')`, [sid]);

  await h.as(mod);
  await h.q(`delete from messages where channel_id=$1`, [general]);
  h.eq('mod deletes messages', (await h.q(`select id from messages where channel_id=$1`, [general])).length, 0);
  await h.fails("mod can't create channels", `select create_channel($1, 'modzone', 'text')`, [sid]);
  await h.fails("mod can't kick", `select kick_member($1, $2)`, [sid, member]);

  await h.as(owner);
  await h.fails("owner can't leave", `select leave_server($1)`, [sid]);
  await h.q(`select kick_member($1, $2)`, [sid, mod]);
  h.eq('kicked mod loses roles', (await h.q(`select * from member_roles where user_id=$1`, [mod])).length, 0);
  await h.q(`select update_server($1, 'Yapper Corp', null)`, [sid]);

  await h.as(member);
  h.eq('unread counts include server channels', (await h.q(`select channel_id from unread_counts()`)).length, 4);
  await h.q(`select leave_server($1)`, [sid]);
  h.eq('left server', (await h.q(`select id from servers`)).length, 0);

  await h.as(owner);
  await h.q(`select delete_server($1)`, [sid]);
  await h.admin();
  h.eq('server deleted with channels', (await h.q(`select id from channels where server_id=$1`, [sid])).length, 0);
}
