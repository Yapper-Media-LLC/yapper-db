-- ============================================================
-- Yapper · Stage 6 · Notifications
-- Unread counts per chat, and muting.
-- ============================================================

create table public.channel_reads (
  user_id uuid not null references public.profiles (id) on delete cascade,
  channel_id uuid not null references public.channels (id) on delete cascade,
  last_read_at timestamptz not null default now(),
  muted boolean not null default false,
  primary key (user_id, channel_id)
);

alter table public.channel_reads enable row level security;
create policy "see your own read state"
  on public.channel_reads for select to authenticated using (user_id = auth.uid());
create policy "create your own read state"
  on public.channel_reads for insert to authenticated
  with check (user_id = auth.uid() and public.can_access_channel(channel_id));
create policy "update your own read state"
  on public.channel_reads for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "remove your own read state"
  on public.channel_reads for delete to authenticated using (user_id = auth.uid());

-- Every channel I'm in that I can access, with how many unread messages it has (capped at 100).
create or replace function public.unread_counts()
returns table (channel_id uuid, unread int, muted boolean)
language sql
stable
security definer
set search_path = public
as $$
  select
    cm.channel_id,
    (
      select count(*)::int from (
        select 1 from public.messages m
        where m.channel_id = cm.channel_id
          and m.author_id <> auth.uid()
          and m.created_at > coalesce(r.last_read_at, cm.joined_at)
        limit 100
      ) x
    ) as unread,
    coalesce(r.muted, false) as muted
  from public.channel_members cm
  left join public.channel_reads r on r.channel_id = cm.channel_id and r.user_id = auth.uid()
  where cm.user_id = auth.uid();
$$;
grant execute on function public.unread_counts() to authenticated;

create or replace function public.mark_read(cid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_access_channel(cid) then return; end if;
  insert into public.channel_reads (user_id, channel_id, last_read_at)
    values (auth.uid(), cid, now())
    on conflict (user_id, channel_id) do update set last_read_at = now();
end;
$$;
grant execute on function public.mark_read(uuid) to authenticated;

create or replace function public.set_muted(cid uuid, mute boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_access_channel(cid) then raise exception 'Chat not found'; end if;
  insert into public.channel_reads (user_id, channel_id, muted)
    values (auth.uid(), cid, mute)
    on conflict (user_id, channel_id) do update set muted = excluded.muted;
end;
$$;
grant execute on function public.set_muted(uuid, boolean) to authenticated;
