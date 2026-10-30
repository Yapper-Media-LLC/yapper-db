// 671: the suggestion limit message says "every 24 hours" and when the next one opens, and nothing else changes.
// submit_suggestion gets a stand-in with the live limit line (the rest of the live body needs later tables).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '671_suggestion_limit_wait.sql'), 'utf8');

const STANDINS = String.raw`
create table if not exists public.suggestions (id uuid primary key default gen_random_uuid(), user_id uuid, created_at timestamptz default now());
create or replace function public.submit_suggestion(cid uuid, p_title text, p_area text, p_body text)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
declare
  uid uuid := cid;
begin
  if p_title = 'other' then raise exception 'Give it a title (5 to 100 characters)'; end if;
  if (select count(*) from public.suggestions where user_id = uid and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You can send 3 suggestions a day. Try again tomorrow';
  end if;
  insert into public.suggestions (user_id) values (uid);
  return uid;
end $function$;
`;

export default async function (h) {
  for (const bad of ['drop', 'delete from', 'truncate']) {
    if (MIG.toLowerCase().includes(bad)) throw new Error(`671 contains "${bad}" (the Supabase MCP hangs on it)`);
  }
  await h.admin();
  await h.db.exec(STANDINS);
  await h.ok('671 runs', () => h.db.exec(MIG));
  await h.ok('671 re-runs cleanly', () => h.db.exec(MIG));
  const src = (await h.one(`select prosrc from pg_proc where proname = 'submit_suggestion'`)).prosrc;
  h.eq('old message gone', src.includes('Try again tomorrow'), false);
  h.eq('other lines kept', src.includes('Give it a title (5 to 100 characters)'), true);
  const u = '00000000-0000-0000-0000-000000000663';
  await h.db.query(`insert into public.suggestions (user_id, created_at) values ($1, now() - interval '20 hours'), ($1, now() - interval '2 hours'), ($1, now() - interval '1 hour')`, [u]);
  let msg = '';
  try { await h.db.query(`select public.submit_suggestion($1, 'title', 'chat', 'body')`, [u]); } catch (e) { msg = e.message; }
  h.eq('limit message', msg, 'You can send 3 suggestions every 24 hours. Your next one opens in 4 h');
  await h.db.query(`update public.suggestions set created_at = now() - interval '23 hours 50 minutes' where created_at < now() - interval '19 hours'`);
  try { await h.db.query(`select public.submit_suggestion($1, 'title', 'chat', 'body')`, [u]); } catch (e) { msg = e.message; }
  h.eq('minutes when under an hour', msg, 'You can send 3 suggestions every 24 hours. Your next one opens in 10 min');
  const ok = (await h.one(`select public.submit_suggestion('00000000-0000-0000-0000-000000000664', 'title', 'chat', 'body') v`)).v;
  h.eq('under the limit still posts', !!ok, true);
}
