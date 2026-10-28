-- Rules channel (flag `rules_channel`): a server manager marks one text channel as the rules channel.
-- It gets a book icon, new members are pointed at it, and only people who can manage the server post there.
-- Not applied live yet. The flag row was inserted live (mode test).

alter table public.servers add column if not exists rules_channel_id uuid references public.channels(id) on delete set null;

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('rules_channel', 'Rules channel',
   'Pick a rules channel in Server settings: book icon, only managers post, new members get a Read the rules prompt',
   'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
  on conflict (key) do nothing;

-- Set or clear (cid null) the rules channel. servers has no UPDATE policy, so this is the only way in.
create or replace function public.set_rules_channel(sid uuid, cid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can change this' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('rules_channel', sid) then
    raise exception 'Rules channels aren''t on in this server yet' using errcode = 'check_violation';
  end if;
  if cid is not null and not exists (
    select 1 from public.channels c
    where c.id = cid and c.server_id = sid and c.kind = 'text' and c.ticket_by is null
  ) then
    raise exception 'Pick a text channel in this server' using errcode = 'check_violation';
  end if;
  update public.servers set rules_channel_id = cid where id = sid;
end $$;

revoke all on function public.set_rules_channel(uuid, uuid) from public, anon;
grant execute on function public.set_rules_channel(uuid, uuid) to authenticated;

create index if not exists servers_rules_channel_idx on public.servers (rules_channel_id) where rules_channel_id is not null;

-- Only managers post in the rules channel. Patch message_perm_guard in place (like 158) so live hotfixes stay.
-- Bots (yapper.bot) return before this, like every other channel rule in the guard.
do $$
declare
  def text := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  anchor text := $b$  if vk = 'voice' and not public.feature_on('voice_chat', sid) then$b$;
  new_block text := $b$  if exists (select 1 from public.servers s where s.id = sid and s.rules_channel_id = new.channel_id)
     and public.feature_on('rules_channel', sid)
     and not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can post in the rules channel' using errcode = 'check_violation';
  end if;
$b$;
  patched text;
begin
  if position('rules_channel' in def) > 0 then
    return; -- already patched
  end if;
  patched := replace(def, anchor, new_block || anchor);
  if patched = def then
    raise exception '178: voice_chat anchor not found in message_perm_guard, nothing patched';
  end if;
  execute patched;
end $$;

-- Same for edits: non-managers can't change message text in the rules channel (pins don't touch content).
do $$
declare
  def text := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
  anchor text := $b$      new.content := public.fix_role_pings(sid, old.channel_id, cp, new.content);$b$;
  new_block text := $b$      if exists (select 1 from public.servers s where s.id = sid and s.rules_channel_id = old.channel_id)
         and public.feature_on('rules_channel', sid)
         and not public.server_perm(sid, 'manage_server') then
        raise exception 'Only server managers can edit messages in the rules channel' using errcode = 'check_violation';
      end if;
$b$;
  patched text;
begin
  if position('rules_channel' in def) > 0 then
    return; -- already patched
  end if;
  patched := replace(def, anchor, new_block || anchor);
  if patched = def then
    raise exception '178: fix_role_pings anchor not found in message_edit_guard, nothing patched';
  end if;
  execute patched;
end $$;
