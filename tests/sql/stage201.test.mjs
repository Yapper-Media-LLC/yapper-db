// 201: profile_cache flag row + rt_profile_changed (tells the realtime server to forget cached profiles).
// public.bc lives only on the live database (pg_net POST to the realtime server); a stand-in records its calls,
// with the same record-typed arguments the live bc_* triggers pass.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    create table if not exists public.bc_calls (topic text, event text, rec jsonb);
    create or replace function public.bc(topic text, event text, op text, tbl text, sch text, rec record, old record)
    returns void language plpgsql security definer set search_path = public as $$
    begin insert into public.bc_calls values (topic, event, to_jsonb(rec)); end; $$;
  `);
  const sql = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '201_profile_cache.sql'), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable
  h.eq('flag row once, test mode', await h.q(`select mode, servers from feature_flags where key = 'profile_cache'`), [{ mode: 'test', servers: [] }]);

  const a = await h.signup('a@test.dev', 'alice');
  const b = await h.signup('b@test.dev', 'bob');
  await h.db.exec(`set role service_role`);
  await h.q(`select rt_profile_changed($1::uuid[])`, [[a, b, a, null]]);
  await h.q(`select rt_profile_changed(null)`);
  await h.admin();
  const calls = await h.q(`select topic, event, rec->>'id' id from bc_calls order by topic`);
  h.eq('one publish per distinct id', calls.length, 2);
  h.eq('topic and event', calls.every((c) => c.topic === `profile:${c.id}` && c.event === 'profile'), true);
  h.eq('ids', calls.map((c) => c.id).sort(), [a, b].sort());

  for (const who of [a, null]) {
    await h.as(who);
    let err = null;
    try { await h.q(`select rt_profile_changed($1::uuid[])`, [[b]]); } catch (e) { err = e.message; }
    await h.admin();
    h.eq(`not callable as ${who ? 'authenticated' : 'anon'}`, /permission denied/.test(err ?? ''), true);
  }
}
