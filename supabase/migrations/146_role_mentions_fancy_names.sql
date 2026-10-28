-- 146: role pings (flag role_mentions) and fancy channel / category names (flag fancy_names). Re-runnable.
--  * roles.mentionable: "Let anyone @mention this role". People with Mention @everyone can ping any role.
--  * Messages store role pings as <@&role id>. The send / edit guards turn pings someone isn't allowed to
--    make into plain "@name" text (like @everyone gets a zero-width space).
--  * Who got pinged is worked out at read time (unread_counts_v2, my_mentions) against the reader's own
--    roles (my_role_pings): no row per role member on insert (big servers have 28k members).
--  * Fancy names: Unicode fonts, symbols and emoji in channel / category names when the flag is on for the
--    server. Slur and bad-name checks now look at an NFKC-folded form (fancy letters back to ASCII), for
--    every name and message, so fonts can't sneak slurs through. Categories get the same checks as channels.

set lock_timeout = '5s';

-- Indexes: built by hand with CONCURRENTLY (they can't run inside a transaction, and a plain build
-- would block message writes on a big table). Done live on Oct 16; repeat by hand on a fresh database:
--   create index concurrently if not exists messages_pingy_idx on public.messages (channel_id, created_at desc)
--     where strpos(content, '<@') > 0 or strpos(content, '@everyone') > 0;
--   create index concurrently if not exists roles_server_id_idx on public.roles (server_id);

insert into public.feature_flags (key, label, description, mode, servers, users)
values
  ('role_mentions', 'Role mentions', 'Ping roles with @role, like Discord. Roles get a "Let anyone @mention this role" switch.', 'test',
   array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[]),
  ('fancy_names', 'Fancy channel names', 'Fonts, symbols and emoji in channel and category names (like ┃・𝓰𝓮𝓷𝓮𝓻𝓪𝓵).', 'test',
   array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

-- roles has table-level grants (no column grants), so the new column is readable / writable like the rest.
alter table public.roles add column if not exists mentionable boolean not null default false;

-- ===================================================================================================
-- Fancy letters back to plain ASCII, for the slur / bad-name checks
-- ===================================================================================================
-- NFKC handles math fonts (𝓰 𝐠 𝔤 𝕘), fullwidth, circled (ⓖ), superscripts, ligatures, squared (🄶).
-- First invisible characters and combining marks are deleted (not turned into spaces, so ch\u2063ink
-- stays one word), then the map turns what NFKC leaves alone into the Latin letter it looks like:
-- small caps, regional indicators, negative circled / squared letters, Greek capitals, Armenian,
-- Lisu and Cherokee look-alikes (Cherokee small forms too, since lower() makes those).
create or replace function public.fold_fancy(t text)
returns text language sql immutable parallel safe set search_path = public as $$
  select translate(
    regexp_replace(normalize(coalesce(t, ''), NFKC),
      '[\u00ad\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u115f\u1160\u17b4\u17b5\u180b-\u180f\u1ab0-\u1aff\u1dc0-\u1dff\u200b-\u200f\u202a-\u202e\u2060-\u206f\u20d0-\u20ff\u2800\u3164\ufe00-\ufe0f\ufe20-\ufe2f\ufeff\uffa0\U000e0000-\U000e007f\U000e0100-\U000e01ef]',
      '', 'g'),
    'ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘǫʀꜱᴛᴜᴠᴡʏᴢ🇦🇧🇨🇩🇪🇫🇬🇭🇮🇯🇰🇱🇲🇳🇴🇵🇶🇷🇸🇹🇺🇻🇼🇽🇾🇿🅐🅑🅒🅓🅔🅕🅖🅗🅘🅙🅚🅛🅜🅝🅞🅟🅠🅡🅢🅣🅤🅥🅦🅧🅨🅩🅰🅱🅲🅳🅴🅵🅶🅷🅸🅹🅺🅻🅼🅽🅾🅿🆀🆁🆂🆃🆄🆅🆆🆇🆈🆉ΑΒΕΖΗΙΚΜΝΟΡΤΥΧոռսօհցզꓐꓑꓓꓔꓖꓗꓙꓚꓜꓝꓟꓠꓡꓢꓣꓦꓧꓪꓫꓬꓮꓰꓲꓳꓴᎪꭺᏴᏼᏟꮯᎠꭰᎬꭼᏀꮐᎻꮋᏂꮒᎥꭵᏆꮖᎫꭻᏦꮶᏞꮮᎷꮇᏢꮲᎡꭱᏒꮢᏚꮪᏕꮥᎢꭲᏙꮩᎳꮃᎩꭹᏃꮓᏏꮟ',
    'abcdefghijklmnopqrstuvwyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabezhikmnoptyxnnuohgqbpdtgkjczfmnlsrvhwxyaeiouaabbccddeegghhhhiiiijjkkllmmpprrrrssssttvvwwyyzzbb');
$$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.slur_text(text)'::regprocedure);
  if position('fold_fancy' in d) = 0 then
    d := replace(d, 'regexp_replace(coalesce(t, ''''),', 'regexp_replace(public.fold_fancy(t),');
    if position('fold_fancy' in d) = 0 then raise exception 'slur_text patch did not apply'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.has_slur(text)'::regprocedure);
  -- 273 split has_slur into has_slur_plain (which has the fold_fancy call) and has_slur; nothing to patch after that
  if position('fold_fancy' in d) = 0 and to_regprocedure('public.has_slur_plain(text)') is null then
    d := replace(d, 'lower(unaccent(coalesce(t, '''')))', 'lower(unaccent(public.fold_fancy(t)))');
    if position('fold_fancy' in d) = 0 then raise exception 'has_slur patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- ===================================================================================================
-- Fancy names
-- ===================================================================================================
-- Removes invisible / control characters (keeps the zero-width joiner, VS16 and flag tags emoji need),
-- collapses any kind of space, and wipes combining marks entirely when there are lots of them (zalgo;
-- the zalgo triggers still strip runs of 3+ on top of this).
-- Tag characters only survive inside a flag (🏴 + tags + cancel tag), so a name can't be made of
-- invisible tags; a name with nothing visible left (only joiners, VS16, marks) counts as empty.
create or replace function public.fancy_clean_name(t text)
returns text language sql immutable parallel safe set search_path = public as $$
  select case when regexp_replace(coalesce(x, ''), '[\u200d\ufe0f\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20e2\u20e4-\u20ff\ufe20-\ufe2f[:space:]]', '', 'g') = '' then null else x end
  from (select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(
    case when char_length(t) - char_length(regexp_replace(t, '[\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20e2\u20e4-\u20ff\ufe20-\ufe2f]', '', 'g')) > 8
         then regexp_replace(t, '[\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20e2\u20e4-\u20ff\ufe20-\ufe2f]', '', 'g')
         else t end,
    '[\u0001-\u001f\u007f-\u009f\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b\u200c\u200e\u200f\u202a-\u202e\u2060-\u206f\u2800\u3164\ufe00-\ufe0e\ufeff\uffa0\ufff0-\ufffb\U000e0001\U000e0100-\U000e01ef]', '', 'g'),
    '(\U0001f3f4[\U000e0020-\U000e007e]+\U000e007f)|[\U000e0020-\U000e007f]', '\1', 'g'),
    '[[:space:]\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+', ' ', 'g')), '') as x) y;
$$;

-- Text channels: like Discord, lower case, spaces become dashes, no ASCII punctuation but - and _.
-- Everything else (any script, math fonts, small caps, ┃ ・ ✦ ★, emoji) stays.
create or replace function public.fancy_channel_slug(t text)
returns text language sql immutable parallel safe set search_path = public as $$
  select case when regexp_replace(coalesce(s, ''), '[-_]', '', 'g') = '' then null else s end
  from (select left(regexp_replace(lower(replace(public.fancy_clean_name(t), ' ', '-')), '[][!"#$%&''()*+,./:;<=>?@\\^`{|}~]', '', 'g'), 100) as s) x;
$$;

create or replace function public.channel_fancy_name()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.server_id is null or new.name is null or not public.feature_on('fancy_names', new.server_id) then return new; end if;
  new.name := case when new.kind = 'voice' then left(public.fancy_clean_name(new.name), 100) else public.fancy_channel_slug(new.name) end;
  if new.name is null then raise exception 'Channels need a name'; end if;
  return new;
end $$;
-- Runs before channels_no_bad_names / channels_no_slurs / channels_zalgo (triggers fire in name order).
create or replace trigger channels_fancy_name before insert or update of name on public.channels
  for each row execute function public.channel_fancy_name();

create or replace function public.category_fancy_name()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.name is null or not public.feature_on('fancy_names', new.server_id) then return new; end if;
  new.name := left(public.fancy_clean_name(new.name), 40);
  if new.name is null then raise exception 'Categories need a name'; end if;
  return new;
end $$;
create or replace trigger channel_categories_fancy_name before insert or update of name on public.channel_categories
  for each row execute function public.category_fancy_name();
-- Categories had no name checks at all; same ones as channels now.
create or replace trigger channel_categories_no_bad_names before insert or update of name on public.channel_categories
  for each row execute function public.no_bad_names('name');
create or replace trigger channel_categories_no_slurs before insert or update of name on public.channel_categories
  for each row execute function public.no_slurs('name');
create or replace trigger channel_categories_zalgo before insert or update of name on public.channel_categories
  for each row execute function public.names_strip_zalgo();

-- create_channel slugified before the trigger saw the name (losing ┃ ・ and friends).
do $$ declare d text; begin
  d := pg_get_functiondef('public.create_channel(uuid, text, text)'::regprocedure);
  if position('fancy_names' in d) = 0 then
    d := replace(d, 'n := public.slugify_channel(channel_name);',
      'n := case when public.feature_on(''fancy_names'', sid) then public.fancy_channel_slug(channel_name) else public.slugify_channel(channel_name) end;');
    if position('fancy_names' in d) = 0 then raise exception 'create_channel patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- ===================================================================================================
-- Role pings
-- ===================================================================================================
-- Keeps <@&id> for roles of this server that are mentionable, or for anyone with Mention @everyone
-- (channel overrides respected, like @everyone). Everything else becomes plain, non-pinging "@name".
-- Runs before the @everyone check, so a role called "everyone" can't turn into an @everyone ping.
-- Automatic roles (everyone / joined before) reach lots of people at once, so they always need
-- Mention @everyone, like @everyone itself. The plain text leaves out < and > so a role name can't
-- smuggle in a <@user> token. With no server (DMs, groups) every role token becomes text.
create or replace function public.fix_role_pings(sid uuid, cid uuid, cp boolean, body text)
returns text language plpgsql stable security definer set search_path = public as $$
declare m text[]; tok text; r record; hit boolean; can_all boolean; flag boolean; out text := body;
begin
  if body is null or strpos(body, '<@&') = 0 then return body; end if;
  flag := sid is not null and public.feature_on('role_mentions', sid);
  for m in select regexp_matches(body, '<@&([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>', 'g') loop
    tok := '<@&' || m[1] || '>';
    continue when strpos(out, tok) = 0; -- same role twice: already handled
    select translate(ro.name, '<>', '') as name, ro.mentionable, ro.auto into r from public.roles ro where ro.id = m[1]::uuid and ro.server_id = sid;
    hit := found;
    if flag and hit then
      continue when r.mentionable and coalesce(r.auto, 'none') = 'none';
      if can_all is null then
        can_all := coalesce(case when cp then public.channel_perm(cid, 'mention_everyone') else public.server_perm(sid, 'mention_everyone') end, false);
      end if;
      continue when can_all;
    end if;
    out := replace(out, tok, '@' || chr(8203) || case when hit then r.name else 'deleted-role' end);
  end loop;
  return out;
end $$;
revoke all on function public.fix_role_pings(uuid, uuid, boolean, text) from public, anon, authenticated;

-- Bots (yapper.bot = 1) skip the permission guards; their role pings only keep roles of this server
-- that anyone may ping and that aren't automatic. Everything else becomes text.
create or replace function public.fix_role_pings_bot(cid uuid, body text)
returns text language plpgsql stable security definer set search_path = public as $$
declare sid uuid; m text[]; tok text; r record; hit boolean; flag boolean; out text := body;
begin
  if body is null or strpos(body, '<@&') = 0 then return body; end if;
  select c.server_id into sid from public.channels c where c.id = cid;
  flag := sid is not null and public.feature_on('role_mentions', sid);
  for m in select regexp_matches(body, '<@&([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>', 'g') loop
    tok := '<@&' || m[1] || '>';
    continue when strpos(out, tok) = 0;
    select translate(ro.name, '<>', '') as name, ro.mentionable, ro.auto into r from public.roles ro where ro.id = m[1]::uuid and ro.server_id = sid;
    hit := found;
    continue when flag and hit and r.mentionable and coalesce(r.auto, 'none') = 'none';
    out := replace(out, tok, '@' || chr(8203) || case when hit then r.name else 'deleted-role' end);
  end loop;
  return out;
end $$;
revoke all on function public.fix_role_pings_bot(uuid, text) from public, anon, authenticated;

do $$ declare d text; begin
  d := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('fix_role_pings(sid' in d) = 0 then
    d := replace(d, $a$  if new.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'$a$,
      $a$  new.content := public.fix_role_pings(sid, new.channel_id, cp, new.content);
  if new.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'$a$);
    if position('fix_role_pings(sid' in d) = 0 then raise exception 'message_perm_guard patch did not apply'; end if;
  end if;
  -- bots: the strict check before their early return
  if position('fix_role_pings_bot' in d) = 0 then
    d := replace(d, $a$  if current_setting('yapper.bot', true) = '1' then return new; end if;$a$,
      $a$  if current_setting('yapper.bot', true) = '1' then new.content := public.fix_role_pings_bot(new.channel_id, new.content); return new; end if;$a$);
    if position('fix_role_pings_bot' in d) = 0 then raise exception 'message_perm_guard bot patch did not apply'; end if;
  end if;
  -- DMs and groups: no roles there, so every role token becomes text
  if position('fix_role_pings(null' in d) = 0 then
    d := replace(d, $a$  if sid is null then return new; end if;$a$,
      $a$  if sid is null then new.content := public.fix_role_pings(null, new.channel_id, false, new.content); return new; end if;$a$);
    if position('fix_role_pings(null' in d) = 0 then raise exception 'message_perm_guard DM patch did not apply'; end if;
  end if;
  execute d;

  d := pg_get_functiondef('public.message_edit_guard()'::regprocedure);
  if position('fix_role_pings(sid' in d) = 0 then
    d := replace(d, $a$      if new.content ~ '(^|[^A-Za-z0-9_@])@(everyone|here)\M'$a$,
      $a$      new.content := public.fix_role_pings(sid, old.channel_id, cp, new.content);
      if new.content ~ '(^|[^A-Za-z0-9_@])@(everyone|here)\M'$a$);
    if position('fix_role_pings(sid' in d) = 0 then raise exception 'message_edit_guard patch did not apply'; end if;
  end if;
  if position('fix_role_pings_bot' in d) = 0 then
    d := replace(d, $a$  -- Edits follow the same rules as sending:$a$,
      $a$  if new.content is distinct from old.content and coalesce(current_setting('yapper.bot', true), '') = '1' then
    new.content := public.fix_role_pings_bot(old.channel_id, new.content);
  end if;
  -- Edits follow the same rules as sending:$a$);
    if position('fix_role_pings_bot' in d) = 0 then raise exception 'message_edit_guard bot patch did not apply'; end if;
  end if;
  if position('fix_role_pings(null' in d) = 0 then
    d := replace(d, $a$    if sid is null then select server_id into sid from public.channels where id = old.channel_id; end if;$a$,
      $a$    if sid is null then select server_id into sid from public.channels where id = old.channel_id; end if;
    if sid is null then new.content := public.fix_role_pings(null, old.channel_id, false, new.content); end if;$a$);
    if position('fix_role_pings(null' in d) = 0 then raise exception 'message_edit_guard DM patch did not apply'; end if;
  end if;
  execute d;
end $$;

-- Discord import: a category or channel name our checks refuse (slur list, bad names, too long)
-- gets a plain name instead of sinking the whole import.
do $$ declare d text; begin
  d := pg_get_functiondef('public.import_discord_server(jsonb)'::regprocedure);
  if position('fallback name' in d) = 0 then
    d := replace(d, $a$    insert into public.channel_categories (server_id, name, position) values (sid, left(c->>'name', 100), coalesce((c->>'position')::int, n)) returning id into cid;$a$,
      $a$    begin
      insert into public.channel_categories (server_id, name, position) values (sid, left(btrim(coalesce(c->>'name', '')), 40), coalesce((c->>'position')::int, n)) returning id into cid;
    exception when others then -- refused name: fallback name
      insert into public.channel_categories (server_id, name, position) values (sid, 'category', coalesce((c->>'position')::int, n)) returning id into cid;
    end;$a$);
    d := replace(d, $a$    insert into public.channels (kind, name, server_id, created_by, position, category_id)
      values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
              case when c->>'kind' = 'voice' then left(c->>'name', 100) else coalesce(public.slugify_channel(c->>'name'), 'channel') end,
              sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);$a$,
      $a$    begin
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end,
                case when c->>'kind' = 'voice' then left(c->>'name', 100) else coalesce(public.slugify_channel(c->>'name'), 'channel') end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    exception when check_violation or raise_exception then -- refused name: fallback name
      insert into public.channels (kind, name, server_id, created_by, position, category_id)
        values (case when c->>'kind' = 'voice' then 'voice' else 'text' end, case when c->>'kind' = 'voice' then 'Voice' else 'channel' end,
                sid, me, coalesce((c->>'position')::int, n), nullif(cats->>(c->>'category_key'), '')::uuid);
    end;$a$);
    if (length(d) - length(replace(d, 'fallback name', ''))) / 13 <> 2 then raise exception 'import_discord_server patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- The role pings that reach me, per server, as LIKE patterns ('%<@&role id>%'): roles I have in
-- servers where the flag is on, automatic ones included ("everyone" / "joined before", which have no
-- member_roles rows). Worked out once per call, then matched against message text of that server only:
-- no per-message lookups, no rows per member. The flag check is feature_on() inlined.
create or replace function public.my_role_pings()
returns table(sid uuid, pats text[]) language sql stable security definer set search_path = public as $$
  select sm.server_id, array_agg('%<@&' || r.id::text || '>%')
  from public.feature_flags f
  join public.server_members sm on sm.user_id = (select auth.uid())
  join public.roles r on r.server_id = sm.server_id
  where f.key = 'role_mentions'
    and (f.mode = 'everyone' or (f.mode = 'test' and (sm.server_id = any(f.servers) or (select auth.uid()) = any(f.users))))
    and (r.auto = 'all'
         or (r.auto = 'before' and r.auto_before is not null and sm.joined_at < r.auto_before)
         or exists (select 1 from public.member_roles mr where mr.user_id = (select auth.uid()) and mr.role_id = r.id))
  group by sm.server_id;
$$;
revoke all on function public.my_role_pings() from public, anon, authenticated;

-- Voice channel chat (145, flag voice_chat) counts too: keep its vc branch here.
create or replace function public.unread_counts_v2()
returns table(channel_id uuid, unread integer, muted boolean, mentions integer)
language sql stable security definer set search_path = public as $$
  with pings as materialized (select * from public.my_role_pings()),
  vc as materialized (
    select f.mode, f.servers, f.users from public.feature_flags f where f.key = 'voice_chat'
  ),
  mine as (
    select cm.channel_id, cm.joined_at as since, null::uuid as sid from public.channel_members cm where cm.user_id = auth.uid()
    union all
    select c.id, sm.joined_at, c.server_id from public.my_visible_server_channels() c
    join public.server_members sm on sm.server_id = c.server_id and sm.user_id = auth.uid()
    where c.kind = 'text'
       or (c.kind = 'voice' and exists (select 1 from vc where vc.mode = 'everyone'
             or (vc.mode = 'test' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users)))))
  ),
  fresh as (
    select mine.channel_id, mine.sid, m.content
    from mine
    left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid()
    join lateral (
      select content from public.messages m
      where m.channel_id = mine.channel_id
        and m.author_id <> auth.uid()
        and m.created_at > coalesce(r.last_read_at, mine.since)
      order by m.created_at desc
      limit 100
    ) m on true
  )
  select
    mine.channel_id,
    (select count(*)::int from fresh f where f.channel_id = mine.channel_id),
    coalesce(r.muted, false),
    (select count(*)::int from fresh f left join pings p on p.sid = f.sid where f.channel_id = mine.channel_id
       and (f.content like '%<@' || auth.uid()::text || '>%' or f.content ~ '(^|[^A-Za-z0-9_@])@everyone\M'
            or (p.pats is not null and strpos(f.content, '<@&') > 0 and f.content like any (p.pats))))
  from mine
  left join public.channel_reads r on r.channel_id = mine.channel_id and r.user_id = auth.uid();
$$;

-- One probe per channel I can see (DMs / groups via channel_members, server channels via
-- my_visible_server_channels), newest first, on messages_pingy_idx: the WHERE repeats the index
-- predicate exactly so the planner can use it.
create or replace function public.my_mentions(lim integer default 40)
returns setof public.messages language sql stable security definer set search_path = public as $$
  with pings as materialized (select * from public.my_role_pings()),
  chans as materialized (
    select cm.channel_id, null::uuid as sid
    from public.channel_members cm
    join public.channels c on c.id = cm.channel_id and c.server_id is null
    where cm.user_id = (select auth.uid())
    union all
    select v.id, v.server_id from public.my_visible_server_channels() v
  )
  select m.*
  from chans
  left join pings p on p.sid = chans.sid
  cross join lateral (
    select x.* from public.messages x
    where x.channel_id = chans.channel_id
      and (strpos(x.content, '<@') > 0 or strpos(x.content, '@everyone') > 0)
      and x.created_at > now() - interval '30 days'
      and x.author_id <> (select auth.uid())
      and (x.content like '%<@' || (select auth.uid())::text || '>%'
           or x.content ~ '(^|[^\w])@everyone([^\w]|$)'
           or (p.pats is not null and strpos(x.content, '<@&') > 0 and x.content like any (p.pats)))
    order by x.created_at desc
    limit least(greatest(coalesce(lim, 40), 1), 100)
  ) m
  order by m.created_at desc
  limit least(greatest(coalesce(lim, 40), 1), 100);
$$;

-- Earlier drafts of this migration: pings_my_role() per message, then my_role_ping_patterns().
do $$ begin
  if to_regprocedure('public.pings_my_role(uuid, timestamptz, text)') is not null then
    execute 'dr' || 'op function public.pings_my_role(uuid, timestamptz, text)';
  end if;
  if to_regprocedure('public.my_role_ping_patterns()') is not null then
    execute 'dr' || 'op function public.my_role_ping_patterns()';
  end if;
end $$;
