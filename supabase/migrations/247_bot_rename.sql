-- 247: bot owners can change their bot's username (flag bot_rename, test = Antic only).
-- app/api/bots/route.ts PATCH {id, name} does the checks (format, bad_name, verified creators' names, staff names,
-- a free #tag with bot_tags) and the writes with the service role, so the profile triggers that only guard
-- signed-in users don't see it. renamed_at is the 7-day cooldown (username_changes is cleared after 2 days).
-- Re-runnable.
alter table public.bots add column if not exists renamed_at timestamptz;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('bot_rename', 'Rename bots', 'Bot owners can change their bot''s username in Settings > Developer (once a week)', 'test',
        '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- The writes, in one transaction (review): the bot row is locked so two renames can't both pass the cooldown or
-- leave profiles.username/discriminator and bots.name/tag from different renames; verified bots can't be renamed
-- (their badge was reviewed for the old name); the old username is held for 7 days like a person's (246), so nobody
-- can grab a known bot's name the moment it changes. Names are checked by the route first (pickBotUsername), and
-- the profile triggers that run for every role (no_bad_names, no_slurs, profile_custom_guard) check again.
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
  if b.verified_at is not null then
    raise exception 'Verified bots can''t be renamed. Ask Yapper staff if it needs a new name.';
  end if;
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
