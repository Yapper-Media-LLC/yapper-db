// 278: intimate image removal requests. Stand-ins for what 277 runs next to (PGlite stops at 024), then 277 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '278_image_removal.sql'), 'utf8');

export default async function (h) {
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(`
    create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
      mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
    create table if not exists public.mod_log (id bigserial primary key, actor uuid references public.profiles (id), action text, target_id uuid references public.profiles (id), reason text, created_at timestamptz default now());
    create table if not exists public.site_moderators (user_id uuid primary key);
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
      select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;`);
  await h.db.exec(MIG);
  await h.ok('277 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag made in test mode', (await h.one(`select mode from feature_flags where key = 'legal_fixes'`)).mode, 'test');

  const amy = await h.signup('amy@test.dev', 'amy');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  const ins = `insert into image_removal_requests (reporter_id, name, email, for_whom, links, signature, good_faith) values ($1, 'A', 'a@b.co', 'me', $2, 'A', $3) returning id, extract(epoch from due_at - created_at)::int / 3600 as win`;
  const r = await h.one(ins, [amy, ['@bob in server X'], true]);
  h.eq('48 hour deadline', r.win, 48);
  await failsWith('no links refused', /check/, ins, [amy, [], true]);
  await failsWith('no good faith refused', /check/, ins, [amy, ['x'], false]);

  await h.as(amy);
  await failsWith('users can’t read the table', /permission denied/, `select * from image_removal_requests`);
  await failsWith('users can’t list the queue', /Staff only/, `select * from staff_image_removals('open')`);
  await failsWith('users can’t handle one', /Staff only/, `select staff_handle_image_removal($1, 'removed', '')`, [r.id]);

  await h.as(mod);
  h.eq('staff see it', (await h.q(`select id from staff_image_removals('open')`)).length, 1);
  await failsWith('reject needs a reason', /Say why/, `select staff_handle_image_removal($1, 'rejected', '')`, [r.id]);
  await h.ok('staff mark it removed', () => h.q(`select staff_handle_image_removal($1, 'removed', '')`, [r.id]));
  h.eq('moved to done', (await h.q(`select id from staff_image_removals('done')`)).length, 1);
  await h.admin();
  h.eq('logged', (await h.one(`select count(*)::int n from mod_log where action = 'image_removal_removed' and actor = $1`, [mod])).n, 1);
}
