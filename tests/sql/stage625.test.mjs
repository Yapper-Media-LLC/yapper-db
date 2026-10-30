// 625: emoji source card and staff emoji lookup. Base 24 has emojis with server_id; stand-ins for the later bits
// (is_staff, invites.vanity, servers.shut_down_at/member_count, media_purge, profiles.display_name).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage589.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const MORE = `
alter table public.invites add column if not exists vanity boolean not null default false;
alter table public.servers add column if not exists shut_down_at timestamptz;
alter table public.servers add column if not exists member_count integer not null default 0;
alter table public.servers add column if not exists discoverable boolean not null default false;
alter table public.profiles add column if not exists display_name text;
create table if not exists public.media_purge (bucket text not null, path text not null, queued_at timestamptz not null default now(),
  done_at timestamptz, error text, primary key (bucket, path));
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null); $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod(); $$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(mig('625_emoji_source.sql'));
  await h.ok('625 re-runs cleanly', () => h.db.exec(mig('625_emoji_source.sql')));

  const mod = await h.signup('mod622@test.dev', 'mod622');
  const owner = await h.signup('owner622@test.dev', 'owner622');
  const member = await h.signup('member622@test.dev', 'member622');
  const outsider = await h.signup('out622@test.dev', 'out622');
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);
  const SID = '00000000-0000-4000-8000-00000000b001';
  const PUB = 'a1509fda-bcf4-48a2-9cac-756bd3fff8f2';
  await h.q(`insert into servers (id, name, owner_id, discoverable) values ($1, 'Private', $2, false), ($3, 'Public', $2, true)`, [SID, owner, PUB]);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3), ($4, $2) on conflict do nothing`, [SID, owner, member, PUB]);
  await h.q(`insert into invites (code, server_id, created_by, vanity) values ('pubpub', $1, $2, true)`, [PUB, owner]);
  const E1 = '11111111-1111-4111-8111-111111111111';
  const E2 = '22222222-2222-4222-8222-222222222222';
  await h.q(`insert into emojis (id, owner_id, server_id, name, path) values
    ($1::uuid, $2::uuid, $3::uuid, 'yikes', $2 || '/r2-' || $1 || '-1700000000-abc123.png'),
    ($4::uuid, $2::uuid, $5::uuid, 'party', $2 || '/r2-1700000001-def456.gif')`, [E1, owner, SID, E2, PUB]);
  // Flag: test mode, on in the private server (member and owner), off for the outsider.
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'emoji_source'`, [SID]);

  // emoji_source: anyone with the flag, uploader only for staff.
  await h.as(member);
  let r = (await h.one(`select emoji_source($1) j`, [E1])).j;
  h.eq('member sees the server name', r.server.name, 'Private');
  h.eq('member sees joined', r.server.joined, true);
  h.eq('member does not see the uploader', r.uploader, null);
  r = (await h.one(`select emoji_source($1) j`, [E2])).j;
  h.eq('public server: invite code', r.server.invite, 'pubpub');
  h.eq('public server: not joined', r.server.joined, false);
  h.eq('private server: no invite', (await h.one(`select emoji_source($1) j`, [E1])).j.server.invite, null);
  await h.as(outsider);
  h.eq('flag off: nothing', (await h.one(`select emoji_source($1) j`, [E1])).j, null);
  await h.as(null);
  await h.fails('anon cannot call', `select emoji_source($1)`, [E1]);
  await h.as(mod);
  r = (await h.one(`select emoji_source($1) j`, [E1])).j;
  h.eq('staff: flag off for them too', r, null);
  await h.admin();
  await h.q(`update feature_flags set mode = 'everyone' where key = 'emoji_source'`);
  await h.as(mod);
  r = (await h.one(`select emoji_source($1) j`, [E1])).j;
  h.eq('staff sees the uploader', r.uploader.username, 'owner622');

  // staff_emoji_lookup: staff only; by id, token, link with id, link without id, path, name.
  await h.as(member);
  await h.fails('member cannot look up', `select staff_emoji_lookup('yikes')`);
  await h.as(null);
  await h.fails('anon cannot look up', `select staff_emoji_lookup('yikes')`);
  await h.as(mod);
  const look = async (q) => (await h.one(`select staff_emoji_lookup($1) j`, [q])).j;
  h.eq('by id', (await look(E1)).map((x) => x.id), [E1]);
  h.eq('by token', (await look(`<:whatever:${E1}>`)).map((x) => x.id), [E1]);
  h.eq('by link with the id in the name', (await look(`https://files.yapper.website/emojis/${owner}/r2-${E1}-1700000000-abc123.png?r=1`)).map((x) => x.id), [E1]);
  h.eq('by old link (path match)', (await look(`https://files.yapper.website/emojis/${owner}/r2-1700000001-def456.gif`)).map((x) => x.id), [E2]);
  h.eq('by path', (await look(`${owner}/r2-1700000001-def456.gif`)).map((x) => x.id), [E2]);
  h.eq('by name', (await look(':YIKES:')).map((x) => x.name), ['yikes']);
  h.eq('by part of a name', (await look('art')).map((x) => x.name), ['party']);
  h.eq('nothing', await look('zzz'), []);
  h.eq('empty', await look('  '), []);
  h.eq('lookup carries the uploader', (await look(E1))[0].uploader.username, 'owner622');
  h.eq('lookup carries the server', (await look(E1))[0].server.name, 'Private');

  // staff_emoji_remove: staff only; row gone, purge queued, log written.
  await h.as(member);
  await h.fails('member cannot remove', `select staff_emoji_remove($1, 'nope')`, [E1]);
  await h.as(mod);
  await h.q(`select staff_emoji_remove($1, 'racist')`, [E1]);
  await h.fails('removing twice fails', `select staff_emoji_remove($1, 'again')`, [E1]);
  await h.admin();
  h.eq('row gone', (await h.q(`select 1 from emojis where id = $1`, [E1])).length, 0);
  h.eq('other emoji stays', (await h.q(`select 1 from emojis where id = $1`, [E2])).length, 1);
  h.eq('picture queued for purge', (await h.q(`select 1 from media_purge where bucket = 'emojis' and path like '%abc123.png'`)).length, 1);
  const log = await h.one(`select * from mod_log where action = 'emoji_removed'`);
  h.eq('log targets the uploader', log.target_id, owner);
  h.eq('log reason names the emoji and server', log.reason.startsWith(':yikes: (Private, '), true);
  h.eq('log reason keeps the note', log.reason.endsWith(' racist'), true);
}
