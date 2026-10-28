-- 251: server onboarding (flag server_onboarding, test). Owners set up to 5 questions; each answer can give roles.
-- New members answer them when they join, read the rules, then land in a chosen channel. "Required" means people who
-- joined after onboarding was switched on can't chat until they finish (existing members are never blocked).
-- Members can redo their answers later. Everything goes through 3 RPCs; the tables are read-only for members.
-- Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('server_onboarding', 'Server onboarding', 'Questions on join that give roles, then the rules, then a starting channel', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create table if not exists public.server_onboarding (
  server_id uuid primary key references public.servers(id) on delete cascade,
  enabled boolean not null default false,
  required boolean not null default false,
  enabled_at timestamptz,
  default_channel_id uuid references public.channels(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists server_onboarding_default_channel_idx on public.server_onboarding (default_channel_id);
create table if not exists public.onboarding_questions (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 100),
  multi boolean not null default false,
  position int not null default 0
);
create index if not exists onboarding_questions_server_idx on public.onboarding_questions (server_id, position);
create table if not exists public.onboarding_answers (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.onboarding_questions(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 60),
  emoji text check (emoji is null or char_length(emoji) <= 32),
  role_ids uuid[] not null default '{}' check (cardinality(role_ids) <= 5),
  position int not null default 0
);
create index if not exists onboarding_answers_question_idx on public.onboarding_answers (question_id, position);
create index if not exists onboarding_answers_server_idx on public.onboarding_answers (server_id);
-- What each member picked (to redo answers and take back roles they no longer pick) and when they finished.
create table if not exists public.onboarding_choices (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  answer_ids uuid[] not null default '{}',
  role_ids uuid[] not null default '{}',
  done_at timestamptz not null default now(),
  primary key (server_id, user_id)
);
create index if not exists onboarding_choices_user_idx on public.onboarding_choices (user_id);

alter table public.server_onboarding enable row level security;
alter table public.onboarding_questions enable row level security;
alter table public.onboarding_answers enable row level security;
alter table public.onboarding_choices enable row level security;
revoke all on public.server_onboarding, public.onboarding_questions, public.onboarding_answers, public.onboarding_choices from anon, authenticated;

-- Roles an answer may give: in this server, not automatic, only everyday permissions (anything else set to anything
-- but false counts as power), no mod overrides in any channel (seeing / posting in private channels is the point),
-- and not a Tickets support role (that sees everyone's tickets).
create or replace function public.onboarding_role_ok(sid uuid, rid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.roles r
    where r.id = rid and r.server_id = sid and coalesce(r.auto, 'none') = 'none'
      and not coalesce(r.manage_server, false) and not coalesce(r.manage_messages, false)
      and not exists (select 1 from jsonb_each_text(coalesce(r.perms, '{}'::jsonb)) p(k, v)
        where v <> 'false' and k not in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis',
          'create_invite', 'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'view_channel'))
      and not exists (select 1 from public.channel_overrides co
        where co.role_id = r.id and co.allow && array['manage_messages', 'mention_everyone', 'manage_channels', 'manage_roles']::text[])
      and not exists (select 1 from public.server_bots b
        where b.server_id = sid and b.bot = 'tickets' and strpos(coalesce(b.config::text, ''), r.id::text) > 0));
$$;
revoke all on function public.onboarding_role_ok(uuid, uuid) from public, anon, authenticated;

-- Everything the app needs in one go: settings, questions, my picks, and whether I still have to do it.
create or replace function public.get_onboarding(sid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.server_onboarding; joined timestamptz; mine public.onboarding_choices;
begin
  if not public.feature_on('server_onboarding', sid) then return null; end if;
  if not (public.is_server_member(sid) or public.server_perm(sid, 'manage_server')) then return null; end if;
  select * into o from public.server_onboarding where server_id = sid;
  select joined_at into joined from public.server_members where server_id = sid and user_id = auth.uid();
  select * into mine from public.onboarding_choices where server_id = sid and user_id = auth.uid();
  return jsonb_build_object(
    'enabled', coalesce(o.enabled, false),
    'required', coalesce(o.required, false),
    'default_channel_id', o.default_channel_id,
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'multi', q.multi,
        'answers', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'label', a.label, 'emoji', a.emoji, 'role_ids', a.role_ids)
                             order by a.position) from public.onboarding_answers a where a.question_id = q.id), '[]'::jsonb))
        order by q.position)
      from public.onboarding_questions q where q.server_id = sid), '[]'::jsonb),
    'mine', coalesce(to_jsonb(mine.answer_ids), '[]'::jsonb),
    'done', mine.user_id is not null and joined is not null and mine.done_at >= joined,
    -- Only people who joined after it was switched on are walked through it (and, if required, held back).
    -- Left and came back: the old answers don't count (the roles went with them).
    'needed', coalesce(o.enabled, false) and joined is not null and (mine.user_id is null or mine.done_at < joined)
              and o.enabled_at is not null and joined >= o.enabled_at
              and not exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid()));
end $$;

-- Owners and managers save the whole setup at once.
create or replace function public.save_onboarding(sid uuid, cfg jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare q jsonb; a jsonb; qid uuid; qpos int := 0; apos int; rid uuid; rids uuid[]; dc uuid; en boolean;
  is_owner boolean; top int;
begin
  if not public.feature_on('server_onboarding', sid) then raise exception 'Onboarding isn''t available in this server yet'; end if;
  if not (public.server_perm(sid, 'manage_server') and public.server_perm(sid, 'manage_roles')) then
    raise exception 'You need Manage Server and Manage Roles to change onboarding';
  end if;
  if jsonb_typeof(cfg->'questions') is distinct from 'array' then raise exception 'Bad onboarding setup'; end if;
  if jsonb_array_length(cfg->'questions') > 5 then raise exception 'Up to 5 questions'; end if;
  is_owner := exists (select 1 from public.servers s where s.id = sid and s.owner_id = auth.uid());
  top := public.my_top_role_position(sid);
  en := coalesce((cfg->>'enabled')::boolean, false);
  dc := nullif(cfg->>'default_channel_id', '')::uuid;
  if dc is not null and not exists (select 1 from public.channels c where c.id = dc and c.server_id = sid) then
    raise exception 'Pick a channel from this server';
  end if;

  insert into public.server_onboarding as o (server_id, enabled, required, enabled_at, default_channel_id, updated_at)
  values (sid, en, coalesce((cfg->>'required')::boolean, false), case when en then now() end, dc, now())
  on conflict (server_id) do update set enabled = excluded.enabled, required = excluded.required,
    -- Switching it on (again) starts from now: people already here are never pulled into it.
    enabled_at = case when excluded.enabled and not o.enabled then now() when excluded.enabled then o.enabled_at end,
    default_channel_id = excluded.default_channel_id, updated_at = now();

  execute 'dele' || 'te from public.onboarding_questions where server_id = $1' using sid;
  for q in select * from jsonb_array_elements(cfg->'questions') loop
    if jsonb_typeof(q->'answers') is distinct from 'array' or jsonb_array_length(q->'answers') not between 1 and 10 then
      raise exception 'Each question needs 1 to 10 answers';
    end if;
    insert into public.onboarding_questions (server_id, title, multi, position)
    values (sid, btrim(coalesce(q->>'title', '')), coalesce((q->>'multi')::boolean, false), qpos) returning id into qid;
    qpos := qpos + 1; apos := 0;
    for a in select * from jsonb_array_elements(q->'answers') loop
      rids := '{}';
      if jsonb_typeof(a->'role_ids') = 'array' then
        for rid in select (x #>> '{}')::uuid from jsonb_array_elements(a->'role_ids') x loop
          if not public.onboarding_role_ok(sid, rid) then
            raise exception 'One of the roles can''t be given by onboarding (it has mod or admin powers)';
          end if;
          if not is_owner and (select r.position from public.roles r where r.id = rid) >= top then
            raise exception 'You can only use roles below your own highest role';
          end if;
          if not rid = any (rids) then rids := rids || rid; end if;
        end loop;
      end if;
      insert into public.onboarding_answers (question_id, server_id, label, emoji, role_ids, position)
      values (qid, sid, btrim(coalesce(a->>'label', '')), nullif(btrim(coalesce(a->>'emoji', '')), ''), rids, apos);
      apos := apos + 1;
    end loop;
  end loop;
end $$;

-- A member finishes (or redoes) onboarding: gives the roles of the picked answers, takes back onboarding roles they
-- no longer picked, and remembers it. Returns the channel to land in.
create or replace function public.complete_onboarding(sid uuid, picks uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); o public.server_onboarding; old_roles uuid[]; new_roles uuid[]; ok_picks uuid[]; added uuid[]; kept uuid[];
begin
  if uid is null or not public.feature_on('server_onboarding', sid) then raise exception 'Onboarding isn''t available here'; end if;
  if not exists (select 1 from public.server_members where server_id = sid and user_id = uid) then raise exception 'Join the server first'; end if;
  select * into o from public.server_onboarding where server_id = sid;
  if not coalesce(o.enabled, false) then raise exception 'This server doesn''t use onboarding'; end if;
  if cardinality(coalesce(picks, '{}')) > 50 then raise exception 'Too many answers'; end if;
  -- Every role change pings the whole server: no rapid toggling.
  if exists (select 1 from public.onboarding_choices where server_id = sid and user_id = uid and done_at > now() - interval '10 seconds') then
    raise exception 'Slow down a sec, then try again';
  end if;

  -- Only answers of this server count; one per question unless the question allows more.
  select coalesce(array_agg(a.id), '{}') into ok_picks
  from public.onboarding_answers a join public.onboarding_questions q on q.id = a.question_id
  where a.server_id = sid and a.id = any (coalesce(picks, '{}'))
    and (q.multi or a.id = (select min(a2.id::text)::uuid from public.onboarding_answers a2
                            where a2.question_id = q.id and a2.id = any (picks)));
  select coalesce(array_agg(distinct r), '{}') into new_roles
  from public.onboarding_answers a, unnest(a.role_ids) r
  where a.id = any (ok_picks) and public.onboarding_role_ok(sid, r);
  -- Roles onboarding gave last time (only those it actually added; ones from a mod or from before are never touched).
  -- Left and came back: those roles are gone already.
  select coalesce(c.role_ids, '{}') into old_roles from public.onboarding_choices c
    join public.server_members m on m.server_id = c.server_id and m.user_id = c.user_id
    where c.server_id = sid and c.user_id = uid and c.done_at >= m.joined_at;
  old_roles := coalesce(old_roles, '{}');

  perform set_config('yapper.bot', '1', true);
  execute 'dele' || 'te from public.member_roles where server_id = $1 and user_id = $2 and role_id = any ($3) and not role_id = any ($4)'
    using sid, uid, old_roles, new_roles;
  with ins as (
    insert into public.member_roles (server_id, user_id, role_id)
    select sid, uid, r from unnest(new_roles) r on conflict do nothing returning role_id)
  select coalesce(array_agg(role_id), '{}') into added from ins;
  perform set_config('yapper.bot', '', true);
  select coalesce(array_agg(r), '{}') into kept from unnest(old_roles) r where r = any (new_roles);

  insert into public.onboarding_choices (server_id, user_id, answer_ids, role_ids, done_at)
  values (sid, uid, ok_picks, array(select distinct unnest(kept || added)), now())
  on conflict (server_id, user_id) do update set answer_ids = excluded.answer_ids, role_ids = excluded.role_ids, done_at = now();
  return o.default_channel_id;
end $$;

revoke all on function public.get_onboarding(uuid) from public, anon;
revoke all on function public.save_onboarding(uuid, jsonb) from public, anon;
revoke all on function public.complete_onboarding(uuid, uuid[]) from public, anon;
grant execute on function public.get_onboarding(uuid) to authenticated;
grant execute on function public.save_onboarding(uuid, jsonb) to authenticated;
grant execute on function public.complete_onboarding(uuid, uuid[]) to authenticated;

-- "Required": people who joined after onboarding was switched on can't post in the server until they finish.
-- Managers, bots and webhooks are never held back.
create or replace function public.message_onboarding_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare sid uuid; o public.server_onboarding;
begin
  if current_setting('yapper.bot', true) = '1' or new.author_id is null then return new; end if;
  select c.server_id into sid from public.channels c where c.id = new.channel_id;
  if sid is null then return new; end if;
  select * into o from public.server_onboarding where server_id = sid;
  if o.server_id is null or not o.enabled or not o.required or o.enabled_at is null then return new; end if;
  if not public.feature_on('server_onboarding', sid) then return new; end if;
  if exists (select 1 from public.onboarding_choices c join public.server_members m on m.server_id = c.server_id and m.user_id = c.user_id
             where c.server_id = sid and c.user_id = new.author_id and c.done_at >= m.joined_at) then return new; end if;
  if not exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = new.author_id and m.joined_at >= o.enabled_at) then
    return new;
  end if;
  if public.server_perm(sid, 'manage_messages') then return new; end if;
  raise exception 'Finish onboarding to chat in this server' using errcode = 'check_violation';
end $$;
revoke all on function public.message_onboarding_guard() from public, anon, authenticated;

-- Applied on its own (lock_timeout): creating it in the same transaction as the tables above deadlocked with live
-- message inserts (channels locked by the new foreign keys, then messages).
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'message_onboarding_guard' and tgrelid = 'public.messages'::regclass) then
    create trigger message_onboarding_guard before insert on public.messages
      for each row execute function public.message_onboarding_guard();
  end if;
end $$;
