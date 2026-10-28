-- 227: Suggestions form (flag suggest_form, test = Yapper HQ only, and the channel starts staff-only).
-- #suggestions-new in HQ has no message box: a "Submit a suggestion" form instead. Each suggestion is posted in the
-- channel as the person's own message (so people can react to vote) and saved in `suggestions` for Mod Center.
-- Only HQ's #suggestions-new takes them (no other server can make a channel with that name and fill Mod Center).
-- Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers)
select 'suggest_form', 'Suggestions form', 'A suggestion form in HQ #suggestions-new; suggestions land in Mod Center', 'test',
  coalesce((select array[default_server_id] from public.app_settings where default_server_id is not null limit 1), '{}')
on conflict (key) do nothing;

create table if not exists public.suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  server_id uuid references public.servers(id) on delete set null,
  channel_id uuid references public.channels(id) on delete set null,
  message_id uuid references public.messages(id) on delete set null,
  title text not null check (char_length(title) between 5 and 100),
  area text not null check (area in ('chat', 'voice', 'servers', 'profile', 'bots', 'mobile', 'other')),
  body text not null check (char_length(body) between 10 and 1500),
  status text not null default 'open' check (status in ('open', 'planned', 'done', 'declined')),
  staff_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create index if not exists suggestions_status_idx on public.suggestions (status, created_at desc);
create index if not exists suggestions_user_idx on public.suggestions (user_id, created_at desc);
create index if not exists suggestions_message_idx on public.suggestions (message_id) where message_id is not null;
create index if not exists suggestions_channel_idx on public.suggestions (channel_id) where channel_id is not null;
create index if not exists suggestions_server_idx on public.suggestions (server_id) where server_id is not null;

alter table public.suggestions enable row level security;
-- Your own, or all of them for Yapper staff. Rows are only made by submit_suggestion (no insert policy).
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'suggestions' and policyname = 'suggestions: read own or staff') then
    create policy "suggestions: read own or staff" on public.suggestions for select to authenticated
      using (user_id = (select auth.uid()) or (select public.is_staff()));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'suggestions' and policyname = 'suggestions: staff update') then
    create policy "suggestions: staff update" on public.suggestions for update to authenticated
      using ((select public.is_staff())) with check ((select public.is_staff()));
  end if;
end $$;
revoke all on public.suggestions from anon, authenticated;
grant select on public.suggestions to authenticated;
grant update (status, staff_note, updated_at) on public.suggestions to authenticated;


create or replace function public.submit_suggestion(cid uuid, p_title text, p_area text, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  t text := btrim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g'));
  a text := lower(btrim(coalesce(p_area, '')));
  b text := btrim(coalesce(p_body, ''));
  c public.channels;
  hq uuid;
  mid uuid;
  sid uuid;
  label text;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  select default_server_id into hq from public.app_settings limit 1;
  select * into c from public.channels where id = cid;
  if c.id is null or c.server_id is null or c.server_id is distinct from hq or c.name <> 'suggestions-new' then
    raise exception 'Suggestions go in #suggestions-new in Yapper HQ';
  end if;
  if not public.feature_on('suggest_form', c.server_id) then raise exception 'Suggestions aren''t open yet'; end if;
  if not public.can_access_channel(cid) then raise exception 'You can''t see that channel'; end if;
  -- Send Messages still counts (only the read-only part is skipped: the form is how you post here).
  if not (case when exists (select 1 from public.feature_flags f where f.key = 'channel_perms'
                              and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers))))
                and exists (select 1 from public.channel_overrides o where o.channel_id = c.id or o.category_id = c.category_id)
              then public.channel_perm(c.id, 'send_messages')
              else public.server_perm(c.server_id, 'send_messages') end) then
    raise exception 'You can''t post in that channel';
  end if;
  if public.is_site_banned(uid) then raise exception 'You can''t post right now'; end if;
  if char_length(t) < 5 or char_length(t) > 100 then raise exception 'Give it a title (5 to 100 characters)'; end if;
  if char_length(b) < 10 or char_length(b) > 1500 then raise exception 'Tell us a bit more (10 to 1500 characters)'; end if;
  label := case a when 'chat' then 'Chat' when 'voice' then 'Voice' when 'servers' then 'Servers' when 'profile' then 'Profile'
    when 'bots' then 'Bots' when 'mobile' then 'Mobile' when 'other' then 'Other' end;
  if label is null then raise exception 'Pick what it''s about'; end if;
  perform pg_advisory_xact_lock(hashtextextended('suggest:' || uid::text, 0));
  if (select count(*) from public.suggestions where user_id = uid and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You can send 3 suggestions a day. Try again tomorrow';
  end if;
  -- Posted as their own message (the channel is read-only for everyone else), so all the usual filters run on it.
  insert into public.messages (channel_id, author_id, content)
  values (cid, uid, '## 💡 ' || t || E'\n-# ' || label || E'\n' || b)
  returning id into mid;
  insert into public.suggestions (user_id, server_id, channel_id, message_id, title, area, body)
  values (uid, c.server_id, cid, mid, t, a, b)
  returning id into sid;
  return sid;
end $$;
revoke all on function public.submit_suggestion(uuid, text, text, text) from public, anon;
grant execute on function public.submit_suggestion(uuid, text, text, text) to authenticated;

-- The posted message is what people vote on: only staff can change its text afterwards (it would no longer match
-- the suggestion, and the votes were for something else).
create or replace function public.suggestion_edit_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.content is not distinct from old.content then return new; end if;
  if exists (select 1 from public.suggestions s where s.message_id = new.id) and not public.is_staff() then
    raise exception 'Suggestions can''t be edited. Send a new one instead' using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke all on function public.suggestion_edit_lock() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'messages_suggestion_lock' and tgrelid = 'public.messages'::regclass) then
    create trigger messages_suggestion_lock before update of content on public.messages
      for each row execute function public.suggestion_edit_lock();
  end if;
end $$;

-- Votes for Mod Center: reactions per suggestion message, counted in one go (staff only).
create or replace function public.suggestion_votes(ids uuid[])
returns table (message_id uuid, up int, down int, total int)
language sql
stable
security definer
set search_path = public
as $$
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

-- The channel itself: read-only (the form is the only way in), staff-only while testing. Publishing makes it public.
do $$
declare hq uuid; ch uuid;
begin
  select default_server_id into hq from public.app_settings limit 1;
  if hq is null or not exists (select 1 from public.servers where id = hq) then return; end if;
  if exists (select 1 from public.channels where server_id = hq and name = 'suggestions-new') then return; end if;
  insert into public.channels (server_id, name, kind, position, read_only, private, slowmode, created_by)
  values (hq, 'suggestions-new', 'text',
          coalesce((select position from public.channels where server_id = hq and name = 'suggestions' limit 1), 8),
          true, true, 0, (select owner_id from public.servers where id = hq))
  returning id into ch;
  insert into public.channel_roles (channel_id, role_id, server_id)
  select ch, r.id, hq from public.roles r where r.server_id = hq and r.name in ('Admin', 'Moderator')
  on conflict do nothing;
end $$;
