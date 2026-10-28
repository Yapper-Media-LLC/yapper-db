-- Close a DM: it leaves the sidebar until the other person writes again.
alter table public.channel_members add column if not exists hidden_at timestamptz;
drop policy if exists "hide your own dms" on public.channel_members;
create policy "hide your own dms" on public.channel_members for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create or replace function public.channel_member_guard() returns trigger language plpgsql security invoker set search_path = public as $$
begin
  if current_user = 'authenticated' then
    new.channel_id := old.channel_id; new.user_id := old.user_id; new.joined_at := old.joined_at;
  end if;
  return new;
end; $$;
drop trigger if exists channel_members_guard on public.channel_members;
create trigger channel_members_guard before update on public.channel_members for each row execute function public.channel_member_guard();
