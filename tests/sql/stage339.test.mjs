// 339: leaving a server clears the member's onboarding answers (so they are asked again on return), and an answer's
// emoji may be a custom emoji token. Starts like stage 251 (stage 24 + flags + stand-ins), plus 105 (first joins).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql', '041_flag_users.sql', '105_first_joins.sql'];
const mig = (n) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', n), 'utf8');

const STANDINS = `
alter table public.roles add column if not exists perms jsonb not null default '{}';
alter table public.roles add column if not exists auto text not null default 'none';
alter table public.roles add column if not exists manage_server boolean not null default false;
alter table public.roles add column if not exists manage_messages boolean not null default false;
create table if not exists public.channel_overrides (id uuid primary key default gen_random_uuid(), server_id uuid, channel_id uuid,
  role_id uuid, allow text[] not null default '{}', deny text[] not null default '{}');
create table if not exists public.server_bots (server_id uuid, bot text, config jsonb, enabled boolean default true);
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
    or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
               where mr.server_id = sid and mr.user_id = auth.uid()
                 and (coalesce((r.perms ->> perm)::boolean, false) or coalesce((r.perms ->> 'administrator')::boolean, false)));
$$;
create or replace function public.my_top_role_position(sid uuid) returns integer language sql stable security definer set search_path = public as $$
  select coalesce(max(r.position), -1) from public.member_roles mr join public.roles r on r.id = mr.role_id
  where mr.server_id = sid and mr.user_id = auth.uid();
$$;
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  const owner = await h.signup('o@x.com', 'owner');
  const kid = await h.signup('k@x.com', 'kid');
  const kid2 = await h.signup('k2@x.com', 'kid2');
  const kid3 = await h.signup('k3@x.com', 'kid3');
  const both = await h.signup('b@x.com', 'both');
  await h.admin();
  const S = (await h.one(`insert into servers (name, owner_id) values ('Test', $1) returning id`, [owner])).id;
  const T = (await h.one(`insert into servers (name, owner_id) values ('Other', $1) returning id`, [owner])).id;
  await h.q(`insert into server_members (server_id, user_id, joined_at) values ($1, $2, now() - interval '1 day')`, [S, owner]);
  await h.db.exec(mig('251_server_onboarding.sql'));
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'server_onboarding'`, [S]);
  await h.as(owner);
  await h.q(`select save_onboarding($1, $2::jsonb)`, [S, JSON.stringify({ enabled: true, required: false, questions: [
    { title: 'Pick one', multi: false, answers: [{ label: 'A', emoji: '🎮', role_ids: [] }, { label: 'B', role_ids: [] }] }] })]);
  await h.admin();
  await h.q(`update server_onboarding set enabled_at = now() - interval '10 minutes' where server_id = $1`, [S]);

  const join = (uid, sid = S) => h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [sid, uid]);
  const needed = async (uid) => { await h.as(uid); const r = (await h.one(`select get_onboarding($1) g`, [S])).g.needed; await h.admin(); return r; };
  const finish = async (uid) => {
    await h.as(uid);
    const g = (await h.one(`select get_onboarding($1) g`, [S])).g;
    await h.q(`select complete_onboarding($1, $2::uuid[])`, [S, [g.questions[0].answers[0].id]]);
    await h.admin();
  };
  const rows = async (uid, sid = S) => (await h.one(`select count(*)::int n from onboarding_choices where server_id = $1 and user_id = $2`, [sid, uid])).n;

  // The bug, before the fix: leave and come back, and the old answers still count.
  await join(kid);
  h.eq('new member is asked', await needed(kid), true);
  await finish(kid);
  h.eq('after finishing: not asked', await needed(kid), false);
  await h.as(kid); await h.q(`select leave_server($1)`, [S]); await h.admin();
  await join(kid);
  h.eq('before 339: the returning member is wrongly not asked again', await needed(kid), false);
  h.eq('before 339: the old answers row is still there', await rows(kid), 1);

  // The fix.
  await h.db.exec(mig('339_onboarding_rejoin_emoji.sql'));
  await h.ok('339 runs twice', () => h.db.exec(mig('339_onboarding_rejoin_emoji.sql')));
  h.eq('rows of people who already left or stayed are not touched by the migration', await rows(kid), 1);

  await join(kid2);
  await finish(kid2);
  h.eq('kid2 done', await needed(kid2), false);
  await h.as(kid2); await h.q(`select leave_server($1)`, [S]); await h.admin();
  h.eq('leaving clears the answers', await rows(kid2), 0);
  await join(kid2);
  h.eq('first join date is still kept (OG roles unaffected)', (await h.one(`select m.joined_at = f.first_joined_at ok from server_members m join server_first_joins f using (server_id, user_id) where m.server_id = $1 and m.user_id = $2`, [S, kid2])).ok, true);
  h.eq('after 339: the returning member is asked again', await needed(kid2), true);
  await finish(kid2);
  h.eq('and can finish again', await needed(kid2), false);

  // Kicked or banned (a plain delete of the membership) does the same.
  await join(kid3);
  await finish(kid3);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [S, kid3]);
  h.eq('removed member: answers cleared', await rows(kid3), 0);
  await join(kid3);
  h.eq('removed member comes back: asked again', await needed(kid3), true);

  // Other servers are not affected.
  await join(both); await join(both, T);
  await h.q(`insert into onboarding_choices (server_id, user_id) values ($1, $2), ($3, $2)`, [S, both, T]);
  await h.q(`delete from server_members where server_id = $1 and user_id = $2`, [T, both]);
  h.eq('answers of the other server stay', await rows(both, S), 1);
  h.eq('answers of the server left are gone', await rows(both, T), 0);

  // Deleting a whole server (members go with it) still works.
  await h.q(`insert into onboarding_choices (server_id, user_id) values ($1, $2)`, [S, owner]);
  await h.ok('deleting a server works', () => h.q(`delete from servers where id = $1`, [T]));
  await h.ok('deleting a server with members and answers still there works', async () => {
    const U = (await h.one(`insert into servers (name, owner_id) values ('Gone', $1) returning id`, [owner])).id;
    await h.q(`insert into server_members (server_id, user_id) values ($1, $2)`, [U, kid]);
    await h.q(`insert into onboarding_choices (server_id, user_id) values ($1, $2)`, [U, kid]);
    await h.q(`delete from servers where id = $1`, [U]);
  });

  // The function can't be run by hand.
  await h.as(kid);
  await h.fails('trigger function is not callable', `select public.forget_onboarding_on_leave()`);
  await h.admin();

  // Emoji: standard, custom token, nothing; too long is refused.
  const custom = '<a:' + 'n'.repeat(32) + ':' + '0123abcd-0123-4abc-8def-0123456789ab' + '>';
  h.eq('longest custom emoji token fits', custom.length <= 80, true);
  const save = (emoji) => h.q(`select save_onboarding($1, $2::jsonb)`, [S, JSON.stringify({ enabled: true, required: false, questions: [
    { title: 'Q', multi: false, answers: [{ label: 'A', emoji, role_ids: [] }] }] })]);
  await h.as(owner);
  await h.ok('standard emoji saves', () => save('🎮'));
  await h.ok('custom emoji token saves', () => save(custom));
  await h.ok('no emoji saves', () => save(null));
  await h.fails('81 characters is too long', `select save_onboarding($1, $2::jsonb)`, [S, JSON.stringify({ enabled: true, required: false, questions: [
    { title: 'Q', multi: false, answers: [{ label: 'A', emoji: 'x'.repeat(81), role_ids: [] }] }] })]);
  await save(custom);
  await h.as(owner);
  h.eq('the token comes back as saved', (await h.one(`select get_onboarding($1) g`, [S])).g.questions[0].answers[0].emoji, custom);
}
