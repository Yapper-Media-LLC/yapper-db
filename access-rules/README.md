# Access rules dump

Taken from the live database on 2026-10-28. Regenerate with `node scripts/dump-access-rules.mjs` (see the script header for the ways to run it). Files are sorted, so a diff between two dumps shows exactly which rule changed.

| what | count |
|---|---|
| policies (policies.md) | 179 |
| security definer functions (security-definer-functions.sql) | 837 |
| tables with RLS on and no policies (rls-without-policies.md) | 109 |
| tables in all (tables.md) | 202 |
| tables with RLS off | 0 |

A few account and server ids that appear in flag rows are replaced with fixed placeholder uuids (`00000000-0000-4000-8000-...`), nothing else is edited.
