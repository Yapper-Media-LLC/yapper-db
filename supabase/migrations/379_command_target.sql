-- 379: flag command_target (Oct 22). Two bots with the same slash command (/fish, /inventory) both answered every
-- use of it. Picking a command in the "/" menu that another bot also has now adds that bot's mention
-- ("/fish @BotSandwich"), and bot_webhooks gives the command only to that bot: it gets command/args as usual (its
-- mention taken out of args). Every other bot still gets the message (nothing is hidden from mod or log bots), but
-- the ones that also know /fish get it without command/args and with command_for = [the picked bot]; the SDKs
-- (yapper.js / yapper.py) then don't run their /fish. Copies of the SDK from before this still read the text and
-- answer: their owners download it again. Only a mention right after the command counts, and only for a bot that
-- can see the channel. No such mention, or flag off: as before. Test: Antic and HQ.
--   * server_command_menu also returns bot_id (null for the built-in "!" ones) so the menu knows whose it is, and
--     keeps two bots that share a display name apart. Return type changes: dropped and made again, same grants.
-- Re-runnable. Functions only.
set lock_timeout = '3s';
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('command_target', 'Command for one bot', 'When two bots have the same slash command, the menu picks one and only that bot answers', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'server_command_menu'
               and pg_get_function_result(p.oid) not like '%bot_id%') then
    execute 'dr' || 'op function public.server_command_menu(uuid)';
  end if;
end $$;

create or replace function public.server_command_menu(sid uuid)
returns table(bot_name text, name text, description text, prefix text, bot_id uuid)
language sql stable security definer set search_path = public as $$
  select distinct on (prefix, name, case when prefix = '/' then bot_id end) * from (
    select b.name, c.name, coalesce(c.description, ''), '/', b.id
      from public.bot_commands c
      join public.bots b on b.id = c.bot_id
      join public.bot_servers bs on bs.bot_id = c.bot_id and bs.server_id = sid
    union all
    select x.label, x.cmd, x.descr, '!', null::uuid
      from public.server_bots sb
      join (values
        ('helper', 'Helper', 'help', 'All Helper commands'),
        ('helper', 'Helper', '8ball', 'Ask a yes or no question: !8ball will it rain'),
        ('helper', 'Helper', 'roll', 'Roll dice: !roll or !roll 2d6'),
        ('helper', 'Helper', 'flip', 'Flip a coin'),
        ('helper', 'Helper', 'choose', 'Pick for you: !choose pizza | tacos'),
        ('helper', 'Helper', 'afk', 'Go AFK with a reason: !afk lunch'),
        ('helper', 'Helper', 'rank', 'Your level and XP'),
        ('helper', 'Helper', 'top', 'Most active people here'),
        ('levels', 'Levels', 'rank', 'Your level and XP'),
        ('levels', 'Levels', 'top', 'Most active people here'),
        ('giveaways', 'Giveaways', 'giveaway', 'Start one: !giveaway 1d Cool prize (3 winners: !giveaway 1d 3w Cool prize)'),
        ('giveaways', 'Giveaways', 'gend', 'End the giveaway early'),
        ('giveaways', 'Giveaways', 'greroll', 'Pick new winners')
      ) as x(bot, label, cmd, descr) on x.bot = sb.bot
     where sb.server_id = sid and sb.enabled and public.feature_on('bots', sid)
  ) t(bot_name, name, description, prefix, bot_id)
  where public.is_server_member(sid)
  order by prefix, name, case when prefix = '/' then bot_id end, bot_name;
$$;
revoke all on function public.server_command_menu(uuid) from public, anon;
grant execute on function public.server_command_menu(uuid) to authenticated;

-- Live text (119 + 144/202 patches), plus the target.
create or replace function public.bot_webhooks()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare live boolean; sid uuid; b record; chname text; priv boolean; payload jsonb; cmd text; args text; m text[];
  targets uuid[]; has_cmd boolean; my_args text;
begin
  select server_id, name, private into sid, chname, priv from public.channels where id = new.channel_id;
  if sid is null then return null; end if;
  if not exists (select 1 from public.bot_servers bs where bs.server_id = sid) then return null; end if;
  m := regexp_match(coalesce(new.content, ''), '^[/!]([a-z0-9_-]{1,32})(?:\s+([\s\S]*))?$', 'i');
  if m is not null then cmd := lower(m[1]); args := coalesce(btrim(m[2]), ''); end if;
  -- Flag command_target: "/fish <@bot> ..." is for that bot when it has /fish here, not every bot that has it.
  if cmd is not null and args like '<@%' and public.feature_on('command_target', sid) then
    select array_agg(c.bot_id) into targets
      from public.bot_commands c join public.bot_servers bs on bs.bot_id = c.bot_id and bs.server_id = sid
     where c.name = cmd and starts_with(args, '<@' || c.bot_id::text || '>')
       and (not (coalesce(priv, false) or public.channel_overrides_live(new.channel_id)) or public.bot_channel_visible(c.bot_id, new.channel_id));
  end if;
  payload := jsonb_build_object(
    'id', new.id, 'channel_id', new.channel_id, 'channel_name', chname, 'server_id', sid, 'author_id', new.author_id,
    'author', (select username from public.profiles where id = new.author_id),
    'content', new.content, 'attachment', new.attachment_path, 'reply_to_id', new.reply_to_id, 'created_at', new.created_at,
    'author_bot', new.webhook is not null or public.is_bot_user(new.author_id));
  live := public.channel_overrides_live(new.channel_id);
  for b in select bo.id, bo.webhook_url, bo.webhook_secret from public.bot_servers bs join public.bots bo on bo.id = bs.bot_id
           where bs.server_id = sid and bo.id <> new.author_id loop
    if (coalesce(priv, false) or live) and not public.bot_channel_visible(b.id, new.channel_id) then continue; end if;
    has_cmd := cmd is not null and exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name = cmd);
    my_args := args;
    if targets is not null and has_cmd then
      if b.id = any(targets) then my_args := btrim(substr(args, length(b.id::text) + 4));
      else has_cmd := false; end if;  -- another bot's /fish: the message, not the command
    end if;
    perform public.bot_push(b.id, b.webhook_url, b.webhook_secret, 'message',
      payload || jsonb_build_object('mentioned', coalesce(new.content, '') like '%<@' || b.id::text || '>%')
              || case when has_cmd then jsonb_build_object('command', cmd, 'args', my_args) else '{}'::jsonb end
              || case when targets is not null then jsonb_build_object('command_for', to_jsonb(targets)) else '{}'::jsonb end);
  end loop;
  return null;
end $function$;
reset lock_timeout;
