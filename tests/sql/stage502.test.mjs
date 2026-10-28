// 502: one Shard quest per linked account (Steam, AniList, Trakt, verified Last.fm). Same stand-ins as stage468.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { STANDINS } from './stage345.test.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql'];

const MORE = `
alter table public.profiles add column if not exists badges text[] not null default '{}';
alter table public.profiles add column if not exists shown_badge text;
create or replace function public.mod_guard(action text, target uuid, why text) returns void language sql as $$ select $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select public.is_site_admin() or public.is_site_mod() $$;
alter table auth.users add column if not exists email_confirmed_at timestamptz;
-- Live profiles are updatable column by column (085); the base here grants the whole table.
revoke update on public.profiles from anon, authenticated;
grant update (avatar_deco, profile_effect) on public.profiles to authenticated;
create table if not exists public.bots (id uuid primary key);
create table if not exists public.bot_accounts (bot text, user_id uuid primary key);
-- join_server as it is live (pg_get_functiondef, Oct 24), with stand-ins for what it calls.
create or replace function public.server_locked(sid uuid) returns boolean language sql stable as $$ select false $$;
create or replace function public.new_account_join_check(sid uuid) returns void language sql as $$ select $$;
CREATE OR REPLACE FUNCTION public.join_server(invite_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sid uuid; staff boolean := public.is_staff();
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select server_id into sid from public.invites where lower(code) = lower(invite_code);
  if sid is null then raise exception 'This invite is invalid or has expired'; end if;
  if not staff and public.server_locked(sid) then raise exception 'This server is locked right now. Try again in a few minutes.'; end if;
  if not staff and exists (select 1 from public.server_bans where server_id = sid and user_id = auth.uid()) then
    raise exception 'You''re banned from this server';
  end if;
  if not staff and (select count(*) from public.server_members where user_id = auth.uid()) >= 100 then
    raise exception 'You''re in too many servers';
  end if;
  -- 193: new account rule (join mode)
  if not staff then perform public.new_account_join_check(sid); end if;
  insert into public.server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  if found then
    update public.invites set uses = uses + 1 where lower(code) = lower(invite_code);
  end if;
  return sid;
end; $function$;
create table if not exists public.user_devices (user_id uuid not null, kind text not null, h text not null, first_seen timestamptz default now(), last_seen timestamptz default now(), primary key (user_id, kind, h));
`;

const MORE468 = `
alter table public.profiles add column if not exists plus_until timestamptz;
create table if not exists public.steam_links (user_id uuid primary key, steam_id text);
create table if not exists public.media_links (user_id uuid, source text, primary key (user_id, source));
create table if not exists auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid, status text);
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(MORE);
  await h.db.exec(MORE468);
  await h.db.exec(`alter table public.media_links add column if not exists verified boolean;`);
  for (const f of ['345_community_decos.sql', '360_artist_badge.sql', '389_one_decoration.sql', '462_shards.sql', '468_shard_quests.sql']) await h.db.exec(mig(f));
  const MIG = mig('502_link_quests.sql');
  await h.ok('502 runs', () => h.db.exec(MIG));
  await h.ok('502 re-runs cleanly', () => h.db.exec(MIG));

  const me = await h.signup('me@test.dev', 'me');
  await h.admin();
  await h.q(`update profiles set created_at = now() - interval '30 days' where id = $1`, [me]);
  await h.q(`update feature_flags set mode = 'everyone' where key in ('shards', 'shard_quests')`);
  const quests = async () => { await h.as(me); return Object.fromEntries((await h.one(`select shard_quests() r`)).r.map((q) => [q.key, q])); };
  const claim = async (key) => { await h.as(me); return h.q(`select claim_shard_quest($1)`, [key]).then(() => 'paid', (e) => e.message); };

  let q = await quests();
  h.eq('old connect quest is gone', 'connect' in q, false);
  h.eq('four link quests, 50 each', ['steam', 'anilist', 'trakt', 'lastfm'].map((k) => q[k]?.reward), [50, 50, 50, 50]);
  h.eq('none done yet', ['steam', 'anilist', 'trakt', 'lastfm'].map((k) => q[k].done), [false, false, false, false]);

  await h.admin();
  await h.q(`insert into steam_links (user_id, steam_id) values ($1, '1')`, [me]);
  await h.q(`insert into media_links (user_id, source) values ($1, 'anilist'), ($1, 'lastfm')`, [me]);
  q = await quests();
  h.eq('steam and anilist done, trakt not, typed-in lastfm not', ['steam', 'anilist', 'trakt', 'lastfm'].map((k) => q[k].done), [true, true, false, false]);
  h.eq('steam pays', await claim('steam'), 'paid');
  h.eq('anilist pays', await claim('anilist'), 'paid');
  h.eq('unverified lastfm refused', await claim('lastfm'), 'Not done yet');
  await h.admin();
  await h.q(`update media_links set verified = true where user_id = $1 and source = 'lastfm'`, [me]);
  await h.q(`insert into media_links (user_id, source) values ($1, 'trakt')`, [me]);
  h.eq('verified lastfm pays', await claim('lastfm'), 'paid');
  h.eq('trakt pays', await claim('trakt'), 'paid');
  h.eq('each only once', await claim('steam'), 'Already claimed');
  await h.admin();
  h.eq('balance is 4 x 50', (await h.one(`select balance from shard_wallets where user_id = $1`, [me])).balance, 200);
}
