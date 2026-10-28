-- 148: command menu (flag command_menu). Typing "/" (or "!") in the chat box lists every command the
-- bots in this server know: bots' own registered commands, plus the built-in Helper and Giveaways
-- "!" commands when those bots are on in the server. Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('command_menu', 'Command menu', 'Type / or ! in the chat box to see every bot command in the server, built-in bots too, with how to use them', 'test',
   array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

create or replace function public.server_command_menu(sid uuid)
returns table(bot_name text, name text, description text, prefix text)
language sql stable security definer set search_path = public as $$
  select distinct on (prefix, name, case when prefix = '/' then bot_name end) * from (
    select b.name, c.name, coalesce(c.description, ''), '/'
      from public.bot_commands c
      join public.bots b on b.id = c.bot_id
      join public.bot_servers bs on bs.bot_id = c.bot_id and bs.server_id = sid
    union all
    select x.label, x.cmd, x.descr, '!'
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
  ) t(bot_name, name, description, prefix)
  where public.is_server_member(sid)
  order by prefix, name, case when prefix = '/' then bot_name end, bot_name;
$$;
revoke all on function public.server_command_menu(uuid) from public, anon;
grant execute on function public.server_command_menu(uuid) to authenticated;
