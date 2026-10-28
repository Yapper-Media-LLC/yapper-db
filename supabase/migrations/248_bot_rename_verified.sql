-- 248: verified bots can be renamed too (Antic, Oct 18). They keep the badge; the same name checks as any bot apply
-- (route: bad, staff and verified creators' names), once a week, and the old username is held for 7 days.
-- Re-runnable (create or replace).
create or replace function public.bot_rename(p_bot uuid, p_name text, p_username text, p_tag text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bots%rowtype;
  old_username text;
  old_display text;
begin
  select * into b from public.bots where id = p_bot for update;
  if not found then raise exception 'That bot is gone'; end if;
  if b.renamed_at is not null and b.renamed_at > now() - interval '7 days' then
    raise exception 'Bots can be renamed once a week. Try again on %.', to_char(b.renamed_at + interval '7 days', 'Mon FMDD');
  end if;
  select username, display_name into old_username, old_display from public.profiles where id = p_bot for update;
  update public.profiles
     set username = p_username,
         discriminator = p_tag,
         -- The display name follows when it was still the old name; one the owner picked stays.
         display_name = case when display_name is null or display_name = b.name then p_name else display_name end
   where id = p_bot;
  update public.bots set name = p_name, tag = p_tag, renamed_at = now() where id = p_bot;
  if old_username is not null and lower(old_username) <> lower(p_username) then
    insert into public.username_holds (name_key, user_id, until) values (lower(old_username), p_bot, now() + interval '7 days')
    on conflict (name_key) do update set user_id = excluded.user_id, until = excluded.until;
  end if;
  return jsonb_build_object('name', p_name, 'tag', p_tag, 'username', p_username);
end $$;

revoke all on function public.bot_rename(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.bot_rename(uuid, text, text, text) to service_role;
