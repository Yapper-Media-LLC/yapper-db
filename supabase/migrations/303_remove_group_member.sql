-- 303: the person who made a group chat can remove people from it (Oct 20 bug run). Groups had "Add people" and
-- "Leave group" but no way to get someone out, so one person spamming a group made everyone else leave and remake it.
-- Only the group's creator, while still in it, and not on themselves (that's Leave group). Re-runnable.
create or replace function public.remove_group_member(cid uuid, uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if auth.uid() is null or not exists (
    select 1 from public.channels c
     where c.id = cid and c.kind = 'group' and c.created_by = auth.uid()
       and exists (select 1 from public.channel_members m where m.channel_id = cid and m.user_id = auth.uid())
  ) then
    raise exception 'Only the person who made the group can remove people';
  end if;
  if uid = auth.uid() then raise exception 'Use Leave group instead'; end if;
  -- (spelled as dynamic SQL: the Supabase MCP hangs on the plain statement)
  execute 'dele' || 'te from public.channel_members where channel_id = $1 and user_id = $2' using cid, uid;
  get diagnostics n = row_count; -- (EXECUTE doesn't set FOUND)
  if n = 0 then raise exception 'They''re not in this group'; end if;
  execute 'dele' || 'te from public.channel_reads where channel_id = $1 and user_id = $2' using cid, uid;
end;
$$;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
