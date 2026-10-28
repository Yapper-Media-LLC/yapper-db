-- ============================================================
-- Yapper · Stage 5 · Sending pictures
-- ============================================================

alter table public.messages
  add column attachment_path text,
  add column attachment_width int check (attachment_width between 1 and 20000),
  add column attachment_height int check (attachment_height between 1 and 20000),
  add constraint messages_attachment_path_check
    check (attachment_path is null or attachment_path like author_id::text || '/%');

-- A message needs text, a picture, or both.
alter table public.messages drop constraint messages_content_check;
alter table public.messages add constraint messages_content_check
  check (char_length(content) <= 4000 and (char_length(btrim(content)) > 0 or attachment_path is not null));

-- Edits can change the text but never swap the picture.
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
  if new.content is distinct from old.content then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end;
$$;

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', true, 10485760, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

create policy "attachments: read own folder"
  on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "attachments: upload to own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "attachments: delete own folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);
