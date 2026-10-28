// 276: IP loggers and short links. Base 024 (PGlite stops there), the live shapes 276 replaces (has_adult_link without
// SECURITY DEFINER, check_links, the links triggers), then 276 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');
const LIST = JSON.parse(readFileSync(join(here, '..', '..', 'lib', 'linkhosts.json'), 'utf8'));
// Added to the JSON later (cocainee.pro: in link_hosts live with 526, checked in stage528).
const LATER = ['cocainee.pro'];

const LIVE_SHAPES = `
alter table public.profiles add column if not exists links jsonb default '[]'::jsonb;
alter table public.servers add column if not exists links jsonb default '[]'::jsonb;
insert into public.blocked_domains (domain) values ('grabify.link'), ('iplogger.org') on conflict do nothing;
CREATE OR REPLACE FUNCTION public.has_adult_link(t text) RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.link_targets(t) as l join public.blocked_domains b
    on l = b.domain or l like '%.' || b.domain or l like b.domain || '/%' or l like '%.' || b.domain || '/%')
  or exists (select 1 from public.link_targets(t) as l where split_part(lower(l), '/', 1) ~ '(roblox|robux|rbx)'
    and split_part(lower(l), '/', 1) !~ '(^|\\.)(roblox\\.com|rbxcdn\\.com|rblx\\.co|robloxdev\\.cn|roblox\\.cn)$');
$function$;
CREATE OR REPLACE FUNCTION public.check_links() RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare l jsonb; u text;
begin
  if jsonb_typeof(new.links) <> 'array' or jsonb_array_length(new.links) > 5 then raise exception 'Up to 5 links'; end if;
  for l in select * from jsonb_array_elements(new.links) loop
    u := l ->> 'url';
    if u is null or u !~* '^https?://[^\\s]{3,200}$' then raise exception 'Links must start with http(s)://'; end if;
    if public.has_adult_link(u) then raise exception 'Links to adult sites aren''t allowed on Yapper.'; end if;
  end loop;
  return new;
end; $function$;
create trigger profiles_check_links before insert or update of links on public.profiles for each row execute function check_links();
create trigger servers_check_links before insert or update of links on public.servers for each row execute function check_links();
create trigger profiles_no_bad_links before insert or update of links on public.profiles for each row execute function no_adult_links('links');
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists pronouns text;
alter table public.profiles add column if not exists accent_color text;
alter table public.profiles add column if not exists accent_color2 text;
alter table public.profiles add column if not exists verified_as text;
create or replace function public.clean_name(t text) returns text language sql immutable as $$ select nullif(btrim(t), '') $$;
create or replace function public.bad_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_name(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.verify_name_key(t text) returns text language sql immutable as $$ select lower(coalesce(t, '')) $$;
create or replace function public.profile_custom_guard() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger profiles_custom_guard before insert or update on public.profiles for each row execute function profile_custom_guard();
`;

export default async function (h) {
  const refused = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(LIVE_SHAPES);

  const amy = await h.signup('amy@test.dev', 'amy');
  await h.as(amy);
  h.eq('before 276: a normal user sees an empty block list (the bug)', (await h.one(`select has_adult_link('https://grabify.link/x') x`)).x, false);

  await h.admin();
  const MIG = mig('276_link_loggers.sql');
  await h.db.exec(MIG);
  await h.ok('276 re-runs cleanly', () => h.db.exec(MIG));

  const rows = await h.q(`select domain, kind from link_hosts order by domain`);
  const want = [...LIST.loggers.map((d) => ({ domain: d, kind: 'logger' })), ...LIST.shorteners.map((d) => ({ domain: d, kind: 'shortener' }))]
    .filter((r) => !LATER.includes(r.domain))
    .sort((a, b) => (a.domain < b.domain ? -1 : 1));
  h.eq('link_hosts matches lib/linkhosts.json', rows, want);

  // An old bit.ly link someone already has (saved before 276; triggers off to put it there).
  await h.db.exec(`alter table profiles disable trigger user`);
  await h.q(`update profiles set links = '[{"label":"old","url":"https://bit.ly/old"},{"label":"bad","url":"https://grabify.link/old"}]',
    bio = 'see pornhub.com', display_name = 'grabify.link fan' where id = $1`, [amy]);
  await h.db.exec(`alter table profiles enable trigger user`);

  await h.as(amy);
  h.eq('after: block list works for normal users', (await h.one(`select has_adult_link('https://grabify.link/x') x`)).x, true);
  h.eq('after: urlto.me is blocked everywhere', (await h.one(`select has_adult_link('look https://urlto.me/29Had') x`)).x, true);
  h.eq("link_hosts isn't readable by users", (await h.q(`select * from link_hosts`)).length, 0);

  const save = (url) => h.q(`update profiles set links = jsonb_build_array(jsonb_build_object('label', 'x', 'url', $1::text)) || links where id = $2`, [url, amy]);
  const SHORT = /Short links and IP loggers/;
  const IP = /not an IP address/;
  const ODD = /look like a real site|start with/;
  for (const u of ['https://urlto.me/29Had', 'https://URLTO.ME/29Had', 'https://www.urlto.me/x', 'https://urlto.me./x', 'https://urlto.me:443/x',
    'https://youtube.com@urlto.me/x', 'https://youtube.com:pw@urlto.me', 'https://urlto.me\\@youtube.com/', 'https://bit.ly/abc', 'http://t.co/x',
    'https://tinyurl.com/x', 'https://a.b.cutt.ly/x', 'https://grabify.link/ABC', 'https://iplogger.org/2abc', 'https://2no.co/1', 'https://xn--yotu-1ra.be/x']) {
    await refused(`refuses ${u}`, SHORT, `update profiles set links = jsonb_build_array(jsonb_build_object('label', 'x', 'url', $1::text)) where id = $2`, [u, amy]);
  }
  for (const u of ['http://1.2.3.4/x', 'http://127.1', 'http://0x7f.1/', 'http://a.0x7f', 'https://[::1]/', 'https://[::ffff:1.2.3.4]:80/', 'http://foo.123']) {
    await refused(`refuses IP ${u}`, IP, `update profiles set links = jsonb_build_array(jsonb_build_object('label', 'x', 'url', $1::text)) where id = $2`, [u, amy]);
  }
  for (const u of ['https://urlto%2Eme/x', 'https://yoütu.be/x', 'https:///urlto.me/x', 'https://\\urlto.me/x', 'http://2130706433/', 'https://localhost/']) {
    await refused(`refuses odd ${u}`, ODD, `update profiles set links = jsonb_build_array(jsonb_build_object('label', 'x', 'url', $1::text)) where id = $2`, [u, amy]);
  }
  await refused('refuses adult site in links', /that site/, `update profiles set links = '[{"label":"x","url":"https://pornhub.com/x"}]' where id = $1`, [amy]);

  await h.ok('a normal new link next to the old bit.ly one saves (old link left alone)', () => save('https://youtube.com/@amy'));
  await h.ok('punycode site names are fine', () => save('https://xn--mnchen-3ya.de/'));
  await refused('a new bit.ly next to the old one is refused', SHORT, `update profiles set links = links || '[{"label":"y","url":"https://bit.ly/new"}]' where id = $1`, [amy]);
  h.eq('saved links unchanged by the checks', (await h.one(`select links from profiles where id = $1`, [amy])).links.map((l) => l.url),
    ['https://xn--mnchen-3ya.de/', 'https://youtube.com/@amy', 'https://bit.ly/old', 'https://grabify.link/old']);
  h.eq('069 whole-list triggers are gone', (await h.q(`select tgname from pg_trigger where tgname in ('profiles_no_bad_links', 'servers_no_bad_links')`)).length, 0);
  await h.ok('relabelling an old bad link keeps it (URL not re-checked)', () => h.q(
    `update profiles set links = jsonb_set(links, '{3,label}', '"my old"') where id = $1`, [amy]));
  await refused('a blocked site in a changed label is refused', /that site/,
    `update profiles set links = jsonb_set(links, '{3,label}', '"pornhub.com"') where id = $1`, [amy]);
  await h.ok('removing the old bad link works', () => h.q(`update profiles set links = links - 3 where id = $1`, [amy]));

  // 1. Display name: only checked when it changes.
  await h.ok('bio edit with an old bad display name works', () => h.q(`update profiles set bio = 'hi' where id = $1`, [amy]));
  await refused('a new bad display name is refused', /display name/, `update profiles set display_name = 'see grabify。link' where id = $1`, [amy]);
  await h.ok('a fine display name works', () => h.q(`update profiles set display_name = 'Amy' where id = $1`, [amy]));

  // 2. Disguised links.
  for (const t of ['https://grabify%2Elink/x', 'https://grabify%2elink', 'grabify。link/x', 'grabify．link', 'grabify｡link', 'ｇｒａｂｉｆｙ.link',
    'https://ＧＲＡＢＩＦＹ．ＬＩＮＫ/x', 'grab\u00ADify.link', 'grab\u200Bify.link', 'grab\u200Cify.link', 'grab\u200Dify.link', 'grab\u2060ify.link', 'grab\uFEFFify.link',
    'urlto。me/29Had']) {
    h.eq(`blocks ${JSON.stringify(t)}`, (await h.one(`select has_adult_link($1) x`, [t])).x, true);
  }
  for (const t of ['https://youtube.com/watch?v=1', 'hello。world', 'ｈｅｌｌｏ', 'a%2eb']) {
    h.eq(`allows ${JSON.stringify(t)}`, (await h.one(`select has_adult_link($1) x`, [t])).x, false);
  }
  await h.ok('editing the name keeps working with an old bad bio', () => h.q(`update profiles set username = 'amy2' where id = $1`, [amy]));
  await refused('a new bad bio is refused', /that site/, `update profiles set bio = 'see https://grabify.link/x' where id = $1`, [amy]);

  // Server links go through the same trigger.
  const sid = (await h.one(`select create_server('S', null) id`)).id;
  const chan = (await h.one(`select id from channels where server_id = $1 and name = 'general'`, [sid])).id;
  await h.admin();
  await refused('server link shortener refused', SHORT, `update servers set links = '[{"label":"x","url":"https://rb.gy/x"}]' where id = $1`, [sid]);
  await h.ok('server normal link fine', () => h.q(`update servers set links = '[{"label":"x","url":"https://github.com/x"}]' where id = $1`, [sid]));

  // Chat: IP loggers now refused in messages for normal users.
  await h.as(amy);
  await refused('IP logger in a message refused', /that site/, `insert into messages (channel_id, author_id, content) values ($1, $2, 'free nitro https://urlto.me/29Had')`, [chan, amy]);
  await refused('disguised IP logger in a message refused', /that site/, `insert into messages (channel_id, author_id, content) values ($1, $2, 'free nitro https://grabify%2Elink/x')`, [chan, amy]);
  await refused('full-width dot IP logger in a message refused', /that site/, `insert into messages (channel_id, author_id, content) values ($1, $2, 'grabify。link/abc')`, [chan, amy]);

  // 7. Triage note.
  await h.admin();
  const bob = await h.signup('bob@test.dev', 'bob');
  const rid = (await h.one(`insert into reports (reporter_id, target_id, reason, message_content) values ($1, $2, 'spam', 'https://urlto.me/29Had') returning id`, [bob, amy])).id;
  h.eq('triage says Blocked link', (await h.one(`select (triage_rules(r)).note from reports r where id = $1`, [rid])).note, 'Blocked link');
}
