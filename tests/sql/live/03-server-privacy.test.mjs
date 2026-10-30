// Server messages are for members only, private channels for the people they are opened to, and Yapper staff who
// aren't members don't read a server's channels. Live policies and functions, servers made with the real RPCs.
export default async function (h) {
  const owner = await h.signup('owner@example.com', 'owner');
  const member = await h.signup('member@example.com', 'member');
  const stranger = await h.signup('stranger@example.com', 'stranger');
  const mod = await h.signup('mod@example.com', 'moddy');
  const banned = await h.signup('banned@example.com', 'banned');
  await h.admin();
  await h.q(`insert into public.site_moderators (user_id) values ($1)`, [mod]);
  // Accounts older than a week, so the new-account message limits stay out of the way.
  await h.q(`update public.profiles set created_at = now() - interval '30 days'`);

  await h.as(owner);
  const sid = (await h.one(`select public.create_server('Test server', null) as id`)).id;
  const general = (await h.one(`select id from public.channels where server_id = $1 and kind = 'text'`, [sid])).id;
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hello members')`, [general, owner]);
  const secret = (await h.one(`select public.create_channel($1, 'owners-only', 'text') as id`, [sid])).id;
  h.eq('owner makes the channel private', (await h.q(`update public.channels set private = true where id = $1 returning id`, [secret])).length, 1);
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'owners only')`, [secret, owner]);

  // Joining is set up directly (the invite flow has its own tests); the rules under test are the read rules.
  await h.admin();
  await h.q(`insert into public.server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, member, banned]);
  await h.q(`insert into public.site_bans (user_id, reason) values ($1, 'test')`, [banned]);

  const read = async (cid) => (await h.q(`select content from public.messages where channel_id = $1`, [cid])).map((r) => r.content);
  await h.as(owner);
  h.eq('the owner reads the private channel', await read(secret), ['owners only']);
  await h.as(member);
  h.eq('a member reads #general', await read(general), ['hello members']);
  h.eq('a member without access reads none of the private channel', await read(secret), []);
  h.eq('a member does not even see the private channel', (await h.q(`select 1 from public.channels where id = $1`, [secret])).length, 0);
  for (const [who, uid] of [['a stranger', stranger], ['a Yapper moderator who is not a member', mod], ['a site-banned member', banned], ['signed out', null]]) {
    await h.as(uid);
    h.eq(`${who} reads none of #general`, await read(general), []);
    h.eq(`${who} reads none of the private channel`, await read(secret), []);
    // (A site-banned member still sees the member list of servers they are in; only their reads of messages are cut.)
    if (uid !== banned) h.eq(`${who} doesn't see the server's members`, (await h.q(`select 1 from public.server_members where server_id = $1 and user_id <> coalesce($2, '00000000-0000-0000-0000-000000000000'::uuid)`, [sid, uid])).length, 0);
  }
  await h.as(stranger);
  await h.fails('a stranger can\'t join by inserting a membership', `insert into public.server_members (server_id, user_id) values ($1, $2)`, [sid, stranger]);
  await h.fails('a stranger can\'t post', `insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [general, stranger]);
  await h.as(member);
  await h.fails('a member can\'t post as someone else', `insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [general, owner]);
}
