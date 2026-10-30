-- 680: quiz polls and "see who voted" (flag quiz_polls).
--   Quiz: the creator marks the right answer(s). They live in poll_answers, which nobody can select (RLS on, no
--   policies, no grants): they only come back from poll_view / vote_quiz, and only once you may see them (you voted
--   and the poll reveals on vote, or it closed, or you made it). Until then poll_results and poll_view give 0 votes,
--   and the live ballot broadcast to the channel carries no picks for quiz polls. Quiz answers are final.
--   Voters: poll_voters lists who picked an option, 50 at a time, unless the poll is anonymous. Every poll made
--   before this (votes were private, migration 420) and every poll made through the plain create_poll stays
--   anonymous; only create_poll_ex with the flag on makes a poll whose voters show.
--   create_poll itself is untouched (206/430/455 patch it in place on the live database): create_poll_ex calls it,
--   then marks the poll. Re-runnable, and nothing in it that hangs the Supabase MCP.

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('quiz_polls', 'Quiz polls',
  'Quiz polls (mark the right answer, revealed after voting or when the poll ends) and the voter list on polls (unless anonymous). Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- columns ----------
alter table public.polls add column if not exists quiz boolean not null default false;
alter table public.polls add column if not exists reveal text not null default 'vote';
alter table public.polls add column if not exists anonymous boolean not null default true;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'polls_reveal_check') then
    alter table public.polls add constraint polls_reveal_check check (reveal in ('vote', 'close'));
  end if;
end $$;

-- The right answers. Never readable by clients.
create table if not exists public.poll_answers (
  poll_id uuid primary key references public.polls (id) on delete cascade,
  correct text[] not null
);
alter table public.poll_answers enable row level security;
revoke all on public.poll_answers from public, anon, authenticated;

-- The voter list pages through a poll's ballots newest first. (~79k rows / 20 MB on Oct 29: a plain build takes well under a second.)
create index if not exists poll_ballots_poll_at_idx on public.poll_ballots (poll_id, created_at desc, user_id desc);

-- ---------- helpers (internal) ----------
-- May the caller see this poll's results (and, for a quiz, the answer)? Plain polls: always.
create or replace function public.poll_visible(p public.polls)
returns boolean language sql stable security definer set search_path = public as $$
  select not p.quiz
      or p.created_by = (select auth.uid())
      or (p.closes_at is not null and p.closes_at <= now())
      or (p.reveal = 'vote' and exists (select 1 from public.poll_ballots b where b.poll_id = p.id and b.user_id = (select auth.uid())));
$$;
revoke all on function public.poll_visible(public.polls) from public, anon, authenticated;

-- ---------- results ----------
-- Same shape as before, but a quiz you may not see yet gives 0 votes (your own pick still shows as mine).
create or replace function public.poll_results(pid uuid)
returns table (option_id text, votes bigint, mine boolean) language sql stable security definer set search_path = public as $$
  with p as (select p.*, public.poll_visible(p) vis from public.polls p where p.id = pid and public.can_access_channel(p.channel_id))
  select e ->> 'id',
         case when p.vis then (select count(*) from public.poll_ballots v where v.poll_id = pid and (e ->> 'id') = any(v.option_ids)) else 0 end,
         exists (select 1 from public.poll_ballots v where v.poll_id = pid and v.user_id = auth.uid() and (e ->> 'id') = any(v.option_ids))
  from p, jsonb_array_elements(p.options) e;
$$;
revoke all on function public.poll_results(uuid) from public, anon;
grant execute on function public.poll_results(uuid) to authenticated;

-- Everything a poll shows, in one call: counts (when visible), how many answered, and for a quiz the answer,
-- how many got it right and whether you did (only when visible).
create or replace function public.poll_view(pid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.polls; vis boolean; ans text[]; res jsonb; total int; mine text[]; right_n int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into p from public.polls where id = pid;
  if p.id is null or not public.can_access_channel(p.channel_id) then raise exception 'Poll not found'; end if;
  vis := public.poll_visible(p);
  select b.option_ids into mine from public.poll_ballots b where b.poll_id = pid and b.user_id = auth.uid();
  select count(*) into total from public.poll_ballots b where b.poll_id = pid;
  select coalesce(jsonb_agg(jsonb_build_object('option_id', r.option_id, 'votes', r.votes, 'mine', r.mine)), '[]'::jsonb)
    into res from public.poll_results(pid) r;
  if p.quiz and vis then
    select a.correct into ans from public.poll_answers a where a.poll_id = pid;
    -- Single choice: any right option counts. Several answers: exactly the right set.
    select count(*) into right_n from public.poll_ballots b where b.poll_id = pid
       and case when p.multi then b.option_ids @> coalesce(ans, '{}') and b.option_ids <@ coalesce(ans, '{}')
                else b.option_ids && coalesce(ans, '{}') end;
  end if;
  return jsonb_build_object(
    'quiz', p.quiz, 'visible', vis, 'voted', mine is not null, 'total', total, 'results', res,
    'correct', case when p.quiz and vis then to_jsonb(coalesce(ans, '{}')) end,
    'right', right_n,
    'you_right', case when p.quiz and vis and mine is not null then
      case when p.multi then mine @> coalesce(ans, '{}') and mine <@ coalesce(ans, '{}') else mine && coalesce(ans, '{}') end end);
end;
$$;
revoke all on function public.poll_view(uuid) from public, anon;
grant execute on function public.poll_view(uuid) to authenticated;

-- ---------- creating ----------
-- create_poll (all its checks: post permission, Create Polls, HQ rule, cooldown, filters) plus the quiz and
-- anonymous settings. correct = option numbers ('1' = first option, as create_poll numbers them).
create or replace function public.create_poll_ex(cid uuid, question text, opts text[], multi boolean default false, hours int default 24,
  quiz boolean default false, correct text[] default '{}', reveal text default 'vote', anon boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; pid uuid; n int := coalesce(array_length(opts, 1), 0); ok text[];
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select server_id into sid from public.channels where id = cid;
  if not (public.feature_on('quiz_polls', sid) or public.feature_on_for_me('quiz_polls')) then
    raise exception 'Quiz polls aren''t available here yet';
  end if;
  if quiz then
    select coalesce(array_agg(distinct x order by x), '{}') into ok from unnest(coalesce(correct, '{}')) x
     where x ~ '^[0-9]+$' and x::int between 1 and n;
    if coalesce(array_length(ok, 1), 0) = 0 then raise exception 'Mark the right answer'; end if;
    if ok is distinct from (select coalesce(array_agg(distinct x order by x), '{}') from unnest(correct) x) then raise exception 'Mark the right answer'; end if;
    if array_length(ok, 1) = n then raise exception 'Not every answer can be right'; end if;
    if coalesce(reveal, '') not in ('vote', 'close') then raise exception 'Pick when to show the answer'; end if;
    if reveal = 'close' and coalesce(hours, 0) <= 0 then raise exception 'Pick when the quiz ends to show the answer then'; end if;
  end if;
  pid := public.create_poll(cid, question, opts, multi, hours);
  update public.polls set quiz = create_poll_ex.quiz, reveal = case when create_poll_ex.quiz then create_poll_ex.reveal else 'vote' end,
         anonymous = coalesce(anon, false)
   where id = pid;
  if quiz then
    insert into public.poll_answers (poll_id, correct) values (pid, ok) on conflict (poll_id) do update set correct = excluded.correct;
  end if;
  return pid;
end;
$$;
revoke all on function public.create_poll_ex(uuid, text, text[], boolean, int, boolean, text[], text, boolean) from public, anon;
grant execute on function public.create_poll_ex(uuid, text, text[], boolean, int, boolean, text[], text, boolean) to authenticated;

-- ---------- voting ----------
-- A quiz answer, once. Returns poll_view, so the reveal comes back with the vote.
create or replace function public.vote_quiz(pid uuid, option_ids text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.polls; valid text[];
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into p from public.polls where id = pid;
  if p.id is null or not public.can_access_channel(p.channel_id) then raise exception 'Poll not found'; end if;
  if not p.quiz then raise exception 'This poll isn''t a quiz'; end if;
  if p.closes_at is not null and p.closes_at < now() then raise exception 'This poll is closed'; end if;
  if exists (select 1 from public.poll_ballots b where b.poll_id = pid and b.user_id = auth.uid()) then raise exception 'You already answered'; end if;
  select coalesce(array_agg(x order by ord), '{}') into valid from (
    select distinct on (x) x, ord from unnest(coalesce(vote_quiz.option_ids, '{}')) with ordinality u(x, ord)
     where exists (select 1 from jsonb_array_elements(p.options) e where e ->> 'id' = x)
     order by x, ord) d;
  if coalesce(array_length(valid, 1), 0) = 0 then raise exception 'Pick an answer'; end if;
  if not p.multi and array_length(valid, 1) > 1 then raise exception 'Pick one option'; end if;
  insert into public.poll_ballots (poll_id, user_id, option_ids) values (pid, auth.uid(), valid);
  return public.poll_view(pid);
end;
$$;
revoke all on function public.vote_quiz(uuid, text[]) from public, anon;
grant execute on function public.vote_quiz(uuid, text[]) to authenticated;

-- Quiz answers are final: vote_poll can't change or take back a quiz ballot (it could otherwise be used to vote,
-- see the answer, and switch). Cascades (poll or account deleted: delete_my_account runs as the voter, so the
-- cascade is told apart by trigger depth, the foreign key's own trigger being the outer level) and admin cleanup
-- still go through.
create or replace function public.poll_ballot_quiz_lock()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return coalesce(new, old); end if;
  if exists (select 1 from public.polls p where p.id = old.poll_id and p.quiz) then
    if tg_op = 'UPDATE' and new.option_ids is distinct from old.option_ids then raise exception 'Quiz answers are final'; end if;
    if tg_op = 'DELETE' and old.user_id = auth.uid() then raise exception 'Quiz answers are final'; end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function public.poll_ballot_quiz_lock() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'poll_ballots_quiz_lock' and tgrelid = 'public.poll_ballots'::regclass) then
    create trigger poll_ballots_quiz_lock before update or delete on public.poll_ballots
      for each row execute function public.poll_ballot_quiz_lock();
  end if;
end $$;

-- ---------- live ballots ----------
-- 420's version, plus: for a quiz, other people's copies carry no picks either (they'd give the results away live).
create or replace function public.broadcast_poll_ballot()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; sid uuid; uid uuid; voter uuid; is_quiz boolean; n public.poll_ballots; o public.poll_ballots;
begin
  if tg_op = 'UPDATE' and new.option_ids is not distinct from old.option_ids then return null; end if;
  select channel_id, quiz into cid, is_quiz from public.polls where id = coalesce(new.poll_id, old.poll_id);
  if cid is null then return null; end if;
  voter := coalesce(new.user_id, old.user_id);
  -- Copies without the voter (and, for a quiz, without the picks), for everyone else.
  if tg_op <> 'DELETE' then n := new; n.user_id := null; if is_quiz then n.option_ids := '{}'; end if; end if;
  if tg_op <> 'INSERT' then o := old; o.user_id := null; if is_quiz then o.option_ids := '{}'; end if; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform public.bc('chan:' || cid, 'poll', tg_op, tg_table_name, tg_table_schema,
      case when tg_op = 'DELETE' then null else n end, case when tg_op = 'INSERT' then null else o end);
    perform public.bc('user:' || voter, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      if uid = voter then
        perform public.bc('user:' || uid, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
      else
        perform public.bc('user:' || uid, 'poll', tg_op, tg_table_name, tg_table_schema,
          case when tg_op = 'DELETE' then null else n end, case when tg_op = 'INSERT' then null else o end);
      end if;
    end loop;
  end if;
  return null;
end;
$$;
revoke all on function public.broadcast_poll_ballot() from public, anon, authenticated;

-- ---------- who voted ----------
-- People who picked one option, newest first, 50 a page (pass the last row's voted_at + user_id for the next).
-- Not for anonymous polls, nor for a quiz you can't see yet.
create or replace function public.poll_voters(pid uuid, opt text, before_at timestamptz default null, before_uid uuid default null, lim int default 50)
returns table (user_id uuid, voted_at timestamptz) language plpgsql stable security definer set search_path = public as $$
declare p public.polls; sid uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into p from public.polls where id = pid;
  if p.id is null or not public.can_access_channel(p.channel_id) then raise exception 'Poll not found'; end if;
  select server_id into sid from public.channels where id = p.channel_id;
  if not (public.feature_on('quiz_polls', sid) or public.feature_on_for_me('quiz_polls')) then raise exception 'Poll not found'; end if;
  if p.anonymous then raise exception 'This poll is anonymous'; end if;
  if not public.poll_visible(p) then raise exception 'Answer first to see who voted'; end if;
  return query
    select b.user_id, b.created_at from public.poll_ballots b
     where b.poll_id = pid and opt = any(b.option_ids)
       and (before_at is null or (b.created_at, b.user_id) < (before_at, coalesce(before_uid, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
     order by b.created_at desc, b.user_id desc
     limit greatest(1, least(coalesce(lim, 50), 100));
end;
$$;
revoke all on function public.poll_voters(uuid, text, timestamptz, uuid, int) from public, anon;
grant execute on function public.poll_voters(uuid, text, timestamptz, uuid, int) to authenticated;
