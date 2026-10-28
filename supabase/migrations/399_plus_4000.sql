-- 399: Yapper Plus members can send messages up to 4000 characters (flag plus_4000, test). Everyone else stays at
-- 2000. message_length() (018) is the gatekeeper; it only looks up the author's profile when the text is over 2000,
-- so ordinary messages cost nothing extra. Edits count too (the trigger runs on update of content). Bots and webhooks
-- keep their own 2000 cut (left(body, 2000) in the API functions) and their profiles have no Plus anyway.
-- Re-runnable.
create or replace function public.message_length()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n int; lim int := 2000;
begin
  n := char_length(regexp_replace(new.content, '<a?:([A-Za-z0-9_]{2,32}):[0-9a-f-]{36}>', ':\1:', 'g'));
  -- The stored form of a custom emoji (<:name:uuid>) is far longer than what was typed; the table's hard cap is on
  -- the stored text, so say so before it fails as a bare constraint error.
  if char_length(new.content) > 4000 then
    raise exception 'That message is too long with those custom emojis in it. Trim it a bit' using errcode = 'check_violation';
  end if;
  -- An edit that doesn't make the message longer always goes through: a 3000-character message sent on Plus can
  -- still have a typo fixed after Plus runs out.
  if tg_op = 'UPDATE' and n <= char_length(regexp_replace(old.content, '<a?:([A-Za-z0-9_]{2,32}):[0-9a-f-]{36}>', ':\1:', 'g')) then
    return new;
  end if;
  if n > 2000 and public.feature_on_for_me('plus_4000')
     and exists (select 1 from public.profiles p where p.id = new.author_id and p.plus_until > now()) then
    lim := 4000;
  end if;
  if n > lim then
    raise exception 'Messages can be up to % characters', lim using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function public.message_length() from public, anon, authenticated;

-- Test: Antic and the "test" server.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('plus_4000', 'Plus: 4000 character messages', 'Yapper Plus members can send and edit messages up to 4000 characters (free stays at 2000)', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
