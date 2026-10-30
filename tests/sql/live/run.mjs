// Runs the policy tests against the live schema: restores standins/supabase.sql + schema/*.sql (the schema-only
// dump of the live database, see schema/README.md) into a real Postgres once, then gives every test file its own
// copy of that database. No migration replay and no stand-ins for our own functions: every policy, trigger and
// security definer function is the one running in production.
//
//   node tests/sql/live/run.mjs              the live suite (tests/sql/live/*.test.mjs) + the stage tests listed
//                                            in tests/sql/live/stages.json
//   node tests/sql/live/run.mjs --stages     also try every other stage test and report what happens
//   node tests/sql/live/run.mjs name ...     only test files whose name contains one of these
//
// Connection: the usual PG* environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD); the user must be a
// superuser (it creates databases and roles). ./run-tests.sh sets all of this up in Docker.
//
// A stage test that replaces one of our live functions (create or replace function public.is_site_mod ...) or
// rewrites policies or grants (re-running its migration) is stopped before the statement runs and reported as
// "uses stand-ins": it is only meaningful in the PGlite suite (tests/sql/run.mjs), where it checks the migration as
// it shipped.
import pg from 'pg';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Harness } from './harness.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const TEMPLATE = 'yapper_live';
const argv = process.argv.slice(2);
const tryAllStages = argv.includes('--stages');
const only = argv.filter((a) => !a.startsWith('--'));

async function connect(database) {
  const c = new pg.Client({ database });
  await c.connect();
  c.on('notice', () => {});
  return c;
}

// ---------- restore ----------
const t0 = Date.now();
const admin = await connect('postgres');
await admin.query(`select pg_terminate_backend(pid) from pg_stat_activity where datname = '${TEMPLATE}' and pid <> pg_backend_pid()`);
await admin.query(`update pg_database set datistemplate = false where datname = '${TEMPLATE}'`);
await admin.query(`drop database if exists ${TEMPLATE}`);
for (const d of (await admin.query(`select datname from pg_database where datname like 'yt\\_%'`)).rows) await admin.query(`drop database "${d.datname}"`);
await admin.query(`create database ${TEMPLATE}`);
{
  const db = await connect(TEMPLATE);
  // standins/ sits at the root of the public repo; in the app repo it is public-db/standins/.
  const standins = [join(root, 'standins', 'supabase.sql'), join(root, 'public-db', 'standins', 'supabase.sql')].find((f) => existsSync(f));
  const files = [standins,
    ...readdirSync(join(root, 'schema')).filter((f) => /^\d\d-.*\.sql$/.test(f)).sort().map((f) => join(root, 'schema', f))];
  for (const f of files) {
    try { await db.query(readFileSync(f, 'utf8')); }
    catch (e) { console.error(`Restore failed in ${f.slice(root.length + 1)}: ${e.message}`); process.exit(1); }
  }
  const n = (await db.query(`select
      (select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace where c.relkind = 'r' and s.nspname in ('public','app_host','api_host','private')) as tables,
      (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname in ('public','app_host','api_host','private')
         and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')) as functions,
      (select count(*) from pg_policy) as policies,
      (select count(*) from pg_trigger where not tgisinternal) as triggers`)).rows[0];
  const ver = (await db.query('show server_version')).rows[0].server_version;
  // Same fingerprints as scripts/dump-schema.mjs takes on the live database (schema/counts.json, live_md5).
  const live = JSON.parse(readFileSync(join(root, 'schema', 'counts.json'), 'utf8')).live_md5;
  const fp = (await db.query(`set search_path = pg_catalog; select json_build_object(
     'functions_md5', (select md5(string_agg(h, ',' order by h)) from (select md5(pg_get_functiondef(p.oid)) as h
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname in ('public','app_host','api_host','private') and p.prokind in ('f', 'p')
          and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')) x),
     'policies_md5', (select md5(string_agg(h, ',' order by h)) from (select md5(n.nspname || '.' || c.relname || '.' || p.polname || '|' || p.polcmd::text || '|' || p.polpermissive::text
          || '|' || coalesce(pg_get_expr(p.polqual, p.polrelid), '') || '|' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')) as h
        from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('public','app_host','api_host','private','storage','realtime')) x)) as v; reset search_path;`))[1].rows[0].v;
  console.log(`Restored the live schema into Postgres ${ver} in ${((Date.now() - t0) / 1000).toFixed(1)}s: ${n.tables} tables, ${n.functions} functions, ${n.policies} policies, ${n.triggers} triggers.`);
  if (!live) console.log('schema/counts.json has no live fingerprints, skipping the byte-for-byte check.');
  else {
    const same = (k) => (fp[k] === live[k] ? 'identical to live' : `DIFFERENT from live (${fp[k]} here, ${live[k]} live)`);
    console.log(`Function bodies: ${same('functions_md5')}. Policies: ${same('policies_md5')}.`);
    if (fp.functions_md5 !== live.functions_md5 || fp.policies_md5 !== live.policies_md5) process.exit(1);
  }
  await db.end();
}
await admin.query(`update pg_database set datistemplate = true where datname = '${TEMPLATE}'`);

// Names of our live functions, to catch a test that would overwrite one with a stand-in.
const liveFns = new Set();
{
  const db = await connect(TEMPLATE);
  for (const r of (await db.query(`select n.nspname || '.' || p.proname as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_host','api_host','private','extensions')`)).rows) liveFns.add(r.f);
  await db.end();
}
class UsesStandins extends Error {}
const FN_RE = /create\s+(?:or\s+replace\s+)?function\s+([\w"]+(?:\.[\w"]+)?)\s*\(/gi;
// Re-running an old migration (or any test DDL) that rewrites policies or grants would test that text, not live.
const RULES_RE = /\b(create|drop|alter)\s+policy\b|\brevoke\s|\bgrant\s+[\w ,()]+\s+on\s|\bdisable\s+row\s+level\s+security\b/i;
function guard(sql) {
  const r = RULES_RE.exec(sql);
  if (r) throw new UsesStandins(`(rewrites the live rules: "${r[0]}")`);
  for (const m of sql.matchAll(FN_RE)) {
    let name = m[1].replace(/"/g, '').toLowerCase();
    if (!name.includes('.')) name = `public.${name}`;
    if (liveFns.has(name)) throw new UsesStandins(name);
  }
}

// ---------- tests ----------
const liveTests = readdirSync(here).filter((f) => f.endsWith('.test.mjs')).sort().map((f) => ({ file: join(here, f), name: `live/${f}`, live: true }));
const listed = existsSync(join(here, 'stages.json')) ? JSON.parse(readFileSync(join(here, 'stages.json'), 'utf8')).stages : [];
const stageDir = join(here, '..');
const allStages = readdirSync(stageDir).filter((f) => /^stage\d+[a-z]?\.test\.mjs$/.test(f)).sort();
const stageTests = (tryAllStages ? allStages : listed.filter((f) => allStages.includes(f))).map((f) => ({ file: join(stageDir, f), name: f, listed: listed.includes(f) }));
let tests = [...liveTests, ...stageTests];
if (only.length) tests = tests.filter((t) => only.some((o) => t.name.includes(o)));

const result = { pass: [], fail: [], standins: [] };
let i = 0;
for (const t of tests) {
  const dbName = `yt_${i++}`;
  await admin.query(`create database ${dbName} template ${TEMPLATE}`);
  const client = await connect(dbName);
  const h = new Harness(client);
  if (!t.live) h.db.guard = guard;
  try {
    const mod = await import(pathToFileURL(t.file).href);
    await mod.default(h);
    result.pass.push(t);
    console.log(`✓ ${t.name} (${h.passed} checks)`);
  } catch (e) {
    if (e instanceof UsesStandins) {
      result.standins.push(t);
      if (tryAllStages) console.log(`- ${t.name}: replaces ${e.message}, PGlite suite only`);
      else { result.fail.push(t); console.log(`${t.name}\n   listed in stages.json but replaces ${e.message}`); }
    } else {
      result.fail.push(t);
      console.log(`${t.name}\n   ${String(e.message).split('\n')[0]}`);
    }
  } finally {
    await client.end();
    await admin.query(`drop database ${dbName}`);
  }
}
const failedListed = result.fail.filter((t) => t.live || t.listed);
console.log(`\n${result.pass.length} passed, ${failedListed.length} failed` +
  (tryAllStages ? `, ${result.standins.length} stage tests use stand-ins for our functions (PGlite only), ${result.fail.length - failedListed.length} unlisted stage tests fail against live` : '') + '.');
if (tryAllStages) console.log('Passing stage tests: ' + JSON.stringify(result.pass.filter((t) => !t.live).map((t) => t.name)));
await admin.end();
process.exit(failedListed.length ? 1 : 0);
