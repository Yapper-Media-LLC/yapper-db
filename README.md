# Yapper database: rules and tests

This is the database side of [Yapper](https://www.yapper.website) (also at yapin.gg), published so you can read the access rules yourself instead of taking our word for them.

What is here:

- `schema/` is a schema-only dump of the live database: every table with its columns, types and defaults, constraints, indexes, sequences, every function with its full body, triggers, row level security flags, every policy, and the table, column and function grants. No rows from any table, not even config. It is refreshed with each release batch; `schema/counts.json` has the date. See [The live schema](#the-live-schema) below.
- `standins/supabase.sql` is the small set of things Supabase provides that a plain Postgres doesn't have (roles, `auth.uid()`, the auth/storage tables, pg_net), so the dump restores anywhere. None of our own code is in there.
- `access-rules/` is the same rules in readable form: every policy, every security definer function and who may call it, every table with RLS on and no policy, the RLS state of every table.
- `supabase/migrations/` is every migration ever applied, in order.
- `tests/sql/` is the test suite. `tests/sql/live/` runs against the live schema; the `stageNN` tests replay migrations (see below).

## Run the tests against the live schema

Needs Docker, nothing else:

```bash
./run-tests.sh
```

or `docker compose up --abort-on-container-exit --exit-code-from tests`. It starts Postgres 17 in Docker, restores `standins/supabase.sql` and `schema/01..06`, then runs `tests/sql/live/*.test.mjs` against the real functions and policies. Each test file gets its own copy of the restored database. A run takes about ten seconds once the images are pulled.

With your own Postgres 17 instead (superuser, it creates databases): `npm install && PGHOST=... PGUSER=... PGPASSWORD=... npm run test:live`.

What the live tests check, with no stand-ins for any of our functions:

- `01-dm-privacy`: a DM is readable by its two people only. A stranger, a moderator, a head moderator and an admin (all signed in with 2FA, and checked to really be staff by the live `is_site_mod()`/`is_staff()`) read no messages, don't see the channel or its members, can't add themselves, post, edit or delete in it. Signed out sees nothing.
- `02-private-data`: signed out or signed in, nobody reads `app_host`/`api_host` (server secrets), `select *` on profiles is refused, and the private profile columns (mutes, Stripe customer id, ...) can't be read even by naming them.
- `03-server-privacy`: server messages are for members, a private channel only for the people it is opened to; a moderator who is not a member, a site-banned member and signed out read nothing; nobody can join by inserting a membership or post as someone else.
- `04-reports`: the one way staff see DM content is a report from someone in the DM. The report carries that message and a few before it, only staff read reports, and the DM itself stays closed to them.

The tests also prove they are not passing for a trivial reason: staff accounts are checked to be staff, and staff are shown reading a staff-only table, before the checks that they can't read DMs.

`./run-tests.sh --stages` additionally tries every `stageNN` test against the live schema and reports what happens with each (see the next section for why most of them can't run there).

## The migration tests (PGlite)

```bash
npm install
npm test
```

Each `stageNN.test.mjs` runs against migrations 001 to NN in [PGlite](https://pglite.dev), so a stage is checked exactly as it was when it shipped. Replaying all migrations from zero doesn't reproduce production: many later migrations patch live function bodies in place, and some need Supabase pieces PGlite doesn't have. So later stages start from stage 24 and put small stand-ins in place of the functions they lean on (`is_site_mod()` and the like), then test the migration's own change against those. That is a fair test of "does this migration do what it says", but not of the live database as a whole. That's what `schema/` and `tests/sql/live/` are for.

## The live schema

`schema/` restores in file order, after `standins/supabase.sql`:

| file | what |
|---|---|
| `01-tables.sql` | our roles, schemas, extensions, sequences, tables (columns, types, not null, identity) |
| `02-functions.sql` | every function in our schemas, full body from `pg_get_functiondef`, security definer ones marked |
| `03-defaults.sql` | column defaults (they can call functions, so they come after them), sequence ownership |
| `04-constraints-indexes.sql` | primary keys, unique, checks, foreign keys, indexes |
| `05-rls-policies-triggers.sql` | RLS on/forced per table, every policy (also ours on `storage.objects` and `realtime.messages`), triggers (also ours on `auth.users`) |
| `06-grants.sql` | schema, table, column and function grants to `anon`, `authenticated`, `service_role`, `authenticator`, `yapper_api` and PUBLIC, and default privileges |
| `REDACTED.md` | what was redacted |

It is made by `scripts/dump-schema.mjs` from read-only catalog queries (`pg_class`, `pg_attribute`, `pg_proc`, `pg_policy`, `aclexplode(...)`), the same way `pg_dump --schema-only` reads them. After a restore, the function bodies and policies are byte for byte the live ones: the dump records an md5 fingerprint of every live `pg_get_functiondef` and policy expression (`schema/counts.json`, `live_md5`), and the test runner recomputes it after every restore and stops if anything differs. It prints `Function bodies: identical to live. Policies: identical to live.`

Redactions: function bodies, defaults and policies are scanned for keys, tokens, passwords, database URLs and webhook URLs; anything found is replaced with `<redacted:kind>` and listed in `schema/REDACTED.md`. Server-side secrets live in table rows (Vault, `app_host.secrets`) and the dump has no rows, so their values are never in it. A few real account and server ids (staff accounts, Yapper's own servers) are swapped for fixed placeholder uuids (`00000000-0000-4000-8000-...`), here and in the rest of the repo.

What is not in it: Supabase's own schemas (`auth`, `storage`, `realtime`, `vault`, `cron`, `net`, ...) apart from our policies and triggers on their tables, the scheduled jobs, and any data.

### What the stand-ins are, and why

Supabase runs a few things beside Postgres that our rules call into. `standins/supabase.sql` recreates just enough of them:

| stand-in | live | why it's needed | faithful to live |
|---|---|---|---|
| roles `anon`, `authenticated`, `service_role`, `authenticator` | Supabase's API roles | every policy and grant names them | names, `service_role` bypasses RLS, the others don't |
| `auth.uid()`, `auth.role()`, `auth.jwt()`, `auth.email()` | Supabase's helpers over the JWT PostgREST verified | 900+ references in policies and functions | same definitions: read `request.jwt.claims` (and the older `request.jwt.claim.*` settings) |
| `auth.users`, `auth.identities`, `auth.mfa_factors` | GoTrue's tables | our signup triggers and a few functions read them | same columns and types as live; no GoTrue logic, no Supabase triggers |
| `storage.objects`, `storage.buckets`, `storage.foldername()` & co | Supabase Storage | our upload policies sit on `storage.objects` | same columns; helpers behave the same |
| `realtime.messages`, `realtime.topic()` | Supabase Realtime | our broadcast policies sit on it | plain table here (live is partitioned by day) |
| `vault.decrypted_secrets` | Supabase Vault | a few functions read a secret from it | empty table: no secret values exist here |
| `net.http_post()`, `net.http_get()` | the pg_net extension | some triggers send webhooks/notifications | records the request in `net.http_request_queue` instead of sending it |

Our own functions (`is_site_mod`, `is_staff`, `can_access_channel`, `server_perm`, every policy) are never stood in for in the live suite: the runner refuses to let a test replace one of them.

## How this repo is made

The private app repo copies `supabase/migrations/`, `tests/sql/`, `schema/`, `access-rules/` and these repo files in here with a script, swapping the placeholder ids on the way, and refuses to finish if anything looks like a key or a real id. `scripts/dump-schema.mjs` and `scripts/dump-access-rules.mjs` are the scripts that make the two dumps; they only read catalog tables.

## What this is not

There has been no outside security audit of Yapper. This repo lets you do your own reading. The app code (Next.js, the realtime server, the bot API) is not in here, only the database. The server side uses `service_role` (which bypasses RLS) for some work; what it does with it is in the app code, not here.

If you find a hole, email hello@yapin.gg (see [security.txt](https://www.yapper.website/.well-known/security.txt)). Please do not test against other people's accounts.
