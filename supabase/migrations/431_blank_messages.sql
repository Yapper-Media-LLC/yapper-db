-- Blank messages (bug report Oct 23): the message box refuses empty text, and the database refuses '' and spaces
-- (messages_content_check), but text made only of invisible characters (zero-width space U+200B, Hangul filler U+3164,
-- direction marks, Braille blank...) went through a direct request and showed as an empty bubble. Edits too.
-- Live: 116 such messages in the last 60 days, nearly all Hangul filler walls.
--
-- A trigger, not a CHECK: only new messages and edits of the text are looked at, so existing rows aren't scanned and
-- an old blank row can still be pinned or otherwise updated. Messages with a file, embeds or buttons may have no text.
-- Safe to apply any time (no app change needed; the app already never sends these).

create or replace function public.messages_not_blank()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.attachment_path is null and new.embeds is null and new.components is null
     and coalesce(new.content, '') !~ '[^[:space:]\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u206f\u2800\u3164\ufe00-\ufe0f\ufeff\uffa0\U000e0000-\U000e007f]' then
    raise exception 'Type something first.' using errcode = 'check_violation';
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'messages_not_blank' and tgrelid = 'public.messages'::regclass) then
    create trigger messages_not_blank before insert or update of content on public.messages
      for each row execute function public.messages_not_blank();
  end if;
end $$;
