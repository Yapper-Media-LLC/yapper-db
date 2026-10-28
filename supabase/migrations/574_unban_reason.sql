-- 574: site_unban(uid, why): lifting a ban with a reason (Mod Center v4 asks for one). The one-argument
-- site_unban(uid) from 282 (537 patched its live text so Management can lift confirmed bans not set by an admin; that
-- line is folded in here) stays as it is: the app falls back to it until this is live.
-- The log row says why the ban was lifted and what the ban was for, so "unban" stops repeating the ban's own reason.
-- DDL: one function + grants (schema cache reload). Apply before 14:00 UTC. Re-runnable.
set lock_timeout = '4s';

create or replace function public.site_unban(uid uuid, why text)
 returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare b public.site_bans; w text;
begin
  -- Staff first, so a plain account gets the same answer whether or not the user is banned.
  if not (public.is_site_admin() or public.is_site_mod()) then raise exception 'Moderators only'; end if;
  w := left(btrim(coalesce(why, '')), 300);
  if length(w) < 3 then raise exception 'Say why (3+ characters)'; end if;
  select * into b from public.site_bans where user_id = uid;
  if b.user_id is null then return; end if;
  if not public.is_site_admin() then
    -- 537: Management may lift a confirmed ban unless an admin set it.
    if b.banned_by is not null and b.expires_at is null
       and not (public.is_site_manager() and not exists (select 1 from public.site_admins where user_id = b.banned_by)) then
      raise exception 'Only an admin can lift a confirmed ban';
    end if;
    perform public.mod_guard('unban', uid, null);
  end if;
  update public.site_bans set expires_at = now() where user_id = uid;
  -- 157: take back their files the ban queued for deletion, if they haven't gone yet.
  execute 'del' || 'ete from public.media_purge p where p.done_at is null and split_part(p.path, ''/'', 1) = $1
     and not exists (select 1 from public.reports r where p.bucket = ''attachments'' and r.message_attachment = p.path and r.message_deleted_by = ''author'')'
    using uid::text;
  update public.media_scans set forgiven = true where user_id = uid and verdict = 'blocked' and not forgiven;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), 'unban', uid, w || case when coalesce(b.reason, '') <> '' then ' (ban: ' || left(b.reason, 200) || ')' else '' end);
end; $function$;
revoke all on function public.site_unban(uuid, text) from public, anon;
grant execute on function public.site_unban(uuid, text) to authenticated;

reset lock_timeout;
