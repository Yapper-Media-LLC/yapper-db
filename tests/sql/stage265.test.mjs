// 265: Use Big Text permission. PGlite stops at 024, so: stand-ins for the permission helpers and short versions
// of the two message guards that carry the same anchor lines as live (265 patches them in place). Then 265 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const STANDINS = `
create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
alter table public.servers add column if not exists everyone_perms jsonb not null default '{}';
create table if not exists public.roles (id uuid primary key default gen_random_uuid(), server_id uuid, name text);
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table if not exists public.member_roles (server_id uuid, user_id uuid, role_id uuid, primary key (server_id, user_id, role_id));
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), channel_id uuid, category_id uuid, role_id uuid,
  allow text[] not null default '{}', deny text[] not null default '{}',
  constraint channel_overrides_known_perms check (allow <@ array['view_channel', 'send_messages'] and deny <@ array['view_channel', 'send_messages']));
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$
  select coalesce((select mode = 'everyone' or (mode = 'test' and sid = any(servers)) from public.feature_flags where key = k), false) $$;
create or replace function public.basic_perm(perm text) returns boolean language sql immutable as $$ select perm in ('send_messages') $$;
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                 where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms ->> perm)::boolean, false))
      or (public.basic_perm(perm) and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = auth.uid())
          and coalesce((select (everyone_perms ->> perm)::boolean from public.servers where id = sid), true)) $$;
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql stable as $$
  select public.server_perm((select server_id from public.channels where id = cid), perm) $$;
create or replace function public.fix_role_pings(sid uuid, cid uuid, cp boolean, t text) returns text language sql as $$ select t $$;

-- Short versions of the live guards, same anchor lines.
CREATE OR REPLACE FUNCTION public.message_perm_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid; cp boolean := false;
begin
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return new; end if;
  new.content := public.fix_role_pings(sid, new.channel_id, cp, new.content);
  return new;
end; $function$;
CREATE OR REPLACE FUNCTION public.message_edit_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid; cp boolean := false;
begin
  if new.content is distinct from old.content and auth.uid() is not null then
    select server_id into sid from public.channels where id = old.channel_id;
    if sid is not null then
      new.content := public.fix_role_pings(sid, old.channel_id, cp, new.content);
    end if;
  end if;
  return new;
end $function$;
-- Short version of the live suggestion form RPC, same anchor lines.
CREATE OR REPLACE FUNCTION public.submit_suggestion(cid uuid, p_title text, p_area text, p_body text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  uid uuid := auth.uid();
  t text := btrim(coalesce(p_title, ''));
  b text := btrim(coalesce(p_body, ''));
  label text := 'Other';
  mid uuid;
begin
  insert into public.messages (channel_id, author_id, content)
  values (cid, uid, '## 💡 ' || t || E'\\n-# ' || label || E'\\n' || b)
  returning id into mid;
  return mid;
end $function$;
create trigger messages_perm_guard_t before insert on public.messages for each row execute function public.message_perm_guard();
create trigger messages_edit_guard_t before update on public.messages for each row execute function public.message_edit_guard();
`;

export default async function (h) {
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('265_big_text_perm.sql');
  await h.db.exec(MIG);
  await h.ok('265 re-runs cleanly', () => h.db.exec(MIG));
  h.eq('patched the send guard once', (await h.one(`select (length(pg_get_functiondef('message_perm_guard()'::regprocedure)) - length(replace(pg_get_functiondef('message_perm_guard()'::regprocedure), 'use_headings', ''))) / 12 n`)).n, 2);
  h.eq('patched the edit guard once', (await h.one(`select (length(pg_get_functiondef('message_edit_guard()'::regprocedure)) - length(replace(pg_get_functiondef('message_edit_guard()'::regprocedure), 'use_headings', ''))) / 12 n`)).n, 2);

  const big = async (t) => (await h.one(`select has_big_text($1) b`, [t])).b;
  const cases = [
    ['# hi', true], ['## hi', true], ['### hi', true], ['hello\n# hi', true], ['> # quoted', true], ['  # indented', true],
    ['#### four', false], ['#hashtag', false], ['-# small text', false], ['text # not at the start', false],
    ['```\n# in code\n```', false], ['x```y```# glued after code', true], ['#\u00a0nbsp', false], ['#\u3000wide', false], ['#\rcr', false], ['```\ncode\n```\n# after code', true], ['', false], ['#', false], ['# ', false],
  ];
  for (const [t, want] of cases) h.eq(`has_big_text(${JSON.stringify(t)})`, await big(t), want);
  h.eq('null content', (await h.one(`select has_big_text(null) b`)).b, false);
  h.eq('basic perm now includes use_headings', (await h.one(`select basic_perm('use_headings') b`)).b, true);
  await h.ok('override can deny use_headings', () => h.q(`insert into channel_overrides (allow, deny) values ('{}', '{use_headings}')`));

  const owner = await h.signup('own@test.dev', 'own');
  const vip = await h.signup('vip@test.dev', 'vip');
  const pleb = await h.signup('pleb@test.dev', 'pleb');
  await h.admin();
  // Older accounts, so the new-account send limit (024) doesn't get in the way.
  await h.q(`update profiles set created_at = now() - interval '30 days'`);
  const sid = (await h.one(`insert into servers (name, owner_id) values ('S', $1) returning id`, [owner])).id;
  for (const u of [owner, vip, pleb]) await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, u]);
  const cid = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('general', 'text', $1, $2) returning id`, [sid, owner])).id;
  const rid = (await h.one(`insert into roles (server_id, name, perms) values ($1, 'VIP', '{"use_headings": true}') returning id`, [sid])).id;
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, vip, rid]);
  const send = (t) => h.q(`insert into messages (channel_id, author_id, content) values ($1, auth.uid(), $2) returning id`, [cid, t]);

  // Flag off for this server: nothing changes even with @everyone's big text off.
  await h.q(`update servers set everyone_perms = '{"use_headings": false}' where id = $1`, [sid]);
  await h.as(pleb);
  await h.ok('flag off: anyone can still post a heading', () => send('# hello'));

  await h.admin();
  await h.q(`update feature_flags set servers = array[$1]::uuid[] where key = 'big_text_perm'`, [sid]);
  await h.as(pleb);
  await failsWith('big text off for @everyone: a heading is refused', /big text/, `insert into messages (channel_id, author_id, content) values ($1, auth.uid(), '# hello')`, [cid]);
  await failsWith('also inside a quote', /big text/, `insert into messages (channel_id, author_id, content) values ($1, auth.uid(), E'> ## hey')`, [cid]);
  await h.ok('plain text is fine', () => send('hello # there'));
  await h.ok('small text is fine', () => send('-# psst'));
  await h.ok('a heading in a code block is fine', () => send('```\n# not big\n```'));
  const plain = (await send('typo heree'))[0].id;
  await failsWith('editing a heading in is refused', /big text/, `update messages set content = '# typo here' where id = $1`, [plain]);
  await h.ok('the suggestion form header isn\'t blocked', () => h.q(`select submit_suggestion($1, 'Dark mode', 'other', 'please')`, [cid]));
  await failsWith('and the setting doesn\'t stick after it', /big text/, `insert into messages (channel_id, author_id, content) values ($1, auth.uid(), '# sneaky')`, [cid]);
  await h.as(vip);
  await h.ok('a role with Use Big Text can', () => send('# announcement'));
  await h.as(owner);
  const own = (await send('# owner post'))[0].id;
  await h.ok('the owner always can', () => Promise.resolve());

  // An old heading message (posted before the switch) can still be fixed.
  await h.admin();
  const old = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, '# old one') returning id`, [cid, pleb])).id;
  await h.as(pleb);
  await h.ok('editing a message that already had a heading is fine', () => h.q(`update messages set content = '# old one, fixed' where id = $1`, [old]));

  // Back on for @everyone.
  await h.admin();
  await h.q(`update servers set everyone_perms = '{}' where id = $1`, [sid]);
  await h.as(pleb);
  await h.ok('default (no setting): everyone can', () => send('# yay'));
  void own;
}
