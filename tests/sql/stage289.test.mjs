// 289 developer role. PGlite can't replay migrations 025+, so this starts from stage 24 and adds stand-ins for what the
// migration touches: the staff helpers (is_site_mod / is_staff), bans, mod_log, bug_reports and suggestions with their live
// policies and grants, the live bug_hunter_on_fix and suggestion_votes functions, and the proofs bucket.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '289_developer_role.sql'), 'utf8');
const BADGE = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '290_developer_badge.sql'), 'utf8');

export const base = 24;

// The live bug_hunter_on_fix text (migration 204), kept apart so the "line moved" check can put it back.
const HUNTER = `
create or replace function public.bug_hunter_on_fix()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.status <> 'fixed' or old.status = 'fixed' then return new; end if;
  if auth.uid() is not null and (not public.is_staff() or (new.user_id = auth.uid() and not public.is_site_admin())) then
    return new;
  end if;
  if exists (select 1 from public.site_bans b where b.user_id = new.user_id and (b.expires_at is null or b.expires_at > now())) then
    return new;
  end if;
  begin
    update public.profiles p set badges = array(select distinct unnest(coalesce(p.badges, '{}'::text[]) || 'bug_hunter'::text))
     where p.id = new.user_id and not ('bug_hunter' = any(coalesce(p.badges, '{}'::text[])));
    if found then
      insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'badge_auto', new.user_id, 'bug_hunter (report fixed)');
    end if;
  exception when others then
    raise warning 'bug_hunter_on_fix: % (report %)', sqlerrm, new.id;
  end;
  return new;
end $function$;
revoke all on function public.bug_hunter_on_fix() from public, anon, authenticated;
`;

const STANDINS = `
alter table public.site_bans add column if not exists expires_at timestamptz;
alter table public.profiles add column if not exists badges text[];
alter table public.profiles add column if not exists shown_badge text;
create table if not exists public.mod_log (actor uuid, action text, target_id uuid, reason text);
create table if not exists public.site_moderators (user_id uuid primary key, suspended_at timestamptz);
create or replace function public.is_site_mod() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_moderators where user_id = auth.uid() and suspended_at is null) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select public.is_site_admin() or public.is_site_mod() $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
revoke all on function public.is_site_banned(uuid) from public, anon, authenticated;

create table public.bug_reports (id uuid primary key default gen_random_uuid(), user_id uuid not null, title text, status text not null default 'open',
  staff_note text not null default '', images text[], staff_pick boolean not null default false, updated_at timestamptz);
alter table public.bug_reports enable row level security;
-- Live, bug_reports was made by hand and UPDATE is granted on the whole table to anon and authenticated (checked with
-- information_schema.table_privileges). The migration has to narrow that.
grant select, insert, update on public.bug_reports to anon, authenticated;
create policy "own bug reports; staff see all" on public.bug_reports for select to authenticated using (user_id = (select auth.uid()) or (select public.is_staff()));
create policy "staff update bugs" on public.bug_reports for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));
create policy "file a bug" on public.bug_reports for insert to authenticated with check (user_id = (select auth.uid()));

create table public.suggestions (id uuid primary key default gen_random_uuid(), user_id uuid not null, message_id uuid, title text,
  status text not null default 'open', staff_note text not null default '', updated_at timestamptz);
alter table public.suggestions enable row level security;
revoke all on public.suggestions from anon, authenticated;
grant select on public.suggestions to authenticated;
grant update (status, staff_note, updated_at) on public.suggestions to authenticated;
create policy "suggestions: read own or staff" on public.suggestions for select to authenticated using (user_id = (select auth.uid()) or (select public.is_staff()));
create policy "suggestions: staff update" on public.suggestions for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));

-- reactions already exists (009); the votes function only reads message_id and emoji, so loosen the foreign keys here.
alter table public.reactions drop constraint if exists reactions_message_id_fkey;
alter table public.reactions drop constraint if exists reactions_user_id_fkey;
create or replace function public.suggestion_votes(ids uuid[])
returns table (message_id uuid, up int, down int, total int) language sql stable security definer set search_path = public as $$
  select r.message_id,
         count(*) filter (where r.emoji in ('👍', '⬆️', '✅'))::int,
         count(*) filter (where r.emoji in ('👎', '⬇️', '❌'))::int,
         count(*)::int
  from public.reactions r
  where public.is_staff() and r.message_id = any(ids[1:500])
  group by r.message_id;
$$;
revoke all on function public.suggestion_votes(uuid[]) from public, anon;
grant execute on function public.suggestion_votes(uuid[]) to authenticated;

create table if not exists public.feature_flags (key text primary key, label text, description text, mode text not null default 'off',
  servers uuid[] not null default '{}', users uuid[] not null default '{}');
insert into storage.buckets (id, name) values ('proofs', 'proofs') on conflict do nothing;
${HUNTER}
create trigger bug_reports_bug_hunter after update of status on public.bug_reports
  for each row when (new.status = 'fixed' and old.status is distinct from 'fixed') execute function public.bug_hunter_on_fix();
`;

export default async function (h) {
  await h.db.exec(STANDINS);

  const admin = await h.signup('admin289@example.com', 'admin289');
  const dev = await h.signup('dev289@example.com', 'dev289');       // the developer
  const mod = await h.signup('mod289@example.com', 'mod289');       // a moderator
  const rep = await h.signup('rep289@example.com', 'rep289');       // files bug reports and suggestions
  const other = await h.signup('other289@example.com', 'other289'); // a plain account
  const banned = await h.signup('banned289@example.com', 'banned289');
  await h.admin();
  await h.q(`insert into site_admins (user_id) values ($1)`, [admin]);
  await h.q(`insert into site_moderators (user_id) values ($1)`, [mod]);

  // Existing data the role will read: reports (one with a screenshot), suggestions, a verification proof in the same bucket.
  const bugOf = async (uid, title, images = null) => (await h.one(`insert into bug_reports (user_id, title, images) values ($1, $2, $3) returning id`, [uid, title, images])).id;
  const b1 = await bugOf(rep, 'rep bug 1', [`${rep}/shot1.png`]);
  const b2 = await bugOf(rep, 'rep bug 2');
  const b3 = await bugOf(other, 'other bug');
  const sg1 = (await h.one(`insert into suggestions (user_id, message_id, title) values ($1, gen_random_uuid(), 'idea') returning id, message_id`, [rep]));
  await h.q(`insert into suggestions (user_id, title) values ($1, 'idea 2')`, [other]);
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, gen_random_uuid(), '👍'), ($1, gen_random_uuid(), '👍'), ($1, gen_random_uuid(), '👎')`, [sg1.message_id]);
  await h.q(`insert into storage.objects (bucket_id, name) values ('proofs', $1), ('proofs', $2)`, [`${rep}/shot1.png`, `${rep}/verification-id.png`]);

  // Owner and ACL of the two functions the migration rewrites; they must come out exactly as they went in.
  const aclOf = async () => await h.q(`select proname, proowner::regrole::text owner, proacl::text acl from pg_proc
    where pronamespace = 'public'::regnamespace and proname in ('bug_hunter_on_fix', 'suggestion_votes') order by proname`);
  const aclBefore = await aclOf();
  h.eq('before: the table-wide UPDATE grant is there (this is what the live table has)',
    (await h.one(`select has_table_privilege('authenticated', 'public.bug_reports', 'update') r`)).r, true);

  // Before the migration, a developer sees nothing: it does not exist yet.
  await h.db.exec(MIGRATION);
  await h.ok('289 re-runs cleanly', () => h.db.exec(MIGRATION));

  // ---- the role: admins give and take it away ----
  const call = async (who, sql, params = []) => {
    await h.as(who);
    try { await h.q(sql, params); return 'ok'; } catch (e) { return e.message; } finally { await h.admin(); }
  };
  h.eq('a plain account can not give the role', await call(other, `select admin_set_developer($1, true)`, [other]), 'Admins only');
  h.eq('a moderator can not give the role', await call(mod, `select admin_set_developer($1, true)`, [dev]), 'Admins only');
  h.eq('nobody is a developer yet', (await h.one(`select count(*)::int n from site_developers`)).n, 0);
  h.eq('an admin can not give it to an admin', await call(admin, `select admin_set_developer($1, true)`, [admin]), "Admins don't need the role");
  await h.q(`insert into site_bans (user_id, reason, banned_by) values ($1, 'test', $2)`, [banned, admin]);
  h.eq('...nor to a banned account', await call(admin, `select admin_set_developer($1, true)`, [banned]), 'That account is banned');
  h.eq('an admin gives the role', await call(admin, `select admin_set_developer($1, true, 'works on the code')`, [dev]), 'ok');
  h.eq('...twice is fine', await call(admin, `select admin_set_developer($1, true)`, [dev]), 'ok');
  h.eq('one row, added by the admin', await h.q(`select user_id, added_by from site_developers`), [{ user_id: dev, added_by: admin }]);
  h.eq('the grant is logged with the note', (await h.one(`select reason from mod_log where action = 'dev_added' order by reason desc limit 1`)).reason, 'works on the code');
  h.eq('...and only once, the second call changed nothing', (await h.one(`select count(*)::int n from mod_log where action = 'dev_added' and target_id = $1`, [dev])).n, 1);

  const isDev = async (who) => { await h.as(who); const r = (await h.one(`select is_site_dev() d, is_staff() s, is_site_mod() m`)); await h.admin(); return r; };
  h.eq('the developer is a developer and not staff or a moderator', await isDev(dev), { d: true, s: false, m: false });
  h.eq('a moderator is not a developer', (await isDev(mod)).d, false);
  h.eq('an admin is not a developer', (await isDev(admin)).d, false);
  h.eq('a plain account is not a developer', (await isDev(other)).d, false);

  // ---- who can read the role table ----
  const devRows = async (who) => { await h.as(who); const r = await h.q(`select user_id from site_developers`); await h.admin(); return r.map((x) => x.user_id); };
  h.eq('an admin sees the developers', await devRows(admin), [dev]);
  h.eq('a developer sees only their own row', await devRows(dev), [dev]);
  h.eq('a plain account sees nobody', await devRows(other), []);
  h.eq('a moderator sees nobody', await devRows(mod), []);
  h.eq('a signed-in account can not write the table directly', await call(other, `insert into site_developers (user_id) values ($1)`, [other]).then((m) => /permission denied/i.test(m)), true);
  h.eq('...nor change it', await call(dev, `update site_developers set added_by = null`).then((m) => /permission denied/i.test(m)), true);

  // ---- bug reports ----
  const bugs = async (who) => { await h.as(who); const r = await h.q(`select title from bug_reports order by title`); await h.admin(); return r.map((x) => x.title); };
  h.eq('the developer reads every bug report', await bugs(dev), ['other bug', 'rep bug 1', 'rep bug 2']);
  h.eq('a moderator still reads every bug report', (await bugs(mod)).length, 3);
  h.eq('a reporter still sees only their own', await bugs(rep), ['rep bug 1', 'rep bug 2']);
  h.eq('a plain account sees only their own', await bugs(other), ['other bug']);
  h.eq('anon sees none', await bugs(null).catch(() => []), []);
  const upd = async (who, sql, params) => { await h.as(who); try { return (await h.q(sql, params)).length; } catch (e) { return e.message; } finally { await h.admin(); } };
  h.eq('the developer can change status and note', await upd(dev, `update bug_reports set status = 'confirmed', staff_note = 'on it' where id = $1 returning id`, [b2]), 1);
  h.eq('...it stuck', (await h.one(`select status, staff_note from bug_reports where id = $1`, [b2])), { status: 'confirmed', staff_note: 'on it' });
  h.eq('a plain account changes nothing (not even their own)', await upd(other, `update bug_reports set status = 'fixed' where id = $1 returning id`, [b3]), 0);
  h.eq('a reporter changes nothing of someone elses', await upd(rep, `update bug_reports set status = 'fixed' where id = $1 returning id`, [b3]), 0);
  h.eq('the developer can pin a report and stamp the time (the other two columns the app writes)', await upd(dev, `update bug_reports set staff_pick = true, updated_at = now() where id = $1 returning id`, [b2]), 1);

  // Only four columns can be updated at all. Without this a developer could move a report to someone else and mark it
  // fixed, which hands that person Bug Hunter.
  const col = async (role, c) => (await h.one(`select has_column_privilege($1, 'public.bug_reports', $2, 'update') r`, [role, c])).r;
  for (const c of ['status', 'staff_note', 'staff_pick', 'updated_at']) h.eq(`authenticated can update ${c}`, await col('authenticated', c), true);
  for (const c of ['user_id', 'title', 'images', 'id']) h.eq(`authenticated can not update ${c}`, await col('authenticated', c), false);
  h.eq('anon can not update anything on the table', (await h.one(`select has_table_privilege('anon', 'public.bug_reports', 'update') r`)).r, false);
  const moved = await upd(dev, `update bug_reports set user_id = $1 where id = $2 returning id`, [other, b2]);
  h.eq('a developer can not move a report to another account', /permission denied/i.test(moved), true);
  h.eq('...a moderator can not either', /permission denied/i.test(await upd(mod, `update bug_reports set user_id = $1 where id = $2 returning id`, [other, b2])), true);
  h.eq('...and can not rewrite the text', /permission denied/i.test(await upd(dev, `update bug_reports set title = 'x', images = null where id = $1 returning id`, [b2])), true);
  h.eq('...the report still belongs to the reporter', (await h.one(`select user_id from bug_reports where id = $1`, [b2])).user_id, rep);

  // ---- Bug Hunter ----
  const badges = async (uid) => (await h.one(`select coalesce(badges, '{}') b from profiles where id = $1`, [uid])).b;
  await upd(dev, `update bug_reports set status = 'fixed' where id = $1`, [b1]);
  h.eq('a developer marking a report fixed gives the reporter Bug Hunter', await badges(rep), ['bug_hunter']);
  h.eq('...and it is logged against the developer', (await h.one(`select actor from mod_log where action = 'badge_auto' and target_id = $1`, [rep])).actor, dev);
  const devOwn = await bugOf(dev, 'dev own bug');
  await upd(dev, `update bug_reports set status = 'fixed' where id = $1`, [devOwn]);
  h.eq('a developer can not award themselves by marking their own report fixed', await badges(dev), []);
  const b4 = await bugOf(other, 'other bug 2');
  await upd(mod, `update bug_reports set status = 'fixed' where id = $1`, [b4]);
  h.eq('a moderator marking a report fixed still gives the badge', await badges(other), ['bug_hunter']);

  // ---- suggestions ----
  const sgs = async (who) => { await h.as(who); const r = await h.q(`select title from suggestions order by title`); await h.admin(); return r.map((x) => x.title); };
  h.eq('the developer reads every suggestion', await sgs(dev), ['idea', 'idea 2']);
  h.eq('a plain account sees only their own', await sgs(other), ['idea 2']);
  h.eq('the developer can answer a suggestion', await upd(dev, `update suggestions set status = 'planned', staff_note = 'soon', updated_at = now() where id = $1 returning id`, [sg1.id]), 1);
  h.eq('...but not change what it says (column grants are unchanged)', /permission denied/i.test(await upd(dev, `update suggestions set title = 'x' where id = $1 returning id`, [sg1.id])), true);
  h.eq('a plain account answers nothing', await upd(other, `update suggestions set status = 'planned' where id = $1 returning id`, [sg1.id]), 0);
  const votes = async (who) => { await h.as(who); const r = await h.q(`select up, down, total from suggestion_votes(array[$1::uuid])`, [sg1.message_id]); await h.admin(); return r; };
  h.eq('the developer gets the vote counts', await votes(dev), [{ up: 2, down: 1, total: 3 }]);
  h.eq('a moderator still gets them', await votes(mod), [{ up: 2, down: 1, total: 3 }]);
  h.eq('a plain account gets nothing', await votes(other), []);
  // Counts only for real suggestion posts: a reaction count on any other message (a DM, a private channel) is not
  // something staff or a developer can read through this function.
  const notASuggestion = (await h.one(`select gen_random_uuid() id`)).id;
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, gen_random_uuid(), '👍'), ($1, gen_random_uuid(), '👍')`, [notASuggestion]);
  const votesFor = async (who, ids) => { await h.as(who); const r = await h.q(`select message_id, total from suggestion_votes($1::uuid[])`, [ids]); await h.admin(); return r; };
  h.eq('the developer gets nothing for a message that is not a suggestion', await votesFor(dev, [notASuggestion]), []);
  h.eq('...a moderator neither', await votesFor(mod, [notASuggestion]), []);
  h.eq('...a mixed list returns only the suggestion', (await votesFor(dev, [notASuggestion, sg1.message_id])).map((r) => r.message_id), [sg1.message_id]);

  // ---- bug screenshots in the proofs bucket ----
  const files = async (who) => { await h.as(who); const r = await h.q(`select name from storage.objects where bucket_id = 'proofs' order by name`); await h.admin(); return r.map((x) => x.name); };
  h.eq('the developer opens a screenshot attached to a bug report', await files(dev), [`${rep}/shot1.png`]);
  h.eq('...but not the other proofs in the bucket', (await files(dev)).includes(`${rep}/verification-id.png`), false);
  h.eq('a plain account gets nothing from this policy', await files(other), []);
  h.eq('a moderator gets nothing from this policy (they have their own)', await files(mod), []);
  const probe = async (who, path) => { await h.as(who); const r = (await h.one(`select dev_can_see_bug_image($1) r`, [path])).r; await h.admin(); return r; };
  h.eq('the helper tells a plain account nothing about attachments', await probe(other, `${rep}/shot1.png`), false);
  h.eq('the helper says yes to the developer for an attached file', await probe(dev, `${rep}/shot1.png`), true);
  h.eq('...and no for one that is not attached', await probe(dev, `${rep}/verification-id.png`), false);

  // ---- a ban takes the role away while it lasts ----
  await h.q(`insert into site_developers (user_id, added_by) values ($1, $2)`, [banned, admin]);
  h.eq('a banned developer is not a developer', (await isDev(banned)).d, false);
  h.eq('...and reads only their own reports', await bugs(banned), []);
  await h.q(`delete from site_bans where user_id = $1`, [banned]);
  h.eq('the role is back once the ban is gone', (await isDev(banned)).d, true);
  await h.q(`delete from site_developers where user_id = $1`, [banned]);

  // ---- taking it away ----
  h.eq('a moderator can not take it away', await call(mod, `select admin_set_developer($1, false)`, [dev]), 'Admins only');
  h.eq('the developer can not take it away', await call(dev, `select admin_set_developer($1, false)`, [dev]), 'Admins only');
  h.eq('an admin takes it away', await call(admin, `select admin_set_developer($1, false, 'left the team')`, [dev]), 'ok');
  h.eq('...and the developer is back to a plain account (sees only their own report)', await bugs(dev), ['dev own bug']);
  h.eq('...no suggestions either', await sgs(dev), []);
  h.eq('...and no screenshots', await files(dev), []);
  h.eq('taking it away is logged', (await h.one(`select reason from mod_log where action = 'dev_removed'`)).reason, 'left the team');
  h.eq('taking it away from someone without it is fine', await call(admin, `select admin_set_developer($1, false)`, [other]), 'ok');
  h.eq('...and logs nothing, since nothing changed', (await h.one(`select count(*)::int n from mod_log where action = 'dev_removed' and target_id = $1`, [other])).n, 0);
  await h.q(`insert into site_developers (user_id, added_by) values ($1, $2) on conflict do nothing`, [dev, admin]);

  // ---- ACLs ----
  const canRun = async (role, fn) => (await h.one(`select has_function_privilege($1, $2, 'execute') r`, [role, fn])).r;
  for (const fn of ['public.is_site_dev()', 'public.admin_set_developer(uuid, boolean, text)', 'public.dev_can_see_bug_image(text)']) {
    h.eq(`signed-in accounts can run ${fn}`, await canRun('authenticated', fn), true);
    h.eq(`anon can not run ${fn}`, await canRun('anon', fn), false);
  }
  h.eq('anon can not read the role table', (await h.one(`select has_table_privilege('anon', 'public.site_developers', 'select') r`)).r, false);
  h.eq('the two rewritten functions keep their owner and who can run them', await aclOf(), aclBefore);
  h.eq('bug_hunter_on_fix still can not be called by a signed-in account', await canRun('authenticated', 'public.bug_hunter_on_fix()'), false);
  h.eq('...nor by anon', await canRun('anon', 'public.bug_hunter_on_fix()'), false);

  // ---- it stops loudly instead of leaving the role half set up ----
  // (exec runs the whole file as one implicit transaction, so a failure leaves nothing half done)
  const runs = async (sql) => { try { await h.db.exec(sql); return 'ok'; } catch (e) { return e.message; } };
  await h.db.exec(`alter policy "staff update bugs" on public.bug_reports rename to "staff update bugs x"`);
  h.eq('a missing policy stops the migration', (await runs(MIGRATION)).startsWith('289: one of the bug_reports / suggestions policies is missing'), true);
  await h.db.exec(`alter policy "staff update bugs x" on public.bug_reports rename to "staff update bugs"`);
  // A policy with the right name but a different command (FOR ALL) must not be widened silently either.
  await h.db.exec(`drop policy "staff update bugs" on public.bug_reports;
    create policy "staff update bugs" on public.bug_reports for all to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));`);
  h.eq('a policy that became FOR ALL stops the migration', (await runs(MIGRATION)).startsWith('289: one of the bug_reports / suggestions policies is missing or changed'), true);
  await h.db.exec(`drop policy "staff update bugs" on public.bug_reports;
    create policy "staff update bugs" on public.bug_reports for update to authenticated using ((select public.is_staff()) or (select public.is_site_dev())) with check ((select public.is_staff()) or (select public.is_site_dev()));`);
  await h.db.exec(`create or replace function public.bug_hunter_on_fix() returns trigger language plpgsql as $$ begin return new; end $$;`);
  h.eq('a rewritten bug_hunter_on_fix (line not found) stops the migration', (await runs(MIGRATION)).startsWith('289: bug_hunter_on_fix changed'), true);
  await h.db.exec(HUNTER);
  await h.ok('...and it runs again once the function is back', () => h.db.exec(MIGRATION));
  h.eq('the patch is in the function', (await h.one(`select position('is_site_dev()' in pg_get_functiondef('public.bug_hunter_on_fix()'::regprocedure)) > 0 p`)).p, true);
  h.eq('the vote function has the patch too', (await h.one(`select position('is_site_dev()' in pg_get_functiondef('public.suggestion_votes(uuid[])'::regprocedure)) > 0 p`)).p, true);

  // ---- the flag ----
  const flag = await h.one(`select mode, users from feature_flags where key = 'developer_role'`);
  h.eq('the flag is in test mode', flag.mode, 'test');
  h.eq('...for the owner and Minecraft', flag.users.length, 2);

  // ---- 290: the Developer badge comes and goes with the role ----
  await h.db.exec(`create or replace function public.mod_guard(a text, uid uuid, x text) returns void language sql as $$ select $$;`);
  h.eq('before 290, the current developer has no badge', (await badges(dev)).includes('developer'), false);
  await h.db.exec(BADGE);
  await h.ok('290 re-runs cleanly', () => h.db.exec(BADGE));
  h.eq('290 gives everyone with the role the badge', (await badges(dev)).includes('developer'), true);
  h.eq('...once', (await badges(dev)).filter((b) => b === 'developer').length, 1);
  h.eq('...and nobody else', (await badges(other)).includes('developer'), false);
  await h.q(`update profiles set shown_badge = 'developer' where id = $1`, [dev]);
  h.eq('taking the role away takes the badge off', await call(admin, `select admin_set_developer($1, false)`, [dev]), 'ok');
  h.eq('...and clears it as their shown badge', (await h.one(`select shown_badge from profiles where id = $1`, [dev])).shown_badge, null);
  h.eq('...gone', (await badges(dev)).includes('developer'), false);
  h.eq('giving the role gives the badge', await call(admin, `select admin_set_developer($1, true)`, [dev]), 'ok');
  h.eq('...there', (await badges(dev)).includes('developer'), true);
  h.eq('an admin can hand it out by hand', await call(admin, `select admin_set_badge($1, 'developer', true)`, [other]), 'ok');
  h.eq('...there', (await badges(other)).includes('developer'), true);
  h.eq('a moderator can not', await call(mod, `select admin_set_badge($1, 'developer', true)`, [rep]), 'Admins only');
  h.eq('...nor the developer themself', await call(dev, `select admin_set_badge($1, 'developer', true)`, [rep]), 'Admins only');
  h.eq('a moderator can still give Bug Hunter', await call(mod, `select admin_set_badge($1, 'bug_hunter', true)`, [other]), 'ok');
  h.eq('unknown badges are still refused', await call(admin, `select admin_set_badge($1, 'god', true)`, [other]), 'Unknown badge');
  h.eq('anon can not run admin_set_badge', await canRun('anon', 'public.admin_set_badge(uuid, text, boolean)'), false);
  h.eq('anon still can not run admin_set_developer', await canRun('anon', 'public.admin_set_developer(uuid, boolean, text)'), false);
}
