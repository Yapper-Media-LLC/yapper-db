# What was redacted from the schema dump

Dump of 2026-10-30. Anything in a function body, column default or policy that matches a key, token, password or
webhook pattern (see SECRET_RULES in scripts/dump-schema.mjs) is replaced with `<redacted:kind>`.

Nothing matched: no secrets are stored in function bodies, defaults or policies.

Server-side secrets live in rows (`app_host.secrets`, Supabase Vault), and the dump has no rows, so their values are
never in here. A few real account and server ids are swapped for placeholder uuids (`00000000-0000-4000-8000-...`)
by the same redaction as the rest of this repo.
