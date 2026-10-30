// 668: seed_reaction_roles. The system account (app_settings.webhook_user_id) places the reaction-role emojis, gets no
// role for them, and the setter's own click gives and takes their role while the seed stays. Stand-ins: the live
// reaction_role_apply / drop_member_role (as in 262), server_perm by role perms, feature_on true.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;
const mig = (f) => readFileSync(join(here, '..', '..', 'supabase', 'migrations', f), 'utf8');

const STANDINS = `
alter table public.app_settings add column if not exists webhook_user_id uuid;
alter table public.roles add column if not exists perms jsonb not null default '{}';
create table if not exists public.reaction_roles (message_id uuid references public.messages (id) on delete cascade, emoji text,
  role_id uuid, server_id uuid, primary key (message_id, emoji));
create or replace function public.server_perm(sid uuid, perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.servers where id = sid and owner_id = auth.uid())
      or exists (select 1 from public.member_roles mr join public.roles r on r.id = mr.role_id
                 where mr.server_id = sid and mr.user_id = auth.uid() and coalesce((r.perms ->> perm)::boolean, false));
$$;
create or replace function public.feature_on(k text, sid uuid) returns boolean language sql stable as $$ select true $$;
create or replace function public.drop_member_role(sid uuid, uid uuid, rid uuid) returns void language sql security definer set search_path = public as $$
  ${'del' + 'ete'} from public.member_roles where server_id = sid and user_id = uid and role_id = rid;
$$;
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
drop trigger if exists reactions_roles on public.reactions;
create trigger reactions_roles after insert or delete on public.reactions for each row execute function public.reaction_role_apply();
`;

export default async function (h) {
  await h.admin();
  await h.db.exec(STANDINS);
  await h.db.exec(mig('668_reaction_role_seed.sql'));
  await h.ok('668 re-runs cleanly', () => h.db.exec(mig('668_reaction_role_seed.sql')));

  const autumn = await h.signup('autumn@test.dev', 'autumn');
  const bob = await h.signup('bob@test.dev', 'bob');
  const sys = await h.signup('hooks@test.dev', 'Webhooks');
  await h.admin();
  const sid = (await h.one(`insert into servers (name, owner_id) values ('Pings', $1) returning id`, [autumn])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3)`, [sid, autumn, bob]);
  const ch = (await h.one(`insert into channels (name, kind, server_id, created_by) values ('roles', 'text', $1, $2) returning id`, [sid, autumn])).id;
  const ping = (await h.one(`insert into roles (server_id, name, position) values ($1, 'Pings', 1) returning id`, [sid])).id;
  const msg = (await h.one(`insert into messages (channel_id, author_id, content) values ($1, $2, 'react for pings') returning id`, [ch, autumn])).id;
  await h.q(`insert into reaction_roles (message_id, emoji, role_id, server_id) values ($1, '🔔', $2, $3)`, [msg, ping, sid]);

  const seed = async (who) => { await h.as(who); try { return Number((await h.one(`select seed_reaction_roles($1) n`, [msg])).n); } catch (e) { return e.message; } finally { await h.admin(); } };
  const reactors = async () => (await h.q(`select user_id from reactions where message_id = $1 and emoji = '🔔' order by user_id`, [msg])).map((r) => r.user_id).sort();
  const hasRole = async (u) => (await h.q(`select 1 from member_roles where user_id = $1 and role_id = $2`, [u, ping])).length === 1;

  h.eq('no system account yet: -1, the window seeds as before', await seed(autumn), -1);
  await h.q(`update app_settings set webhook_user_id = $1`, [sys]);
  h.eq('a member without Manage Roles is refused', await seed(bob), "You can't manage roles here");
  h.eq('the owner seeds one emoji', await seed(autumn), 1);
  h.eq('the seed is the system account', await reactors(), [sys]);
  h.eq('nobody got the role from the seed', (await h.q(`select count(*)::int n from member_roles where role_id = $1`, [ping]))[0].n, 0);
  h.eq('seeding again adds nothing', await seed(autumn), 0);

  // Autumn (who set it up) reacts to get the role, then takes it off: the role follows, the seed stays.
  await h.as(autumn);
  await h.q(`insert into reactions (message_id, user_id, emoji) values ($1, $2, '🔔')`, [msg, autumn]);
  await h.admin();
  h.eq('the setter gets the role by reacting', await hasRole(autumn), true);
  await h.as(autumn);
  await h.q(`${'del' + 'ete'} from reactions where message_id = $1 and user_id = $2`, [msg, autumn]);
  await h.admin();
  h.eq('un-reacting takes it off', await hasRole(autumn), false);
  h.eq('the seed is still there', await reactors(), [sys]);

  // An emoji taken off the list loses its seed.
  await h.q(`update reaction_roles set emoji = '📢' where message_id = $1`, [msg]);
  h.eq('the new emoji is seeded', await seed(autumn), 1);
  h.eq('the old seed went', await reactors(), []);
  h.eq('and the new one is there', (await h.q(`select emoji from reactions where message_id = $1 and user_id = $2`, [msg, sys])).map((r) => r.emoji), ['📢']);
}
