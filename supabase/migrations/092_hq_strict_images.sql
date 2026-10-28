-- Stricter image line in Yapper HQ (applied live Oct 15). The scanner refuses uploads scoring 0.75+
-- everywhere; in the default server, pictures scoring 0.6+ are refused as well (managers and mods
-- excepted). Asked for after a wave of NSFW pictures posted and deleted in #general. Pictures stay on.
create or replace function public.require_scanned_media()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  i int; col text; b text; val text; old_val text; sid uuid; strict_server boolean := false; cid uuid;
begin
  -- This trigger also guards avatars, banners and server icons, whose rows have no channel.
  cid := (to_jsonb(new) ->> 'channel_id')::uuid;
  if cid is not null then
    select c.server_id into sid from public.channels c where c.id = cid;
    strict_server := sid is not null and sid = (select default_server_id from public.app_settings limit 1)
                     and not public.server_perm(sid, 'manage_messages');
  end if;
  for i in 0 .. (tg_nargs / 2) - 1 loop
    col := tg_argv[i * 2];
    b := tg_argv[i * 2 + 1];
    val := to_jsonb(new) ->> col;
    old_val := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and val is distinct from old_val then
      if not public.media_ok(b, val) then
        raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
      end if;
      if strict_server and exists (select 1 from public.media_scans s where s.bucket = b and s.path = val and s.score >= 0.6) then
        raise exception 'That picture is too close to the line for Yapper HQ. It is fine in smaller servers.' using errcode = 'check_violation';
      end if;
    end if;
  end loop;
  return new;
end;
$function$;
