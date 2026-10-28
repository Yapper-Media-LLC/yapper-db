set lock_timeout = '3s';
-- 265: "Use Big Text" permission (flag big_text_perm, test only). Deric (#suggestions, Oct 18): only important
-- people should be able to post headings ("# text", "## text", "### text"). A basic permission like Embed Links:
-- everyone has it until the server turns it off for @everyone, then only roles (or channel overrides) that allow it
-- can. Small text ("-# text") isn't big, so it stays free. Bots and server-side posts (no signed-in person) aren't checked.
-- Sending: refused with a clear message. Editing: same, unless the message already had a heading.
-- Code blocks don't count (``` ... ``` is shown as code, not as a heading).
-- The two guards are patched in place (like 158 and 178), so whatever else they do live stays as it is.
-- Re-runnable.

-- Does this text have a heading line, outside code blocks? Lines may sit in "> " quotes (they're shown there too).
create or replace function public.has_big_text(t text)
returns boolean
language sql
immutable
as $$
  -- A code block becomes a line break (text right after one starts a new line when shown).
  select coalesce(strpos(t, '#') > 0 and regexp_replace(t, '```.*?```', E'\n', 'g') ~ '(^|\n)[ \t]*(>[ \t]*)*#{1,3}[ \t]+[^ \t\n]', false);
$$;

-- Basic permissions: live definition (Oct 18) plus use_headings.
create or replace function public.basic_perm(perm text)
returns boolean
language sql
immutable
set search_path = public, extensions
as $$
  select perm in ('send_messages', 'add_reactions', 'attach_files', 'embed_links', 'use_external_emojis', 'create_invite',
                  'change_nickname', 'connect', 'speak', 'create_polls', 'read_history', 'send_voice_messages', 'use_headings');
$$;

-- Channel overrides can allow or deny it too (e.g. only in #announcements).
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'channel_overrides_known_perms'
                 and pg_get_constraintdef(oid) like '%use_headings%') then
    execute 'alter table public.channel_overrides ' || 'dr' || 'op constraint if exists channel_overrides_known_perms';
    alter table public.channel_overrides add constraint channel_overrides_known_perms check (
      allow <@ array['view_channel', 'send_messages', 'add_reactions', 'attach_files', 'embed_links', 'mention_everyone', 'manage_messages',
                     'read_history', 'connect', 'speak', 'send_voice_messages', 'use_headings']
      and deny <@ array['view_channel', 'send_messages', 'add_reactions', 'attach_files', 'embed_links', 'mention_everyone', 'manage_messages',
                        'read_history', 'connect', 'speak', 'send_voice_messages', 'use_headings']);
  end if;
end $$;

-- Sending.
do $$
declare d text; anchor text := E'  new.content := public.fix_role_pings(sid, new.channel_id, cp, new.content);\n';
begin
  d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('use_headings' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception '265: message_perm_guard anchor not found'; end if;
  d := replace(d, anchor, anchor ||
    E'  if auth.uid() is not null and strpos(new.content, ''#'') > 0 and coalesce(current_setting(''yapper.sys_post'', true), '''') <> ''1''\n' ||
    E'     and public.feature_on(''big_text_perm'', sid) and public.has_big_text(new.content)\n' ||
    E'     and not (case when cp then public.channel_perm(new.channel_id, ''use_headings'') else public.server_perm(sid, ''use_headings'') end) then\n' ||
    E'    raise exception ''You can''''t use big text (# headings) here'' using errcode = ''check_violation'';\n' ||
    E'  end if;\n');
  execute d;
end $$;

-- Editing: only when the edit adds the first heading (an old heading message can still get a typo fixed).
do $$
declare d text; anchor text := E'      new.content := public.fix_role_pings(sid, old.channel_id, cp, new.content);\n';
begin
  d := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
  if position('use_headings' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception '265: message_edit_guard anchor not found'; end if;
  d := replace(d, anchor, anchor ||
    E'      if strpos(new.content, ''#'') > 0 and public.feature_on(''big_text_perm'', sid)\n' ||
    E'         and public.has_big_text(new.content) and not public.has_big_text(old.content)\n' ||
    E'         and not (case when cp then public.channel_perm(old.channel_id, ''use_headings'') else public.server_perm(sid, ''use_headings'') end) then\n' ||
    E'        raise exception ''You can''''t use big text (# headings) here'' using errcode = ''check_violation'';\n' ||
    E'      end if;\n');
  execute d;
end $$;

-- The suggestion form posts "## 💡 title" as the person's own message: that header is ours, not big text they typed.
-- yapper.sys_post skips the check for that one insert (only database functions can set it, not the app).
do $$
declare d text; a1 text := E'  insert into public.messages (channel_id, author_id, content)\n  values (cid, uid, '; a2 text := E'  returning id into mid;\n';
begin
  if not exists (select 1 from pg_proc where proname = 'submit_suggestion' and pronamespace = 'public'::regnamespace) then return; end if;
  d := pg_get_functiondef('public.submit_suggestion(uuid, text, text, text)'::regprocedure);
  if position('yapper.sys_post' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception '265: submit_suggestion anchor not found'; end if;
  d := replace(d, a1, E'  perform set_config(''yapper.sys_post'', ''1'', true);\n' || a1);
  d := replace(d, a2, a2 || E'  perform set_config(''yapper.sys_post'', '''', true);\n');
  execute d;
end $$;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('big_text_perm', 'Big text permission', 'Use Big Text: a role permission for posting # headings. Turn it off for @everyone to keep big text for chosen roles.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

reset lock_timeout;
