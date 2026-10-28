-- ============================================================
-- Yapper · Stage 4 · Edit and delete messages
-- ============================================================

alter table public.messages add column edited_at timestamptz;

-- Only the text of a message can change. Everything else stays put,
-- and any edit is stamped so the "(edited)" label can't be dodged.
create or replace function public.message_edit_guard()
returns trigger
language plpgsql
as $$
begin
  new.id := old.id;
  new.channel_id := old.channel_id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  if new.content is distinct from old.content then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end;
$$;
create trigger messages_edit_guard
  before update on public.messages
  for each row execute function public.message_edit_guard();

create policy "edit your own messages"
  on public.messages for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());

create policy "delete your own messages"
  on public.messages for delete to authenticated
  using (author_id = auth.uid());
