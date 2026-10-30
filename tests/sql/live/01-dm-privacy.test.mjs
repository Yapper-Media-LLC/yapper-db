// DMs are private to the two people in them: not readable by a stranger, a Yapper moderator, a head moderator or
// an admin. Runs against the live policies and the live is_site_mod/is_staff/can_access_channel, no stand-ins.
// Staff rights come from rows in the real tables (site_moderators, site_admins), signed in with an aal2 JWT like
// a staff member who passed 2FA, and a positive control proves those staff accounts really are staff.
export default async function (h) {
  const alice = await h.signup('alice@example.com', 'alice');
  const bob = await h.signup('bob@example.com', 'bob');
  const carol = await h.signup('carol@example.com', 'carol');
  const mod = await h.signup('mod@example.com', 'moddy');
  const head = await h.signup('head@example.com', 'headmod');
  const admin = await h.signup('admin@example.com', 'adminy');

  await h.admin();
  await h.q(`insert into public.site_moderators (user_id) values ($1)`, [mod]);
  await h.q(`insert into public.site_moderators (user_id, head) values ($1, true)`, [head]);
  await h.q(`insert into public.site_admins (user_id) values ($1)`, [admin]);
  // Staff need 2FA when the staff_2fa flag is on (it is on live): turn it on here too, and sign staff in at aal2.
  await h.q(`insert into public.feature_flags (key, label, mode) values ('staff_2fa', 'Staff 2FA', 'everyone') on conflict (key) do update set mode = 'everyone'`);
  await h.q(`update public.profiles set dms_from = 'everyone' where id = $1`, [bob]);

  const staff = async (uid) => { await h.as(uid); await h.db.client.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: uid, role: 'authenticated', aal: 'aal2' })]); };

  // Positive control: these accounts are staff as far as the live functions are concerned.
  await staff(mod);
  h.eq('control: the moderator is a site mod', (await h.one(`select public.is_site_mod() as v`)).v, true);
  await staff(admin);
  h.eq('control: the admin is a site admin', (await h.one(`select public.is_site_admin() as v`)).v, true);
  await staff(head);
  h.eq('control: the head mod is staff', (await h.one(`select public.is_staff() as v`)).v, true);
  await h.as(mod);
  h.eq('control: without 2FA (aal1) a moderator is not staff', (await h.one(`select public.is_staff() as v`)).v, false);

  // Alice opens a DM with Bob through the real RPC and sends a message as herself.
  await h.as(alice);
  const dm = (await h.one(`select public.get_or_create_dm($1) as id`, [bob])).id;
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'only for bob')`, [dm, alice]);
  const msg = (await h.one(`select id from public.messages where channel_id = $1`, [dm])).id;
  await h.as(bob);
  await h.q(`insert into public.messages (channel_id, author_id, content) values ($1, $2, 'only for alice')`, [dm, bob]);

  const seen = async () => (await h.q(`select content from public.messages where channel_id = $1 order by content`, [dm])).map((r) => r.content);
  await h.as(alice);
  h.eq('alice reads the DM', await seen(), ['only for alice', 'only for bob']);
  await h.as(bob);
  h.eq('bob reads the DM', await seen(), ['only for alice', 'only for bob']);

  for (const [who, uid, asStaff] of [['a stranger', carol, false], ['a moderator', mod, true], ['a head moderator', head, true], ['an admin', admin, true]]) {
    if (asStaff) await staff(uid); else await h.as(uid);
    h.eq(`${who} reads none of the DM`, await seen(), []);
    h.eq(`${who} can't search all messages for it either`, (await h.q(`select 1 from public.messages where content like 'only for%'`)).length, 0);
    h.eq(`${who} doesn't see the DM channel`, (await h.q(`select 1 from public.channels where id = $1`, [dm])).length, 0);
    h.eq(`${who} doesn't see who is in it`, (await h.q(`select 1 from public.channel_members where channel_id = $1`, [dm])).length, 0);
    await h.fails(`${who} can't add themselves to the DM`, `insert into public.channel_members (channel_id, user_id) values ($1, $2)`, [dm, uid]);
    await h.fails(`${who} can't post into the DM`, `insert into public.messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [dm, uid]);
    h.eq(`${who} can't edit a DM message`, (await h.q(`update public.messages set content = 'x' where id = $1 returning id`, [msg])).length, 0);
    // Moderators may delete messages they can see (the "yapper moderators delete messages" policy); a DM row is
    // not visible to them, so the delete matches nothing.
    h.eq(`${who} can't delete a DM message`, (await h.db.client.query(`delete from public.messages where id = $1`, [msg])).rowCount, 0);
  }

  await h.as(null);
  h.eq('signed out: nothing', await seen(), []);

  // Staff can read staff-only tables, so the empty results above are the DM rules, not a broken staff setup.
  await h.admin();
  await h.q(`insert into public.mod_notes (user_id, author, body) values ($1, $2, 'note')`, [carol, admin]);
  await staff(mod);
  h.eq('control: the moderator reads mod notes', (await h.q(`select body from public.mod_notes`)).length, 1);
  await h.as(carol);
  h.eq('control: a normal account reads no mod notes', (await h.q(`select body from public.mod_notes`)).length, 0);
}
