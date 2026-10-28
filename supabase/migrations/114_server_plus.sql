-- Server Plus: a per-server subscription (Stripe Payment Link with client_reference_id = splus_<server id>)
-- that unlocks the premium bits of the in-house bots. Free stays free.
--   Levels:   xp_mult (1 / 1.5 / 2), custom level-up message, role rewards [{level, role_id}]
--   Welcomer: extra welcome lines (random pick), goodbye message in a channel
--   Helper:   custom commands [{name, reply}]
-- set_server_bot drops those keys when the server is not on Plus, and the bots check again at run time.

create table if not exists public.server_plus (
  server_id uuid primary key references public.servers(id) on delete cascade,
  until timestamptz not null,
  stripe_customer text,
  granted_by uuid,
  updated_at timestamptz not null default now()
);
create index if not exists server_plus_customer on public.server_plus (stripe_customer);
alter table public.server_plus enable row level security;
grant select on public.server_plus to authenticated;
do $x$ begin
  if not exists (select 1 from pg_policies where policyname = 'server plus visible to members') then
    execute $p$create policy "server plus visible to members" on public.server_plus for select to authenticated using (public.is_server_member(server_id))$p$;
  end if;
end $x$;

create or replace function public.server_plus_on(sid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.server_plus p where p.server_id = sid and p.until > now());
$$;
grant execute on function public.server_plus_on(uuid) to authenticated;

/** Admins: hand out Plus by hand (a giveaway, a refund, a test). */
create or replace function public.admin_grant_server_plus(sid uuid, days integer) returns timestamptz
language plpgsql security definer set search_path to 'public' as $$
declare u timestamptz;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  insert into public.server_plus (server_id, until, granted_by)
  values (sid, now() + make_interval(days => greatest(days, 1)), auth.uid())
  on conflict (server_id) do update set until = greatest(server_plus.until, now()) + make_interval(days => greatest(days, 1)), granted_by = auth.uid(), updated_at = now()
  returning until into u;
  return u;
end $$;
grant execute on function public.admin_grant_server_plus(uuid, integer) to authenticated;

create or replace function public.set_server_bot(sid uuid, p_bot text, p_enabled boolean, p_config jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb := coalesce(p_config, '{}'::jsonb);
begin
  if not public.server_perm(sid, 'manage_server') then raise exception 'Only server managers can set up bots'; end if;
  if not public.feature_on('bots', sid) then raise exception 'Bots aren''t available here yet'; end if;
  if not public.server_plus_on(sid) then
    cfg := cfg - 'xp_mult' - 'rewards' - 'lines' - 'leave_channel_id' - 'leave_message' - 'commands';
    if p_bot = 'levels' then cfg := cfg - 'message'; end if;
  end if;
  -- Keep the lists sane whatever the client sends.
  if jsonb_typeof(cfg -> 'rewards') = 'array' and jsonb_array_length(cfg -> 'rewards') > 20 then raise exception 'Up to 20 role rewards'; end if;
  if jsonb_typeof(cfg -> 'commands') = 'array' and jsonb_array_length(cfg -> 'commands') > 25 then raise exception 'Up to 25 custom commands'; end if;
  if jsonb_typeof(cfg -> 'lines') = 'array' and jsonb_array_length(cfg -> 'lines') > 10 then raise exception 'Up to 10 welcome lines'; end if;
  insert into public.server_bots (server_id, bot, enabled, config) values (sid, p_bot, p_enabled, cfg)
  on conflict (server_id, bot) do update set enabled = excluded.enabled, config = excluded.config;
end $$;

create or replace function public.bot_levels(sid uuid, cid uuid, uid uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; row public.server_xp; gain int; lvl int; ann uuid; plus boolean; mult numeric; tpl text; rw jsonb;
begin
  select config into cfg from public.server_bots where server_id = sid and bot = 'levels' and enabled;
  if cfg is null then return; end if;
  select * into row from public.server_xp where server_id = sid and user_id = uid;
  if row.user_id is not null and row.last_at > now() - interval '60 seconds' then return; end if;
  plus := public.server_plus_on(sid);
  mult := case when plus then least(greatest(coalesce((cfg ->> 'xp_mult')::numeric, 1), 1), 2) else 1 end;
  gain := round((15 + floor(random() * 11)) * mult)::int;
  insert into public.server_xp (server_id, user_id, xp, level, last_at) values (sid, uid, gain, 0, now())
    on conflict (server_id, user_id) do update set xp = server_xp.xp + excluded.xp, last_at = now()
    returning * into row;
  lvl := floor(sqrt(row.xp / 100.0))::int;
  if lvl > row.level then
    update public.server_xp set level = lvl where server_id = sid and user_id = uid;
    if plus and jsonb_typeof(cfg -> 'rewards') = 'array' then
      perform set_config('yapper.bot', '1', true);
      for rw in select * from jsonb_array_elements(cfg -> 'rewards') loop
        if (rw ->> 'level')::int <= lvl and exists (select 1 from public.roles r where r.id = (rw ->> 'role_id')::uuid and r.server_id = sid and r.auto = 'none') then
          insert into public.member_roles (server_id, user_id, role_id, manual) values (sid, uid, (rw ->> 'role_id')::uuid, true) on conflict do nothing;
        end if;
      end loop;
      perform set_config('yapper.bot', '', true);
    end if;
    if coalesce((cfg ->> 'announce')::boolean, true) then
      ann := coalesce(nullif(cfg ->> 'channel_id', '')::uuid, cid);
      if not exists (select 1 from public.channels where id = ann and server_id = sid) then ann := cid; end if;
      tpl := case when plus then nullif(cfg ->> 'message', '') end;
      tpl := coalesce(tpl, '🎉 {user} just reached **level {level}**!');
      tpl := replace(replace(tpl, '{user}', '<@' || uid::text || '>'), '{level}', lvl::text);
      perform public.bot_say(ann, 'levels', tpl);
    end if;
  end if;
end $$;

create or replace function public.bot_welcome() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; cid uuid; tpl text; nm text; ls jsonb;
begin
  select config into cfg from public.server_bots where server_id = new.server_id and bot = 'welcome' and enabled;
  if cfg is null or not public.feature_on('bots', new.server_id) then return null; end if;
  cid := nullif(cfg ->> 'channel_id', '')::uuid;
  if cid is null or not exists (select 1 from public.channels where id = cid and server_id = new.server_id and kind = 'text') then return null; end if;
  select coalesce(display_name, username) into nm from public.profiles where id = new.user_id;
  tpl := nullif(cfg ->> 'message', '');
  ls := cfg -> 'lines';
  if public.server_plus_on(new.server_id) and jsonb_typeof(ls) = 'array' and jsonb_array_length(ls) > 0 then
    -- Plus: the main message plus extra lines, one picked at random each time.
    ls := ls || to_jsonb(coalesce(tpl, 'Welcome to {server}, {user}! 👋'));
    tpl := ls ->> floor(random() * jsonb_array_length(ls))::int;
  end if;
  tpl := coalesce(tpl, 'Welcome to {server}, {user}! 👋');
  tpl := replace(tpl, '{user}', '<@' || new.user_id::text || '>');
  tpl := replace(tpl, '{name}', coalesce(nm, 'friend'));
  tpl := replace(tpl, '{server}', (select name from public.servers where id = new.server_id));
  tpl := replace(tpl, '{count}', (select count(*)::text from public.server_members where server_id = new.server_id));
  perform public.bot_say(cid, 'welcome', tpl);
  return null;
end $$;

/** Plus: Welcomer says goodbye when someone leaves. */
create or replace function public.bot_goodbye() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; cid uuid; tpl text; nm text;
begin
  if exists (select 1 from public.bots where id = old.user_id) or exists (select 1 from public.bot_accounts where user_id = old.user_id) then return null; end if;
  select config into cfg from public.server_bots where server_id = old.server_id and bot = 'welcome' and enabled;
  if cfg is null or not public.server_plus_on(old.server_id) then return null; end if;
  cid := nullif(cfg ->> 'leave_channel_id', '')::uuid;
  if cid is null or not exists (select 1 from public.channels where id = cid and server_id = old.server_id and kind = 'text') then return null; end if;
  select coalesce(display_name, username) into nm from public.profiles where id = old.user_id;
  tpl := coalesce(nullif(cfg ->> 'leave_message', ''), '{name} left. See you around 👋');
  tpl := replace(tpl, '{name}', coalesce(nm, 'someone'));
  tpl := replace(tpl, '{server}', (select name from public.servers where id = old.server_id));
  tpl := replace(tpl, '{count}', (select count(*)::text from public.server_members where server_id = old.server_id));
  perform public.bot_say(cid, 'welcome', tpl);
  return null;
end $$;
create or replace trigger server_members_bot_goodbye after delete on public.server_members for each row execute function public.bot_goodbye();

/** Plus: Helper answers the server's own commands before its built-in ones. */
create or replace function public.bot_on_message() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sid uuid; helper_on boolean; levels_on boolean; hcfg jsonb; c jsonb; cmd text;
begin
  if current_setting('yapper.bot', true) = '1' then return null; end if;
  if exists (select 1 from public.bot_accounts where user_id = new.author_id) then return null; end if;
  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null or not public.feature_on('bots', sid) then return null; end if;
  select bool_or(bot = 'helper' and enabled), bool_or(bot = 'levels' and enabled) into helper_on, levels_on from public.server_bots where server_id = sid;
  if coalesce(levels_on, false) then perform public.bot_levels(sid, new.channel_id, new.author_id); end if;
  if coalesce(helper_on, false) and left(new.content, 1) in ('!', '/') and public.server_plus_on(sid) then
    select config into hcfg from public.server_bots where server_id = sid and bot = 'helper';
    cmd := lower(substr(split_part(new.content, ' ', 1), 2));
    if jsonb_typeof(hcfg -> 'commands') = 'array' then
      for c in select * from jsonb_array_elements(hcfg -> 'commands') loop
        if lower(c ->> 'name') = cmd and nullif(c ->> 'reply', '') is not null then
          perform public.bot_say(new.channel_id, 'helper', replace(left(c ->> 'reply', 1000), '{user}', '<@' || new.author_id::text || '>'));
          return null;
        end if;
      end loop;
    end if;
  end if;
  if coalesce(helper_on, false) or (coalesce(levels_on, false) and lower(new.content) in ('!rank', '!top')) then
    perform public.bot_helper(sid, new.channel_id, new.author_id, new.content);
  end if;
  return null;
end $$;

insert into public.feature_flags (key, label, description, mode, users)
  values ('server_plus', 'Server Plus', 'Paid per-server tier: Levels rewards and multipliers, Welcomer goodbyes and extra lines, Helper custom commands', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
