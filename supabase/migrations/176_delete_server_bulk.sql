-- Deleting a server ran every per-row trigger on everything it removed: one realtime broadcast and one
-- logger-bot check per message, and the logger tried to post "message deleted" into channels that were
-- being deleted in the same statement. Big servers took long enough to hit the statement timeout and the
-- delete just failed. yapper.bulk (transaction-local) is the existing switch those triggers already honour
-- (broadcast_message_change, logger_messages, logger_members, log_mod_delete).
create or replace function public.delete_server(sid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.servers where id = sid and owner_id = auth.uid()) then
    raise exception 'Only the owner can delete a server';
  end if;
  perform set_config('yapper.bulk', '1', true);
  delete from public.servers where id = sid;
  perform set_config('yapper.bulk', '', true);
end;
$$;
revoke all on function public.delete_server(uuid) from public, anon;
grant execute on function public.delete_server(uuid) to authenticated;
