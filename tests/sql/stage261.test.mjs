// 261: (a) channel_messages_since() carries name_style and the other newer profile columns; (b) the verified badge
// stays when only the display name changes, and still goes on a username change that doesn't match the channel.
// PGlite can't replay every migration: 001..024 plus stand-ins for the profile columns and the name helpers the
// live guard calls (bad_name, brand_name, clean_name, skeleton, verify_name_key as in 171). Then 261 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const COLS = ['links', 'verified_as', 'verified_hidden', 'badges', 'display_name', 'pronouns', 'accent_color', 'accent_color2',
  'plus_until', 'plus_badge_hidden', 'dms_from', 'server_tag', 'tag', 'server_order', 'shown_badge', 'verify_required', 'profile_effect',
  'custom_status', 'avatar_deco', 'discriminator'];

const STANDINS = `
${COLS.map((c) => `alter table public.profiles add column if not exists ${c} text;`).join('\n')}
alter table public.profiles add column if not exists name_style jsonb;
alter table public.messages add column if not exists webhook jsonb;
create or replace function public.channel_history_ok(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select true;
$$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select false; $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false; $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select false; $$;
create or replace function public.clean_name(t text) returns text language sql immutable as $$ select nullif(btrim(coalesce(t, '')), ''); $$;
create or replace function public.skeleton(t text) returns text language sql immutable as $$ select lower(t); $$;
create or replace function public.verify_name_key(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(
    public.skeleton(regexp_replace(normalize(regexp_replace(coalesce(t, ''), '^\\s*@+', ''), NFKD), '[̀-ͯ]', '', 'g')),
    '[^a-z0-9]', '', 'g');
$$;
grant update (display_name, username) on public.profiles to authenticated;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '261_profile_fixes.sql'), 'utf8');
  await h.db.exec(STANDINS);
  const run = () => h.db.exec(MIG);
  await run();
  await h.ok('261 re-runs cleanly', run);
  await h.db.exec(`create trigger profiles_custom_guard before insert or update on public.profiles
    for each row execute function public.profile_custom_guard();`);

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat');

  // (a) catch-up carries the name style.
  await h.admin();
  await h.q(`update profiles set name_style = '{"f":"hand","c":"#ff0000"}', avatar_deco = 'halo' where id = $1`, [amy]);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const cid = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  await h.q(`alter table messages disable trigger user`);
  await h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, 'hi', now())`, [cid, amy]);
  await h.q(`alter table messages enable trigger user`);
  await h.as(bob);
  const r = (await h.one(`select channel_messages_since($1, now() - interval '1 hour') r`, [cid])).r;
  h.eq('channel_messages_since: the author comes with their name style and decoration',
    r.profiles.map((p) => [p.username, p.name_style, p.avatar_deco]), [['amy', { c: '#ff0000', f: 'hand' }, 'halo']]);

  // (b) amy is verified through her display name (her username doesn't match the channel).
  await h.admin();
  await h.q(`update profiles set display_name = 'Amy Makes', verified_as = 'YouTube · Amy Makes' where id = $1`, [amy]);
  await h.q(`update profiles set verified_as = 'YouTube · bob' where id = $1`, [bob]);
  await h.q(`update profiles set display_name = 'Cat Plays', verified_as = 'Twitch · Cat Plays' where id = $1`, [cat]);
  const badge = async (id) => (await h.one(`select verified_as from profiles where id = $1`, [id])).verified_as;

  await h.as(amy);
  await h.q(`update profiles set display_name = 'regret' where id = $1`, [amy]);
  h.eq('a new display name keeps the badge', await badge(amy), 'YouTube · Amy Makes');
  await h.q(`update profiles set display_name = null where id = $1`, [amy]);
  h.eq('clearing the display name keeps the badge', await badge(amy), 'YouTube · Amy Makes');
  await h.q(`update profiles set username = 'amy2' where id = $1`, [amy]);
  h.eq('a new username matching neither name removes it', await badge(amy), null);

  await h.as(bob);
  await h.q(`update profiles set display_name = 'Joel' where id = $1`, [bob]);
  h.eq('bob (verified through his username) renames his display name and keeps it', await badge(bob), 'YouTube · bob');

  await h.as(cat);
  await h.q(`update profiles set username = 'catplays' where id = $1`, [cat]);
  h.eq('a new username that matches the channel keeps it', await badge(cat), 'Twitch · Cat Plays');
  await h.q(`update profiles set username = 'kitty', display_name = 'Cat Plays' where id = $1`, [cat]);
  h.eq('a new username that only matches the display name removes it (no two-step rename dodge)', await badge(cat), null);
}
