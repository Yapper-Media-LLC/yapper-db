// 544: automatic bans get a human look. Stand-ins for what 543 runs next to (PGlite stops at 024).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '544_auto_ban_review.sql'), 'utf8');

export default async function (h) {
  h.eq('544 has no drop / delete / truncate', /\b(drop|delete\s+from|truncate)\b/i.test(MIG), false);
  await h.admin();
  await h.db.exec(`
    create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
    create table if not exists public.site_moderators (user_id uuid primary key);
    create table if not exists public.site_bans (user_id uuid primary key, reason text, banned_by uuid, created_at timestamptz default now(), expires_at timestamptz);
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
  `);
  await h.db.exec(MIG);
  await h.db.exec(MIG); // re-runnable

  const mod = await h.signup('mod543@x.test', 'mod543');
  const auto = await h.signup('auto543@x.test', 'auto543');
  const manual = await h.signup('manual543@x.test', 'manual543');
  await h.q(`insert into public.site_moderators values ($1)`, [mod]);
  await h.q(`insert into public.site_bans (user_id, reason) values ($1, 'ban evasion')`, [auto]);
  await h.q(`insert into public.site_bans (user_id, reason, banned_by) values ($1, 'spam', $2)`, [manual, mod]);

  await h.as(auto);
  await h.fails('member cannot review', `select public.staff_review_auto_ban($1)`, [auto]);
  await h.as(mod);
  await h.fails('not an auto ban', `select public.staff_review_auto_ban($1)`, [manual]);
  await h.q(`select public.staff_review_auto_ban($1)`, [auto]);
  await h.fails('only once', `select public.staff_review_auto_ban($1)`, [auto]);

  await h.admin();
  const b = await h.one(`select reviewed_at is not null as r, reviewed_by from public.site_bans where user_id = $1`, [auto]);
  h.eq('stamped', b.r, true);
  h.eq('by the mod', b.reviewed_by, mod);
  h.eq('logged', (await h.q(`select 1 from public.mod_log where action = 'auto_ban_reviewed' and target_id = $1`, [auto])).length, 1);
}
