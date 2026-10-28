#!/usr/bin/env node
// Dumps the database access rules from the live Supabase project into readable, sorted text files, so anyone
// can read exactly who may read or write what, and diffs between two dumps show exactly what changed.
//
// What it writes (default out dir: access-rules/):
//   policies.md                  every row of pg_policies: table, command, roles, USING and WITH CHECK expressions
//   security-definer-functions.sql  every function that runs with the owner's rights (prosecdef), full body,
//                                   plus who may call it (EXECUTE grants)
//   rls-without-policies.md      tables with row level security on but no policy at all (nobody but the
//                                service role can touch them through the API)
//   tables.md                    every table: RLS on/off, forced or not, how many policies
//   README.md                    counts and the date of the dump
//
// Read only: the queries touch pg_catalog views only. No DDL, no data tables.
//
// How to run (pick one):
//   SUPABASE_ACCESS_TOKEN=sbp_... node scripts/dump-access-rules.mjs [--project dnfkuqzddwvtdojzgmdm] [--out dir]
//     Runs the queries through the Supabase Management API (same thing the Supabase MCP's execute_sql does).
//     A personal access token from https://supabase.com/dashboard/account/tokens. Never commit it.
//   node scripts/dump-access-rules.mjs --from some/dir [--out dir]
//     Formats JSON results you fetched yourself (Supabase MCP execute_sql, the SQL editor, psql -At -c '... json').
//     Files in that dir are read by prefix: policies*.json, functions*.json, rls*.json, tables*.json; each holds a
//     JSON array of rows from the matching query below (any number of pages, they get merged and re-sorted).
//   node scripts/dump-access-rules.mjs --sql
//     Prints the four queries so you can run them yourself.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf(name);
  return i === -1 ? def : argv[i + 1];
};
const OUT = opt('--out', 'access-rules');
const PROJECT = opt('--project', process.env.SUPABASE_PROJECT_REF || 'dnfkuqzddwvtdojzgmdm');
const FROM = opt('--from');

// Schemas that belong to Postgres, Supabase or extensions, not to Yapper. Their functions and policies are not
// ours to publish and would drown the file in noise.
const SKIP_SCHEMAS = `('pg_catalog','information_schema','extensions','vault','pgsodium','pgsodium_masks','graphql','graphql_public','supabase_functions','supabase_migrations','net','cron','pgbouncer','realtime','auth','pgmq','pg_toast')`;

import { redact } from './redact-ids.mjs';

export const QUERIES = {
  policies: `
select schemaname, tablename, policyname, permissive, roles::text[] as roles, cmd, qual, with_check,
  md5(coalesce(qual,'') || '|' || coalesce(with_check,'')) as md5
from pg_policies
where schemaname not in ${SKIP_SCHEMAS}
order by schemaname, tablename, policyname`,
  functions: `
select n.nspname as schema, p.proname as name, pg_get_function_identity_arguments(p.oid) as args,
  pg_get_functiondef(p.oid) as def, md5(pg_get_functiondef(p.oid)) as md5,
  coalesce((select string_agg(case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end, ', ' order by a.grantee)
    from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner),
    case when p.proacl is null then 'PUBLIC (default)' else '' end) as execute_grants
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef and n.nspname not in ${SKIP_SCHEMAS}
order by n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)`,
  rls: `
select n.nspname as schema, c.relname as table, c.relforcerowsecurity as forced
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p') and c.relrowsecurity and n.nspname not in ${SKIP_SCHEMAS}
  and not exists (select 1 from pg_policy pol where pol.polrelid = c.oid)
order by n.nspname, c.relname`,
  tables: `
select n.nspname as schema, c.relname as table, c.relrowsecurity as rls, c.relforcerowsecurity as forced,
  (select count(*) from pg_policy pol where pol.polrelid = c.oid) as policies,
  coalesce((select string_agg(distinct a.grantee::regrole::text, ', ')
    from aclexplode(c.relacl) a where a.grantee <> c.relowner and a.grantee <> 0
      and a.grantee::regrole::text in ('anon','authenticated')), '') as api_roles
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p') and n.nspname not in ${SKIP_SCHEMAS}
order by n.nspname, c.relname`,
};

if (argv.includes('--sql')) {
  for (const [k, q] of Object.entries(QUERIES)) console.log(`-- ${k}\n${q.trim()};\n`);
  process.exit(0);
}

async function viaManagementApi(sql) {
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query: sql, read_only: true }),
  });
  if (!r.ok) throw new Error(`Management API ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

function fromDir(dir, prefix) {
  const files = readdirSync(dir).filter((f) => f.startsWith(prefix) && f.endsWith('.json')).sort();
  if (!files.length) throw new Error(`No ${prefix}*.json in ${dir}`);
  return files.flatMap((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')));
}

async function load() {
  if (FROM) return Object.fromEntries(Object.keys(QUERIES).map((k) => [k, fromDir(FROM, k)]));
  if (!process.env.SUPABASE_ACCESS_TOKEN) {
    console.error('Set SUPABASE_ACCESS_TOKEN, or pass --from <dir of json results>, or --sql to print the queries.');
    process.exit(2);
  }
  const out = {};
  for (const [k, q] of Object.entries(QUERIES)) out[k] = await viaManagementApi(q);
  return out;
}

const cmp = (...keys) => (a, b) => {
  for (const k of keys) {
    const x = String(a[k] ?? ''), y = String(b[k] ?? '');
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
};
const roleList = (r) => (Array.isArray(r) ? r : String(r).replace(/^\{|\}$/g, '').split(',')).join(', ');
const block = (s) => '```sql\n' + s.trim() + '\n```';

function policiesMd(rows) {
  rows.sort(cmp('schemaname', 'tablename', 'policyname'));
  const out = ['# Row level security policies', '',
    'One entry per policy, straight from `pg_policies`. `USING` decides which rows a role can see or touch; `WITH CHECK` decides which rows it may write. A command with no policy for a role is denied.', ''];
  let table = '';
  for (const p of rows) {
    const t = `${p.schemaname}.${p.tablename}`;
    if (t !== table) { table = t; out.push(`## ${t}`, ''); }
    out.push(`### ${p.policyname}`, '',
      `- command: ${p.cmd}`,
      `- roles: ${roleList(p.roles)}`,
      `- ${p.permissive === 'PERMISSIVE' || p.permissive === true ? 'permissive' : 'restrictive'}`);
    if (p.qual) out.push('', 'USING', '', block(p.qual));
    if (p.with_check) out.push('', 'WITH CHECK', '', block(p.with_check));
    out.push('');
  }
  return out.join('\n');
}

function functionsSql(rows) {
  rows.sort(cmp('schema', 'name', 'args'));
  const out = ['-- Functions that run with their owner\'s rights (security definer), full bodies from pg_get_functiondef.',
    '-- "may be called by" lists the roles with EXECUTE on the function. anon = not signed in, authenticated = any signed-in',
    '-- user, service_role = the server only. PUBLIC means everyone (Postgres default when no grants were changed).', ''];
  for (const f of rows) {
    out.push(`-- ===== ${f.schema}.${f.name}(${f.args}) =====`, `-- may be called by: ${f.execute_grants || '(nobody besides the owner)'}`, f.def.trim(), '');
  }
  return out.join('\n');
}

function rlsMd(rows) {
  rows.sort(cmp('schema', 'table'));
  const out = ['# Tables with RLS on and no policies', '',
    'Row level security is on and there is no policy, so `anon` and `authenticated` get no rows at all. Only the server (service role, which bypasses RLS) or a security definer function can reach these.', '',
    '| table | forced |', '|---|---|'];
  for (const r of rows) out.push(`| ${r.schema}.${r.table} | ${r.forced ? 'yes' : 'no'} |`);
  return out.join('\n') + '\n';
}

function tablesMd(rows) {
  rows.sort(cmp('schema', 'table'));
  const out = ['# Every table', '',
    'RLS on or off, whether it is forced for the owner too, how many policies, and which API roles hold any table grant (what the policies then narrow down).', '',
    '| table | RLS | forced | policies | granted to |', '|---|---|---|---|---|'];
  for (const r of rows) out.push(`| ${r.schema}.${r.table} | ${r.rls ? 'on' : 'OFF'} | ${r.forced ? 'yes' : 'no'} | ${r.policies} | ${r.api_roles || ''} |`);
  return out.join('\n') + '\n';
}

function readme(d, date) {
  const noRls = d.tables.filter((t) => !t.rls).length;
  return `# Access rules dump

Taken from the live database on ${date}. Regenerate with \`node scripts/dump-access-rules.mjs\` (see the script header for the ways to run it). Files are sorted, so a diff between two dumps shows exactly which rule changed.

| what | count |
|---|---|
| policies (policies.md) | ${d.policies.length} |
| security definer functions (security-definer-functions.sql) | ${d.functions.length} |
| tables with RLS on and no policies (rls-without-policies.md) | ${d.rls.length} |
| tables in all (tables.md) | ${d.tables.length} |
| tables with RLS off | ${noRls} |

A few account and server ids that appear in flag rows are replaced with fixed placeholder uuids (\`00000000-0000-4000-8000-...\`), nothing else is edited.
`;
}

const data = await load();
// Every row carries an md5 the database computed; a copy that was shortened or retyped on the way (hand-pasted
// results) fails here instead of ending up published.
const md5 = (t) => createHash('md5').update(t).digest('hex');
const bad = [
  ...data.policies.filter((p) => md5(`${p.qual ?? ''}|${p.with_check ?? ''}`) !== p.md5).map((p) => `policy ${p.schemaname}.${p.tablename}.${p.policyname}`),
  ...data.functions.filter((f) => md5(f.def) !== f.md5).map((f) => `function ${f.schema}.${f.name}(${f.args})`),
];
if (bad.length) { console.error('Rows that do not match their md5 (copied wrong?):\n' + bad.join('\n')); process.exit(1); }
// Pages copied at different moments can overlap (the database changed in between): the row from the later
// file (sorted by name) wins, so a re-fetch named functions-z-*.json replaces what an earlier page had.
const uniq = (rows, key) => [...new Map(rows.map((r) => [key(r), r])).values()];
data.policies = uniq(data.policies, (p) => `${p.schemaname}.${p.tablename}.${p.policyname}`);
data.functions = uniq(data.functions, (f) => `${f.schema}.${f.name}(${f.args})`);
data.rls = uniq(data.rls, (r) => `${r.schema}.${r.table}`);
data.tables = uniq(data.tables, (r) => `${r.schema}.${r.table}`);
mkdirSync(OUT, { recursive: true });
const date = new Date().toISOString().slice(0, 10);
const files = {
  'policies.md': policiesMd(data.policies),
  'security-definer-functions.sql': functionsSql(data.functions),
  'rls-without-policies.md': rlsMd(data.rls),
  'tables.md': tablesMd(data.tables),
  'README.md': readme(data, date),
};
for (const [name, body] of Object.entries(files)) writeFileSync(join(OUT, name), redact(body));
console.log(`Wrote ${Object.keys(files).length} files to ${OUT}/: ${data.policies.length} policies, ${data.functions.length} security definer functions, ${data.rls.length} RLS tables without policies, ${data.tables.length} tables.`);
