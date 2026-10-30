// The one way staff see DM content: someone in the DM reports a message. The report carries that message and a few
// around it (report_message's evidence), and only staff read reports. The DM itself stays closed to staff.
export default async function (h) {
  const alice = await h.signup('alice@example.com', 'alice');
  const bob = await h.signup('bob@example.com', 'bob');
  const carol = await h.signup('carol@example.com', 'carol');
  const mod = await h.signup('mod@example.com', 'moddy');
  await h.admin();
  await h.q(`insert into public.site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`update public.profiles set created_at = now() - interval '30 days', dms_from = 'everyone'`);

  await h.as(alice);
  const dm = (await h.one(`select public.get_or_create_dm($1) as id`, [bob])).id;
  await h.q(`insert into public.messages (channel_id, author_id, content, created_at) values ($1, $2, 'earlier message', now() - interval '1 minute')`, [dm, alice]);
  const bad = (await h.one(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'the reported message') returning id`, [dm, alice])).id;

  await h.as(carol);
  await h.fails('someone outside the DM can\'t report its messages', `select public.report_message($1, 'spam')`, [bad]);
  await h.as(alice);
  await h.fails('you can\'t report your own message', `select public.report_message($1, 'spam')`, [bad]);
  await h.as(bob);
  const rid = (await h.one(`select public.report_message($1, 'harassment', 'please look') as id`, [bad])).id;
  h.eq('the reporter can\'t read the reports table', (await h.q(`select 1 from public.reports`)).length, 0);

  await h.as(carol);
  h.eq('another user reads no reports', (await h.q(`select 1 from public.reports`)).length, 0);
  await h.as(null);
  h.eq('signed out: no reports', (await h.q(`select 1 from public.reports`)).length, 0);

  await h.as(mod);
  const r = await h.one(`select message_content, evidence from public.reports where id = $1`, [rid]);
  h.eq('a moderator reads the reported message in the report', r?.message_content, 'the reported message');
  h.eq('with the messages around it as context', r.evidence.map((e) => e.content), ['earlier message']);
  h.eq('but still not the DM itself', (await h.q(`select 1 from public.messages where channel_id = $1`, [dm])).length, 0);
}
