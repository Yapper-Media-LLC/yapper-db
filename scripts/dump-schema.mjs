#!/usr/bin/env node
// Schema-only dump of the live database: every table, column, constraint, index, sequence, type, function (full
// body), trigger, RLS flag, policy and grant in Yapper's own schemas, as SQL that restores into a plain Postgres.
// No rows from any table, ever. Published in the yapper-db repo (schema/), where `./run-tests.sh` restores it into
// a Docker Postgres with the Supabase stand-ins and runs the policy tests against the real functions.
//
// Why not just replay the migrations: many later migrations patch a function body in place (create or replace)
// or were applied by hand, so the live database is the thing to test, not the file history.
//
// Read only: every query reads pg_catalog. No pg_dump password needed.
//
// How to run (pick one):
//   SUPABASE_ACCESS_TOKEN=sbp_... node scripts/dump-schema.mjs [--project ref] [--out dir]
//     Runs the queries through the Supabase Management API (read only), writes schema/ (default out dir).
//   node scripts/dump-schema.mjs --sql meta|functions [--page N --pages M]
//     Prints one query, for the Supabase MCP execute_sql or the SQL editor. Run `meta` once and `functions` for
//     page 0..M-1 (M=10 keeps each page around 170 KB), and `nonascii` and `verify` once. Save each result as
//     meta*.json, functions*.json, nonascii*.json, verify*.json.
//   node scripts/dump-schema.mjs --from dir [--out dir]
//     Builds the dump from saved results. A file may be a plain JSON result or a saved MCP execute_sql result
//     (the wrapper with <untrusted-data-...> tags); files are picked by name: *meta*, *functions*, *nonascii*, *verify*.
//
// Then: node scripts/sync-public-db.mjs (copies schema/ into ../yapper-db with the id redaction), commit, push.
//
// Secrets: function bodies and column defaults are scanned for anything key-like (rules below plus the ones in
// sync-public-db.mjs). A hit is replaced with '<redacted:NAME>' and listed in schema/REDACTED.md; the run fails on
// a hit it has no rule for, so a new secret in a function body is never published by accident.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { REDACT, redact } from './redact-ids.mjs';

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf(name);
  return i === -1 ? def : argv[i + 1];
};
const OUT = opt('--out', 'schema');
const PROJECT = opt('--project', process.env.SUPABASE_PROJECT_REF || 'dnfkuqzddwvtdojzgmdm');
const FROM = opt('--from');

// Yapper's own schemas. Everything in here is ours and goes into the dump.
const OURS = ['public', 'app_host', 'api_host', 'private'];
// Supabase-owned schemas where we still put policies or triggers of our own (storage.objects policies for the
// proofs/sounds buckets, realtime.messages policies, signup triggers on auth.users). Only the objects that are
// ours are dumped from these; the tables themselves come from the stand-ins.
const FOREIGN = ['auth', 'storage', 'realtime'];
const ours = `(${OURS.map((s) => `'${s}'`).join(',')})`;
const foreign = `(${FOREIGN.map((s) => `'${s}'`).join(',')})`;
// Roles whose grants are dumped. Supabase's internal roles (supabase_admin, dashboard_user, ...) are left out.
const ROLES = ['anon', 'authenticated', 'service_role', 'authenticator', 'yapper_api'];
const roles = `(${ROLES.map((s) => `'${s}'`).join(',')})`;

// An object is skipped when an extension owns it (dblink, unaccent and friends live in public).
const notExt = (cls, col) => `not exists (select 1 from pg_depend d where d.classid = '${cls}'::regclass and d.objid = ${col} and d.deptype = 'e')`;
// Grants as [{grantee, privilege, grantable}], owner entries left out, only the roles above or PUBLIC.
const acl = (col, owner) => `coalesce((select json_agg(json_build_object('grantee', case when g_.grantee = 0 then 'PUBLIC' else pg_get_userbyid(g_.grantee) end,
    'privilege', g_.privilege_type, 'grantable', g_.is_grantable) order by g_.grantee, g_.privilege_type)
  from aclexplode(${col}) g_ where g_.grantee <> ${owner} and (g_.grantee = 0 or pg_get_userbyid(g_.grantee) in ${roles})), '[]')`;

// search_path is pg_catalog so every name in the generated text comes out schema-qualified (same as pg_dump).
const PRELUDE = 'set search_path = pg_catalog;\n';

export const QUERIES = {
  meta: () => PRELUDE + `
select json_build_object(
 'server_version', current_setting('server_version'),
 'extensions', (select json_agg(json_build_object('name', extname, 'version', extversion, 'schema', extnamespace::regnamespace::text) order by extname) from pg_extension),
 'schemas', (select json_agg(json_build_object('name', nspname, 'acl', ${acl('nspacl', 'nspowner')}) order by nspname) from pg_namespace where nspname in ${ours} or nspname in ${foreign}),
 'enums', (select json_agg(json_build_object('schema', n.nspname, 'name', t.typname,
     'labels', (select json_agg(enumlabel order by enumsortorder) from pg_enum e where e.enumtypid = t.oid)) order by n.nspname, t.typname)
   from pg_type t join pg_namespace n on n.oid = t.typnamespace where t.typtype = 'e' and n.nspname in ${ours} and ${notExt('pg_type', 't.oid')}),
 'composites', (select json_agg(json_build_object('schema', n.nspname, 'name', t.typname,
     'attrs', (select json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod)) order by a.attnum)
       from pg_attribute a where a.attrelid = t.typrelid and a.attnum > 0 and not a.attisdropped)) order by n.nspname, t.typname)
   from pg_type t join pg_namespace n on n.oid = t.typnamespace join pg_class c on c.oid = t.typrelid
   where t.typtype = 'c' and c.relkind = 'c' and n.nspname in ${ours} and ${notExt('pg_type', 't.oid')}),
 'domains', (select json_agg(json_build_object('schema', n.nspname, 'name', t.typname, 'base', format_type(t.typbasetype, t.typtypmod),
     'notnull', t.typnotnull, 'default', t.typdefault,
     'checks', (select json_agg(pg_get_constraintdef(c.oid) order by c.conname) from pg_constraint c where c.contypid = t.oid)) order by n.nspname, t.typname)
   from pg_type t join pg_namespace n on n.oid = t.typnamespace where t.typtype = 'd' and n.nspname in ${ours} and ${notExt('pg_type', 't.oid')}),
 'sequences', (select json_agg(json_build_object('schema', s.schemaname, 'name', s.sequencename, 'type', s.data_type::text,
     'start', s.start_value::text, 'inc', s.increment_by::text, 'min', s.min_value::text, 'max', s.max_value::text, 'cache', s.cache_size::text, 'cycle', s.cycle,
     'owned_by', (select quote_ident(tn.nspname) || '.' || quote_ident(tc.relname) || '.' || quote_ident(a.attname)
        from pg_depend d join pg_class tc on tc.oid = d.refobjid join pg_namespace tn on tn.oid = tc.relnamespace
        join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
        where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'a'),
     'acl', ${acl('c.relacl', 'c.relowner')}) order by s.schemaname, s.sequencename)
   from pg_sequences s join pg_namespace n on n.nspname = s.schemaname join pg_class c on c.relnamespace = n.oid and c.relname = s.sequencename
   where s.schemaname in ${ours}
     and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'i')
     and ${notExt('pg_class', 'c.oid')}),
 'tables', (select json_agg(json_build_object('schema', n.nspname, 'name', c.relname, 'rls', c.relrowsecurity, 'force_rls', c.relforcerowsecurity,
     'columns', (select json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
          'identity', a.attidentity, 'generated', a.attgenerated, 'default', pg_get_expr(ad.adbin, ad.adrelid),
          'collation', case when a.attcollation <> t.typcollation and a.attcollation <> 0 then (select quote_ident(collname) from pg_collation where oid = a.attcollation) end,
          'acl', ${acl('a.attacl', 'c.relowner')}) order by a.attnum)
        from pg_attribute a join pg_type t on t.oid = a.atttypid left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
        where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped),
     'acl', ${acl('c.relacl', 'c.relowner')}) order by n.nspname, c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname in ${ours} and ${notExt('pg_class', 'c.oid')}),
 'views', (select json_agg(json_build_object('schema', n.nspname, 'name', c.relname, 'kind', c.relkind, 'def', pg_get_viewdef(c.oid),
     'acl', ${acl('c.relacl', 'c.relowner')}) order by n.nspname, c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('v', 'm') and n.nspname in ${ours} and ${notExt('pg_class', 'c.oid')}),
 'constraints', (select json_agg(json_build_object('table', quote_ident(n.nspname) || '.' || quote_ident(c.relname), 'name', k.conname, 'type', k.contype,
     'def', pg_get_constraintdef(k.oid)) order by n.nspname, c.relname, k.conname)
   from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ${ours} and k.contype in ('p', 'u', 'c', 'f', 'x') and k.conislocal),
 'indexes', (select json_agg(json_build_object('schema', n.nspname, 'name', i.relname, 'def', pg_get_indexdef(i.oid)) order by n.nspname, i.relname)
   from pg_index x join pg_class i on i.oid = x.indexrelid join pg_class c on c.oid = x.indrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ${ours} and not exists (select 1 from pg_constraint k where k.conindid = i.oid and k.contype in ('p', 'u', 'x'))),
 'triggers', (select json_agg(json_build_object('table', quote_ident(n.nspname) || '.' || quote_ident(c.relname), 'name', t.tgname,
     'def', pg_get_triggerdef(t.oid), 'enabled', t.tgenabled) order by n.nspname, c.relname, t.tgname)
   from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
   join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
   where not t.tgisinternal and (n.nspname in ${ours} or (n.nspname in ${foreign} and pn.nspname in ${ours}))),
 'policies', (select json_agg(json_build_object('table', quote_ident(n.nspname) || '.' || quote_ident(c.relname), 'name', p.polname,
     'permissive', p.polpermissive, 'cmd', p.polcmd,
     'roles', (select json_agg(case when r = 0 then 'public' else pg_get_userbyid(r) end order by r) from unnest(p.polroles) r),
     'using', pg_get_expr(p.polqual, p.polrelid), 'check', pg_get_expr(p.polwithcheck, p.polrelid)) order by n.nspname, c.relname, p.polname)
   from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ${ours} or n.nspname in ('storage', 'realtime')),
 'foreign_rls', (select json_agg(json_build_object('table', quote_ident(n.nspname) || '.' || quote_ident(c.relname), 'rls', c.relrowsecurity, 'force_rls', c.relforcerowsecurity) order by 1)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname in ('storage', 'realtime')
     and exists (select 1 from pg_policy p where p.polrelid = c.oid)),
 'default_acl', (select json_agg(json_build_object('owner', pg_get_userbyid(d.defaclrole), 'schema', n.nspname, 'objtype', d.defaclobjtype,
     'acl', (select json_agg(json_build_object('grantee', case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end, 'privilege', a.privilege_type) order by a.grantee, a.privilege_type)
       from aclexplode(d.defaclacl) a where a.grantee = 0 or pg_get_userbyid(a.grantee) in ${roles})) order by 1, 2, 3)
   from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace where n.nspname in ${ours} and pg_get_userbyid(d.defaclrole) = 'postgres'),
 'role_settings', (select json_agg(json_build_object('role', r.rolname, 'config', s.setconfig) order by r.rolname)
   from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname in ${roles}),
 'roles', (select json_agg(json_build_object('name', rolname, 'login', rolcanlogin, 'bypassrls', rolbypassrls, 'inherit', rolinherit,
     'member_of', (select json_agg(pg_get_userbyid(m.roleid) order by 1) from pg_auth_members m where m.member = r.oid and pg_get_userbyid(m.roleid) in ${roles})) order by rolname)
   from pg_roles r where rolname in ${roles}),
 'auth_columns', (select json_agg(json_build_object('table', quote_ident(n.nspname) || '.' || quote_ident(c.relname),
     'columns', (select json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull) order by a.attnum)
       from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)) order by 1)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and n.nspname in ${foreign})
)`,
  // Function bodies are the bulk (about 1.3 MB), so they can be fetched in pages: page N of M by running byte count.
  functions: (page, pages) => PRELUDE + `
with f as (
  select p.oid, n.nspname as schema, p.proname as name, pg_get_function_identity_arguments(p.oid) as args,
    pg_get_functiondef(p.oid) as def, p.prosecdef as secdef, ${acl('p.proacl', 'p.proowner')} as acl, p.proacl is null as default_acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ${ours} and p.prokind in ('f', 'p') and ${notExt('pg_proc', 'p.oid')}
), paged as (
  select f.*, md5(def) as md5, sum(length(def)) over (order by schema, name, args) as run, sum(length(def)) over () as total from f
)
select json_agg(json_build_object('schema', schema, 'name', name, 'args', args, 'def', def, 'md5', md5, 'secdef', secdef, 'acl', acl, 'default_acl', default_acl)
  order by schema, name, args)
from paged ${pages > 1 ? `where least(floor((run - 1) * ${pages} / total), ${pages - 1}) = ${page}` : ''}`,
  // Bodies with characters outside ASCII (zero-width and combining marks in name and blank-message checks) can get
  // altered on the way through a JSON tool, so those come again as base64 of their UTF-8 bytes and replace the plain copy.
  nonascii: () => PRELUDE + `
select json_agg(json_build_object('schema', n.nspname, 'name', p.proname, 'args', pg_get_function_identity_arguments(p.oid),
    'b64', translate(encode(convert_to(pg_get_functiondef(p.oid), 'UTF8'), 'base64'), E'\\n', ''), 'md5', md5(pg_get_functiondef(p.oid))) order by 1)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ${ours} and p.prokind in ('f', 'p') and ${notExt('pg_proc', 'p.oid')} and pg_get_functiondef(p.oid) ~ '[^\\x01-\\x7f]'`,
  // Fingerprints of the live function bodies and policies, with the same id redaction applied as the dump gets, so
  // tests/sql/live/run.mjs can check after a restore that what it restored is byte for byte what runs live.
  // Sorted by hash, not by name, so collation differences between servers don't matter.
  verify: () => {
    const swap = (e) => Object.entries(REDACT).filter(([k]) => /^[0-9a-f-]{36}$/.test(k)).reduce((x, [k, v]) => `replace(${x}, '${k}', '${v}')`, e);
    return PRELUDE + `
select json_build_object(
 'functions_md5', (select md5(string_agg(h, ',' order by h)) from (select md5(${swap('pg_get_functiondef(p.oid)')}) as h
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ${ours} and p.prokind in ('f', 'p') and ${notExt('pg_proc', 'p.oid')}) x),
 'policies_md5', (select md5(string_agg(h, ',' order by h)) from (select md5(n.nspname || '.' || c.relname || '.' || p.polname || '|' || p.polcmd::text || '|' || p.polpermissive::text
      || '|' || ${swap("coalesce(pg_get_expr(p.polqual, p.polrelid), '')")} || '|' || ${swap("coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')")}) as h
    from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ${ours} or n.nspname in ('storage', 'realtime')) x)
)`;
  },
};

if (argv.includes('--sql')) {
  const which = opt('--sql');
  const page = Number(opt('--page', 0)), pages = Number(opt('--pages', 1));
  if (!QUERIES[which]) { console.error('--sql meta|functions|nonascii|verify'); process.exit(2); }
  console.log(QUERIES[which](page, pages).trim() + ';');
  process.exit(0);
}

async function viaManagementApi(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query: sql, read_only: true }),
  });
  if (!r.ok) throw new Error(`Management API ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

// A result is an array with one row holding one json column. Saved MCP results wrap that array in
// {"result": "... <untrusted-data-x> [rows] </untrusted-data-x> ..."}.
function parseResult(text) {
  let v = JSON.parse(text);
  if (v && typeof v.result === 'string') {
    const m = /<untrusted-data-([\w-]+)>\s*(\[[\s\S]*\])\s*<\/untrusted-data-\1>/.exec(v.result);
    if (!m) throw new Error('saved MCP result without data');
    v = JSON.parse(m[2]);
  }
  if (Array.isArray(v) && v.length === 1 && Object.keys(v[0]).length === 1) v = Object.values(v[0])[0];
  return v;
}

async function load() {
  if (FROM) {
    const files = readdirSync(FROM).sort();
    const pick = (k) => files.filter((f) => f.includes(k)).map((f) => parseResult(readFileSync(join(FROM, f), 'utf8')));
    const metas = pick('meta');
    if (metas.length !== 1) throw new Error(`Need exactly one *meta* file in ${FROM}, found ${metas.length}`);
    return { meta: metas[0], functions: pick('functions').flat(), nonascii: pick('nonascii').flat(), verify: pick('verify')[0] };
  }
  if (!process.env.SUPABASE_ACCESS_TOKEN) {
    console.error('Set SUPABASE_ACCESS_TOKEN, or pass --from <dir of saved results>, or --sql meta|functions to print a query.');
    process.exit(2);
  }
  return {
    meta: parseResult(JSON.stringify(await viaManagementApi(QUERIES.meta()))),
    functions: parseResult(JSON.stringify(await viaManagementApi(QUERIES.functions(0, 1)))),
    nonascii: parseResult(JSON.stringify(await viaManagementApi(QUERIES.nonascii()))) ?? [],
    verify: parseResult(JSON.stringify(await viaManagementApi(QUERIES.verify()))),
  };
}

// ---------- secrets ----------
// [name, regex]. Applied to every function body, default and policy expression. Anything that matches is replaced.
const SECRET_RULES = [
  ['supabase-secret-key', /sb_secret_[A-Za-z0-9_-]{20,}/g],
  ['jwt', /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/g],
  ['bot-token', /\byb_[A-Za-z0-9]{8,}\.[A-Za-z0-9_-]{16,}/g],
  ['oauth-token', /\byo_[A-Za-z0-9_-]{30,}/g],
  ['stripe-key', /\b(sk|rk)_live_[A-Za-z0-9]{16,}/g],
  ['stripe-webhook-secret', /\bwhsec_[A-Za-z0-9]{20,}/g],
  ['anthropic-key', /\bsk-ant-[A-Za-z0-9_-]{20,}/g],
  ['resend-key', /\bre_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,}/g],
  ['github-token', /\b(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}/g],
  ['supabase-access-token', /\bsbp_[A-Za-z0-9]{20,}/g],
  ['aws-key', /\bAKIA[0-9A-Z]{16}\b/g],
  ['private-key', /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g],
  ['database-url', /postgres(ql)?:\/\/[^:\s'"]+:[^@\s'"]+@[^\s'"]+/g],
  ['discord-webhook', /https:\/\/(?:\w+\.)?discord(?:app)?\.com\/api\/webhooks\/[^\s'"]+/g],
  ['slack-webhook', /https:\/\/hooks\.slack\.com\/[^\s'"]+/g],
];
// Looser patterns that are not replaced automatically: a hit stops the run so a person looks at it and either adds
// a SECRET_RULES entry or an ALLOW entry. Long random-looking strings in quotes, bearer headers with a literal.
const SUSPECT_RULES = [
  ['long-random-literal', /'[A-Za-z0-9+/_-]{40,}={0,2}'/g],
  ['bearer-literal', /Bearer [A-Za-z0-9._-]{20,}/g],
  ['key-assignment', /\b(api[_-]?key|secret|password|token)\s*[:=]\s*'[^'\s]{12,}'/gi],
];
// Literals that look random but are not secrets (checked by hand). Matched against the whole hit.
const ALLOW = [
  /^'[a-z]+'$/, // translate() target alphabets in the name and slur folding (fold_fancy, ru_latin, slur_text)
  /^'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'$/, // invite code alphabet (invite_random_code)
];

const redactions = [];
const suspects = [];
function scrub(text, where) {
  let t = text;
  for (const [name, re] of SECRET_RULES) {
    t = t.replace(re, () => { redactions.push({ where, name }); return `<redacted:${name}>`; });
  }
  for (const [name, re] of SUSPECT_RULES) {
    for (const m of t.match(re) ?? []) if (!ALLOW.some((a) => a.test(m))) suspects.push(`${where}: ${name}: ${m.slice(0, 24)}...`);
  }
  return t;
}

// ---------- SQL generation ----------
const q = (s) => (/^[a-z_][a-z0-9_]*$/.test(s) && !RESERVED.has(s) ? s : `"${s.replace(/"/g, '""')}"`);
const RESERVED = new Set(['all', 'analyse', 'analyze', 'and', 'any', 'array', 'as', 'asc', 'asymmetric', 'authorization', 'binary', 'both', 'case', 'cast', 'check', 'collate', 'collation', 'column', 'concurrently', 'constraint', 'create', 'cross', 'current_catalog', 'current_date', 'current_role', 'current_schema', 'current_time', 'current_timestamp', 'current_user', 'default', 'deferrable', 'desc', 'distinct', 'do', 'else', 'end', 'except', 'false', 'fetch', 'for', 'foreign', 'freeze', 'from', 'full', 'grant', 'group', 'having', 'ilike', 'in', 'initially', 'inner', 'intersect', 'into', 'is', 'isnull', 'join', 'lateral', 'leading', 'left', 'like', 'limit', 'localtime', 'localtimestamp', 'natural', 'not', 'notnull', 'null', 'offset', 'on', 'only', 'or', 'order', 'outer', 'overlaps', 'placing', 'primary', 'references', 'returning', 'right', 'select', 'session_user', 'similar', 'some', 'symmetric', 'system_user', 'table', 'tablesample', 'then', 'to', 'trailing', 'true', 'union', 'unique', 'user', 'using', 'variadic', 'verbose', 'when', 'where', 'window', 'with']);
const qn = (schema, name) => `${q(schema)}.${q(name)}`;
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;
const PRIV_ORDER = ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'USAGE', 'EXECUTE', 'CREATE', 'MAINTAIN'];

// grant lines from an acl list: one line per grantee
function grants(acl, objSql, { col } = {}) {
  const by = new Map();
  for (const a of acl) {
    if (!by.has(a.grantee)) by.set(a.grantee, []);
    by.get(a.grantee).push(a.privilege);
  }
  return [...by].map(([g, privs]) => {
    privs.sort((x, y) => PRIV_ORDER.indexOf(x) - PRIV_ORDER.indexOf(y));
    const p = col ? privs.map((x) => `${x} (${q(col)})`).join(', ') : privs.join(', ');
    return `grant ${p} on ${objSql} to ${g === 'PUBLIC' ? 'public' : q(g)};`;
  });
}

function build({ meta, functions, nonascii = [] }) {
  const files = {};
  const m = meta;
  const md5 = (t) => createHash('md5').update(t).digest('hex');
  const exact = new Map(nonascii.map((x) => [`${x.schema}.${x.name}(${x.args})`, x]));
  for (const f of functions) {
    const x = exact.get(`${f.schema}.${f.name}(${f.args})`);
    if (x && x.md5 === f.md5) f.def = Buffer.from(x.b64, 'base64').toString('utf8');
  }
  const bad = functions.filter((f) => md5(f.def) !== f.md5);
  if (bad.length) throw new Error('Function bodies that do not match their md5 (copied wrong?): ' + bad.map((f) => f.name).join(', '));
  const seen = new Set();
  for (const f of functions) {
    const k = `${f.schema}.${f.name}(${f.args})`;
    if (seen.has(k)) throw new Error(`function ${k} twice (pages overlap?)`);
    seen.add(k);
  }

  const head = (title, more = '') => `-- ${title}\n-- Schema-only dump of the live Yapper database (Postgres ${m.server_version}). No rows from any table.\n-- Made by scripts/dump-schema.mjs from catalog queries. ${more}\n`;

  // 01: roles, schemas, extensions, types, sequences, tables (no defaults, no constraints yet)
  const a = [head('01 roles, schemas, extensions, types, sequences, tables', 'Restore order: 01..06, after supabase-standins.sql.'),
    'set check_function_bodies = off;', 'set client_min_messages = warning;', ''];
  a.push('-- Our own role (the API host). The Supabase roles come from the stand-ins.');
  for (const r of m.roles.filter((r) => !['anon', 'authenticated', 'service_role', 'authenticator'].includes(r.name))) {
    a.push(`do $$ begin create role ${q(r.name)} ${r.login ? 'login' : 'nologin'}${r.bypassrls ? ' bypassrls' : ''}${r.inherit ? '' : ' noinherit'}; exception when duplicate_object then null; end $$;`);
    for (const g of r.member_of ?? []) a.push(`grant ${q(g)} to ${q(r.name)};`);
  }
  for (const r of m.roles) for (const g of (m.role_settings ?? []).filter((s) => s.role === r.name).flatMap((s) => s.config)) {
    // statement timeouts and PostgREST settings on the API roles; harmless in a test database, kept so the dump says what is set
    const [k, ...v] = g.split('=');
    a.push(`-- live: alter role ${q(r.name)} set ${k} = ${lit(v.join('='))};`);
  }
  a.push('', '-- Schemas');
  for (const s of m.schemas.filter((s) => OURS.includes(s.name))) a.push(`create schema if not exists ${q(s.name)};`);
  a.push('', '-- Extensions on the live database. The ones a vanilla Postgres ships are created; the Supabase-only ones', '-- (pg_net, pg_cron, supabase_vault, pg_graphql...) are covered by supabase-standins.sql.');
  const VANILLA = new Set(['pgcrypto', 'uuid-ossp', 'pg_trgm', 'unaccent', 'dblink', 'pg_stat_statements', 'citext', 'btree_gist', 'btree_gin', 'hstore', 'ltree', 'fuzzystrmatch']);
  for (const e of m.extensions) {
    if (e.name === 'plpgsql') continue;
    a.push(VANILLA.has(e.name) ? `create extension if not exists ${q(e.name)} with schema ${q(e.schema)};  -- live ${e.version}`
      : `-- extension ${e.name} ${e.version} in ${e.schema}: Supabase-provided, see supabase-standins.sql`);
  }
  a.push('', '-- Types');
  for (const t of m.enums ?? []) a.push(`create type ${qn(t.schema, t.name)} as enum (${t.labels.map(lit).join(', ')});`);
  for (const t of m.composites ?? []) a.push(`create type ${qn(t.schema, t.name)} as (${t.attrs.map((x) => `${q(x.name)} ${x.type}`).join(', ')});`);
  for (const t of m.domains ?? []) a.push(`create domain ${qn(t.schema, t.name)} as ${t.base}${t.default ? ` default ${t.default}` : ''}${t.notnull ? ' not null' : ''}${(t.checks ?? []).map((c) => ` ${c}`).join('')};`);
  a.push('', '-- Sequences (identity columns make their own)');
  for (const s of m.sequences ?? []) {
    a.push(`create sequence ${qn(s.schema, s.name)} as ${s.type} increment ${s.inc} minvalue ${s.min} maxvalue ${s.max} start ${s.start} cache ${s.cache}${s.cycle ? ' cycle' : ''};`);
  }
  a.push('', '-- Tables: columns, types, not null and identity. Defaults come in 03 (they can call functions), constraints in 04.');
  for (const t of m.tables) {
    const cols = (t.columns ?? []).map((c) => {
      let s = `  ${q(c.name)} ${c.type}`;
      if (c.collation) s += ` collate ${c.collation}`;
      if (c.generated === 's') s += ` generated always as (${scrub(c.default, `${t.name}.${c.name} generated`)}) stored`;
      if (c.identity === 'a') s += ' generated always as identity';
      if (c.identity === 'd') s += ' generated by default as identity';
      if (c.notnull) s += ' not null';
      return s;
    });
    a.push(`create table ${qn(t.schema, t.name)} (\n${cols.join(',\n')}\n);`);
  }
  files['01-tables.sql'] = a.join('\n') + '\n';

  // 02: functions
  const b = [head('02 functions', 'Full bodies from pg_get_functiondef, sorted by schema, name, arguments.'), 'set check_function_bodies = off;', ''];
  for (const f of [...functions].sort((x, y) => `${x.schema}.${x.name}(${x.args})`.localeCompare(`${y.schema}.${y.name}(${y.args})`))) {
    b.push(`-- ${f.schema}.${f.name}(${f.args})${f.secdef ? '  [security definer]' : ''}`);
    b.push(scrub(f.def.trim(), `function ${f.schema}.${f.name}(${f.args})`) + ';', '');
  }
  files['02-functions.sql'] = b.join('\n');

  // 03: defaults, sequence ownership, views
  const c = [head('03 column defaults, sequence ownership, views'), ''];
  for (const t of m.tables) for (const col of t.columns ?? []) {
    if (col.default != null && !col.identity && col.generated !== 's') c.push(`alter table ${qn(t.schema, t.name)} alter column ${q(col.name)} set default ${scrub(col.default, `${t.name}.${col.name} default`)};`);
  }
  for (const s of m.sequences ?? []) if (s.owned_by) c.push(`alter sequence ${qn(s.schema, s.name)} owned by ${s.owned_by};`);
  for (const v of m.views ?? []) c.push(`create ${v.kind === 'm' ? 'materialized view' : 'view'} ${qn(v.schema, v.name)} as\n${v.def.trim().replace(/;$/, '')};`);
  files['03-defaults.sql'] = c.join('\n') + '\n';

  // 04: constraints (keys first, then checks, then foreign keys) and indexes
  const d = [head('04 constraints and indexes'), ''];
  const order = { p: 0, u: 1, x: 2, c: 3, f: 4 };
  for (const k of [...m.constraints].sort((x, y) => order[x.type] - order[y.type] || x.table.localeCompare(y.table) || x.name.localeCompare(y.name))) {
    d.push(`alter table ${k.table} add constraint ${q(k.name)} ${scrub(k.def, `constraint ${k.name}`)};`);
  }
  d.push('');
  for (const i of m.indexes ?? []) d.push(`${i.def};`);
  files['04-constraints-indexes.sql'] = d.join('\n') + '\n';

  // 05: row level security and policies, triggers
  const CMD = { r: 'select', a: 'insert', w: 'update', d: 'delete', '*': 'all' };
  const e = [head('05 row level security, policies, triggers', 'Policies straight from pg_policy; the same rules are listed readably in access-rules/policies.md.'), ''];
  for (const t of m.tables) {
    if (t.rls) e.push(`alter table ${qn(t.schema, t.name)} enable row level security;`);
    if (t.force_rls) e.push(`alter table ${qn(t.schema, t.name)} force row level security;`);
  }
  for (const t of m.foreign_rls ?? []) {
    if (t.rls) e.push(`alter table ${t.table} enable row level security;`);
    if (t.force_rls) e.push(`alter table ${t.table} force row level security;`);
  }
  e.push('');
  for (const p of m.policies) {
    let s = `create policy ${q(p.name)} on ${p.table} as ${p.permissive ? 'permissive' : 'restrictive'} for ${CMD[p.cmd]} to ${p.roles.map((r) => (r === 'public' ? 'public' : q(r))).join(', ')}`;
    if (p.using != null) s += `\n  using (${scrub(p.using, `policy ${p.name}`)})`;
    if (p.check != null) s += `\n  with check (${scrub(p.check, `policy ${p.name}`)})`;
    e.push(s + ';');
  }
  e.push('');
  for (const t of m.triggers) {
    e.push(`${t.def};`);
    if (t.enabled === 'D') e.push(`alter table ${t.table} disable trigger ${q(t.name)};`);
    else if (t.enabled === 'R') e.push(`alter table ${t.table} enable replica trigger ${q(t.name)};`);
    else if (t.enabled === 'A') e.push(`alter table ${t.table} enable always trigger ${q(t.name)};`);
  }
  files['05-rls-policies-triggers.sql'] = e.join('\n') + '\n';

  // 06: grants
  const g = [head('06 grants', 'Only grants to anon, authenticated, service_role, authenticator, yapper_api and PUBLIC.'),
    '-- Every object starts with Postgres defaults (functions: EXECUTE for PUBLIC, tables: owner only). Where the live',
    '-- object has an explicit ACL, the defaults are revoked first and the live grants applied, so the result matches live.', ''];
  for (const s of m.schemas.filter((s) => OURS.includes(s.name))) {
    g.push(`revoke all on schema ${q(s.name)} from public;`, ...grants(s.acl, `schema ${q(s.name)}`));
  }
  g.push('');
  for (const t of m.tables) {
    const obj = `table ${qn(t.schema, t.name)}`;
    g.push(...grants(t.acl, obj));
    for (const col of t.columns ?? []) g.push(...grants(col.acl ?? [], obj, { col: col.name }));
  }
  for (const v of m.views ?? []) g.push(...grants(v.acl, `table ${qn(v.schema, v.name)}`));
  for (const s of m.sequences ?? []) g.push(...grants(s.acl, `sequence ${qn(s.schema, s.name)}`));
  g.push('');
  for (const f of functions) {
    if (f.default_acl) continue;
    const obj = `function ${qn(f.schema, f.name)}(${f.args})`;
    g.push(`revoke all on ${obj} from public;`, ...grants(f.acl, obj));
  }
  g.push('', '-- Default privileges for objects postgres creates later (what a new migration gets without a grant).');
  const OBJ = { r: 'tables', S: 'sequences', f: 'functions', T: 'types', n: 'schemas' };
  for (const da of m.default_acl ?? []) {
    const by = new Map();
    for (const x of da.acl ?? []) { if (!by.has(x.grantee)) by.set(x.grantee, []); by.get(x.grantee).push(x.privilege); }
    for (const [who, privs] of by) g.push(`alter default privileges for role postgres in schema ${q(da.schema)} grant ${privs.join(', ')} on ${OBJ[da.objtype]} to ${who === 'PUBLIC' ? 'public' : q(who)};`);
  }
  files['06-grants.sql'] = g.join('\n') + '\n';

  return { files, counts: {
    tables: m.tables.length, columns: m.tables.reduce((n, t) => n + (t.columns?.length ?? 0), 0), functions: functions.length,
    security_definer: functions.filter((f) => f.secdef).length, constraints: m.constraints.length, indexes: (m.indexes ?? []).length,
    triggers: m.triggers.length, policies: m.policies.length, sequences: (m.sequences ?? []).length, enums: (m.enums ?? []).length,
    views: (m.views ?? []).length,
  } };
}

const data = await load();
const { files, counts } = build(data);
if (suspects.length) {
  console.error('Looks like it could be a secret, check by hand and add a SECRET_RULES or ALLOW entry in scripts/dump-schema.mjs:\n' + suspects.join('\n'));
  process.exit(1);
}
const date = new Date().toISOString().slice(0, 10);
files['REDACTED.md'] = `# What was redacted from the schema dump

Dump of ${date}. Anything in a function body, column default or policy that matches a key, token, password or
webhook pattern (see SECRET_RULES in scripts/dump-schema.mjs) is replaced with \`<redacted:kind>\`.

${redactions.length ? '| where | kind |\n|---|---|\n' + redactions.map((r) => `| ${r.where} | ${r.name} |`).join('\n') : 'Nothing matched: no secrets are stored in function bodies, defaults or policies.'}

Server-side secrets live in rows (\`app_host.secrets\`, Supabase Vault), and the dump has no rows, so their values are
never in here. A few real account and server ids are swapped for placeholder uuids (\`00000000-0000-4000-8000-...\`)
by the same redaction as the rest of this repo.
`;
mkdirSync(OUT, { recursive: true });
for (const [name, body] of Object.entries(files)) writeFileSync(join(OUT, name), redact(body));
// live_md5: fingerprints taken from the live database at dump time; the test runner recomputes them after a restore.
writeFileSync(join(OUT, 'counts.json'), JSON.stringify({ date, server_version: data.meta.server_version, ...counts, live_md5: data.verify ?? null }, null, 2) + '\n');
if (!data.verify) console.warn('No verify result (--sql verify): counts.json has no live fingerprints, the runner will skip the byte-for-byte check.');
console.log(`Wrote ${OUT}/ (${Object.keys(files).length + 1} files):`, Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(', '), `| ${redactions.length} redactions`);
