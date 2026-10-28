-- 325: three live false positives from the 20 Oct bug reports. Functions only, no tables, no triggers. Re-runnable.
--
--  1. Slur filter (has_slur_plain): "chicken egg rolls", "queen egg arena", "green egg arena", "hen egg raw" were refused as
--     slurs. The glued check (spaces removed) also held the "negg..." spellings, so any "...n egg r/a/er..." across two
--     words matched. Those spellings are now read inside one word, or from the START of a word with at most a space between
--     their letters ("neg ger", "n e g g e r", "xxneggerxx" still caught). "rock n egg rolls" still matches (rare). The
--     glued check for the "nigg" spellings is unchanged.
--  2. Sexual content filter (has_sexual_spam): a server's own rules ("No porn, no nudes, no onlyfans") were refused as
--     sexual spam (report 0553428f). Rules are now read with server_watch_unneg (249), the same negation cutter the server
--     watch uses, but ONLY when the message shows no sign of an ad (sexual_ad_signal): no link, @handle, price, payment/chat
--     app name, buying or contact words ("buy", "order", "cheap", "dm me", "snap", "hmu"...), and no "free" / "sell" /
--     "promo" unless a rule forbids that word itself ("no selling", "no free nudes", "feel free to ask").
--     So "No bots, free porn" and "No minors, dm me for porn" are still blocked. What can still slip through: a bare list of
--     explicit words that opens with a negator and has no contact, price or buying word ("Don't miss porn nudes onlyfans").
--     That has nothing to act on. Rules that also contain a link or a buying word are still refused. The old function body is
--     kept as has_sexual_spam_raw (not callable by users).
--  3. Bot "What we check" (bot_verify_progress): "was online in the last 7 days" counted last_event_at, which is stamped
--     when an event is QUEUED for the bot (any bot sitting in a server gets it), so a bot that never connected showed
--     as online (d5116494). Online now means it polled for events or posted: last_poll_at / last_used_at.

-- 1 ---------------------------------------------------------------------------------------------------------------
create or replace function public.has_slur_plain(t text)
 returns boolean language sql immutable set search_path to 'public', 'extensions'
as $function$
  select
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*|n+g+a+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i+n+k+s*|c+o+o+n+s*|d+y+k+e+s*|n+i+g+s*) '
    )
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|f+a+g+g+[oei]+t+'
    -- The "negg" spellings: anywhere inside ONE word (the pattern has no space, so it can't reach across words), or from the
    -- start of a word with at most one space between letters ("neg ger"). "chicken egg rolls" is neither: the n sits inside
    -- "chicken" and a space follows it.
    or public.slur_text(t) ~ 'n+e+g+g+(e+r+|r+e*|a+)'
    or public.slur_text(t) ~ '\mn+ ?e+ ?g+ ?g+ ?(e+ ?r+|r+ ?e*|a+)'
    or (
      (' ' || regexp_replace(lower(unaccent(public.fold_fancy(t))), '[*#@$%&!?_.\-]+', '', 'g') || ' ')
        ~ (' (n[iy]*g+g*(a+|e+r+|a+h+|e+t+)?|f[a]*g+g*(o+t+|e+t+|i+t+)?'
           || '|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a*n+n+(y+|i+e+)s*'
           || '|r+e*t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*|c+h+i*n+k+s*|c+o+o+n+s*|d+y+k+e+s*) ')
      and lower(coalesce(t, '')) ~ '[*#@$%&!?_.\-]'
    );
$function$;

-- 2 ---------------------------------------------------------------------------------------------------------------
-- The old body, unchanged, under a name users can't call.
create or replace function public.has_sexual_spam_raw(t text)
 returns boolean language sql immutable set search_path to 'public', 'extensions'
as $function$
  with s as (select ' ' || public.slur_text(coalesce(t, '')) || ' ' as x),
  hits as (
    select count(distinct m[1]) n from s, regexp_matches(replace(s.x, ' ', ''),
      '(p[uv*t]ss(y|ie)|dildo|vibrator|porn|onlyfans|nudes|hentai|blowjob|handjob|cumshot|cumslut|sexting|fleshlight|buttplug|strapon|creampie|deepthroat|camgirl|sexcam|sextape|lube|durex)', 'g') m
  )
  select coalesce((select n from hits), 0) >= 2
      or (coalesce((select n from hits), 0) >= 1
          and (select x from s) ~ ' (order|orders|buy|buying|sell|selling|sale|free|cheap|discount|price|prices|shop|store|dm|dms|link|links|telegram|snap|snapchat|cashapp|paypal|sponsored|promo|deal|deals) ');
$function$;
revoke all on function public.has_sexual_spam_raw(text) from public, anon, authenticated;

-- Words rules use against ads ("sell", "free", "promo"): fine when a rule forbids that very word ("no selling or ads", "no
-- advertising or selling", "no self promo", "no selling, promo or ads", "selling is not allowed", "no free nudes") and in
-- "feel free to ask"; anywhere else they count ("No bots, free porn"). Only a short list of rule-ish words may sit between
-- the negator and the soft word (joined by or / and, never a comma), and "free" never continues a list. Lower case text.
create or replace function public.sexual_soft_word(x text)
 returns boolean language sql immutable set search_path to 'public', 'extensions'
as $function$
  select regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(x, ''),
               '\m(no|not|never|dont|don[’'' ]?t|do not|without|zero)\M[ \t]+(((any|all|the|more|kind of|kinds of|type of|types of|spam|spamming|ads?|advertising|advertisements?|advertise|scams?|scamming|self|begging|beg|asking|ask|trading|trades?|buying|for|of)[ \t]+((or|and)[ \t]+)?)*(self[ \t-]*)?(selling|sell|free|promo|promotions?)\M(([ \t]*[,/&][ \t]*((or|and)[ \t]+)?|[ \t]+(or|and)[ \t]+|[ \t]+)(self[ \t-]*)?(selling|sell|promo|promotions?|ads?|advertising|spam|spamming|trading|scamming|buying)\M)*|((any|all|the|more|kind of|kinds of|type of|types of|spam|spamming|ads?|advertising|advertisements?|advertise|scams?|scamming|self|begging|beg|asking|ask|trading|trades?|buying|for|of)([ \t]*[,/&][ \t]*((or|and)[ \t]+)?|[ \t]+(or|and)[ \t]+))+(self[ \t-]*)?(selling|sell|promo|promotions?)\M(([ \t]*[,/&][ \t]*((or|and)[ \t]+)?|[ \t]+(or|and)[ \t]+|[ \t]+)(self[ \t-]*)?(selling|sell|promo|promotions?|ads?|advertising|spam|spamming|trading|scamming|buying)\M)*(?=[ \t]*([.!?;\n]|$)))',
               ' ', 'g'),
             '\m(sell|selling|free|promo|promotions?)\M[^.!?\n]{0,15}\m(not allowed|not permitted|banned|prohibited|forbidden)\M', ' ', 'g'),
           '\m(feel free|free to|free of|free speech)\M', ' ', 'g')
         ~ '\m(sell|selling|free|promo|promotions?)\M';
$function$;
revoke all on function public.sexual_soft_word(text) from public, anon, authenticated;

-- Is there any sign this is an ad and not a rule? (links, handles, money, apps, buying / contact words)
create or replace function public.sexual_ad_signal(t text)
 returns boolean language sql immutable set search_path to 'public', 'extensions'
as $function$
  select
    -- In the text as written. Mentions and @everyone are not handles.
    regexp_replace(coalesce(t, ''), '<[@#&][^>]*>|@everyone|@here', ' ', 'g')
      ~* '(https?://|www\.|t\.me/|@[a-z0-9_.]{3,}|[$€£] ?[0-9]|[0-9] ?[$€£]|[0-9] ?(usd|eur|gbp|bucks|dollars?|euros?|quid|pounds?|btc|pesos)|telegram|snapchat|cashapp|whatsapp|paypal|venmo|zelle|instagram|tiktok|twitter|(insta|ig|kik|discord|tg|wickr|signal|tele|snap) ?:|discord ?\. ?gg)'
    -- A bare domain or invite (discord.gg/x, example.com, bit.ly/x, EXAMPLE.COM). Endings that are also plain words (to, me,
    -- co, chat, live...) only count in lower case or ALL CAPS, so "porn.To keep" typed without a space isn't one.
    or coalesce(t, '') ~* '[a-z0-9-]+\.(gg|com|net|org|io|xyz|ly|ru|cc|tv|ee|xxx|ai|sex|porn|wtf|ws|fm|sh)\M'
    or coalesce(t, '') ~ '[a-z0-9-]+\.(me|to|co|us|link|app|club|site|online|shop|top|store|ink|adult|fun|lol|vip|live|cam|chat|bio)\M'
    or coalesce(t, '') ~ '[A-Z0-9-]+\.(ME|TO|CO|US|LINK|APP|CLUB|SITE|ONLINE|SHOP|TOP|STORE|INK|ADULT|FUN|LOL|VIP|LIVE|CAM|CHAT|BIO)\M'
    -- Buying and contact words, in folded text so b.u.y and fr33 count too.
    or (' ' || public.slur_text(t) || ' ') ~ ' (buy|buying|order|orders|ordering|cheap|discount|price|prices|deal|deals|sale|shop|store|snap|sponsored|hmu|(dm|pm|msg|message|text|add|inbox|contact|whisper|kik|ping|friend|tele|tg|insta|ig) (me|us|for)|hit me up|dms open|friend request|cash ?app|apple ?pay|google ?pay|revolut|usdc|crypto|gift ?cards?|robux|(five|ten|twenty|fifty|hundred) (bucks|dollars)|links? (in|on) (my )?(bio|profile|page|description)|(in|on|check|see|look at) my (bio|profile|page|status|server|insta|snap|tele)|click (here|the link)) '
    -- "dm" on its own is an ad unless it points at the mods ("DM a mod") or a rule is talking about DMs ("no unsolicited DMs",
    -- "don't DM members", "no dm advertising", "report problems via DM"). Plain "via dm" is an ad ("porn nudes via dm").
    or regexp_replace(
         regexp_replace(' ' || public.slur_text(t) || ' ',
           ' dm (a|an|the|any|our|your|one of the)( one of the)? (mods?|admins?|staff|moderators?) ', ' ', 'g'),
         ' ((no|dont|don t|do not|never|without|report|stop) (unsolicited |unwanted |random |mass |spam |advertising |ads )*(dm|dms|dming)|report(ing)? ([a-z]+ ){0,3}via (dm|dms)|(dm|dms|dming) (advertising|ads|spam|spamming)) ', ' ', 'g') ~ ' (dm|dms) '
    -- The soft words, read both as written (commas keep "No bots, free porn" apart) and folded (fr33).
    or public.sexual_soft_word(lower(coalesce(t, '')))
    or public.sexual_soft_word(' ' || public.slur_text(t) || ' ');
$function$;
revoke all on function public.sexual_ad_signal(text) from public, anon, authenticated;

-- Security definer so it can call server_watch_unneg and the helpers (not granted to users). It only returns a boolean for
-- its input.
create or replace function public.has_sexual_spam(t text)
 returns boolean language sql immutable security definer set search_path to 'public', 'extensions'
as $function$
  select public.has_sexual_spam_raw(t)
    and (
      -- Any sign of an ad: judged as it always was.
      public.sexual_ad_signal(t)
      -- Otherwise, if explicit words are still left once negated mentions are cut out ("No porn", "porn is not
      -- allowed"), it is not a rule.
      or public.has_sexual_spam_raw(public.server_watch_unneg(translate(lower(coalesce(t, '')), '@$0', 'aso')))
    );
$function$;
-- Only message_automod() (security definer, runs as the owner) calls it, so users don't need it as an RPC. Keeping it
-- callable by them would be a new "security definer function executable by authenticated" advisor entry for no reason.
revoke all on function public.has_sexual_spam(text) from public, anon, authenticated;

-- 3 ---------------------------------------------------------------------------------------------------------------
create or replace function public.bot_verify_progress(bid uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare b public.bots;
begin
  select * into b from public.bots where id = bid and owner_id = auth.uid();
  if b.id is null then raise exception 'Bot not found'; end if;
  return jsonb_build_object(
    'servers', (select count(*) from public.bot_servers bs where bs.bot_id = b.id),
    'real_servers', (select count(*) from public.bot_servers bs join public.servers s on s.id = bs.server_id
                      where bs.bot_id = b.id and s.owner_id <> b.owner_id and s.member_count >= 3),
    'need_servers', 3,
    'has_avatar', exists (select 1 from public.profiles p where p.id = b.id and p.avatar_path is not null),
    'commands', (select count(*) from public.bot_commands c where c.bot_id = b.id),
    -- It connected (polled for events) or it posted. last_event_at is "an event was queued for it", not activity.
    'online', coalesce(greatest(b.last_poll_at, b.last_used_at) > now() - interval '7 days', false),
    'description_ok', char_length(btrim(coalesce(b.description, ''))) >= 20
  );
end $function$;
