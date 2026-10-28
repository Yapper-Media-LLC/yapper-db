// 428: @everyone with Mention @everyone, message links for limited accounts, promo rules for yapin.gg invites.
// The three live trigger functions aren't in the repo, so the stand-ins below carry the exact lines 428 patches.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const MIG = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '428_chat_link_fixes.sql'), 'utf8');

const STANDINS = String.raw`
drop function if exists public.message_raid_guard() cascade;
drop function if exists public.not_site_banned() cascade;
drop function if exists public.invites_only_in_promo() cascade;
create or replace function public.message_raid_guard() returns text language plpgsql as $f$
begin
  if exists (select 1 from public.channels c where c.id = null
        and ((c.server_id is not null and public.server_perm(c.server_id, 'manage_messages'))
          or (c.server_id is null and c.kind = 'group'))) then return 'x'; end if;
  return 'y';
end $f$;
create table if not exists public.t428 (content text);
create or replace function public.not_site_banned() returns trigger language plpgsql as $f$
begin
      if coalesce(new.content, '') ~* '(https?://|www\.)[^\s]' then raise exception 'links not allowed'; end if;
  return new;
end $f$;
create trigger t428_guard before insert on public.t428 for each row execute function public.not_site_banned();
create or replace function public.invites_only_in_promo() returns int language plpgsql as $f$
declare body text := 'see yapin.gg/invite/abc and www.yapper.website/invite/def';
begin
  if body !~* '(yapper\.website/invite/|discord\.gg/)' then return -1; end if;
  return (select count(*) from regexp_matches(body, 'yapper\.website/invite/([A-Za-z0-9_-]+)', 'gi'));
end $f$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MIG);
  await h.ok('428 re-runs cleanly', () => h.db.exec(MIG));

  const def = async (fn) => (await h.one(`select pg_get_functiondef('public.${fn}'::regproc) d`)).d;
  h.eq('raid guard: Mention @everyone counts', (await def('message_raid_guard')).includes("public.server_perm(c.server_id, 'mention_everyone')"), true);
  h.eq('raid guard: patched once', (await def('message_raid_guard')).split('mention_everyone').length - 1, 1);
  h.eq('not_site_banned reads the stripped text', (await def('not_site_banned')).includes('public.strip_message_links(new.content) ~*'), true);
  h.eq('promo trigger knows yapin.gg (both invites counted)', (await h.one('select public.invites_only_in_promo() n')).n, 2);
  h.eq('promo trigger: patched once', (await def('invites_only_in_promo')).split('yapin\\.gg)/invite/').length - 1, 2);

  const id0 = '0b7c2f7e-3a52-4c1e-9d55-6f8e2a1b9c00';
  await h.ok('a message link goes through the link rule', () => h.q(`insert into t428 values ('see https://yapin.gg/?channel=${id0}&msg=${id0}')`));
  await h.fails('any other link is still stopped', "insert into t428 values ('see https://evil.com/x')");
  await h.fails('a message link plus another link is stopped', `insert into t428 values ('https://yapin.gg/?channel=${id0}&msg=${id0} https://evil.com')`);

  const strip = async (t) => (await h.one('select public.strip_message_links($1) s', [t])).s;
  const id = '0b7c2f7e-3a52-4c1e-9d55-6f8e2a1b9c00';
  h.eq('a message link is removed', await strip(`look https://yapin.gg/?server=${id}&channel=${id}&msg=${id}`), 'look ');
  h.eq('old address and www too', await strip(`https://www.yapper.website/?channel=${id}&msg=${id}`), '');
  h.eq('any other link stays', await strip('https://evil.com/?channel=1&msg=2'), 'https://evil.com/?channel=1&msg=2');
  h.eq('a look-alike host stays', (await strip(`https://yapin.gg.evil.com/?channel=${id}&msg=${id}`)).startsWith('https://yapin.gg.evil.com'), true);
  h.eq('a link glued on after stays a link', /www\./.test(await strip(`https://yapin.gg/?channel=${id}&msg=${id}www.evil.com`)), true);
  h.eq('a link with more after the id stays', await strip(`https://yapin.gg/?channel=${id}&msg=${id}&next=//evil.com`), `https://yapin.gg/?channel=${id}&msg=${id}&next=//evil.com`);
  h.eq('a link in brackets or before more words still goes', await strip(`(https://yapin.gg/?channel=${id}&msg=${id}) and https://yapin.gg/?channel=${id}&msg=${id} ok`), '() and  ok');
  h.eq('null is empty', await strip(null), '');

  // A function that no longer has the line 428 patches makes it stop instead of silently doing nothing.
  await h.db.exec(`create or replace function public.message_raid_guard() returns text language sql as $f$ select 'rewritten' $f$`);
  await h.fails('changed function: patch by hand', MIG);
}
