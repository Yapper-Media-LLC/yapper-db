// Usage: node tests/sql/run.mjs [maxStage]
// Each stageNN.test.mjs runs against migrations 001..NN only, so every stage
// is checked exactly as it will exist when that stage is rolled out.
// Later migrations need Supabase bits the stand-ins don't have (PGlite stops at 025), so a stage
// file past that can export `base` (run 001..base) and `extra` (just the later migrations it needs).
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setup } from './harness.mjs';

const here = dirname(fileURLToPath(import.meta.url));
// Default: every stage (stage numbers follow migration numbers, which are past 99 now).
const max = parseInt(process.argv[2] ?? '9999', 10);
const tests = readdirSync(here)
  .filter((f) => /^stage\d+[a-z]?\.test\.mjs$/.test(f))
  .sort()
  .filter((f) => parseInt(f.slice(5), 10) <= max);

let failed = false;
for (const f of tests) {
  const stage = parseInt(f.slice(5), 10);
  try {
    const mod = await import(pathToFileURL(`${here}/${f}`).href);
    const h = await setup(mod.base ?? stage);
    for (const m of mod.extra ?? []) {
      try { await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', m), 'utf8')); }
      catch (e) { throw new Error(`Migration ${m} failed: ${e.message}`); }
    }
    await mod.default(h);
    console.log(`✓ ${f} (${h.passed} checks)`);
  } catch (e) {
    failed = true;
    console.log(`${f}\n   ${e.message}`);
  }
}
process.exit(failed ? 1 : 0);
