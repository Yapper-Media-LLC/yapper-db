-- 674, two things:
--
-- 1. Flag raw_mentions, Discord's "\" escape (suggestion by yakazt). \@user, \@role, \#channel and \:emoji: send the
--    token itself so bot devs can grab ids. The app stores it as <\@id>, <\@&id>, <\#id>, <\:name:id> and shows it as
--    code (<@id>). Every ping check in the database (push_on_message, fix_role_pings, @here, mention counts) looks for
--    a literal "<@", so these never ping: nothing to change for it here. Test: Antic and Yapper HQ.
--
-- 2. Bot role pings like Discord. fix_role_pings_bot (146) let a bot ping only roles anyone may @mention. Now a bot
--    with Mention @everyone in the channel (its roles, then the channel's overrides, like people) pings any role.
--    Automatic roles (everyone / joined before) still never ping from a bot, and the role_mentions flag still decides.
--    Only developer bots (public.bots) that are in the server: webhooks and the in-house accounts (bot_accounts:
--    starboard, logger, welcome...; starboard copies people's text, so a starred <@&role> must not ping) keep the old rule. The guards now pass the author; the two-argument form stays for anything else calling it.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('raw_mentions', 'Raw mentions', 'Typing \@user, \@role, \#channel or \:emoji: sends the raw token (<@id>) as code instead of a mention, like Discord. Never pings. Test: Antic and Yapper HQ',
        'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.fix_role_pings_bot(cid uuid, body text, uid uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare sid uuid; m text[]; tok text; r record; hit boolean; flag boolean; can_all boolean; out text := body;
begin
  if body is null or strpos(body, '<@&') = 0 then return body; end if;
  select c.server_id into sid from public.channels c where c.id = cid;
  flag := sid is not null and public.feature_on('role_mentions', sid);
  for m in select regexp_matches(body, '<@&([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>', 'g') loop
    tok := '<@&' || m[1] || '>';
    continue when strpos(out, tok) = 0; -- same role twice: already handled
    select translate(ro.name, '<>', '') as name, ro.mentionable, ro.auto into r from public.roles ro where ro.id = m[1]::uuid and ro.server_id = sid;
    hit := found;
    if flag and hit and coalesce(r.auto, 'none') = 'none' then
      continue when r.mentionable;
      -- Asked once per message, and only when a role isn't open to everyone.
      if can_all is null then
        can_all := uid is not null
          and coalesce(current_setting('yapper.webhook', true), '') <> '1'
          and exists (select 1 from public.bots b where b.id = uid)
          and exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid)
          and coalesce(public.channel_perm_of(uid, cid, 'mention_everyone', public.server_perm_user(sid, uid, 'mention_everyone')), false);
      end if;
      continue when can_all;
    end if;
    out := replace(out, tok, '@' || chr(8203) || case when hit then r.name else 'deleted-role' end);
  end loop;
  return out;
end $$;
revoke all on function public.fix_role_pings_bot(uuid, text, uuid) from public, anon, authenticated;

-- The old form: no author, so the old rule (mentionable, not automatic).
create or replace function public.fix_role_pings_bot(cid uuid, body text)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  return public.fix_role_pings_bot(cid, body, null::uuid);
end $$;
revoke all on function public.fix_role_pings_bot(uuid, text) from public, anon, authenticated;

-- The send and edit guards pass the author (a bot only edits its own messages, so old.author_id is the bot).
do $$ declare d text; begin
  if to_regprocedure('public.message_perm_guard()') is not null then
    d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
    if position('fix_role_pings_bot(new.channel_id, new.content, new.author_id)' in d) = 0 then
      d := replace(d, 'public.fix_role_pings_bot(new.channel_id, new.content)', 'public.fix_role_pings_bot(new.channel_id, new.content, new.author_id)');
      if position('fix_role_pings_bot(new.channel_id, new.content, new.author_id)' in d) = 0 then raise exception 'message_perm_guard patch did not apply'; end if;
      execute d;
    end if;
  end if;
  if to_regprocedure('public.message_edit_guard()') is not null then
    d := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
    if position('fix_role_pings_bot(old.channel_id, new.content, old.author_id)' in d) = 0 then
      d := replace(d, 'public.fix_role_pings_bot(old.channel_id, new.content)', 'public.fix_role_pings_bot(old.channel_id, new.content, old.author_id)');
      if position('fix_role_pings_bot(old.channel_id, new.content, old.author_id)' in d) = 0 then raise exception 'message_edit_guard patch did not apply'; end if;
      execute d;
    end if;
  end if;
end $$;

reset lock_timeout;
