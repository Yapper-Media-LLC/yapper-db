# Yapper database: rules and tests

This is the database side of [Yapper](https://www.yapper.website) (also at yapin.gg), published so you can read the access rules yourself instead of taking our word for them.

What is here:

- `supabase/migrations/` is every migration ever applied to the live database, in order. Tables, row level security policies, functions, triggers, grants. The live database is the result of running these.
- `access-rules/` is a dump of what the live database actually enforces right now: every RLS policy, every security definer function with its full body and who may call it, every table with RLS on and no policy, and the RLS state of every table. Sorted, so a diff between two dumps shows exactly which rule changed. `access-rules/README.md` has the date it was taken.
- `tests/sql/` is the test suite behind the rules. It runs the migrations into [PGlite](https://pglite.dev) (real Postgres compiled to WebAssembly) with small stand-ins for Supabase's auth and storage schemas, then signs in as fake users and checks who can read or write what. No Supabase project, no keys, no network.

## Run the tests

```bash
npm install
npm test
```

Each `stageNN.test.mjs` runs against migrations 001 to NN, so a stage is checked exactly as it existed when it shipped. Later stages that need bits the stand-ins do not have export `base` and `extra`, see `tests/sql/run.mjs`. The GitHub Action in this repo runs the same command on every push.

## How this repo is made

The private app repo copies `supabase/migrations/`, `tests/sql/` and the dump in here with a script. Three ids (the founder's account and two staff test servers) are swapped for fixed placeholder uuids (`00000000-0000-4000-8000-...`) on the way; nothing else is edited. The dump is made by `scripts/dump-access-rules.mjs`, which only reads `pg_policies`, `pg_proc` and `pg_class`.

## What this is not

There has been no outside security audit of Yapper. This repo lets you do your own reading. The app code (Next.js, the realtime server, the bot API) is not in here, only the database.

If you find a hole, email hello@yapin.gg (see [security.txt](https://www.yapper.website/.well-known/security.txt)). Please do not test against other people's accounts.
