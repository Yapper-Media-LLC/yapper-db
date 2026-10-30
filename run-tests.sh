#!/bin/sh
# One command: start Postgres in Docker, restore standins/supabase.sql + schema/*.sql (the live schema, no data),
# run the policy tests against the real functions, clean up. Extra arguments go to tests/sql/live/run.mjs,
# e.g. ./run-tests.sh --stages   or   ./run-tests.sh dm-privacy
set -eu
cd "$(dirname "$0")"
docker compose up -d --wait db
status=0
docker compose run --rm tests "$@" || status=$?
docker compose down -v >/dev/null 2>&1 || true
exit $status
