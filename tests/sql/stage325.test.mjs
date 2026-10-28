// 325: slur false positive across words ("chicken egg rolls"), sexual-content filter vs server rules, bot "was online" check.
// Starts from stage 24 with stand-ins for the live pieces these functions call (as stage 273 does): unaccent, fold_fancy,
// slur_text, six_nine_g, and the REAL server_watch_unneg text from migration 249. has_slur is the live text, unchanged by 325.
// The slurs are put together from pieces so this file doesn't spell them out.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MIG = mig('325_filter_and_bot_check_fixes.sql');

// The negation cutter, exactly as 249 defines it (just the function and its revoke, not the scan below it).
const m249 = mig('249_server_watch_negation.sql');
const UNNEG = m249.slice(m249.indexOf('create or replace function public.server_watch_unneg'), m249.indexOf('revoke all on function public.server_watch_unneg(text)'))
  + 'revoke all on function public.server_watch_unneg(text) from public, anon, authenticated;';

const STANDINS = String.raw`
set check_function_bodies = off;
create schema if not exists extensions;
create or replace function extensions.unaccent(t text) returns text language sql immutable as $$ select t $$;
create or replace function public.fold_fancy(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.six_nine_g(t text) returns text language sql immutable as $$ select coalesce(t, '') $$;
create or replace function public.slur_text(t text) returns text language sql immutable set search_path to 'public', 'extensions' as $function$
  select regexp_replace(
    regexp_replace(
      translate(lower(unaccent(regexp_replace(public.fold_fancy(t), '[​-‏]', '', 'g'))), '0134578@$!|', 'oieastbasii'),
      '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g');
$function$;
create or replace function public.has_slur(t text) returns boolean language sql immutable set search_path to 'public', 'extensions' as $function$
  select public.has_slur_plain(t)
    or (
      (coalesce(t, '') ~ '[[:alpha:]][69]+[[:alpha:]]')
      and public.has_slur_plain(public.six_nine_g(t))
    )
    or (
      strpos(coalesce(t, ''), chr(8238)) > 0
      and (public.has_slur_plain(reverse(t)) or public.has_slur_plain(public.six_nine_g(reverse(t))))
    );
$function$;
alter table public.profiles add column if not exists custom_status text;
`;

/** The error message a statement throws, or '' if it worked. */
async function msg(h, sql, params = []) {
  try { await h.db.query(sql, params); return ''; } catch (e) { return String(e.message); }
}

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(UNNEG);
  await h.db.exec(MIG);
  await h.ok('325 re-runs cleanly', () => h.db.exec(MIG));

  const slur = async (t) => (await h.one(`select has_slur($1) r`, [t])).r;
  const spam = async (t) => (await h.one(`select has_sexual_spam($1) r`, [t])).r;
  const w = (...p) => p.join('');

  // 1. Slur filter: phrases that only look like a slur once the spaces are gone are fine now.
  for (const ok of ['chicken egg rolls', 'queen egg arena', 'green egg arena', 'seven egg rice', 'hen egg raw', 'Open egg run', 'an egg raw', 'join us https://yapper.website/invite/Cz8mb7fG']) {
    h.eq(`fine: ${ok}`, await slur(ok), false);
  }
  // ...and the real ones are still caught, spelled out, spaced out, with symbols, and the "negg" spellings inside one word.
  for (const bad of [w('n', 'ig', 'ger'), w('n', 'ig', 'ga'), 'n i g g e r', 'N I G G A', w('n', '1', 'gg', '3', 'r'), w('f', '@', 'gg', '0', 't'), w('n', '*', 'gger'),
    w('n', 'e', 'gger'), 'n e g g e r', w('n', 'e', 'gga'), 'you ' + w('n', 'ig', 'ger') + ' you', w('ni', 'gg', 'er'),
    // the "negg" spellings split by a space still count (they did before 325 too)
    'xx' + w('ne', 'gger') + 'xx', w('neg', ' ', 'ger'), w('ne', ' ', 'gga'), w('n', ' ', 'eg', ' ', 'ger'), w('neg', ' ', 'gas'), w('ne', ' ', 'g', ' ', 'g', ' ', 'er')]) {
    h.eq(`caught: ${bad}`, await slur(bad), true);
  }

  // 2. Sexual content: ads are still blocked, server rules are not.
  const blocked = [
    'buy dildo cheap', 'best porn site dm me', 'porn nudes onlyfans', 'free nudes https://t.me/someone',
    'No porn. Buy nudes at https://example.com',
    'No problem, buy porn from me $20',
    'no limits porn nudes dm me',
    'No minors. Post your nudes and porn in #pics',
    'DM @seller for onlyfans and nudes',
    'Price list: dildo 20 usd, vibrator 30 usd',
    'no problem buy porn nudes',
    // an opening "No ..." must not hide a call to action (found by the security review)
    'No minors, dm me for porn', 'No bots, free porn', 'No scams, selling nudes and onlyfans leaks', 'No fakes, b.u.y porn',
    'No fakes, porn nudes 20$', 'No fakes, porn nudes 5€', 'No minors, porn link in bio', 'No bots, sell nudes and porn',
    'No bots, fr33 porn', 'No bots, hmu for porn and nudes', 'No scams, snap me for nudes and porn',
    // bare domains and invites, other ways to be reached, other money words (second review)
    'No minors, porn and nudes at discord.gg/abc123', 'No minors, porn nudes -> discord.gg/abc123', 'No minors, porn nudes onlyfans: example.com',
    'No minors, porn nudes bit.ly/x1', 'Not for kids, porn nudes bit.ly/x1',
    'No kids, pm me for porn and nudes', 'No kids, hit me up for porn and nudes', 'No bots, insta: xyz porn and nudes',
    'No bots, discord: xyz#1234 porn and nudes', 'No minors, dm now porn and nudes', 'No minors, 20 quid porn nudes', 'No minors, 20 dollar porn nudes',
    // third round: domains in other cases and endings, payment and social names
    'No kids, porn nudes EXAMPLE.COM', 'No kids, porn nudes bit.LY/x', 'No kids, porn nudes linktr.ee/x', 'No kids, porn nudes nudes.xxx',
    'No kids, porn nudes t.co/x', 'No kids, porn nudes CHAT.ME', 'No kids, porn nudes fans.vip', 'No kids, porn nudes x.live',
    'No kids, cash app porn nudes', 'No kids, venmo porn nudes', 'No kids, 5 btc porn nudes', 'No kids, ten bucks porn nudes',
    'No kids, gift cards for porn nudes', 'No kids, robux for porn nudes', 'No kids, instagram porn nudes', 'No kids, tiktok porn nudes',
    'No kids, porn and nudes available via dm', 'No kids, contact via dm porn nudes', 'No kids, porn nudes. Via dm',
    'No kids, dm our team for porn and nudes', 'No kids, dm the owner for porn and nudes',
    'No kids, tele me porn nudes', 'No kids, ping me for porn nudes', 'No kids, friend me porn nudes', 'No kids, look at my profile porn nudes',
  ];
  for (const t of blocked) h.eq(`blocked: ${t}`, await spam(t), true);
  const allowed = [
    'No porn, no nudes, no onlyfans.',
    'Rules:\n1. No NSFW or porn.\n2. No selling or advertising.\n3. No nudes or hentai.',
    "Don't post porn, nudes or onlyfans links",
    'Porn and nudes are not allowed here',
    'Banned: porn, nudes, onlyfans',
    'be nice, no porn, no nudes @everyone read the rules',
    'Nothing sexual: no dildo or vibrator jokes please. Questions? DM a mod.',
    'Feel free to ask a mod. No porn, no nudes', 'No porn, no nudes, no links or ads', "Don't post porn, nudes or onlyfans links", 'No selling or advertising of porn, nudes or onlyfans',
    'No free porn, no nudes', 'No porn, no nudes, no promo, no selling',
    // rule wordings with the soft words in them
    'No porn, no nudes. No advertising or selling.', 'No porn, no nudes. No spam or selling.', 'No porn, no nudes. No ads or promo.',
    'No porn, no nudes. No self promo.', 'No porn, no nudes. Selling is not allowed.', 'No porn, no nudes. Advertising/selling is banned.',
    "No porn, no nudes. Don't advertise or sell", 'No porn, no nudes, no begging for free stuff', 'No porn, no nudes. DM a mod for help',
    'Free to join! No porn, no nudes', 'No NSFW. No selling. No ads. No porn or nudes.',
    'No porn, no nudes. No selling, promo or ads.', 'No porn, no nudes. No selling/promo', 'No porn, no nudes. No spam, ads, or selling.',
    'No porn, no nudes. No advertising, selling or trading', 'No porn, no nudes. No spam/self-promo', 'No porn, no nudes. No ads/selling',
    'No porn, no nudes. No scamming or selling accounts', "Don't ask for free nitro. No porn, no nudes", 'Do not ask for free stuff. No porn, no nudes',
    'No porn, no nudes. No unsolicited DMs', "No porn, no nudes. Don't DM members", 'No porn, no nudes. No dm advertising', 'No porn, no nudes. Report to staff via DM',
    'No porn, no nudes. No spam, selling, or advertising.', 'No porn, no nudes. Report problems via DM to a mod.', 'No porn, no nudes. Report via DM',
    'No porn.To be clear, no nudes', 'No porn.So be nice, no nudes',
    'Tupperware lube', 'a normal message', '',
  ];
  for (const t of allowed) h.eq(`allowed: ${JSON.stringify(t).slice(0, 50)}`, await spam(t), false);
  h.eq('null is fine', (await h.one(`select has_sexual_spam(null) r`)).r, false);
  // Known gaps, written down so a change to them is noticed: rules that carry a link or a buying word are still refused, and a
  // bare list of explicit words behind a negator, with nothing to act on (no contact, price or buying word), is let through.
  h.eq('known gap: rules with a link are still refused', await spam('No porn, no nudes. Read more at https://yapper.website/rules'), true);
  h.eq('known gap: rules with a buying word are still refused', await spam('No porn, no nudes. Buy nitro in #shop'), true);
  h.eq('known gap: a bare list behind a negator passes', await spam("Don't miss porn nudes onlyfans"), false);

  // Users can't call the helper or the cutter; the public function still works for them.
  const u = await h.signup('amy@test.dev', 'amy');
  await h.as(u);
  h.eq('a user can’t call has_sexual_spam directly (only the message trigger does)', /permission denied/.test(await msg(h, `select has_sexual_spam('porn nudes')`)), true);
  h.eq('a user can’t call the raw helper', /permission denied/.test(await msg(h, `select has_sexual_spam_raw('porn nudes')`)), true);
  h.eq('a user can’t call the ad signal helper', /permission denied/.test(await msg(h, `select sexual_ad_signal('porn nudes')`)), true);
  h.eq('a user can’t call the soft word helper', /permission denied/.test(await msg(h, `select sexual_soft_word('free')`)), true);
  h.eq('a user can’t call the negation cutter', /permission denied/.test(await msg(h, `select server_watch_unneg('no porn')`)), true);
  await h.admin();

  // 3. Bot "What we check": online means it polled or posted. An event queued for it is not activity.
  await h.db.exec(`
    create table if not exists public.bots (id uuid primary key, owner_id uuid, description text, last_poll_at timestamptz, last_event_at timestamptz, last_used_at timestamptz);
    create table if not exists public.bot_servers (bot_id uuid, server_id uuid);
    create table if not exists public.bot_commands (bot_id uuid);
    alter table public.servers add column if not exists member_count int not null default 0;
  `);
  const ago = (p) => `case when ${p}::text is null then null else now() - ${p}::interval end`;
  const bot = async (poll, event, used) => {
    const id = crypto.randomUUID();
    await h.q(`insert into bots (id, owner_id, description, last_poll_at, last_event_at, last_used_at)
               values ($1, $2, 'A bot that does a few things', ${ago('$3')}, ${ago('$4')}, ${ago('$5')})`, [id, u, poll, event, used]);
    return id;
  };
  const online = async (id) => { await h.as(u); try { return (await h.one(`select bot_verify_progress($1) r`, [id])).r.online; } finally { await h.admin(); } };
  h.eq('never connected, but events were queued: not online', await online(await bot(null, '1 minute', null)), false);
  h.eq('polled yesterday: online', await online(await bot('1 day', null, null)), true);
  h.eq('posted 2 days ago: online', await online(await bot(null, null, '2 days')), true);
  h.eq('polled 8 days ago, events since: not online', await online(await bot('8 days', '1 hour', null)), false);
  h.eq('nothing at all: not online', await online(await bot(null, null, null)), false);
  const other = await h.signup('bob@test.dev', 'bob');
  const anyBot = (await h.one(`select id from bots limit 1`)).id;
  await h.as(other);
  h.eq('someone else’s bot is not found', /Bot not found/.test(await msg(h, `select bot_verify_progress($1)`, [anyBot])), true);
  await h.admin();
}
