-- 502: Shards for each linked account (Antic, Oct 25: "a good amount of shards for connecting Steam, AniList, Trakt and
-- Last.fm"). The one "Link an account" quest (25, any one link) becomes four, 50 each (75 with Plus): Steam, AniList,
-- Trakt and Last.fm. Last.fm only counts when verified through its sign-in (media_links.verified, 467), so it pays once
-- that sign-in ships. Whoever claimed the old "connect" quest keeps it. shard_quest_list and shard_quest_met are 468's
-- text with the change; nothing else. Functions only, re-runnable.

create or replace function public.shard_quest_list()
returns table (key text, kind text, reward int, title text, how text, pos int)
language sql immutable set search_path = public as $$
  values
    ('chats3',   'daily', 10, 'Talk in 3 chats',          'Send a message in 3 different chats today', 1),
    ('react3',   'daily',  5, 'React to 3 messages',      'React to 3 messages from other people today', 2),
    ('reply',    'daily',  5, 'Reply to someone',         'Reply to someone else''s message today', 3),
    ('profile',  'once',  25, 'Make your profile yours',  'Add an avatar and an About me', 4),
    ('friend',   'once',  25, 'Make a friend',            'Have a friend request accepted, or accept one', 5),
    ('servers3', 'once',  25, 'Join 3 servers',           'Be in 3 servers at once', 6),
    ('deco',     'once',  15, 'Dress up your avatar',     'Wear an avatar decoration', 7),
    ('steam',    'once',  50, 'Link Steam',               'Link your Steam account on your profile', 8),
    ('anilist',  'once',  50, 'Link AniList',             'Link your AniList account on your profile', 9),
    ('trakt',    'once',  50, 'Link Trakt',               'Link your Trakt account on your profile', 10),
    ('lastfm',   'once',  50, 'Link Last.fm',             'Sign in with Last.fm on your profile', 11),
    ('mfa',      'once',  50, 'Lock it down',             'Turn on two-factor sign-in', 12);
$$;

-- Is quest p_key done by uid right now (for today, for the daily ones)?
create or replace function public.shard_quest_met(uid uuid, p_key text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare day_start timestamptz := ((now() at time zone 'utc')::date::timestamp at time zone 'utc');
begin
  return case p_key
    when 'chats3' then (select count(distinct channel_id) >= 3 from (select channel_id from public.messages
                         where author_id = uid and created_at >= day_start order by created_at desc limit 300) x)
    -- Only on other people's messages: reacting to or replying to yourself doesn't count.
    when 'react3' then (select count(*) >= 3 from (select 1 from public.reactions r join public.messages m on m.id = r.message_id
                         where r.user_id = uid and r.created_at >= day_start and m.author_id <> uid limit 3) x)
    when 'reply' then exists (select 1 from (select reply_to_id from public.messages
                         where author_id = uid and created_at >= day_start and reply_to_id is not null
                         order by created_at desc limit 300) x
                         join public.messages p on p.id = x.reply_to_id where p.author_id <> uid)
    when 'profile' then exists (select 1 from public.profiles where id = uid
                         and avatar_path is not null and length(btrim(coalesce(bio, ''))) > 0)
    when 'friend' then exists (select 1 from public.friendships where requester = uid and status = 'accepted')
                    or exists (select 1 from public.friendships where addressee = uid and status = 'accepted')
    when 'servers3' then (select count(*) >= 3 from (select 1 from public.server_members where user_id = uid limit 3) x)
    when 'deco' then exists (select 1 from public.profiles where id = uid and avatar_deco is not null)
    -- One per service. Steam (OpenID), AniList and Trakt (OAuth) are proven by signing in; a Last.fm link counts only
    -- once it's verified through Last.fm's sign-in (467), since a typed-in username could be anyone's.
    when 'steam' then exists (select 1 from public.steam_links where user_id = uid)
    when 'anilist' then exists (select 1 from public.media_links where user_id = uid and source = 'anilist')
    when 'trakt' then exists (select 1 from public.media_links where user_id = uid and source = 'trakt')
    when 'lastfm' then exists (select 1 from public.media_links where user_id = uid and source = 'lastfm' and verified is true)
    when 'mfa' then exists (select 1 from auth.mfa_factors where user_id = uid and status = 'verified')
    else false end;
end; $$;
revoke execute on function public.shard_quest_met(uuid, text) from public, anon, authenticated;
