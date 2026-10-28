// 431: messages made only of invisible characters are refused (new ones and edits); old blank rows stay updatable.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '431_blank_messages.sql'), 'utf8');

const STANDINS = `
alter table public.messages add column if not exists embeds jsonb;
alter table public.messages add column if not exists components jsonb;
alter table public.messages add column if not exists pinned_at timestamptz;
`;

export default async function (h) {
  const amy = await h.signup('amy@test.dev', 'amy');
  await h.admin();
  await h.db.exec(STANDINS);
  // An old account, so the new-account message pace doesn't trip.
  await h.q("update profiles set created_at = now() - interval '30 days'");
  const ch = (await h.one(`insert into channels (kind, dm_key) values ('dm', 'k1') returning id`)).id;
  // An old blank row from before the fix.
  const old = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, $3) returning id`, [ch, amy, 'ㅤ'])).id;
  await h.db.exec(MIG);
  await h.ok('431 re-runs cleanly', () => h.db.exec(MIG));

  const ins = (c) => h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, $3)`, [ch, amy, c]);
  for (const [name, c] of [['zero-width space', '​'], ['Hangul filler', 'ㅤㅤㅤ'], ['spaces and joiners', ' ‍ ‌ '],
    ['direction marks', '‎‮'], ['Braille blank', '⠀'], ['variation selector', '️'], ['newlines + zwsp', '\n​\n'], ['no-break spaces', '  '], ['ideographic space', '　'], ['narrow no-break space', ' ']]) {
    let threw = false;
    try { await ins(c); } catch { threw = true; }
    h.eq(`refuses ${name}`, threw, true);
  }
  for (const [name, c] of [['hi', 'hi'], ['an emoji', '❤️'], ['a dot', '.'], ['zwsp around text', '​ok​'], ['a custom emoji', '<:wave:00000000-0000-0000-0000-000000000000>']]) {
    await h.ok(`allows ${name}`, () => ins(c));
  }
  await h.ok('blank text with embeds is fine', () => h.q(`insert into messages (channel_id, author_id, content, embeds) values ($1, $2, $3, '[{"title":"x"}]')`, [ch, amy, '​']));
  await h.fails('an edit to blank is refused', `update messages set content = E'\\u200b' where id = (select id from messages where content = 'hi' limit 1)`);
  await h.ok('the old blank row can still be pinned', () => h.q(`update messages set pinned_at = now() where id = $1`, [old]));
}
