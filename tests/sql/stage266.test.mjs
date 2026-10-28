// 266: better bug reports. bug_reports was made by hand live, so the stand-in below is its live shape (Oct 18):
// columns, checks, policies and the insert limit trigger. Then 266 twice.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const STANDINS = `
create table if not exists public.feature_flags (key text primary key, label text not null, description text not null default '',
  mode text not null default 'off', servers uuid[] not null default '{}', users uuid[] not null default '{}');
create table if not exists public.site_bans (user_id uuid primary key);
alter table public.site_bans add column if not exists expires_at timestamptz;
create table if not exists public.staff (user_id uuid primary key);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid()) $$;
create or replace function public.is_site_banned(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.site_bans where user_id = uid and (expires_at is null or expires_at > now())) $$;
CREATE OR REPLACE FUNCTION public.feature_on_for_me(k text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select mode = 'everyone' or (mode = 'test' and (auth.uid() = any(users) or exists (select 1 from public.server_members m where m.user_id = auth.uid() and m.server_id = any(servers)))) from public.feature_flags where key = k), false);
$function$;
create table public.bug_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  title text not null constraint bug_reports_title_check check (char_length(title) between 5 and 120),
  body text not null constraint bug_reports_body_check check (char_length(body) between 20 and 4000),
  severity text not null default 'normal' constraint bug_reports_severity_check check (severity in ('low', 'normal', 'security')),
  status text not null default 'open' constraint bug_reports_status_check check (status in ('open', 'confirmed', 'fixed', 'duplicate', 'rejected')),
  staff_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  staff_pick boolean not null default false);
alter table public.bug_reports enable row level security;
create policy "file a bug" on public.bug_reports for insert to authenticated with check (user_id = auth.uid() and not public.is_site_banned(auth.uid()));
create policy "own bug reports; staff see all" on public.bug_reports for select to authenticated using (user_id = (select auth.uid()) or (select public.is_staff()));
create policy "staff update bugs" on public.bug_reports for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));
grant select, insert, update, delete on public.bug_reports to authenticated;
CREATE OR REPLACE FUNCTION public.bug_report_limit()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if (select count(*) from public.bug_reports where user_id = new.user_id and created_at > now() - interval '1 day') >= 5 then raise exception 'You can file 5 bug reports a day'; end if;
  if auth.uid() is not null and not public.is_staff() then
    new.status := 'open';
    new.staff_pick := false;
    new.staff_note := '';
  end if;
  return new;
end; $function$;
create trigger bug_reports_limit before insert on public.bug_reports for each row execute function public.bug_report_limit();
insert into storage.buckets (id, name) values ('proofs', 'proofs') on conflict do nothing;
alter table storage.objects add column if not exists metadata jsonb;
`;

export default async function (h) {
  const failsWith = async (name, re, sql, params = []) => {
    let msg = null;
    try { await h.db.query(sql, params); } catch (e) { msg = e.message; }
    h.eq(name, msg !== null && re.test(msg) ? 'refused' : msg, 'refused');
  };
  await h.admin();
  await h.db.exec(STANDINS);
  const MIG = mig('266_bug_report_edit.sql');
  await h.db.exec(MIG);
  await h.ok('266 re-runs cleanly', () => h.db.exec(MIG));

  const miku = await h.signup('miku@test.dev', 'miku');
  const rin = await h.signup('rin@test.dev', 'rin');
  const mod = await h.signup('mod@test.dev', 'mod');
  await h.admin();
  await h.q(`insert into staff values ($1)`, [mod]);
  const img = (u, n) => `${u}/1760000000000-${n}.png`;
  for (const p of [img(miku, 'a'), img(miku, 'b'), img(miku, 'c'), img(miku, 'd'), img(miku, 'e'), img(rin, 'x')]) {
    await h.q(`insert into storage.objects (bucket_id, name, metadata) values ('proofs', $1, '{"mimetype": "image/png"}')`, [p]);
  }
  await h.q(`insert into storage.objects (bucket_id, name, metadata) values ('proofs', $1, '{"mimetype": "text/html"}')`, [img(miku, 'html')]);
  const body = 'The page goes blank when I click a role.';

  // Flag off: no screenshots, no edit/delete.
  await h.as(miku);
  await failsWith('flag off: screenshots refused', /aren't available/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Blank page', $1, array[$2])`, [body, img(miku, 'a')]);
  const r0 = (await h.one(`insert into bug_reports (user_id, title, body) values (auth.uid(), 'Blank page', $1) returning id`, [body])).id;
  await failsWith('flag off: edit refused', /isn't available/, `select edit_bug_report($1, 'Blank page!', $2, 'normal', '{}')`, [r0, body]);
  await failsWith('flag off: delete refused', /isn't available/, `select withdraw_bug_report($1)`, [r0]);

  await h.admin();
  await h.q(`update feature_flags set users = array[$1, $2]::uuid[] where key = 'bug_report_edit'`, [miku, rin]);
  h.eq('flag row is test only', (await h.one(`select mode from feature_flags where key = 'bug_report_edit'`)).mode, 'test');

  await h.as(miku);
  const r1 = (await h.one(`insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Role click', $1, array[$2, $3]) returning id`, [body, img(miku, 'a'), img(miku, 'b')])).id;
  h.eq('screenshots saved', (await h.one(`select cardinality(images) n from bug_reports where id = $1`, [r1])).n, 2);
  await failsWith('someone else\'s screenshot refused', /didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Steal', $1, array[$2])`, [body, img(rin, 'x')]);
  await failsWith('a file that isn\'t there refused', /didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Ghost', $1, array[$2])`, [body, img(miku, 'zzz')]);
  await failsWith('5 screenshots refused', /images_check|didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Many', $1, array[$2, $3, $4, $5, $6])`,
    [body, img(miku, 'a'), img(miku, 'b'), img(miku, 'c'), img(miku, 'd'), img(miku, 'e')]);
  await failsWith('a page dressed up as a .png refused', /didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Html', $1, array[$2])`, [body, img(miku, 'html')]);
  const dated = (await h.one(`insert into bug_reports (user_id, title, body, created_at) values (auth.uid(), 'Old date', $1, '2000-01-01') returning created_at > now() - interval '1 minute' ok`, [body])).ok;
  h.eq('the app can\'t backdate a report', dated, true);
  await failsWith('same screenshot twice refused', /didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Twice', $1, array[$2, $2])`, [body, img(miku, 'a')]);
  await failsWith('a path outside my folder refused', /didn't upload right/, `insert into bug_reports (user_id, title, body, images) values (auth.uid(), 'Path', $1, array[$2])`, [body, `${miku}/../${rin}/x.png`]);

  // Edit while open.
  await h.ok('edit my open report', () => h.q(`select edit_bug_report($1, 'Role click crash', $2, 'security', array[$3])`, [r1, `${body} Steps: open a profile.`, img(miku, 'c')]));
  const e1 = await h.one(`select title, severity, images, edited_at is not null edited, status from bug_reports where id = $1`, [r1]);
  h.eq('edit saved', [e1.title, e1.severity, e1.images, e1.edited, e1.status], ['Role click crash', 'security', [img(miku, 'c')], true, 'open']);
  await failsWith('edit can\'t sneak in someone else\'s screenshot', /didn't upload right/, `select edit_bug_report($1, 'Role click crash', $2, 'normal', array[$3])`, [r1, body, img(rin, 'x')]);
  await failsWith('edit still checks the length rules', /title_check/, `select edit_bug_report($1, 'x', $2, 'normal', '{}')`, [r1, body]);
  await failsWith('edit can\'t pick a made-up severity', /severity_check/, `select edit_bug_report($1, 'Role click crash', $2, 'urgent', '{}')`, [r1, body]);
  await h.as(rin);
  await failsWith('someone else can\'t edit it', /isn't yours/, `select edit_bug_report($1, 'Mine now', $2, 'normal', '{}')`, [r1, body]);
  await failsWith('someone else can\'t delete it', /only delete your own/, `select withdraw_bug_report($1)`, [r1]);
  const before = (await h.one(`select count(*)::int n from bug_reports where id = $1`, [r1])).n;
  h.eq('rin can\'t even see it', before, 0);
  await h.as(miku);
  await h.q(`update bug_reports set status = 'fixed', staff_note = 'self' where id = $1`, [r1]);
  h.eq('reporter still can\'t change status directly (RLS)', (await h.one(`select status from bug_reports where id = $1`, [r1])).status, 'open');

  // Staff picked it (still open): locked too.
  const rp = (await h.one(`insert into bug_reports (user_id, title, body) values (auth.uid(), 'Picked one', $1) returning id`, [body])).id;
  await h.as(mod);
  await h.q(`update bug_reports set staff_pick = true where id = $1`, [rp]);
  await h.as(miku);
  await failsWith('picked by staff: no edits', /already answered/, `select edit_bug_report($1, 'Picked one!', $2, 'normal', '{}')`, [rp, body]);
  await failsWith('picked by staff: can\'t delete', /only delete your own/, `select withdraw_bug_report($1)`, [rp]);
  // After staff answer: locked.
  await h.as(mod);
  await h.q(`update bug_reports set status = 'duplicate', staff_note = 'Same as another' where id = $1`, [r1]);
  await h.as(miku);
  await failsWith('answered: no more edits', /already answered/, `select edit_bug_report($1, 'Role click crash 2', $2, 'normal', '{}')`, [r1, body]);
  await failsWith('answered: can\'t delete', /only delete your own/, `select withdraw_bug_report($1)`, [r1]);

  // Delete (withdraw) while open; it still counts towards the daily limit.
  await h.ok('delete my open report', () => h.q(`select withdraw_bug_report($1)`, [r0]));
  h.eq('withdrawn', (await h.one(`select status from bug_reports where id = $1`, [r0])).status, 'withdrawn');
  await failsWith('can\'t withdraw twice', /only delete your own/, `select withdraw_bug_report($1)`, [r0]);
  await failsWith('can\'t edit a withdrawn one', /already answered/, `select edit_bug_report($1, 'Back again', $2, 'normal', '{}')`, [r0, body]);
  await h.q(`insert into bug_reports (user_id, title, body) values (auth.uid(), $1, $2)`, [`Bug number five`, body]);
  await failsWith('withdrawn ones still count for 5 a day', /5 bug reports a day/, `insert into bug_reports (user_id, title, body) values (auth.uid(), 'One more bug', $1)`, [body]);

  // Banned reporters can't edit.
  await h.admin();
  const r2 = (await h.one(`insert into bug_reports (user_id, title, body) values ($1, 'Rin bug report', $2) returning id`, [rin, body])).id;
  await h.q(`insert into site_bans (user_id) values ($1)`, [rin]);
  await h.as(rin);
  await failsWith('banned: no edits', /banned/, `select edit_bug_report($1, 'Rin bug report 2', $2, 'normal', '{}')`, [r2, body]);
  await h.as(null);
  await failsWith('signed out: no edits', /permission denied|Sign in/, `select edit_bug_report($1, 'x', $2, 'normal', '{}')`, [r2, body]);
}
