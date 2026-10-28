-- 212: bot message limits that fit big bots. Re-runnable. Patches the live send functions in place.
--
-- Before: 30 messages a minute per bot across ALL servers (bot_api_send / bot_api_post, 103/119/147/149). A bot in
-- 400+ servers (Sapphire) kept hitting it and its command replies failed.
-- Now, checked by public.bot_send_gate before every bot message:
--   * per bot per server: 30 a minute (DMs: per DM). Keeps spam in one server in check. Counts every message.
--   * per bot overall: 30 a minute for unverified bots, 300 for verified ones (bots.verified_at is set).
--     Replies to a slash command or a button press don't count here (they still count per server):
--       - button / interaction answers: bot_interaction_respond marks the first 5 per press (yapper.bot_reply = '1');
--       - slash command replies: reply_to is a person's message (not a bot's or a webhook's) in the same channel, under 15 minutes
--         old, that starts with "/<a command this bot registered>". At most 5 free replies per command message,
--         after that they count like any other message.
-- The error keeps the "Slow down: ..." wording and says which limit was hit plus the wait, e.g.
--   "Slow down: 30 messages a minute in this server (try again in 12 s)" / "... 300 messages a minute overall ...".
-- The bot API turns the seconds into Retry-After.
--
-- How it counts: per server is exact (the bot's messages of the last minute, author index, at most a few hundred
-- rows). Overall uses a sliding-window counter on the bot's own row (bots.rate_min / rate_cur / rate_prev): the
-- row is locked by every send anyway (149: one send per bot at a time, so parallel sends can't slip through),
-- and replies that don't count simply don't add to it, so no per-message marker or log table is needed.

alter table public.bots add column if not exists rate_min timestamptz;
alter table public.bots add column if not exists rate_cur int not null default 0;
alter table public.bots add column if not exists rate_prev int not null default 0;

create or replace function public.bot_send_gate(bid uuid, cid uuid, reply uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bots;
  sid uuid;
  in_server int;
  oldest timestamptz;
  free_reply boolean := false;
  cap int;
  t timestamptz;
  bucket timestamptz;
  frac float8;
  cur int; prev int;
  est float8;
  wait int;
begin
  -- Lock the bot's own row first: one send per bot at a time (149), and the overall counter lives on it.
  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid returning * into b;
  if b.id is null then raise exception 'No such bot'; end if;
  -- The time after the lock, not the transaction start: a send that waited on the lock across a minute boundary
  -- must not write an older window back.
  t := clock_timestamp();
  bucket := date_trunc('minute', t);

  -- 1. Per server (per DM for DMs): every message counts.
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    select count(*), min(x.created_at) into in_server, oldest from (
      select m.created_at from public.messages m
       where m.channel_id = any (array(select c.id from public.channels c where c.server_id = sid))
         and m.author_id = bid and m.created_at > t - interval '1 minute'
       order by m.created_at desc limit 30) x;
  else
    select count(*), min(x.created_at) into in_server, oldest from (
      select m.created_at from public.messages m
       where m.channel_id = cid and m.author_id = bid and m.created_at > t - interval '1 minute'
       order by m.created_at desc limit 30) x;
  end if;
  if in_server >= 30 then
    wait := greatest(1, least(60, ceil(extract(epoch from (oldest + interval '1 minute' - t)))::int));
    raise exception 'Slow down: 30 messages a minute in this server (try again in % s)', wait using errcode = 'P0001';
  end if;

  -- 2. Overall, unless this answers a button press or a slash command.
  if current_setting('yapper.bot_reply', true) = '1' then
    free_reply := true;
  elsif reply is not null then
    select true into free_reply
      from public.messages u
     where u.id = reply and u.channel_id = cid and u.author_id <> bid
       and u.webhook is null and not public.is_bot_user(u.author_id)   -- a person's command, not another bot's
       and u.created_at > t - interval '15 minutes'
       and left(u.content, 1) = '/'
       and exists (select 1 from public.bot_commands c
                    where c.bot_id = bid and c.name = lower(substring(u.content from '^/([^\s/]+)')))
       and (select count(*) from public.messages r
             where r.reply_to_id = reply and r.author_id = bid and r.created_at > t - interval '15 minutes') < 5;
    free_reply := coalesce(free_reply, false);
  end if;
  if free_reply then return; end if;

  cap := case when b.verified_at is not null then 300 else 30 end;
  -- Roll the window: the minute before becomes "prev", older ones are forgotten.
  if b.rate_min is null or b.rate_min < bucket - interval '1 minute' then
    prev := 0; cur := 0;
  elsif b.rate_min < bucket then
    prev := b.rate_cur; cur := 0;
  else
    prev := b.rate_prev; cur := b.rate_cur;
  end if;
  frac := extract(epoch from (t - bucket)) / 60.0;
  est := prev * (1 - frac) + cur;
  if est >= cap then
    -- When the estimate drops under the cap: the previous minute's share fades out over this minute.
    if cur >= cap or prev = 0 then
      wait := ceil(extract(epoch from (bucket + interval '1 minute' - t)))::int;
    else
      wait := ceil(60.0 * (1 - (cap - cur)::float8 / prev) - frac * 60.0)::int;
    end if;
    wait := greatest(1, least(60, wait));
    raise exception 'Slow down: % messages a minute overall (try again in % s)', cap, wait using errcode = 'P0001';
  end if;
  update public.bots set rate_min = greatest(bucket, b.rate_min), rate_prev = prev, rate_cur = cur + 1 where id = bid;
end $$;
revoke all on function public.bot_send_gate(uuid, uuid, uuid) from public, anon, authenticated;

-- ---------- use it in the send functions ----------
do $$
declare
  src text; out text;
  old_send constant text := $a$  update public.bots set last_used_at = now(), posts = posts + 1 where id = bid;
  select count(*) into recent from public.messages where author_id = bid and created_at > now() - interval '1 minute';
  if recent >= 30 then raise exception 'Slow down: 30 messages a minute per bot' using errcode = 'P0001'; end if;
$a$;
  new_send constant text := $a$  -- 212: per-server and overall limits (verified bots get more, command replies don't count overall).
  perform public.bot_send_gate(bid, cid, reply);
$a$;
begin
  src := pg_get_functiondef('public.bot_api_send(uuid, uuid, text, uuid, jsonb, jsonb)'::regprocedure);
  if position('212:' in src) = 0 then
    out := replace(src, old_send, new_send);
    if out = src then raise exception '212: bot_api_send limit anchor not found, nothing patched'; end if;
    execute out;
  end if;

  src := pg_get_functiondef('public.bot_api_post(uuid, uuid, text, uuid)'::regprocedure);
  if position('212:' in src) = 0 then
    out := replace(src, old_send, new_send);
    if out = src then raise exception '212: bot_api_post limit anchor not found, nothing patched'; end if;
    execute out;
  end if;

  -- Button / interaction answers: mark the send so it doesn't count toward the overall cap.
  src := pg_get_functiondef('public.bot_interaction_respond(uuid, uuid, text, text, text, jsonb, jsonb, boolean, boolean)'::regprocedure);
  if position('212:' in src) = 0 then
    out := replace(src,
      $a$    msg := public.bot_api_send(bid, i.channel_id, body, null, p_embeds, p_components);
$a$,
      $a$    -- 212: the first 5 answers to a button press don't count toward the bot's overall limit (still per server).
    if i.replies <= 5 then perform set_config('yapper.bot_reply', '1', true); end if;
    msg := public.bot_api_send(bid, i.channel_id, body, null, p_embeds, p_components);
    perform set_config('yapper.bot_reply', '', true);
$a$);
    if out = src then raise exception '212: bot_interaction_respond send anchor not found, nothing patched'; end if;
    execute out;
  end if;
end $$;
