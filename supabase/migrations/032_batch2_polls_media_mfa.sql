-- ============================================================
-- Yapper · Batch 2 (applied to production 2026-10-13): polls, video/audio, 2FA enforcement
-- ============================================================

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique references public.messages (id) on delete cascade,
  channel_id uuid not null references public.channels (id) on delete cascade,
  question text not null check (char_length(question) between 1 and 200),
  options jsonb not null,
  multi boolean not null default false,
  closes_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.poll_ballots (
  poll_id uuid not null references public.polls (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  option_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);
alter table public.polls enable row level security;
alter table public.poll_ballots enable row level security;
drop policy if exists "members read polls" on public.polls;
create policy "members read polls" on public.polls for select to authenticated using (public.can_access_channel(channel_id));
drop policy if exists "members read ballots" on public.poll_ballots;
create policy "members read ballots" on public.poll_ballots for select to authenticated using (exists (select 1 from public.polls p where p.id = poll_id and public.can_access_channel(p.channel_id)));
alter publication supabase_realtime add table public.poll_ballots;

create or replace function public.create_poll(cid uuid, question text, opts text[], multi boolean default false, hours int default 24)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; mid uuid; pid uuid; o jsonb := '[]'::jsonb; i int;
begin
  select server_id into sid from public.channels where id = cid;
  if not public.can_access_channel(cid) then raise exception 'Channel not found'; end if;
  if not (public.feature_on('polls', sid) or public.feature_on_for_me('polls')) then raise exception 'Polls aren''t available here yet'; end if;
  if coalesce(array_length(opts, 1), 0) < 2 or array_length(opts, 1) > 10 then raise exception 'Give 2 to 10 options'; end if;
  for i in 1 .. array_length(opts, 1) loop
    if char_length(trim(opts[i])) = 0 or char_length(opts[i]) > 80 then raise exception 'Options are 1–80 characters'; end if;
    o := o || jsonb_build_object('id', i::text, 'text', trim(opts[i]));
  end loop;
  insert into public.messages (channel_id, author_id, content) values (cid, auth.uid(), '📊 ' || left(question, 200)) returning id into mid;
  insert into public.polls (message_id, channel_id, question, options, multi, closes_at, created_by)
  values (mid, cid, left(question, 200), o, multi, case when hours > 0 then now() + make_interval(hours => least(hours, 24 * 14)) end, auth.uid())
  returning id into pid;
  return pid;
end;
$$;
create or replace function public.vote_poll(pid uuid, option_ids text[])
returns void language plpgsql security definer set search_path = public as $$
declare p public.polls; valid text[];
begin
  select * into p from public.polls where id = pid;
  if p.id is null or not public.can_access_channel(p.channel_id) then raise exception 'Poll not found'; end if;
  if p.closes_at is not null and p.closes_at < now() then raise exception 'This poll is closed'; end if;
  if not p.multi and coalesce(array_length(option_ids, 1), 0) > 1 then raise exception 'Pick one option'; end if;
  select coalesce(array_agg(x), '{}') into valid from unnest(option_ids) x where exists (select 1 from jsonb_array_elements(p.options) e where e ->> 'id' = x);
  insert into public.poll_ballots (poll_id, user_id, option_ids) values (pid, auth.uid(), valid)
  on conflict (poll_id, user_id) do update set option_ids = excluded.option_ids, created_at = now();
end;
$$;
create or replace function public.poll_results(pid uuid)
returns table (option_id text, votes bigint, mine boolean) language sql stable security definer set search_path = public as $$
  select e ->> 'id', (select count(*) from public.poll_ballots v where v.poll_id = pid and (e ->> 'id') = any(v.option_ids)),
         exists (select 1 from public.poll_ballots v where v.poll_id = pid and v.user_id = auth.uid() and (e ->> 'id') = any(v.option_ids))
  from public.polls p, jsonb_array_elements(p.options) e where p.id = pid and public.can_access_channel(p.channel_id);
$$;
revoke all on function public.create_poll(uuid, text, text[], boolean, int), public.vote_poll(uuid, text[]), public.poll_results(uuid) from public, anon;
grant execute on function public.create_poll(uuid, text, text[], boolean, int), public.vote_poll(uuid, text[]), public.poll_results(uuid) to authenticated;

-- Video & audio in the attachments bucket (per-server gate is the 'media' flag in the app)
update storage.buckets set allowed_mime_types = array['image/png','image/jpeg','image/gif','image/webp','video/mp4','video/webm','video/quicktime','audio/mpeg','audio/ogg','audio/wav','audio/mp4','audio/webm','audio/x-m4a'], file_size_limit = 26214400 where id = 'attachments';

-- 2FA: once someone has a verified authenticator, writes need an aal2 session
create or replace function public.require_mfa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null
     and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2'
     and exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified') then
    raise exception 'Finish two-factor sign-in first.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists messages_require_mfa on public.messages;
create trigger messages_require_mfa before insert or update on public.messages for each row execute function public.require_mfa();
drop trigger if exists profiles_require_mfa on public.profiles;
create trigger profiles_require_mfa before update on public.profiles for each row execute function public.require_mfa();
