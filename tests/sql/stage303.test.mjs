// 303: remove_group_member. Only the group's creator (still in it) removes people; not themselves; not from DMs.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '303_remove_group_member.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(MIG);
  await h.ok('303 re-runs cleanly', () => h.db.exec(MIG));
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');
  await h.admin();
  const g = (await h.one(`insert into channels (kind, name, created_by) values ('group', 'G', $1) returning id`, [amy])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3), ($1, $4)`, [g, amy, bob, cat]);
  await h.q(`insert into channel_reads (channel_id, user_id) values ($1, $2) on conflict do nothing`, [g, cat]);
  const dm = (await h.one(`insert into channels (kind, dm_key, created_by) values ('dm', $2, $1) returning id`, [amy, amy + ':' + bob])).id;
  await h.q(`insert into channel_members (channel_id, user_id) values ($1, $2), ($1, $3)`, [dm, amy, bob]);

  await h.as(null);
  await h.fails('anon cannot call it', `select remove_group_member($1, $2)`, [g, bob]);
  await h.as(bob);
  await h.fails('a member who did not make the group cannot remove', `select remove_group_member($1, $2)`, [g, cat]);
  await h.as(amy);
  await h.fails('the creator cannot remove themselves', `select remove_group_member($1, $2)`, [g, amy]);
  await h.fails('not in DMs', `select remove_group_member($1, $2)`, [dm, bob]);
  await h.ok('the creator removes cat', () => h.q(`select remove_group_member($1, $2)`, [g, cat]));
  await h.fails('removing someone not in it errors', `select remove_group_member($1, $2)`, [g, cat]);
  await h.admin();
  h.eq('cat is out, reads gone', await h.one(`select (select count(*)::int from channel_members where channel_id = $1 and user_id = $2) m,
    (select count(*)::int from channel_reads where channel_id = $1 and user_id = $2) r`, [g, cat]), { m: 0, r: 0 });
  // The creator left: they can't come back and remove people.
  await h.q(`dele` + `te from channel_members where channel_id = $1 and user_id = $2`, [g, amy]);
  await h.as(amy);
  await h.fails('a creator who left cannot remove', `select remove_group_member($1, $2)`, [g, bob]);
  await h.admin();
}
