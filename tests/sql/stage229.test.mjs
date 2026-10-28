// 229: jump to any message. PGlite can't replay every migration, so: 001..024, flags (031, 041), the missing
// profile/message columns, a stand-in channel_history_ok (always true) and channel_messages copied verbatim from
// the live database (read-only, Oct 18), so the windows are checked against the real page function. Then 229 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const PROFILE_COLS = ['links', 'verified_as', 'verified_hidden', 'badges', 'display_name', 'pronouns', 'accent_color', 'accent_color2',
  'plus_until', 'plus_badge_hidden', 'dms_from', 'server_tag', 'tag', 'server_order', 'shown_badge', 'verify_required', 'profile_effect',
  'custom_status', 'avatar_deco', 'discriminator'];

const STANDINS = `
${PROFILE_COLS.map((c) => `alter table public.profiles add column if not exists ${c} text;`).join('\n')}
alter table public.messages add column if not exists webhook jsonb;
create or replace function public.channel_history_ok(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select true;
$$;
`;

/** Verbatim from the live database (pg_get_functiondef), Oct 18. */
const LIVE = `
CREATE OR REPLACE FUNCTION public.channel_messages(cid uuid, before timestamp with time zone DEFAULT NULL::timestamp with time zone, lim integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and public.channel_history_ok(cid) and (before is null or m.created_at < before)
    order by m.created_at desc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge, verify_required, profile_effect, custom_status, avatar_deco, discriminator
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$function$;
grant execute on function public.channel_messages(uuid, timestamptz, integer) to authenticated;
`;

export default async function (h) {
  const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '229_jump_to_message.sql'), 'utf8');
  await h.db.exec(STANDINS);
  await h.db.exec(LIVE);
  await h.db.exec(MIG);
  await h.ok('229 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat'); // not in the server

  await h.admin();
  h.eq('flag exists in test mode', (await h.one(`select mode from feature_flags where key = 'jump_to_message'`)).mode, 'test');
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, amy, bob]);
  const cid = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, amy])).id;
  const other = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('other', 'text', $1, $2) returning id`, [sid, amy])).id;
  // 200 messages, one second apart, alternating authors (seeded as admin: the new-account slowdown trigger is off meanwhile).
  await h.q(`alter table messages disable trigger user`);
  const ids = (await h.q(
    `insert into messages (channel_id, author_id, content, created_at)
     select $1, case when i % 2 = 0 then $2::uuid else $3::uuid end, 'm' || i, timestamptz '2026-01-01' + i * interval '1 second'
     from generate_series(0, 199) i returning id, content`, [cid, amy, bob],
  )).sort((a, b) => parseInt(a.content.slice(1), 10) - parseInt(b.content.slice(1), 10)).map((r) => r.id);
  const elsewhere = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'x') returning id`, [other, amy])).id;
  await h.q(`alter table messages enable trigger user`);
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '👍')`, [ids[100], bob]);

  const nums = (r) => r.messages.map((m) => parseInt(m.content.slice(1), 10));
  const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i);

  await h.as(bob);
  let r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, ids[100]])).r;
  h.eq('around: 24 older, the target and 25 newer, oldest first', nums(r), range(76, 125));
  h.eq('around: found, not at the end', [r.found, r.at_end], [true, false]);
  h.eq('around: authors come along', r.profiles.map((p) => p.username).sort(), ['amy', 'bob']);
  h.eq('around: reactions come along', r.reactions.map((x) => x.emoji), ['👍']);

  r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, ids[190]])).r;
  h.eq('near the end: newest 50, at the end', [nums(r)[0], nums(r).at(-1), r.messages.length, r.at_end], [150, 199, 50, true]);
  h.eq('near the end: target is in it', r.messages.some((m) => m.id === ids[190]), true);

  r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, ids[174]])).r;
  h.eq('exactly 25 newer left: still at the end', [nums(r)[0], nums(r).at(-1), r.at_end], [150, 199, true]);

  r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, ids[3]])).r;
  h.eq('near the start: everything up to 25 newer', nums(r), range(0, 28));

  r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, elsewhere])).r;
  h.eq('message from another channel: not found, nothing returned', [r.found, r.messages.length], [false, 0]);
  r = (await h.one(`select channel_messages_around($1, gen_random_uuid()) r`, [cid])).r;
  h.eq('unknown message: not found', r.found, false);

  const at = async (i) => (await h.one(`select created_at from messages where id = $1`, [ids[i]])).created_at;
  r = (await h.one(`select channel_messages_newer($1, $2) r`, [cid, await at(125)])).r;
  h.eq('newer: next 50 after the newest loaded', [nums(r)[0], nums(r).at(-1), r.at_end], [126, 175, false]);
  r = (await h.one(`select channel_messages_newer($1, $2) r`, [cid, await at(175)])).r;
  h.eq('newer: last page reaches the present', [nums(r).includes(176), nums(r).at(-1), r.at_end], [true, 199, true]);
  r = (await h.one(`select channel_messages_newer($1, $2) r`, [cid, await at(149)])).r;
  h.eq('newer: exactly 50 left is the end', [nums(r)[0], nums(r).at(-1), r.at_end], [150, 199, true]);

  const t10 = await at(10);
  await h.as(cat);
  r = (await h.one(`select channel_messages_around($1, $2) r`, [cid, ids[100]])).r;
  h.eq('non-member: around gives nothing', [r.found, r.messages.length, r.profiles.length], [false, 0, 0]);
  r = (await h.one(`select channel_messages_newer($1, $2) r`, [cid, t10])).r;
  h.eq('non-member: newer gives nothing', r.messages.length, 0);

  await h.as(null);
  await h.fails('anon cannot call around', `select channel_messages_around($1, $2)`, [cid, ids[100]]);
  await h.fails('anon cannot call newer', `select channel_messages_newer($1, now())`, [cid]);
}
