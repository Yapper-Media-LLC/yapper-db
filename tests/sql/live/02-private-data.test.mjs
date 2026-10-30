// What the API roles can't reach at all, checked against the live grants and policies: server-side secrets and
// other people's private profile columns. anon = signed out, authenticated = any signed-in account.
// (auth.users and Vault are Supabase's; their grants here come from standins/supabase.sql, so they are not tested.)
export default async function (h) {
  const alice = await h.signup('alice@example.com', 'alice');
  const bob = await h.signup('bob@example.com', 'bob');
  await h.admin();
  await h.q(`insert into app_host.secrets (name, value) values ('TEST_KEY', 'not-a-real-secret')`);
  await h.q(`update public.profiles set muted_reason = 'private note', stripe_customer = 'cus_test' where id = $1`, [bob]);

  for (const [who, uid] of [['signed out', null], ['signed in', alice]]) {
    await h.as(uid);
    await h.fails(`${who}: no access to app_host secrets`, `select value from app_host.secrets`);
    await h.fails(`${who}: no access to api_host`, `select 1 from api_host.secrets`);
    await h.fails(`${who}: select * on profiles is refused`, `select * from public.profiles`);
    for (const col of ['muted_reason', 'muted_until', 'voice_muted_until', 'stripe_customer', 'avatar_prev']) {
      await h.fails(`${who}: can't read profiles.${col}`, `select ${col} from public.profiles where id = $1`, [bob]);
    }
  }

  // The functions that read secrets are not callable from the API.
  await h.as(alice);
  await h.fails('signed in: app_host_secrets() is not callable', `select public.app_host_secrets()`);

  // Public profile basics stay readable, so the refusals above are the column grants, not a broken profiles table.
  h.eq('control: usernames are readable', (await h.q(`select username from public.profiles where id = $1`, [bob])).map((r) => r.username), ['bob']);
  // And you can't write someone else's profile.
  h.eq('can\'t edit another profile', (await h.q(`update public.profiles set bio = 'hacked' where id = $1 returning id`, [bob])).length, 0);
}
