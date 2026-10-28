// 275: a cascade delete (channel closed) skips log_mod_delete; a direct message delete still goes through it.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '275_ticket_close_fix.sql'), 'utf8');

export default async function (h) {
  await h.admin();
  await h.db.exec(`
    create table if not exists public.mod_log (actor uuid, action text, target_id uuid, message_id uuid, reason text);
    create or replace function public.is_site_mod() returns boolean language sql stable as $$ select true $$;
    create or replace function public.is_site_admin() returns boolean language sql stable as $$ select false $$;
    create or replace function public.mod_guard(a text, t uuid, w text) returns void language plpgsql as $$
      begin raise exception 'You can''t moderate an admin or another moderator'; end $$;`);
  await h.db.exec(MIG);
  await h.ok('275 re-runs cleanly', () => h.db.exec(MIG));
  await h.db.exec(`create trigger messages_log_mod_delete before delete on public.messages for each row execute function public.log_mod_delete()`);
  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [amy])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, amy, bob]);
  const mk = async () => {
    const c = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('t', 'text', $1, $2) returning id`, [sid, amy])).id;
    await h.q(`insert into messages (channel_id, author_id, content) values ($1, $2, 'a'), ($1, $3, 'b')`, [c, amy, bob]);
    return c;
  };
  const c1 = await mk();
  await h.as(amy);
  let msg = null;
  try { await h.q(`delete from messages where channel_id = $1 and author_id <> auth.uid()`, [c1]); } catch (e) { msg = e.message; }
  h.eq('direct delete of another mod\'s message still checked', /another moderator/.test(msg || '') ? 'refused' : msg, 'refused');
  await h.admin();
  const c2 = await mk();
  await h.as(amy);
  await h.ok('deleting the whole channel works', () => h.q(`delete from channels where id = $1`, [c2]));
  await h.admin();
  h.eq('cascade deletes still logged', (await h.one(`select count(*)::int n from mod_log where action = 'delete' and target_id = $1`, [bob])).n, 1);
  h.eq('messages gone', (await h.one(`select count(*)::int n from messages where channel_id = $1`, [c2])).n, 0);
}
