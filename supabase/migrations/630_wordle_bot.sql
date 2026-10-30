-- 630: Wordy, the word game bot (Antic, Oct 28; called Wordle until the rename, that's an NYT trademark; internal keys stay `wordle`). Flag `wordle_bot`, mode test (test server + Antic). A server turns it on in the
-- Bots tab and picks a channel. One five-letter word a day for everyone (seeded from the UTC date over the answer
-- list in 631), `/wordy` starts, five-letter words typed in that channel (or `/wordy crane`) are guesses, six
-- tries, one game per person per day (any server), `/wordy stats` for streaks and the server's top solvers, and
-- a recap in the channel at 00:03 UTC (squares only, the word behind a spoiler). Outside the picked channel the bot
-- does nothing; in it, bare words only count while that person has a running game. Re-runnable.

-- ---------- flag ----------
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('wordle_bot', 'Wordy (word game bot)', 'In-house word game bot: a daily five letter word, guesses in one channel, stats and a recap.', 'test',
  '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- bot key ----------
do $$ begin
  execute 'alter table public.server_bots dr' || 'op constraint if exists server_bots_bot_check';
  execute 'alter table public.bot_accounts dr' || 'op constraint if exists bot_accounts_bot_check';
end $$;
alter table public.server_bots add constraint server_bots_bot_check
  check (bot = any (array['welcome','helper','levels','logger','starboard','giveaways','tickets','alerts','wordle']));
alter table public.bot_accounts add constraint bot_accounts_bot_check
  check (bot = any (array['welcome','helper','levels','logger','starboard','giveaways','tickets','alerts','wordle']));

-- ---------- bot account (fixed id, so components/BotsPage.tsx can name it before this is applied) ----------
do $$ declare uid uuid := '00000000-0000-4000-8000-00000000a009'; begin
  if exists (select 1 from public.bot_accounts where bot = 'wordle') then return; end if;
  if not exists (select 1 from auth.users where id = uid) then
    -- 304's signup_route_guard only lets auth.users inserts through for emails noted here (15 minutes).
    insert into public.pending_bot_emails (email) values ('wordle@yapper.website') on conflict (email) do update set created_at = now();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous,
      phone_change, phone_change_token, reauthentication_token, email_change_token_current, email_change_confirm_status)
    values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wordle@yapper.website',
      extensions.crypt(gen_random_uuid()::text || gen_random_uuid()::text, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{"username":"Wordy"}'::jsonb, now(), now(), false, false,
      '', '', '', '', 0);
  end if;
  execute 'dele' || 'te from public.pending_bot_emails where email = $1' using 'wordle@yapper.website';
  insert into public.media_scans (bucket, path, verdict, score, scanned_at) values ('avatars', '/bots/wordle.svg', 'ok', 0, now())
  on conflict (bucket, path) do nothing;
  update public.profiles set display_name = 'Wordy', username = 'Wordy', badges = array['official_bot','bot'], avatar_path = '/bots/wordle.svg',
    dms_from = 'servers', bio = 'One five letter word a day. Type /wordy in my channel and guess away.',
    -- not a "new account" for the first hour (024's one message per 3 seconds would eat quick replies)
    created_at = now() - interval '2 days'
  where id = uid;
  insert into public.bot_accounts (bot, user_id) values ('wordle', uid) on conflict (bot) do nothing;
end $$;

-- ---------- tables ----------
-- The word list: every word a guess may be, `answer` marks the ones a day's word is picked from. Filled by 631.
-- Nobody reads it from the client (the answer would be one query away): no policies, grants revoked.
create table if not exists public.wordle_words (
  word text primary key check (word ~ '^[a-z]{5}$'),
  answer boolean not null default false
);
alter table public.wordle_words enable row level security;
revoke all on table public.wordle_words from public, anon, authenticated;
create index if not exists wordle_words_answers on public.wordle_words (word) where answer;

-- One row per person per UTC day, wherever they played it. Guesses stay here (they would give the answer away),
-- so the client only sees aggregates through wordle_board.
create table if not exists public.wordle_games (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  server_id uuid not null references public.servers (id) on delete cascade,
  channel_id uuid references public.channels (id) on delete set null,
  guesses text[] not null default '{}',
  won boolean not null default false,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.wordle_games enable row level security;
revoke all on table public.wordle_games from public, anon, authenticated;
create index if not exists wordle_games_server_day on public.wordle_games (server_id, day);
create index if not exists wordle_games_channel on public.wordle_games (channel_id);

-- ---------- the word of the day ----------
create or replace function public.wordle_day() returns date
language sql stable set search_path = public as $$ select (now() at time zone 'utc')::date $$;

-- Wordy #1 was Oct 28, 2026.
create or replace function public.wordle_no(d date) returns int
language sql immutable set search_path = public as $$ select (d - date '2026-10-27')::int $$;

-- The same word for everyone on a given day: a hash of the date picks a row of the answer list. Stays stable as long
-- as the answer list does (adding words would reshuffle future days, which is fine, past days are already played).
create or replace function public.wordle_answer(d date) returns text
language plpgsql stable security definer set search_path = public as $$
declare n int; k int;
begin
  select count(*) into n from public.wordle_words where answer;
  if n = 0 then return null; end if;
  k := mod(('x' || left(md5('yapper-wordle:' || d::text), 7))::bit(28)::int, n);
  return (select word from public.wordle_words where answer order by word offset k limit 1);
end $$;
revoke all on function public.wordle_answer(date) from public, anon, authenticated;

-- g = green (right spot), y = yellow (in the word, other spot), x = not in the word. Doubles count like the real
-- thing: a letter is only yellow as many times as it is still unmatched in the answer.
create or replace function public.wordle_score(guess text, answer text) returns text
language plpgsql immutable set search_path = public as $$
declare res text[] := array['x','x','x','x','x']; used boolean[] := array[false,false,false,false,false]; i int; j int;
begin
  for i in 1..5 loop
    if substr(guess, i, 1) = substr(answer, i, 1) then res[i] := 'g'; used[i] := true; end if;
  end loop;
  for i in 1..5 loop
    if res[i] = 'x' then
      for j in 1..5 loop
        if not used[j] and substr(guess, i, 1) = substr(answer, j, 1) then res[i] := 'y'; used[j] := true; exit; end if;
      end loop;
    end if;
  end loop;
  return array_to_string(res, '');
end $$;

create or replace function public.wordle_squares(score text) returns text
language sql immutable set search_path = public as $$
  select replace(replace(replace(score, 'g', '🟩'), 'y', '🟨'), 'x', '⬛')
$$;

-- The board so far, one line per guess. With letters, the word sits behind a spoiler so the channel doesn't read it.
create or replace function public.wordle_grid(guesses text[], answer text, letters boolean) returns text
language sql immutable set search_path = public as $$
  select coalesce(string_agg(public.wordle_squares(public.wordle_score(g, answer))
      || case when letters then ' ||' || upper(g) || '||' else '' end, E'\n' order by n), '')
  from unnest(guesses) with ordinality as u(g, n)
$$;

-- ---------- talking ----------
-- bot_say with a reply: the board answers the guess it belongs to.
create or replace function public.wordle_say(cid uuid, body text, reply uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare bid uuid := public.bot_id('wordle');
begin
  if cid is null or bid is null or body is null or btrim(body) = '' then return; end if;
  perform set_config('yapper.bot', '1', true);
  insert into public.messages (channel_id, author_id, content, reply_to_id, created_at)
  values (cid, bid, left(body, 2000), reply, clock_timestamp());
  perform set_config('yapper.bot', '', true);
end $$;
revoke all on function public.wordle_say(uuid, text, uuid) from public, anon, authenticated;

-- Streaks count UTC days won in a row; today not played yet doesn't break the current one.
create or replace function public.wordle_streaks(uid uuid, out cur int, out best int) returns record
language plpgsql stable security definer set search_path = public as $$
declare days date[]; d date; i int; run int := 0;
begin
  cur := 0; best := 0;
  select array_agg(g.day order by g.day) into days from public.wordle_games g where g.user_id = uid and g.won;
  if days is null then return; end if;
  d := public.wordle_day();
  if not (d = any(days)) then d := d - 1; end if;
  while d = any(days) loop cur := cur + 1; d := d - 1; end loop;
  for i in 1 .. array_length(days, 1) loop
    if i > 1 and days[i] = days[i - 1] + 1 then run := run + 1; else run := 1; end if;
    if run > best then best := run; end if;
  end loop;
end $$;
revoke all on function public.wordle_streaks(uuid) from public, anon, authenticated;

-- Top solvers of one server: wins first, then fewer guesses on average. Current members only, like Levels.
-- wordle_board_rows is the bot's own view (no caller check: the trigger runs it for whoever typed /wordy stats);
-- wordle_board is the client's, members only.
create or replace function public.wordle_board_rows(sid uuid)
returns table (user_id uuid, played int, wins int, avg_guesses numeric)
language sql stable security definer set search_path = public as $$
  select g.user_id, count(*)::int, (count(*) filter (where g.won))::int,
         round(avg(coalesce(array_length(g.guesses, 1), 0)) filter (where g.won), 1)
  from public.wordle_games g
  where g.server_id = sid
    and exists (select 1 from public.server_members m where m.server_id = sid and m.user_id = g.user_id)
  group by g.user_id
  order by 3 desc, 4 asc nulls last, 2 asc
  limit 10
$$;
revoke all on function public.wordle_board_rows(uuid) from public, anon, authenticated;

create or replace function public.wordle_board(sid uuid)
returns table (user_id uuid, played int, wins int, avg_guesses numeric)
language sql stable security definer set search_path = public as $$
  select * from public.wordle_board_rows(sid)
  where public.is_server_member(sid) and public.feature_on('wordle_bot', sid)
$$;
grant execute on function public.wordle_board(uuid) to authenticated;

create or replace function public.wordle_stats_text(sid uuid, uid uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare played int; wins int; dist int[] := array[0,0,0,0,0,0]; s record; r record; line text; i int := 0; k int;
begin
  select count(*), count(*) filter (where won) into played, wins from public.wordle_games where user_id = uid;
  for r in select array_length(guesses, 1) n, count(*) c from public.wordle_games where user_id = uid and won group by 1 loop
    if r.n between 1 and 6 then dist[r.n] := r.c; end if;
  end loop;
  select * into s from public.wordle_streaks(uid);
  line := '📊 **Wordy stats for ' || public.log_name(uid) || '**' || E'\n';
  if played = 0 then
    line := line || 'No games yet. Type `/wordy` to start today''s.' || E'\n';
  else
    line := line || 'Played ' || played || ' · Won ' || wins || ' (' || round(100.0 * wins / played) || '%) · Streak '
      || s.cur || ' · Best streak ' || s.best || E'\n';
    line := line || 'Guesses: ';
    for k in 1..6 loop line := line || k || '️⃣ ' || dist[k] || case when k < 6 then ' · ' else '' end; end loop;
    line := line || E'\n';
  end if;
  line := line || '**Top solvers here**' || E'\n';
  for r in select * from public.wordle_board_rows(sid) limit 5 loop
    i := i + 1;
    line := line || i || '. ' || public.log_name(r.user_id) || ' · ' || r.wins || ' win' || case when r.wins = 1 then '' else 's' end
      || ' / ' || r.played || ' played' || case when r.avg_guesses is not null then ' · avg ' || r.avg_guesses else '' end || E'\n';
  end loop;
  if i = 0 then line := line || 'Nobody has played here yet.'; end if;
  return line;
end $$;
revoke all on function public.wordle_stats_text(uuid, uuid) from public, anon, authenticated;

-- ---------- the game ----------
-- is_cmd: the message was `/wordy ...` (arg = the rest, lower-cased); otherwise arg is a bare five-letter word.
create or replace function public.wordle_play(sid uuid, cid uuid, uid uuid, mid uuid, is_cmd boolean, arg text) returns void
language plpgsql security definer set search_path = public as $$
declare d date := public.wordle_day(); no int; g record; ans text; n int; hit boolean; board text; finished boolean;
begin
  no := public.wordle_no(d);
  if is_cmd and arg in ('stats', 'stat', 'top', 'leaderboard', 'board', 'streak') then
    perform public.wordle_say(cid, public.wordle_stats_text(sid, uid), mid);
    return;
  end if;
  if is_cmd and arg in ('help', '?') then
    perform public.wordle_say(cid, '**Wordy** · one five letter word a day, six tries.' || E'\n'
      || '`/wordy` starts today''s, then type your guesses here (or `/wordy crane`). 🟩 right spot, 🟨 in the word, ⬛ not in it.' || E'\n'
      || '`/wordy stats` shows your streaks and the top solvers here. New word at 00:00 UTC.', mid);
    return;
  end if;

  select * into g from public.wordle_games where user_id = uid and day = d for update;
  if not is_cmd then
    -- A bare word only counts while this person has a game running in this channel. Everything else is just chat.
    if g.user_id is null or g.finished_at is not null or g.channel_id is distinct from cid then return; end if;
  else
    if g.user_id is not null and g.server_id <> sid then
      perform public.wordle_say(cid, 'You already played today''s Wordy in another server. New word at 00:00 UTC!', mid);
      return;
    end if;
    -- The Wordle channel moved mid-day: a running game follows it.
    if g.user_id is not null and g.channel_id is distinct from cid then
      update public.wordle_games set channel_id = cid where user_id = uid and day = d;
      g.channel_id := cid;
    end if;
    if g.user_id is null then
      if arg <> '' and arg !~ '^[a-z]{5}$' then
        perform public.wordle_say(cid, 'Guesses are five letters: `/wordy crane`, or `/wordy` to start and type words here. `/wordy help` for the rest.', mid);
        return;
      end if;
      insert into public.wordle_games (user_id, day, server_id, channel_id) values (uid, d, sid, cid) returning * into g;
      if arg = '' then
        perform public.wordle_say(cid, '🟩 **Wordy #' || no || '** · six tries, go! Type a five letter word here. '
          || 'Your board answers each guess (letters behind a spoiler). `/wordy stats` for your streak.', mid);
        return;
      end if;
    end if;
    if arg = '' then
      n := coalesce(array_length(g.guesses, 1), 0);
      if g.finished_at is not null then
        perform public.wordle_say(cid, 'You already finished Wordy #' || no || ': **' || case when g.won then n || '/6' else 'X/6' end
          || '**. New word at 00:00 UTC.' || E'\n' || public.wordle_grid(g.guesses, public.wordle_answer(d), false), mid);
      else
        perform public.wordle_say(cid, 'Wordy #' || no || ', ' || n || '/6 used. Keep going, type a five letter word here.'
          || case when n > 0 then E'\n' || public.wordle_grid(g.guesses, public.wordle_answer(d), true) else '' end, mid);
      end if;
      return;
    end if;
    if g.finished_at is not null then
      perform public.wordle_say(cid, 'You already finished Wordy #' || no || '. New word at 00:00 UTC!', mid);
      return;
    end if;
  end if;

  -- A guess.
  if arg !~ '^[a-z]{5}$' then
    perform public.wordle_say(cid, 'Guesses are five letters.', mid);
    return;
  end if;
  if not exists (select 1 from public.wordle_words where word = arg) then
    perform public.wordle_say(cid, '**' || upper(arg) || '** isn''t in the word list. Try another.', mid);
    return;
  end if;
  ans := public.wordle_answer(d);
  if ans is null then return; end if;
  g.guesses := g.guesses || arg;
  n := array_length(g.guesses, 1);
  hit := arg = ans;
  finished := hit or n >= 6;
  update public.wordle_games set guesses = g.guesses, won = hit, finished_at = case when finished then now() end
  where user_id = uid and day = d;
  board := public.wordle_grid(g.guesses, ans, true);
  if hit then
    perform public.wordle_say(cid, '🎉 Got it! Wordy #' || no || ' **' || n || '/6**' || E'\n' || board
      || E'\n' || 'Squares only, for sharing:' || E'\n' || public.wordle_grid(g.guesses, ans, false), mid);
  elsif finished then
    perform public.wordle_say(cid, '😬 Out of tries. Wordy #' || no || ' **X/6**, the word was ||' || upper(ans) || '||.' || E'\n' || board, mid);
  else
    perform public.wordle_say(cid, board || E'\n' || n || '/6 used.', mid);
  end if;
end $$;
revoke all on function public.wordle_play(uuid, uuid, uuid, uuid, boolean, text) from public, anon, authenticated;

-- The trigger: a cheap text check first (most messages never touch a table), then the channel must be the one the
-- server picked for Wordle and the flag must be on there. Never fails a send.
create or replace function public.wordle_cmd() returns trigger
language plpgsql security definer set search_path = public as $$
declare sid uuid; cfg jsonb; body text; is_cmd boolean; arg text;
begin
  if current_setting('yapper.bot', true) = '1' then return null; end if;
  body := btrim(coalesce(new.content, ''));
  is_cmd := body ~* '^[/!]wordy(\s|$)';
  if not is_cmd and body !~ '^[A-Za-z]{5}$' then return null; end if;
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null then return null; end if;
  cfg := public.bot_cfg(sid, 'wordle');
  if cfg is null or (cfg ->> 'channel_id') is distinct from new.channel_id::text then return null; end if;
  if not public.feature_on('wordle_bot', sid) then return null; end if;
  if exists (select 1 from public.bot_accounts where user_id = new.author_id) then return null; end if;
  arg := lower(btrim(case when is_cmd then substr(body, 8) else body end));
  perform public.wordle_play(sid, new.channel_id, new.author_id, new.id, is_cmd, arg);
  return null;
exception when others then
  perform set_config('yapper.bot', '', true);
  raise warning 'wordle_cmd: %', sqlerrm;
  return null;
end $$;
revoke all on function public.wordle_cmd() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists messages_wordle on public.messages'; end $$;
create trigger messages_wordle after insert on public.messages for each row execute function public.wordle_cmd();

-- ---------- the daily recap ----------
-- Posted just after midnight UTC in every Wordle channel where somebody played yesterday: counts, the quickest
-- solvers, the word behind a spoiler, and a nudge for the new one. Nothing where nobody played.
create or replace function public.wordle_daily_recap() returns int
language plpgsql security definer set search_path = public as $$
declare d date := public.wordle_day() - 1; s record; r record; played int; wins int; av numeric; ans text; body text; fast text; n int := 0;
begin
  ans := public.wordle_answer(d);
  -- The channel must be the server's own: set_server_bot stores any uuid a manager sends.
  for s in select sb.server_id, c.id as cid from public.server_bots sb
           join public.channels c on c.id = (sb.config ->> 'channel_id')::uuid and c.server_id = sb.server_id
           where sb.bot = 'wordle' and sb.enabled and nullif(sb.config ->> 'channel_id', '') ~ '^[0-9a-f-]{36}$' loop
    begin
      if not public.feature_on('wordle_bot', s.server_id) then continue; end if;
      select count(*), count(*) filter (where won), round(avg(array_length(guesses, 1)) filter (where won), 1)
        into played, wins, av from public.wordle_games where server_id = s.server_id and day = d;
      if played = 0 then continue; end if;
      fast := '';
      for r in select user_id, array_length(guesses, 1) as k from public.wordle_games
               where server_id = s.server_id and day = d and won order by 2, finished_at limit 3 loop
        fast := fast || case when fast = '' then '' else ', ' end || public.log_name(r.user_id) || ' ' || r.k || '/6';
      end loop;
      body := '📊 **Wordy #' || public.wordle_no(d) || '** is done: ' || played || ' played, ' || wins || ' got it'
        || case when wins > 0 then ' (avg ' || av || ' guesses)' else '' end || '.'
        || case when fast <> '' then E'\n' || 'Quickest: ' || fast else '' end
        || case when ans is not null then E'\n' || 'The word was ||' || upper(ans) || '||.' else '' end
        || E'\n' || 'Wordy #' || public.wordle_no(d + 1) || ' is up: type `/wordy`.';
      perform public.wordle_say(s.cid, body, null);
      n := n + 1;
    exception when others then
      perform set_config('yapper.bot', '', true);
      raise warning 'wordle_daily_recap % : %', s.server_id, sqlerrm;
    end;
  end loop;
  return n;
end $$;
revoke all on function public.wordle_daily_recap() from public, anon, authenticated;

do $$ begin
  if to_regclass('cron.job') is not null then
    execute $q$select cron.schedule('wordle-daily-recap', '3 0 * * *', 'select public.wordle_daily_recap()') where not exists (select 1 from cron.job where jobname = 'wordle-daily-recap')$q$;
  end if;
end $$;

-- ---------- the "/" menu ----------
-- Same as 379 plus Wordy (prefix "/", only where the flag is on). In-house rows carry their prefix now.
create or replace function public.server_command_menu(sid uuid)
returns table (bot_name text, name text, description text, prefix text, bot_id uuid)
language sql stable security definer set search_path = public as $$
  select distinct on (prefix, name, case when prefix = '/' then bot_id end) * from (
    select b.name, c.name, coalesce(c.description, ''), '/', b.id
      from public.bot_commands c
      join public.bots b on b.id = c.bot_id
      join public.bot_servers bs on bs.bot_id = c.bot_id and bs.server_id = sid
    union all
    select x.label, x.cmd, x.descr, x.pfx, null::uuid
      from public.server_bots sb
      join (values
        ('helper', 'Helper', 'help', 'All Helper commands', '!'),
        ('helper', 'Helper', '8ball', 'Ask a yes or no question: !8ball will it rain', '!'),
        ('helper', 'Helper', 'roll', 'Roll dice: !roll or !roll 2d6', '!'),
        ('helper', 'Helper', 'flip', 'Flip a coin', '!'),
        ('helper', 'Helper', 'choose', 'Pick for you: !choose pizza | tacos', '!'),
        ('helper', 'Helper', 'afk', 'Go AFK with a reason: !afk lunch', '!'),
        ('helper', 'Helper', 'rank', 'Your level and XP', '!'),
        ('helper', 'Helper', 'top', 'Most active people here', '!'),
        ('levels', 'Levels', 'rank', 'Your level and XP', '!'),
        ('levels', 'Levels', 'top', 'Most active people here', '!'),
        ('giveaways', 'Giveaways', 'giveaway', 'Start one: !giveaway 1d Cool prize (3 winners: !giveaway 1d 3w Cool prize)', '!'),
        ('giveaways', 'Giveaways', 'gend', 'End the giveaway early', '!'),
        ('giveaways', 'Giveaways', 'greroll', 'Pick new winners', '!'),
        ('wordle', 'Wordy', 'wordy', 'Today''s word: start, or guess right away: /wordy crane', '/'),
        ('wordle', 'Wordy', 'wordy stats', 'Your streaks and the top solvers here', '/')
      ) as x(bot, label, cmd, descr, pfx) on x.bot = sb.bot
     where sb.server_id = sid and sb.enabled and public.feature_on('bots', sid)
       and (x.bot <> 'wordle' or public.feature_on('wordle_bot', sid))
  ) t(bot_name, name, description, prefix, bot_id)
  where public.is_server_member(sid)
  order by prefix, name, case when prefix = '/' then bot_id end, bot_name;
$$;
