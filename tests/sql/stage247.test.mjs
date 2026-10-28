// 247: bot renames. PGlite can't replay every migration, so: 001..024, flags (031, 041), a stand-in bots table with
// the columns bot_rename touches, username_holds (246's shape) and profiles.discriminator. Then 247 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists discriminator text;
create table if not exists public.bots (
  id uuid primary key references public.profiles(id) on delete cascade,
  owner_id uuid not null,
  name text not null,
  tag text,
  verified_at timestamptz
);
create table if not exists public.username_holds (name_key text primary key, user_id uuid not null, until timestamptz not null);
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '247_bot_rename.sql'), 'utf8');
  const MIG2 = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '248_bot_rename_verified.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('247 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(MIG2);
  await h.ok('248 re-runs cleanly', () => h.db.exec(MIG2));
  h.eq('flag is in test mode', (await h.one(`select mode from feature_flags where key = 'bot_rename'`)).mode, 'test');

  const owner = await h.signup('owner@test.dev', 'owner');
  const bot = await h.signup('bot@test.dev', 'modbot_1234');
  const vbot = await h.signup('vbot@test.dev', 'verified_1111');
  await h.admin();
  await h.q(`update profiles set display_name = 'modbot', discriminator = '1234' where id = $1`, [bot]);
  await h.q(`insert into bots (id, owner_id, name, tag) values ($1, $2, 'modbot', '1234'), ($3, $2, 'verified', '1111')`, [bot, owner, vbot]);
  await h.q(`update bots set verified_at = now() where id = $1`, [vbot]);

  // Only the server (service role) may call it.
  await h.as(owner);
  await h.fails('signed-in users can\'t call bot_rename', `select bot_rename($1, 'x', 'x_1', '1')`, [bot]);
  await h.as(null);
  await h.fails('anon can\'t call bot_rename', `select bot_rename($1, 'x', 'x_1', '1')`, [bot]);
  await h.admin();

  const r = (await h.one(`select bot_rename($1, 'Xoriva', 'Xoriva_5678', '5678') r`, [bot])).r;
  h.eq('returns the new name', [r.name, r.tag, r.username], ['Xoriva', '5678', 'Xoriva_5678']);
  h.eq('profile renamed, display name followed', await h.one(`select username, discriminator, display_name from profiles where id = $1`, [bot]),
    { username: 'Xoriva_5678', discriminator: '5678', display_name: 'Xoriva' });
  const b = await h.one(`select name, tag, renamed_at is not null renamed from bots where id = $1`, [bot]);
  h.eq('bot row renamed and cooldown set', b, { name: 'Xoriva', tag: '5678', renamed: true });
  h.eq('old username held for 7 days', await h.one(`select user_id = $1 mine, until > now() + interval '6 days' held from username_holds where name_key = 'modbot_1234'`, [bot]),
    { mine: true, held: true });

  await h.fails('second rename inside a week is refused', `select bot_rename($1, 'again', 'again_1', '1')`, [bot]);
  h.eq('refused rename changed nothing', (await h.one(`select username from profiles where id = $1`, [bot])).username, 'Xoriva_5678');

  // A display name the owner picked stays.
  await h.q(`update bots set renamed_at = now() - interval '8 days' where id = $1`, [bot]);
  await h.q(`update profiles set display_name = 'My Cool Bot' where id = $1`, [bot]);
  await h.one(`select bot_rename($1, 'Zed', 'Zed_9999', '9999')`, [bot]);
  h.eq('chosen display name kept', (await h.one(`select display_name from profiles where id = $1`, [bot])).display_name, 'My Cool Bot');

  await h.one(`select bot_rename($1, 'Xoriva', 'Xoriva_2222', '2222')`, [vbot]);
  h.eq('verified bot renamed and keeps its badge (248)', await h.one(`select name, verified_at is not null verified from bots where id = $1`, [vbot]),
    { name: 'Xoriva', verified: true });
  await h.fails('verified bot still waits a week', `select bot_rename($1, 'again', 'again_3', '3')`, [vbot]);

  // A username someone else already has fails on the unique index, and nothing is half-written.
  await h.q(`update bots set renamed_at = null where id = $1`, [bot]);
  await h.fails('taken username refused', `select bot_rename($1, 'owner', 'owner', null)`, [bot]);
  h.eq('bot row untouched after a clash', (await h.one(`select name, renamed_at from bots where id = $1`, [bot])), { name: 'Zed', renamed_at: null });
}
