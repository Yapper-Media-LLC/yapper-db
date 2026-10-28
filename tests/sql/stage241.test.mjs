// 241: name styles. PGlite can't replay every migration, so: 001..024, flags (031, 041), the missing profile and
// message columns, column grants on profiles like live (table-level select/update revoked, a few columns granted),
// a stand-in channel_history_ok, then 241 twice (re-runnable). bootstrap() needs far more of the live schema than
// the stand-ins have, so its body isn't checked here (check_function_bodies off while 241 runs); its text is checked
// to carry name_style, and channel_messages() (re-created by 241 too) is run for real.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const COLS = ['links', 'verified_as', 'verified_hidden', 'badges', 'display_name', 'pronouns', 'accent_color', 'accent_color2',
  'plus_until', 'plus_badge_hidden', 'dms_from', 'server_tag', 'tag', 'server_order', 'shown_badge', 'verify_required', 'profile_effect',
  'custom_status', 'avatar_deco', 'discriminator'];

const STANDINS = `
${COLS.map((c) => `alter table public.profiles add column if not exists ${c} text;`).join('\n')}
alter table public.messages add column if not exists webhook jsonb;
create or replace function public.channel_history_ok(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select true;
$$;
-- Live uses column grants on profiles.
revoke select, update on public.profiles from anon, authenticated;
grant select (id, username, display_name, bio) on public.profiles to anon, authenticated;
grant update (display_name, bio) on public.profiles to authenticated;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '241_name_styles.sql'), 'utf8');
  await h.db.exec(STANDINS);
  const run = () => h.db.exec(`set check_function_bodies = off; ${MIG}; set check_function_bodies = on;`);
  await run();
  await h.ok('241 re-runs cleanly', run);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');

  await h.admin();
  const flag = await h.one(`select mode, servers, users from feature_flags where key = 'name_styles'`);
  h.eq('flag exists in test mode for the test server and Antic', [flag.mode, flag.servers, flag.users],
    ['test', ['00000000-0000-4000-8000-00000000b001'], ['00000000-0000-4000-8000-00000000a001']]);
  const boot = (await h.one(`select prosrc from pg_proc where proname = 'bootstrap'`)).prosrc;
  h.eq('bootstrap() lists name_style with the other profile columns', /avatar_deco, discriminator, name_style\n/.test(boot), true);
  h.eq('one shape constraint, even after re-running', (await h.one(
    `select count(*)::int n from pg_constraint where conname = 'profiles_name_style_shape'`)).n, 1);

  await h.as(amy);
  await h.ok('owner sets a font', () => h.q(`update profiles set name_style = '{"f":"serif"}' where id = $1`, [amy]));
  await h.ok('owner sets a font and a gradient', () => h.q(
    `update profiles set name_style = '{"f":"pixel","c":"#ff00aa","c2":"#00FFaa"}' where id = $1`, [amy]));
  await h.ok('owner sets just a colour', () => h.q(`update profiles set name_style = '{"c":"#123456"}' where id = $1`, [amy]));
  await h.fails('unknown font', `update profiles set name_style = '{"f":"papyrus"}' where id = $1`, [amy]);
  await h.fails('font must be a string', `update profiles set name_style = '{"f":["serif"]}' where id = $1`, [amy]);
  await h.fails('colour must be #rrggbb', `update profiles set name_style = '{"c":"red"}' where id = $1`, [amy]);
  await h.fails('no short colours', `update profiles set name_style = '{"c":"#fff"}' where id = $1`, [amy]);
  await h.fails('no css in colours', `update profiles set name_style = '{"c":"#ffffff;background:url(x)"}' where id = $1`, [amy]);
  await h.fails('second colour needs a first one', `update profiles set name_style = '{"c2":"#ffffff"}' where id = $1`, [amy]);
  await h.fails('no extra keys', `update profiles set name_style = '{"f":"serif","x":1}' where id = $1`, [amy]);
  await h.fails('not an array', `update profiles set name_style = '["serif"]' where id = $1`, [amy]);
  await h.fails('not an empty object', `update profiles set name_style = '{}' where id = $1`, [amy]);
  await h.ok('reset to nothing', () => h.q(`update profiles set name_style = null where id = $1`, [amy]));
  await h.ok('owner sets it again', () => h.q(`update profiles set name_style = '{"f":"hand","c":"#ff0000"}' where id = $1`, [amy]));

  await h.as(bob);
  h.eq('everyone signed in can read it', (await h.one(`select name_style from profiles where id = $1`, [amy])).name_style,
    { c: '#ff0000', f: 'hand' });
  await h.q(`update profiles set name_style = '{"f":"mono"}' where id = $1`, [amy]);
  await h.admin();
  h.eq('someone else cannot change it', (await h.one(`select name_style from profiles where id = $1`, [amy])).name_style,
    { c: '#ff0000', f: 'hand' });

  await h.as(null);
  await h.q(`update profiles set name_style = null where id = $1`, [amy]).catch(() => undefined);
  await h.admin();
  h.eq('anon cannot change it', (await h.one(`select name_style from profiles where id = $1`, [amy])).name_style,
    { c: '#ff0000', f: 'hand' });

  // channel_messages() carries it with the author's profile.
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const cid = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  await h.q(`alter table messages disable trigger user`);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'hi')`, [cid, amy]);
  await h.q(`alter table messages enable trigger user`);
  await h.as(bob);
  const r = (await h.one(`select channel_messages($1) r`, [cid])).r;
  h.eq('channel_messages: the author comes with their name style', r.profiles.map((p) => [p.username, p.name_style]),
    [['amy', { c: '#ff0000', f: 'hand' }]]);
}
