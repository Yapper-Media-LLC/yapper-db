// 171 verification name match, 172 per-account app settings. Starts from stage 24 (PGlite can't replay 025+) with
// stand-ins for the live pieces 171 uses (skeleton copied from the live definition), then runs 171 and 172.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const STANDINS = `
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists verified_as text;
create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(), user_id uuid not null, platform text, handle text, link text, note text,
  proof_path text, status text not null default 'pending', reviewed_at timestamptz, created_at timestamptz default now());
grant select, insert on public.verification_requests to authenticated;
create or replace function public.brand_name(t text) returns boolean language sql stable as $$ select lower(coalesce(t, '')) in ('youtube', 'yapper') $$;
create or replace function public.bad_name(t text) returns boolean language sql stable as $$ select false $$;
create or replace function public.skeleton(t text) returns text language plpgsql immutable as $f$
declare s text := lower(coalesce(t, ''));
  pairs text[][] := array[['а','a'],['е','e'],['о','o'],['0','o'],['1','l'],['3','e'],['4','a'],['5','s'],['7','t'],['8','b'],['$','s'],['@','a'],['!','i'],['|','l']];
  i int;
begin
  s := translate(s, 'ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ', 'abcdefghijklmnopqrstuvwxyz');
  for i in 1 .. array_length(pairs, 1) loop s := replace(s, pairs[i][1], pairs[i][2]); end loop;
  return s;
end $f$;
`;

// The three profile guards as they are live (pg_get_functiondef, 2026-10-17), so 171's in-place patches are tested
// against the real text. Helpers they call are simple stand-ins.
const GUARDS = String.raw`
create or replace function public.clean_name(t text) returns text language sql immutable as $$ select nullif(btrim(t), '') $$;
create or replace function public.has_adult_link(t text) returns boolean language sql immutable as $$ select false $$;
create or replace function public.brand_like(t text) returns boolean language sql stable as $$ select lower(coalesce(t, '')) like '%youtube%' $$;
create or replace function public.country_name(t text) returns boolean language sql stable as $$ select false $$;
alter table public.profiles add column if not exists pronouns text;
alter table public.profiles add column if not exists accent_color text;
alter table public.profiles add column if not exists accent_color2 text;
CREATE OR REPLACE FUNCTION public.name_key(t text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(translate(lower(coalesce(t, '')), '01i345780@$', 'olleastbooas'), '[^a-z0-9]', '', 'g') $function$;
CREATE OR REPLACE FUNCTION public.profile_custom_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare handle text; nm text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username) or (public.brand_name(new.username) and not public.is_site_admin())) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := left(public.clean_name(new.display_name), 32);
  if new.display_name is not null and new.display_name !~ '[[:alnum:]]' then raise exception 'Display names need at least one letter or number'; end if;
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or (public.brand_name(new.display_name) and not public.is_site_admin())) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  -- A verified badge belongs to the name it was given for: change the shown name and the badge goes
  -- (unless the new name still matches the verified channel). Admins can re-approve.
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and (new.username is distinct from old.username or new.display_name is distinct from old.display_name)
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := lower(regexp_replace(split_part(old.verified_as, ' · ', 2), '[^a-z0-9]', '', 'gi'));
    nm := lower(regexp_replace(coalesce(new.display_name, new.username), '[^a-z0-9]', '', 'gi'));
    if nm <> handle then new.verified_as := null; end if;
  end if;
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.profile_impersonation_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k_user text; k_disp text;
begin
  if current_user in ('postgres', 'service_role') or public.is_site_admin() then return new; end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username and new.display_name is not distinct from old.display_name then return new; end if;
  if new.display_name ~ '[✓✔☑✅🗸🗹]' or new.username ~ '[✓✔☑✅🗸🗹]' then
    raise exception 'Check marks are reserved for the verified badge. Pick another name.' using errcode = 'check_violation';
  end if;
  k_user := public.name_key(new.username);
  k_disp := public.name_key(new.display_name);
  if exists (select 1 from public.profiles v where v.verified_as is not null and v.id <> new.id
      and length(public.name_key(split_part(v.verified_as, ' · ', 2))) >= 4
      and public.name_key(split_part(v.verified_as, ' · ', 2)) in (k_user, k_disp)) then
    raise exception 'That name belongs to a verified creator. Pick another.' using errcode = 'check_violation';
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.verified_name_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare handle text;
begin
  if new.verified_as is null or current_user in ('postgres', 'service_role') then return new; end if;
  if tg_op = 'UPDATE' and new.verified_as is not distinct from old.verified_as
     and new.username is not distinct from old.username and new.display_name is not distinct from old.display_name then return new; end if;
  handle := public.name_key(split_part(new.verified_as, ' · ', 2));
  if (public.brand_like(new.username) or public.country_name(new.username)) and public.name_key(new.username) <> handle
     or (new.display_name is not null and (public.brand_like(new.display_name) or public.country_name(new.display_name)) and public.name_key(new.display_name) <> handle) then
    if tg_op = 'UPDATE' and old.verified_as is null then
      raise exception 'Can''t verify this account: its name is a brand or country, not the verified channel.' using errcode = 'check_violation';
    end if;
    raise exception 'Verified accounts can''t use a brand or country name. Pick another.' using errcode = 'check_violation';
  end if;
  return new;
end $function$;
-- Same events as live (pg_get_triggerdef).
create trigger t171_custom before insert or update on public.profiles for each row execute function public.profile_custom_guard();
create trigger t171_imp before insert or update of username, display_name on public.profiles for each row execute function public.profile_impersonation_guard();
create trigger t171_vname before update of username, display_name, verified_as on public.profiles for each row execute function public.verified_name_guard();
-- review_verification as it is live, with stand-ins for what it calls.
alter table public.verification_requests add column if not exists reviewed_by uuid;
alter table public.verification_requests add column if not exists review_note text;
create table if not exists public.mod_log (id uuid primary key default gen_random_uuid(), actor uuid, action text, target_id uuid, reason text);
create or replace function public.is_staff() returns boolean language sql stable as $$ select public.is_site_admin() $$;
create or replace function public.mod_guard(a text, t uuid, w text) returns void language sql as $$ select $$;
create or replace function public.bc(a text, b text, c text, d text, e text, f jsonb, g jsonb) returns void language sql as $$ select $$;
CREATE OR REPLACE FUNCTION public.review_verification(rid uuid, approve boolean, p_note text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.verification_requests; label text;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  perform public.mod_guard('verify', null, null);
  update public.verification_requests
    set status = case when approve then 'approved' else 'rejected' end, reviewed_by = auth.uid(), reviewed_at = now(), review_note = coalesce(p_note, '')
    where id = rid;
  if approve then
    label := case r.platform when 'youtube' then 'YouTube' when 'twitch' then 'Twitch' when 'tiktok' then 'TikTok'
                             when 'instagram' then 'Instagram' when 'x' then 'X' else 'Creator' end || ' · ' || r.handle;
    update public.profiles set verified_as = label where id = r.user_id;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), case when approve then 'verify' else 'verify_reject' end, r.user_id, coalesce(p_note, '') || ' (' || r.platform || ' ' || r.handle || ')');
  perform public.bc('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $function$;
`;

const msg = async (h, sql, params = []) => { try { await h.q(sql, params); return null; } catch (e) { return e.message; } };

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(GUARDS);
  for (const m of ['171_verify_name_match.sql', '172_user_prefs.sql']) {
    await h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', m), 'utf8'));
  }
  for (const m of ['171_verify_name_match.sql', '172_user_prefs.sql']) {
    await h.ok(`${m} runs again`, () => h.db.exec(readFileSync(join(here, '..', '..', 'supabase', 'migrations', m), 'utf8')));
  }
  h.eq('verified-name index exists', (await h.q(`select 1 from pg_indexes where indexname = 'profiles_verified_name_key_idx'`)).length, 1);
  for (const fn of ['profile_custom_guard', 'profile_impersonation_guard', 'verified_name_guard']) {
    h.eq(`${fn} patched`, (await h.one(`select position('verify_name_key' in pg_get_functiondef(('public.' || $1 || '()')::regprocedure)) > 0 ok`, [fn])).ok, true);
  }
  h.eq('no bare name_key left in the guards', (await h.one(`select bool_or(pg_get_functiondef(('public.' || f || '()')::regprocedure) ~ 'public\\.name_key\\((?!public\\.verify_name_key\\()') bad
    from unnest(array['profile_impersonation_guard', 'verified_name_guard']) f`)).bad, false);

  // --- 171 ---
  h.eq('@ prefix ignored', (await h.one(`select verify_name_key('@Kaiii_13') k`)).k, (await h.one(`select verify_name_key('kaiii_13') k`)).k);
  h.eq('bold maths letters fold', (await h.one(`select verify_name_key('𝐒𝐇𝐘') k`)).k, 'shy');
  h.eq('fraktur folds', (await h.one(`select verify_name_key('𝕽𝖆𝖕𝖍') k`)).k, 'raph');
  h.eq('accents fold', (await h.one(`select verify_name_key('Ünïcödé') k`)).k, 'unicode');

  const kai = await h.signup('kai@test.dev', 'kaiii_13');
  await h.as(kai);
  const proof = `${kai}/proof.png`;
  await h.ok('tiktok @handle with matching username', () => h.q(
    `select apply_verification('tiktok', '@Kaiii_13', 'https://www.tiktok.com/@kaiii_13', '', $1)`, [proof]));
  h.eq('handle stored without @', (await h.one(`select handle from verification_requests where user_id = $1`, [kai])).handle, 'Kaiii_13');

  const shy = await h.signup('shy@test.dev', 'third');
  await h.admin();
  await h.q(`update profiles set display_name = '𝐒𝐇𝐘' where id = $1`, [shy]);
  await h.as(shy);
  await h.ok('fancy display name matches plain handle', () => h.q(
    `select apply_verification('instagram', 'shy', 'https://instagram.com/shy', '', $1)`, [`${shy}/p.png`]));

  const other = await h.signup('o@test.dev', 'someone');
  await h.as(other);
  await h.fails('different name still refused', `select apply_verification('tiktok', 'famous', 'https://vm.tiktok.com/abc', '', $1)`, [`${other}/p.png`]);
  await h.fails('bare @ refused', `select apply_verification('tiktok', '@', 'https://tiktok.com/@x', '', $1)`, [`${other}/p.png`]);
  await h.admin();
  await h.q(`update profiles set username = 'famous' where id = $1`, [other]);
  await h.as(other);
  await h.ok('tiktok share link accepted', () => h.q(`select apply_verification('tiktok', 'famous', 'https://vm.tiktok.com/abc', '', $1)`, [`${other}/p.png`]));

  // --- 172 ---
  await h.as(kai);
  await h.q(`insert into user_prefs (user_id, prefs) values ($1, '{"theme":"light"}')`, [kai]);
  await h.q(`update user_prefs set prefs = '{"theme":"dark"}' where user_id = $1`, [kai]);
  h.eq('own prefs readable', (await h.one(`select prefs->>'theme' t from user_prefs`)).t, 'dark');
  await h.as(other);
  h.eq('others cannot see my prefs', (await h.q(`select * from user_prefs`)).length, 0);
  await h.fails('cannot write prefs for someone else', `insert into user_prefs (user_id, prefs) values ($1, '{}')`, [kai]);
  await h.q(`update user_prefs set prefs = '{"x":1}' where user_id = $1`, [kai]);
  await h.as(kai);
  h.eq('their update did nothing', (await h.one(`select prefs->>'theme' t from user_prefs`)).t, 'dark');
  await h.fails('prefs must be an object', `update user_prefs set prefs = '[1]' where user_id = $1`, [kai]);
  await h.fails('prefs over 4000 bytes refused', `update user_prefs set prefs = jsonb_build_object('x', repeat('a', 4100)) where user_id = $1`, [kai]);
  await h.admin();
  h.eq('172 checks exist once each', (await h.q(`select conname from pg_constraint where conrelid = 'public.user_prefs'::regclass and contype = 'c' order by 1`)).map((r) => r.conname), ['user_prefs_shape', 'user_prefs_size']);
  await h.as(kai);
  await h.as(null);
  await h.fails('anon cannot read', `select * from user_prefs`);
  // --- 171 review fixes ---
  const zed = await h.signup('zed@test.dev', 'zed');
  await h.as(zed);
  h.eq('CJK-only handle gets its own message', /Latin letters/.test(await msg(h, `select apply_verification('youtube', '小明', 'https://youtube.com/@xm', '', $1)`, [`${zed}/p.png`]) ?? ''), true);
  h.eq('hidden characters refused after the match', await msg(h, `select apply_verification('youtube', 'z' || chr(8203) || 'ed', 'https://youtube.com/@zed', '', $1)`, [`${zed}/p.png`]),
    'Use your channel name as it is spelled on the site');
  await h.admin();
  await h.q(`insert into verification_requests (user_id, platform, handle, link, status) values ($1, 'youtube', 'zed', 'x', 'needs_proof')`, [zed]);
  await h.as(zed);
  h.eq('needs_proof counts as open', /waiting for review/.test(await msg(h, `select apply_verification('youtube', 'zed', 'https://youtube.com/@zed', '', $1)`, [`${zed}/p.png`]) ?? ''), true);

  // Rename lock: badge stays while either name matches.
  await h.admin();
  await h.q(`update profiles set verified_as = 'tiktok · Kaiii_13', display_name = null where id = $1`, [kai]);
  await h.as(kai);
  await h.q(`update profiles set display_name = 'Bob' where id = $1`, [kai]);
  h.eq('display name changed, username still matches: badge kept', (await h.one(`select verified_as from profiles where id = $1`, [kai])).verified_as, 'tiktok · Kaiii_13');
  await h.q(`update profiles set display_name = '𝐊𝐚𝐢𝐢𝐢_13', username = 'bobby' where id = $1`, [kai]);
  h.eq('username changed, fancy display name still matches: badge kept', (await h.one(`select verified_as from profiles where id = $1`, [kai])).verified_as, 'tiktok · Kaiii_13');
  await h.q(`update profiles set display_name = 'Bob' where id = $1`, [kai]);
  h.eq('neither matches: badge goes', (await h.one(`select verified_as from profiles where id = $1`, [kai])).verified_as, null);

  // Impersonation: fancy letters and i/l swaps of a verified name are refused.
  await h.admin();
  await h.q(`update profiles set verified_as = 'youtube · Billie', username = 'billie' where id = $1`, [shy]);
  await h.as(zed);
  await h.fails('fancy copy of a verified name refused', `update profiles set display_name = '𝐁𝐢𝐥𝐥𝐢𝐞' where id = $1`, [zed]);
  await h.fails('i/l swap of a verified name still refused', `update profiles set display_name = 'BiIIie' where id = $1`, [zed]);
  await h.ok('an unrelated name is fine', () => h.q(`update profiles set display_name = 'Zed' where id = $1`, [zed]));
  // Only the changed name is checked: an account that already collides can still change the other name.
  const twin = await h.signup('twin@test.dev', 'twin');
  await h.admin();
  await h.q(`update profiles set display_name = 'Billie' where id = $1`, [twin]); // as postgres: no check (old collision)
  await h.as(twin);
  await h.ok('old collision does not block a username change', () => h.q(`update profiles set username = 'twin_two' where id = $1`, [twin]));
  await h.fails('but changing to another copy of it is refused', `update profiles set display_name = 'B1llie' where id = $1`, [twin]);

  // Sign-ups are checked whatever the role (the auth server inserts the profile).
  h.eq('signing up as a verified name is refused', /verified creator/.test((await h.signup('copy@test.dev', 'B1llie').then(() => '', (e) => e.message))), true);
  await h.ok('a normal sign-up still works', () => h.signup('normal@test.dev', 'just_a_person'));
  h.eq('normal sign-up made its profile', (await h.q(`select 1 from profiles where username = 'just_a_person'`)).length, 1);

  // name_of_verified: service role only, same folding, can leave out the bot's own row.
  await h.admin();
  await h.db.exec(`set role service_role`);
  h.eq('name_of_verified: fancy copy', (await h.one(`select name_of_verified('𝐁𝐢𝐥𝐥𝐢𝐞') v`)).v, true);
  h.eq('name_of_verified: i/l swap', (await h.one(`select name_of_verified('BiIIie') v`)).v, true);
  h.eq('name_of_verified: own row left out', (await h.one(`select name_of_verified('Billie', $1) v`, [shy])).v, false);
  h.eq('name_of_verified: other names', (await h.one(`select name_of_verified('robot_helper') v`)).v, false);
  await h.as(zed);
  await h.fails('users cannot call name_of_verified', `select name_of_verified('x')`);

  // Approving someone whose name is a brand: review_verification gets the guard's own message back.
  const fan = await h.signup('fan@test.dev', 'youtubefan');
  const rev = await h.signup('rev@test.dev', 'reviewer');
  await h.admin();
  await h.q(`insert into site_admins values ($1)`, [rev]);
  const rid = (await h.one(`insert into verification_requests (user_id, platform, handle, link) values ($1, 'youtube', 'fan', 'x') returning id`, [fan])).id;
  await h.as(rev);
  h.eq('review_verification raises the brand guard text', await msg(h, `select review_verification($1, true, '')`, [rid]),
    'Can\'t verify this account: its name is a brand or country, not the verified channel.');
}
