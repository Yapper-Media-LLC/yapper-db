set lock_timeout = '3s';
-- 261: profile fixes (bug reports, Oct 18). Re-runnable: only create or replace.
--
-- (a) channel_messages_since(): the catch-up after a reconnect sent the authors' profiles without the columns added
--     since it was written (verify_required, profile_effect, custom_status, avatar_deco, discriminator, name_style),
--     so it carried no name style. Copied from the LIVE definition (pg_get_functiondef, Oct 18) with only the
--     column list changed to match channel_messages().

create or replace function public.channel_messages_since(cid uuid, since timestamp with time zone, lim integer default 50)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with msgs as (
    select m.* from public.messages m
    where m.channel_id = cid and public.can_access_channel(cid) and public.channel_history_ok(cid) and m.created_at > since
    order by m.created_at asc
    limit least(greatest(coalesce(lim, 50), 1), 100)
  )
  select jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from msgs m),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from (
      select id, username, created_at, bio, avatar_path, banner_path, banner_x, banner_y, avatar_x, avatar_y,
             avatar_zoom, avatar_rot, banner_zoom, links, verified_as, verified_hidden, badges, display_name,
             pronouns, accent_color, accent_color2, plus_until, plus_badge_hidden, dms_from, server_tag, tag, server_order, shown_badge,
             verify_required, profile_effect, custom_status, avatar_deco, discriminator, name_style
      from public.profiles where id in (select author_id from msgs)) p),
    'reactions', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'message_id', r.message_id, 'user_id', r.user_id, 'emoji', r.emoji)), '[]'::jsonb)
      from public.reactions r where r.message_id in (select id from msgs))
  );
$function$;

-- (b) Verified badge kept on a display name change (5 reports: "I changed my display name and lost the badge, now I
--     have to verify again"). 045/171 took the badge away whenever neither the username nor the display name matched
--     the verified channel any more, so anyone verified through their display name lost it for a nickname.
--     The badge belongs to the account now; the hover still says which channel it was given for ("Verified
--     YouTube · name"). What stays: a new USERNAME has to match the channel itself or the badge goes (matching only
--     the display name isn't enough, or a rename in two steps would keep the tick next to any name), a display name can't copy another verified creator's name (profile_impersonation_guard) and verified
--     accounts can't use brand or country names (verified_name_guard).
--     Copied from the LIVE profile_custom_guard (pg_get_functiondef, Oct 18): only the rename block changed.
create or replace function public.profile_custom_guard()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare handle text; nm text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and (public.bad_name(new.username) or public.has_adult_link(new.username) or (public.brand_name(new.username) and not public.is_site_admin())) then
    raise exception 'That username isn''t allowed on Yapper. Pick another.';
  end if;
  new.display_name := left(public.clean_name(new.display_name), 32);
  if new.display_name is not null and new.display_name !~ '[[:alnum:]]' then raise exception 'Display names need at least one letter or number'; end if;
  new.pronouns := nullif(left(btrim(coalesce(new.pronouns, '')), 40), '');
  if new.display_name is not null and (public.bad_name(new.display_name) or public.has_adult_link(new.display_name) or (public.brand_name(new.display_name) and not public.is_site_admin())) then
    raise exception 'That display name isn''t allowed';
  end if;
  if new.pronouns is not null and public.bad_name(new.pronouns) then raise exception 'Those pronouns aren''t allowed'; end if;
  if new.accent_color is not null and new.accent_color !~ '^#[0-9a-fA-F]{6}$' then new.accent_color := null; end if;
  if new.accent_color2 is not null and new.accent_color2 !~ '^#[0-9a-fA-F]{6}$' then new.accent_color2 := null; end if;
  -- A verified badge belongs to the account: changing the display name keeps it. Changing the username to something
  -- that doesn't match the verified channel removes it (unless an admin does it).
  if tg_op = 'UPDATE' and old.verified_as is not null and new.verified_as is not distinct from old.verified_as
     and new.username is distinct from old.username
     and not public.is_site_admin() and current_user not in ('postgres', 'service_role') then
    handle := public.verify_name_key(split_part(old.verified_as, ' · ', 2));
    nm := public.verify_name_key(new.username);
    if handle = '' or handle <> nm then new.verified_as := null; end if;
  end if;
  return new;
end;
$function$;

reset lock_timeout;
