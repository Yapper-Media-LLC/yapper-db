// Private channels: only chosen roles (plus managers) can see and use them.
export default async function (h) {
  const owner = await h.signup('owner@test.dev', 'owner');
  const vip = await h.signup('vip@test.dev', 'vip');
  const pleb = await h.signup('pleb@test.dev', 'pleb');

  await h.as(owner);
  const sid = (await h.one(`select create_server('Club', null) id`)).id;
  const secret = (await h.one(`select create_channel($1, 'vip-lounge', 'text') id`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('club1234', $1, $2)`, [sid, owner]);
  const role = (await h.one(`insert into roles (server_id, name) values ($1, 'VIP') returning id`, [sid])).id;
  await h.as(vip); await h.q(`select join_server('club1234')`);
  await h.as(pleb); await h.q(`select join_server('club1234')`);
  await h.as(owner);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1,$2,$3)`, [sid, vip, role]);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'before it was private')`, [secret, owner]);

  await h.as(pleb);
  await h.fails("members can't lock channels", `select set_channel_access($1, true, array[$2]::uuid[])`, [secret, role]);

  await h.as(owner);
  await h.q(`select set_channel_access($1, true, array[$2]::uuid[])`, [secret, role]);
  h.eq('owner still sees it', (await h.q(`select id from channels where id=$1`, [secret])).length, 1);

  await h.as(vip);
  h.eq('role holder sees it', (await h.q(`select id from channels where id=$1`, [secret])).length, 1);
  h.eq('role holder reads it', (await h.q(`select id from messages where channel_id=$1`, [secret])).length, 1);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'vip only')`, [secret, vip]);

  await h.as(pleb);
  h.eq('others do not see it', (await h.q(`select id from channels where id=$1`, [secret])).length, 0);
  h.eq('others cannot read it', (await h.q(`select id from messages where channel_id=$1`, [secret])).length, 0);
  await h.fails('others cannot post', `insert into messages (channel_id, author_id, content) values ($1,$2,'let me in')`, [secret, pleb]);
  h.eq('no unread badge for it', (await h.q(`select channel_id from unread_counts() where channel_id=$1`, [secret])).length, 0);
  h.eq('can see which roles it is for', (await h.q(`select role_id from channel_roles where channel_id=$1`, [secret])).length, 1);

  await h.as(owner);
  await h.q(`delete from member_roles where user_id=$1 and role_id=$2`, [vip, role]);
  await h.as(vip);
  h.eq('losing the role hides it', (await h.q(`select id from channels where id=$1`, [secret])).length, 0);

  await h.as(owner);
  await h.q(`select set_channel_access($1, false, null)`, [secret]);
  await h.as(pleb);
  h.eq('public again', (await h.q(`select id from channels where id=$1`, [secret])).length, 1);
}
