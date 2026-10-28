// 485: accounts under a day old can't post pictures, videos or media links in HQ (flag new_account_media).
// Starts from stage 24 with stand-ins for the live pieces the guard reads (feature_flags, is_staff, channel_allows).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '485_hq_day_one_media.sql'), 'utf8');
export const base = 24;

const TEST_SERVER = '00000000-0000-4000-8000-00000000b001';
const STANDINS = `
create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
alter table public.messages add column if not exists voice_secs real;
create table if not exists public.site_moderators (user_id uuid primary key);
create table if not exists public.chan_mods (channel_id uuid, user_id uuid);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid()) $$;
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select perm = 'manage_messages' and exists (select 1 from public.chan_mods where channel_id = cid and user_id = auth.uid()) $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('485 runs', () => h.db.exec(MIG));
  await h.ok('485 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('flag starts in test', (await h.one(`select mode from feature_flags where key = 'new_account_media'`)).mode, 'test');

  const owner = await h.signup('owner@test.dev', 'owner');
  await h.admin();
  const hq = (await h.one(`insert into servers (name, owner_id) values ('HQ', $1) returning id`, [owner])).id;
  await h.q(`update app_settings set default_server_id = $1`, [hq]);
  await h.q(`insert into servers (id, name, owner_id) values ($1, 'test', $2)`, [TEST_SERVER, owner]);
  const other = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  const chan = async (sid) => (await h.one(`insert into channels (kind, name, server_id) values ('text', 'media', $1) returning id`, [sid])).id;
  const hqMedia = await chan(hq), testMedia = await chan(TEST_SERVER), otherMedia = await chan(other);

  const fresh = await h.signup('fresh@test.dev', 'fresh');
  const old = await h.signup('old@test.dev', 'old');
  const mod = await h.signup('mod@test.dev', 'modfresh');
  const cmod = await h.signup('cmod@test.dev', 'chanmod');
  await h.admin();
  // Two hours old: past 024's HQ wait, still under a day. "old" is two days old.
  await h.q(`update profiles set created_at = now() - interval '2 hours' where id <> $1`, [old]);
  await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [old]);
  for (const u of [fresh, old, mod, cmod]) for (const s of [TEST_SERVER, other]) {
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2) on conflict do nothing`, [s, u]);
  }
  await h.q(`insert into site_moderators values ($1)`, [mod]);
  await h.q(`insert into chan_mods values ($1, $2)`, [hqMedia, cmod]);

  // Sends as the given person (sub set for is_staff / channel_allows), straight past RLS like the API does after it.
  const send = async (who, cid, content, opts = {}) => {
    await h.admin();
    await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [who]);
    if (opts.bot) await h.q(`select set_config('yapper.bot', '1', false)`);
    try {
      await h.q(`insert into messages (channel_id, author_id, content, attachment_path, voice_secs) values ($1, $2, $3, $4, $5)`,
        [cid, who, content, opts.file ? `${who}/pic.png` : null, opts.voice ?? null]);
      return 'sent';
    } catch (e) { return e.message; } finally {
      await h.q(`select set_config('yapper.bot', '', false)`);
      await h.admin();
    }
  };
  const REFUSED = 'New accounts can post pictures and videos here after their first day.';

  // Test mode: only the flag's servers.
  h.eq('test mode: HQ not covered yet', await send(fresh, hqMedia, '', { file: true }), 'sent');
  h.eq('test mode: test server refuses a day-one picture', await send(fresh, testMedia, '', { file: true }), REFUSED);
  h.eq('test mode: other servers untouched', await send(fresh, otherMedia, '', { file: true }), 'sent');

  await h.q(`update feature_flags set mode = 'everyone' where key = 'new_account_media'`);
  h.eq('day-one picture in HQ refused', await send(fresh, hqMedia, 'look', { file: true }), REFUSED);
  h.eq('day-one image link in HQ refused', await send(fresh, hqMedia, 'https://example.com/x.JPG'), REFUSED);
  h.eq('day-one tenor link in HQ refused', await send(fresh, hqMedia, 'https://tenor.com/view/abc'), REFUSED);
  h.eq('day-one text in HQ fine', await send(fresh, hqMedia, 'hi all'), 'sent');
  h.eq('day-one plain link in HQ fine (link rules are elsewhere)', await send(fresh, hqMedia, 'https://example.com/page'), 'sent');
  h.eq('day-one voice message fine', await send(fresh, hqMedia, '', { file: true, voice: 3.2 }), 'sent');
  h.eq('two-day-old account posts pictures', await send(old, hqMedia, '', { file: true }), 'sent');
  h.eq('staff skip it', await send(mod, hqMedia, '', { file: true }), 'sent');
  h.eq('channel mods skip it', await send(cmod, hqMedia, '', { file: true }), 'sent');
  h.eq('bots skip it', await send(fresh, hqMedia, '', { file: true, bot: true }), 'sent');
  h.eq('everyone mode: other servers still untouched', await send(fresh, otherMedia, '', { file: true }), 'sent');
  h.eq('everyone mode: test server still covered', await send(fresh, testMedia, '', { file: true }), REFUSED);
  h.eq('day-one X post link refused (preview shows media)', await send(fresh, hqMedia, 'https://x.com/someone/status/123'), REFUSED);
  h.eq('day-one YouTube link refused', await send(fresh, hqMedia, 'https://youtu.be/abc'), REFUSED);
  h.eq('day-one text without links fine', await send(fresh, hqMedia, 'no links here'), 'sent');

  // Edits: "hi" can't become an image link; an old account's picture message can still have its text fixed.
  const edit = async (who, content, where) => {
    await h.admin();
    await h.q(`select set_config('request.jwt.claim.sub', $1, false)`, [who]);
    try { await h.q(`update messages set content = $1 where id = (select id from messages where ${where} order by created_at desc limit 1)`, [content]); return 'edited'; }
    catch (e) { return e.message; } finally { await h.admin(); }
  };
  h.eq('day-one edit into an image link refused', await edit(fresh, 'https://i.imgur.com/x.png', `author_id = '${fresh}' and content = 'hi all'`), REFUSED);
  h.eq('day-one plain text edit fine', await edit(fresh, 'hi everyone', `author_id = '${fresh}' and content = 'hi all'`), 'edited');
  h.eq('old account edits text on a picture message', await edit(old, 'caption', `author_id = '${old}' and attachment_path is not null`), 'edited');

  await h.q(`update feature_flags set mode = 'off' where key = 'new_account_media'`);
  h.eq('flag off: HQ allows it again', await send(fresh, hqMedia, '', { file: true }), 'sent');

  await h.as(fresh);
  await h.fails('guard not callable over the API', `select new_account_media_guard()`);
}
