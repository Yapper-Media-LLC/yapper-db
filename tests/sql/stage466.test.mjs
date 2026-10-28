// 466 head mods give Artist: admin_set_badge lets head mods (flag head_mod_badges) give and take Artist only.
// PGlite stops at 24, so this adds stand-ins for what the migration calls (live versions are bigger).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '466_head_mod_badges.sql'), 'utf8');
const ANTIC = '00000000-0000-4000-8000-00000000a001';

const STANDINS = `
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists shown_badge text;
create table if not exists public.site_moderators (user_id uuid primary key, head boolean not null default false, suspended_at timestamptz);
create table if not exists public.mod_log (id bigserial primary key, actor uuid, action text, target_id uuid, reason text, created_at timestamptz default now());
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (sid = any(servers) or auth.uid() = any(users))) from public.feature_flags where key = k), false) $$;
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_head_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and head and suspended_at is null) $$;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then return; end if;
  if not public.is_site_mod() then raise exception 'Moderators only'; end if;
  if exists (select 1 from public.site_moderators where user_id = target) then raise exception 'You can''t moderate an admin or another moderator'; end if;
  if target = auth.uid() then raise exception 'Not yourself'; end if;
end $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const antic = await h.signup('antic466@test.dev', 'antic466');
  const head = await h.signup('head466@test.dev', 'head466');
  const mod = await h.signup('mod466@test.dev', 'mod466');
  const user = await h.signup('user466@test.dev', 'user466');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [antic]);
  await h.q(`insert into site_moderators (user_id, head) values ($1, true), ($2, false)`, [head, mod]);

  await h.db.exec(MIG);
  await h.ok('466 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test with Antic listed', (await h.one(`select mode, $1::uuid = any(users) a from feature_flags where key = 'head_mod_badges'`, [ANTIC])), { mode: 'test', a: true });
  // The test database's ids differ from live: list this head mod for the flag.
  await h.q(`update feature_flags set users = users || array[$1]::uuid[] where key = 'head_mod_badges'`, [head]);

  await h.as(head);
  await h.q(`select admin_set_badge($1, 'artist', true)`, [user]);
  await h.admin();
  h.eq('head mod gave Artist', (await h.one(`select badges from profiles where id = $1`, [user])).badges, ['artist']);
  await h.as(head);
  await h.q(`select admin_set_badge($1, 'artist', false)`, [user]);
  await h.admin();
  h.eq('head mod took Artist off', (await h.one(`select badges from profiles where id = $1`, [user])).badges, []);
  h.eq('both logged', (await h.one(`select string_agg(action, ',' order by id) s from mod_log where actor = $1`, [head])).s, 'badge_given,badge_removed');

  await h.as(head);
  for (const b of ['staff', 'developer', 'partner', 'early', 'creator_1', 'community_manager']) {
    await h.fails(`head mod cannot give ${b}`, `select admin_set_badge($1, $2, true)`, [user, b]);
  }
  await h.q(`select admin_set_badge($1, 'bug_hunter', true)`, [user]); // every mod could already
  await h.fails('head mod cannot badge another mod', `select admin_set_badge($1, 'artist', true)`, [mod]);
  await h.fails('head mod cannot badge themselves', `select admin_set_badge($1, 'artist', true)`, [head]);

  await h.fails('null badge refused', `select admin_set_badge($1, null, true)`, [user]);

  await h.as(mod);
  await h.fails('regular mod cannot give Artist', `select admin_set_badge($1, 'artist', true)`, [user]);
  await h.as(user);
  await h.fails('member cannot give Artist', `select admin_set_badge($1, 'artist', true)`, [user]);

  await h.admin();
  await h.q(`update feature_flags set mode = 'off' where key = 'head_mod_badges'`);
  await h.as(head);
  await h.fails('flag off: head mod cannot give Artist', `select admin_set_badge($1, 'artist', true)`, [user]);

  await h.as(antic);
  await h.q(`select admin_set_badge($1, 'partner', true)`, [user]);
  await h.admin();
  h.eq('admins still give anything', (await h.one(`select badges from profiles where id = $1`, [user])).badges.sort(), ['bug_hunter', 'partner']);
}
