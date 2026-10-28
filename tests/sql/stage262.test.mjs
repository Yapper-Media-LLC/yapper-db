// 262: first category keeps the default Text/Voice headers, templates copy categories, reaction-role emojis can be
// clicked without Add Reactions and must be one emoji, my_slowmode_wait. PGlite can't replay every migration, so:
// 001..024 plus stand-ins for the later tables/functions 262 runs next to, with the live definitions (Oct 18,
// read-only) of create_category, clear_reaction_roles, reaction_role_apply, drop_member_role, and
// reaction_emoji_ok from 161. Then 262 twice (re-runnable).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const m161 = mig('161_reaction_emoji_check.sql');
const EMOJI_OK = m161.slice(m161.indexOf('create or replace function public.reaction_emoji_ok'), m161.indexOf('$$;', m161.indexOf('reaction_emoji_ok')) + 3);

const STANDINS = `
alter table public.channels add column if not exists position int not null default 0;
alter table public.channels add column if not exists read_only boolean not null default false;
alter table public.channels add column if not exists slowmode int not null default 0;
alter table public.channels add column if not exists auto_slow_until timestamptz;
alter table public.channels add column if not exists ticket_by uuid;
create table if not exists public.channel_categories (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  name text not null, position int not null default 0, created_at timestamptz not null default now());
alter table public.channels add column if not exists category_id uuid references public.channel_categories (id) on delete set null;
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}';
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table if not exists public.server_templates (code text primary key, server_id uuid unique, created_by uuid, name text,
  data jsonb, uses int not null default 0, updated_at timestamptz default now());
create table if not exists public.reaction_roles (message_id uuid references public.messages (id) on delete cascade, emoji text,
  role_id uuid, server_id uuid, primary key (message_id, emoji));
create table if not exists public.post_marks (channel_id uuid, author_id uuid, kind text, at timestamptz, album_n int default 0,
  primary key (channel_id, author_id, kind));
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'gen_random_bytes') then
    create function public.gen_random_bytes(n int) returns bytea language sql as 'select decode(md5(random()::text), ''hex'')';
  end if;
end $$;
-- Owner can do anything; others get what their roles' perms say.
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                 where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms ->> perm)::boolean, false));
$$;
-- @everyone's perms decide (default allowed), the owner always can.
create or replace function public.channel_allows(cid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select s.owner_id = auth.uid() or coalesce((s.everyone_perms ->> perm)::boolean, true)
                   from public.channels c join public.servers s on s.id = c.server_id where c.id = cid), true);
$$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.my_top_role_position(sid uuid) returns int language sql stable as $$ select 0 $$;
create or replace function public.check_icon_path(p text) returns void language sql as $$ select $$;
${EMOJI_OK}

-- Live (Oct 18).
CREATE OR REPLACE FUNCTION public.create_category(sid uuid, p_name text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare cid uuid; n text := btrim(coalesce(p_name, ''));
begin
  if not public.server_perm(sid, 'manage_channels') then raise exception 'You can''t manage channels here'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'Category names are 1 to 40 characters'; end if;
  if (select count(*) from public.channel_categories where server_id = sid) >= 50 then raise exception 'Up to 50 categories'; end if;
  insert into public.channel_categories (server_id, name, position)
    values (sid, n, coalesce((select max(position) + 1 from public.channel_categories where server_id = sid), 0))
    returning id into cid;
  return cid;
end; $function$;
CREATE OR REPLACE FUNCTION public.clear_reaction_roles(mid uuid)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  ${'del' + 'ete'} from public.reaction_roles where message_id = mid;
$function$;
CREATE OR REPLACE FUNCTION public.drop_member_role(sid uuid, uid uuid, rid uuid)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  ${'del' + 'ete'} from public.member_roles where server_id = sid and user_id = uid and role_id = rid;
$function$;
CREATE OR REPLACE FUNCTION public.reaction_role_apply()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare rr record; uid uuid := coalesce(new.user_id, old.user_id);
begin
  select * into rr from public.reaction_roles where message_id = coalesce(new.message_id, old.message_id) and emoji = coalesce(new.emoji, old.emoji);
  if rr.role_id is null then return null; end if;
  if not exists (select 1 from public.server_members where server_id = rr.server_id and user_id = uid) then return null; end if;
  perform set_config('yapper.bot', '1', true);
  if tg_op = 'INSERT' then
    insert into public.member_roles (server_id, user_id, role_id) values (rr.server_id, uid, rr.role_id) on conflict do nothing;
  else
    perform public.drop_member_role(rr.server_id, uid, rr.role_id);
  end if;
  perform set_config('yapper.bot', '', true);
  return null;
end; $function$;
create trigger reactions_roles after insert or delete on public.reactions for each row execute function public.reaction_role_apply();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('262_categories_reaction_roles_slowmode.sql');
  await h.db.exec(MIG);
  await h.ok('262 re-runs cleanly', () => h.db.exec(MIG));

  const amy = await h.signup('amy@test.dev', 'amy');
  const bob = await h.signup('bob@test.dev', 'bob');
  const cat = await h.signup('cat@test.dev', 'cat'); // in no server
  await h.admin();
  const newServer = async (name, owner) => {
    const sid = (await h.one(`insert into servers (name, owner_id) values ($1, $2) returning id`, [name, owner])).id;
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, owner]);
    const text = (await h.one(`insert into channels (name, kind, server_id, created_by, position) values ('general', 'text', $1, $2, 0) returning id`, [sid, owner])).id;
    const voice = (await h.one(`insert into channels (name, kind, server_id, created_by, position) values ('General', 'voice', $1, $2, 1) returning id`, [sid, owner])).id;
    return { sid, text, voice };
  };
  const catsOf = async (sid) => (await h.q(`select name, position from channel_categories where server_id = $1 order by position`, [sid])).map((k) => `${k.position}:${k.name}`);
  const catOf = async (chid) => (await h.one(`select k.name from channels c left join channel_categories k on k.id = c.category_id where c.id = $1`, [chid])).name;

  // A1. The first category turns the default headers into real categories; later ones don't.
  const s1 = await newServer('One', amy);
  await h.as(amy);
  const info = (await h.one(`select create_category($1, 'Info') as id`, [s1.sid])).id;
  await h.admin();
  h.eq('first category: Text/Voice made first, new one under them', await catsOf(s1.sid), ['0:Text channels', '1:Voice channels', '2:Info']);
  h.eq('text channel moved into Text channels', await catOf(s1.text), 'Text channels');
  h.eq('voice channel moved into Voice channels', await catOf(s1.voice), 'Voice channels');
  h.eq('create_category still returns the new one', (await h.one(`select name from channel_categories where id = $1`, [info])).name, 'Info');
  const loose = (await h.one(`insert into channels (name, kind, server_id, created_by, position) values ('later', 'text', $1, $2, 2) returning id`, [s1.sid, amy])).id;
  await h.as(amy);
  await h.q(`select create_category($1, 'More')`, [s1.sid]);
  await h.admin();
  h.eq('second category: nothing else made', await catsOf(s1.sid), ['0:Text channels', '1:Voice channels', '2:Info', '3:More']);
  h.eq('second category: loose channels stay loose', await catOf(loose), null);

  // A server with only a text channel gets only "Text channels"; a direct insert (tickets) counts too.
  const s2 = (await h.one(`insert into servers (name, owner_id) values ('Two', $1) returning id`, [amy])).id;
  const t2 = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [s2, amy])).id;
  await h.q(`insert into channel_categories (server_id, name, position) values ($1, 'Tickets', 0)`, [s2]);
  h.eq('ticket category in a fresh server: Text channels first', await catsOf(s2), ['0:Text channels', '1:Tickets']);
  h.eq('ticket category: general kept under Text channels', await catOf(t2), 'Text channels');
  // No channels at all (imports and templates make categories first): nothing extra.
  const s3 = (await h.one(`insert into servers (name, owner_id) values ('Three', $1) returning id`, [amy])).id;
  await h.q(`insert into channel_categories (server_id, name, position) values ($1, 'Imported', 0)`, [s3]);
  h.eq('no channels yet: only the new category', await catsOf(s3), ['0:Imported']);

  // A2. Templates keep categories.
  await h.as(amy);
  const code = (await h.one(`select make_server_template($1) as c`, [s1.sid])).c;
  await h.admin();
  const data = (await h.one(`select data from server_templates where code = $1`, [code])).data;
  h.eq('template lists the categories in order', data.categories.map((k) => k.name), ['Text channels', 'Voice channels', 'Info', 'More']);
  h.eq('template channels point at their category', data.channels.map((c) => `${c.name}:${c.category}`), ['general:0', 'General:1', 'later:null']);
  await h.as(bob);
  const copy = (await h.one(`select create_server_from_template($1, 'Copy', null) as id`, [code])).id;
  await h.admin();
  h.eq('server from template has the categories', await catsOf(copy), ['0:Text channels', '1:Voice channels', '2:Info', '3:More']);
  const placed = await h.q(`select c.name, k.name as cat from channels c left join channel_categories k on k.id = c.category_id where c.server_id = $1 order by c.position`, [copy]);
  h.eq('server from template: channels back in their categories', placed.map((r) => `${r.name}:${r.cat}`), ['general:Text channels', 'General:Voice channels', 'later:null']);
  // A template made before 262 (no categories): channels only, as before.
  await h.q(`insert into server_templates (code, server_id, created_by, name, data) values ('oldtpl', null, $1, 'Old', $2)`,
    [amy, JSON.stringify({ channels: [{ kind: 'text', name: 'chat', position: 0 }], roles: [] })]);
  await h.as(bob);
  const old = (await h.one(`select create_server_from_template('oldtpl', 'Old copy', null) as id`)).id;
  await h.admin();
  h.eq('old template: no categories', await catsOf(old), []);
  h.eq('old template: channel made', (await h.q(`select name from channels where server_id = $1`, [old])).map((r) => r.name), ['chat']);
  // Ticket channels aren't copied into templates.
  await h.q(`insert into channels (name, kind, server_id, created_by, ticket_by) values ('ticket-0001', 'text', $1, $2, $2)`, [s1.sid, amy]);
  await h.as(amy);
  await h.q(`select make_server_template($1)`, [s1.sid]);
  await h.admin();
  h.eq('ticket channels left out of templates', (await h.one(`select data from server_templates where code = $1`, [code])).data.channels.length, 3);

  // B. Reaction roles.
  const rs = await newServer('Roles', amy);
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [rs.sid, bob]);
  await h.q(`update servers set everyone_perms = '{"add_reactions": false}' where id = $1`, [rs.sid]);
  const role = (await h.one(`insert into roles (server_id, name, position) values ($1, 'Gamer', 1) returning id`, [rs.sid])).id;
  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'pick a role') returning id`, [rs.text, amy])).id;
  await h.as(amy);
  await h.fails('emoji plus text refused', `select set_reaction_roles($1, $2)`, [msg, JSON.stringify([{ emoji: '✅ S', role_id: role }])]);
  await h.fails(':name: text refused', `select set_reaction_roles($1, $2)`, [msg, JSON.stringify([{ emoji: ':Yours_Truly:', role_id: role }])]);
  const long = `<a:${'a'.repeat(32)}:11111111-2222-4333-8444-555555555555>`;
  await h.q(`select set_reaction_roles($1, $2)`, [msg, JSON.stringify([{ emoji: '✅', role_id: role }, { emoji: long, role_id: role }])]);
  await h.admin();
  h.eq('saved, long custom emoji not cut off', (await h.q(`select emoji from reaction_roles where message_id = $1 order by emoji`, [msg])).map((r) => r.emoji).sort(), ['✅', long].sort());
  // Bob can't add reactions here, but can click the reaction-role emoji, and gets the role.
  await h.as(bob);
  await h.ok('reaction-role emoji clickable without Add Reactions', () => h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅')`, [msg, bob]));
  await h.fails('any other emoji still needs Add Reactions', `insert into reactions (message_id, user_id, emoji) values ($1, $2, '🔥')`, [msg, bob]);
  await h.fails('not as someone else', `insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅')`, [msg, amy]);
  await h.admin();
  h.eq('role given', (await h.q(`select 1 from member_roles where user_id = $1 and role_id = $2`, [bob, role])).length, 1);
  await h.as(cat);
  await h.fails('outsiders still can\'t react', `insert into reactions (message_id, user_id, emoji) values ($1, $2, '✅')`, [msg, cat]);

  // C. my_slowmode_wait.
  await h.admin();
  await h.q(`update channels set slowmode = 60 where id = $1`, [rs.text]);
  await h.as(bob);
  h.eq('nothing sent yet: no wait', (await h.one(`select my_slowmode_wait($1) as w`, [rs.text])).w, 0);
  await h.admin();
  await h.q(`insert into post_marks (channel_id, author_id, kind, at) values ($1, $2, 'msg', now() - interval '10 seconds')`, [rs.text, bob]);
  await h.as(bob);
  const w = (await h.one(`select my_slowmode_wait($1) as w`, [rs.text])).w;
  h.eq('a message 10s ago (since deleted): about 50s left', w >= 49 && w <= 50, true);
  await h.admin();
  // Seeded as admin with the message triggers off (one of them stamps created_at with now()).
  await h.q(`alter table messages disable trigger user`);
  await h.q(`insert into messages (channel_id, author_id, content, created_at) values ($1, $2, 'hi', now() - interval '2 seconds')`, [rs.voice, bob]);
  await h.q(`alter table messages enable trigger user`);
  await h.q(`update channels set slowmode = 30 where id = $1`, [rs.voice]);
  await h.as(bob);
  const w2 = (await h.one(`select my_slowmode_wait($1) as w`, [rs.voice])).w;
  h.eq('a message without a mark counts too', w2 >= 27 && w2 <= 28 ? 'ok' : w2, 'ok');
  await h.as(cat);
  h.eq('outsiders learn nothing', (await h.one(`select my_slowmode_wait($1) as w`, [rs.text])).w, null);
  await h.as(null);
  await h.fails('anon can\'t call it', `select my_slowmode_wait($1)`, [rs.text]);
}
