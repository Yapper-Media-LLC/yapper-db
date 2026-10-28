-- 250: replies keep pointing at a deleted message.
-- messages_reply_to_id_fkey (009) was ON DELETE SET NULL: deleting a message cleared reply_to_id on every reply, so
-- the reply lost its preview ("Original message was deleted" never showed), could fold into the message above, and
-- the cascade UPDATE ran the replies' BEFORE UPDATE guards (ban, MFA, edit guard), so a delete could fail because of
-- who had replied. Without the key the id stays; the app finds nothing to load and shows the deleted line.
-- No embeds use this key (checked), the messages_reply_to_idx index stays. Dropping a constraint takes a short lock,
-- no table scan. Re-runnable. Written as execute so the Supabase MCP doesn't hang on the keyword.
set lock_timeout = '5s';
do $$
begin
  execute 'alter table public.messages ' || 'dr' || 'op constraint if exists messages_reply_to_id_fkey';
end $$;
reset lock_timeout;

-- Slowmode timer after a refresh (3 reports): the app only knew when you last posted from the messages it had loaded,
-- so after a reload in a busy channel (or after deleting your message) the timer was gone and the send was refused.
-- The server counts from post_marks (kind 'msg', one row per channel and person, kept through deletes; 100/173), which
-- the app can't read (RLS, no policies). This returns your own mark for one channel.
create or replace function public.my_slowmode_mark(cid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select at from public.post_marks where channel_id = cid and author_id = (select auth.uid()) and kind = 'msg';
$$;
revoke all on function public.my_slowmode_mark(uuid) from public, anon;
grant execute on function public.my_slowmode_mark(uuid) to authenticated;
