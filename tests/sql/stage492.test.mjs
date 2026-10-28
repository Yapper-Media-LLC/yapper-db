// 492: Import from Discord keeps channel access (security pass 2, N3). Runs stage 378 first (its stand-ins and
// checks set up import_discord_server as live), then 492 twice (re-runnable), then imports with access keys.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import run378 from './stage378.test.mjs';
export { base } from './stage378.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '492_discord_import_access.sql'), 'utf8');

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`492 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await run378(h);
  await h.admin();
  await h.db.exec(MIG);
  await h.ok('492 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag in test mode', (await h.one(`select mode from feature_flags where key = 'discord_import_access'`)).mode, 'test');

  const ann = await h.signup('ann492@test.dev', 'ann492');
  await h.as(ann);
  const payload = {
    name: 'Imported', categories: [{ key: 'c1', name: 'Staff', position: 0 }],
    roles: [
      { key: 'r-mods', name: 'Mods', position: 0, perms: {} },
      { key: 'r-mem', name: 'Members', position: 1, perms: {} },
      { name: 'No key', position: 2, perms: {} },
    ],
    channels: [
      { kind: 'text', name: 'general', position: 0 },
      { kind: 'text', name: 'staff', position: 1, category_key: 'c1', private: true, role_keys: ['r-mods', 'r-gone', 'r-mods'] },
      { kind: 'text', name: 'secret', position: 2, private: true, role_keys: [] },
      { kind: 'text', name: 'news', position: 3, read_only: true, post_role_keys: ['r-mods'] },
      { kind: 'voice', name: 'Staff VC', position: 4, private: true, role_keys: ['r-mem'], read_only: true, post_role_keys: ['r-mem'] },
      { kind: 'text', name: 'weird', position: 5, private: 'yes', role_keys: 'r-mods' },
    ],
  };
  const sid = (await h.one(`select import_discord_server($1::jsonb) id`, [JSON.stringify(payload)])).id;
  await h.admin();
  const chans = await h.q(
    `select c.name, c.private, coalesce(c.read_only, false) ro,
            array(select r.name from channel_roles cr join roles r on r.id = cr.role_id where cr.channel_id = c.id order by r.name) see,
            array(select r.name from channel_post_roles pr join roles r on r.id = pr.role_id where pr.channel_id = c.id order by r.name) post
       from channels c where c.server_id = $1 order by c.position`, [sid]);
  const by = Object.fromEntries(chans.map((c) => [c.name, c]));
  h.eq('plain channel stays public', [by.general.private, by.general.ro], [false, false]);
  h.eq('private channel open to its mapped roles, unknown and repeated keys ignored', [by.staff.private, by.staff.see], [true, ['Mods']]);
  h.eq('private with no roles: owner and admins only', [by.secret.private, by.secret.see], [true, []]);
  h.eq('read-only channel with its posting roles', [by.news.private, by.news.ro, by.news.post], [false, true, ['Mods']]);
  h.eq('voice: private works, read-only is ignored', [by['Staff VC'].private, by['Staff VC'].see, by['Staff VC'].ro, by['Staff VC'].post], [true, ['Members'], false, []]);
  h.eq('non-boolean private / non-array keys refused quietly', [by.weird.private, by.weird.see], [false, []]);
  h.eq('access rows carry the right server', (await h.one(`select count(*)::int n from channel_roles where server_id <> $1 and channel_id in (select id from channels where server_id = $1)`, [sid])).n, 0);

  // Old payloads (no access keys) import exactly as before.
  await h.as(ann);
  const sid2 = (await h.one(`select import_discord_server($1::jsonb) id`, [JSON.stringify({ name: 'Old', roles: [{ name: 'A', position: 0, perms: {} }], channels: [{ kind: 'text', name: 'x' }] })])).id;
  await h.admin();
  h.eq('old payload: public, no access rows', (await h.one(
    `select bool_or(private) p, (select count(*)::int from channel_roles where server_id = $1) n from channels where server_id = $1`, [sid2])), { p: false, n: 0 });
  h.eq('roles still made', (await h.one(`select count(*)::int n from roles where server_id = $1 and name = 'A'`, [sid2])).n, 1);
}
