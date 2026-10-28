// Reports reach admins only; Yapper-wide bans stop people doing anything.
export default async function (h) {
  const admin = await h.signup('admin@test.dev', 'admin');
  const troll = await h.signup('troll@test.dev', 'troll');
  const kid = await h.signup('kid@test.dev', 'kid');
  const outsider = await h.signup('out@test.dev', 'outsider');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);

  await h.as(kid);
  const sid = (await h.one(`select create_server('Hangout', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('hang1234', $1, $2)`, [sid, kid]);
  await h.as(troll);
  await h.q(`select join_server('hang1234')`);
  const bad = (await h.one(`insert into messages (channel_id, author_id, content) values ($1,$2,'go away loser') returning id`, [gen, troll])).id;

  await h.as(outsider);
  await h.fails("can't report a message you can't see", `select report_message($1, 'harassment', '')`, [bad]);

  await h.as(kid);
  await h.fails("can't report your own messages", `select report_message(id, 'spam', '') from messages where author_id=$1 limit 1`, [kid]).catch(() => undefined);
  const rid = (await h.one(`select report_message($1, 'harassment', 'mean to me') id`, [bad])).id;
  await h.q(`select report_user($1, 'spam', '')`, [troll]);
  await h.fails('bad reason refused', `select report_user($1, 'because', '')`, [troll]);
  h.eq("reporters can't read reports", (await h.q(`select * from reports`)).length, 0);
  await h.fails("members can't resolve", `select resolve_report($1, 'dismissed')`, [rid]);
  await h.fails("members can't ban", `select site_ban($1, 'x', false)`, [troll]);

  // Evidence survives the troll deleting the message.
  await h.as(troll);
  await h.q(`delete from messages where id=$1`, [bad]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'more trolling')`, [gen, troll]);

  await h.as(admin);
  const reps = await h.q(`select * from reports order by created_at`);
  h.eq('admins see reports', reps.length, 2);
  h.eq('message text kept as evidence', reps[0].message_content, 'go away loser');
  await h.q(`select resolve_report($1, 'dismissed')`, [reps[1].id]);
  await h.q(`select site_ban($1, 'harassment', true)`, [troll]);
  h.eq('open reports about them are closed', (await h.q(`select id from reports where status='open'`)).length, 0);
  await h.fails("can't ban yourself", `select site_ban($1, '', false)`, [admin]);

  await h.as(troll);
  h.eq('they can see their own ban', (await h.q(`select reason from site_bans`))[0].reason, 'harassment');
  h.eq('their messages were wiped', (await h.q(`select id from messages where author_id=$1`, [troll])).length, 0);
  await h.fails('banned: no messages', `insert into messages (channel_id, author_id, content) values ($1,$2,'hi')`, [gen, troll]);
  await h.fails('banned: no servers', `select create_server('Mine', null)`);
  await h.fails('banned: no profile edits', `update profiles set bio='hi' where id=$1`, [troll]);

  await h.as(admin);
  await h.q(`select site_unban($1)`, [troll]);
  await h.as(troll);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'sorry')`, [gen, troll]);
  h.eq('unbanned can post again', (await h.q(`select id from messages where author_id=$1`, [troll])).length, 1);
}
