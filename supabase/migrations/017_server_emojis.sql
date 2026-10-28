-- ============================================================
-- Yapper · Server emojis (like Discord)
-- Emojis now belong to a server. People who can manage the server add,
-- rename and remove them (up to 50 per server). Everyone can use the
-- emojis of every server they're in, anywhere — DMs included.
-- Older personal emojis (no server) keep showing in old messages but
-- can't be picked any more.
-- ============================================================

alter table public.emojis
  add column if not exists server_id uuid references public.servers (id) on delete cascade;
create index if not exists emojis_server_idx on public.emojis (server_id);

-- Names are unique per server (the old per-person rule is dropped in 017b).
create unique index if not exists emojis_server_name_idx
  on public.emojis (server_id, lower(name)) where server_id is not null;

create or replace function public.emoji_limit()
returns trigger
language plpgsql
as $$
begin
  if new.server_id is null then
    raise exception 'Emojis are added to a server now (Server Settings → Emoji)';
  end if;
  if (select count(*) from public.emojis where server_id = new.server_id) >= 50 then
    raise exception 'A server can have up to 50 emojis';
  end if;
  return new;
end;
$$;

-- (Policies keep their old names; only what they allow changes.)
alter policy "add your own emojis" on public.emojis
  with check (
    owner_id = auth.uid()
    and server_id is not null
    and public.server_perm(server_id, 'manage_server')
  );
alter policy "rename your own emojis" on public.emojis
  using (server_id is not null and public.server_perm(server_id, 'manage_server'))
  with check (server_id is not null and public.server_perm(server_id, 'manage_server'));
alter policy "delete your own emojis" on public.emojis
  using (owner_id = auth.uid() or (server_id is not null and public.server_perm(server_id, 'manage_server')));
