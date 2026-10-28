-- ============================================================
-- Yapper · Stage 9 · Replies and reactions
-- ============================================================

alter table public.messages
  add column reply_to_id uuid references public.messages (id) on delete set null;

-- A reply has to point at a message in the same chat.
create or replace function public.message_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.created_at := now();
  if new.reply_to_id is not null and not exists (
    select 1 from public.messages where id = new.reply_to_id and channel_id = new.channel_id
  ) then
    new.reply_to_id := null;
  end if;
  return new;
end;
$$;

-- Edits can't change what a message replies to either.
create or replace function public.message_edit_guard()
returns trigger
language plpgsql
as $$
begin
  new.id := old.id;
  new.channel_id := old.channel_id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  new.attachment_path := old.attachment_path;
  new.attachment_width := old.attachment_width;
  new.attachment_height := old.attachment_height;
  new.reply_to_id := case when new.reply_to_id is null then null else old.reply_to_id end;
  if new.content is distinct from old.content then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end;
$$;

-- ---------- Reactions ----------
create table public.reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- A standard emoji, or a custom one as <:name:id> / <a:name:id>
  emoji text not null check (char_length(emoji) between 1 and 80),
  created_at timestamptz not null default now(),
  unique (message_id, user_id, emoji)
);
create index reactions_message_idx on public.reactions (message_id);

create or replace function public.message_channel(mid uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select channel_id from public.messages where id = mid;
$$;

-- At most 20 different emojis on one message.
create or replace function public.reaction_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.reactions where message_id = new.message_id and emoji = new.emoji)
     and (select count(distinct emoji) from public.reactions where message_id = new.message_id) >= 20 then
    raise exception 'This message has enough reactions';
  end if;
  return new;
end;
$$;
create trigger reactions_limit before insert on public.reactions
  for each row execute function public.reaction_limit();

alter table public.reactions enable row level security;
create policy "see reactions in chats you can access"
  on public.reactions for select to authenticated
  using (public.can_access_channel(public.message_channel(message_id)));
create policy "react as yourself"
  on public.reactions for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.can_access_channel(public.message_channel(message_id))
    and not public.dm_blocked(public.message_channel(message_id))
  );
create policy "remove your own reactions"
  on public.reactions for delete to authenticated
  using (user_id = auth.uid());

alter publication supabase_realtime add table public.reactions;
