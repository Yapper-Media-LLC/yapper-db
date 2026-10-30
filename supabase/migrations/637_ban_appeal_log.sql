-- 637: appeal log (asked by Firefox, HQ mod). Every ban appeal decision lands in mod_log under its own action,
-- so the Mod Center log (Appeals chip) shows who accepted or denied whose appeal and the note they left.
-- Before: accepting only left the plain "unban" row from site_unban (nothing at all if the ban had already ended),
-- and denials were logged as "appeal_denied", the same action upload appeals use, so the log read "denied an
-- upload appeal". Upload appeals keep appeal_approved / appeal_denied; ban appeals get ban_appeal_approved /
-- ban_appeal_denied.
-- DDL: two functions (schema cache reload). Apply before 14:00 UTC. Re-runnable. No dependency on 574.
set lock_timeout = '4s';

create or replace function public.decide_ban_appeal(aid uuid, approve boolean, note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.ban_appeals;
  b public.site_bans;
  n text := nullif(left(btrim(coalesce(note, '')), 500), '');
  r text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into a from public.ban_appeals where id = aid for update;
  if a.id is null then raise exception 'That appeal is gone'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided this one'; end if;
  if approve then
    -- Only the ban this appeal is about (a re-ban since gets its own appeal), and only while it's still on.
    select * into b from public.site_bans where user_id = a.user_id for update;
    if b.user_id is null or b.created_at <> a.ban_at then
      raise exception 'They were banned again since. This appeal is for an older ban, so deny it';
    end if;
    -- Lifting goes through site_unban, so its rules (and its limits and "unban" log line) apply as is.
    -- (The one-argument site_unban: 574's site_unban(uid, why) isn't live yet, and this must not depend on it.)
    if b.expires_at is null or b.expires_at > now() then perform public.site_unban(a.user_id); end if;
  else
    -- Hourly cap keyed on the action this writes, so it keeps counting ban appeal denials.
    perform public.mod_guard('ban_appeal_denied', a.user_id, null);
  end if;
  update public.ban_appeals set status = case when approve then 'approved' else 'denied' end,
    decided_at = now(), decided_by = auth.uid(), staff_note = n
    where id = aid;
  -- The log line: the staff note, then what the ban was for.
  r := btrim(coalesce(n, '') || case when coalesce(a.ban_reason, '') <> '' then ' (ban: ' || left(a.ban_reason, 200) || ')' else '' end);
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), case when approve then 'ban_appeal_approved' else 'ban_appeal_denied' end, a.user_id, r);
end; $$;
revoke all on function public.decide_ban_appeal(uuid, boolean, text) from public, anon;
grant execute on function public.decide_ban_appeal(uuid, boolean, text) to authenticated;

-- Mod stats: ban appeal decisions count as appeals, not "other".
create or replace function public.staff_mod_stats(p_days int default 7)
returns table (user_id uuid, head boolean, suspended boolean, since timestamptz, total bigint, deletes bigint, warns bigint,
               timeouts bigint, bans bigint, unbans bigint, verifies bigint, appeals bigint, other bigint, last_action timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public.is_site_admin() or public.is_head_mod()) then raise exception 'Admins only'; end if;
  p_days := least(greatest(coalesce(p_days, 7), 1), 90);
  return query
  select m.user_id, m.head, m.suspended_at is not null, m.created_at,
         count(l.*), count(*) filter (where l.action in ('delete', 'purge')),
         count(*) filter (where l.action = 'warn'),
         count(*) filter (where l.action in ('timeout', 'voice_mute')),
         count(*) filter (where l.action = 'ban'),
         count(*) filter (where l.action = 'unban'),
         count(*) filter (where l.action in ('verify', 'verify_reject', 'verify_ask_proof')),
         count(*) filter (where l.action in ('appeal_approved', 'appeal_denied', 'ban_appeal_approved', 'ban_appeal_denied')),
         count(*) filter (where l.action is not null and l.action not in ('delete', 'purge', 'warn', 'timeout', 'voice_mute', 'ban', 'unban',
           'verify', 'verify_reject', 'verify_ask_proof', 'appeal_approved', 'appeal_denied', 'ban_appeal_approved', 'ban_appeal_denied')),
         (select max(x.created_at) from public.mod_log x where x.actor = m.user_id)
    from public.site_moderators m
    left join public.mod_log l on l.actor = m.user_id and l.created_at > now() - make_interval(days => p_days)
   group by m.user_id, m.head, m.suspended_at, m.created_at;
end $$;
revoke all on function public.staff_mod_stats(int) from public, anon;
grant execute on function public.staff_mod_stats(int) to authenticated;

-- History: old ban appeal denials were logged as appeal_denied (the upload appeal action). Rename the rows that
-- belong to a ban appeal (same mod, same person, written in the same call) so they read right. Upload appeal rows
-- always say 'Upload review', so they are left alone.
update public.mod_log l
   set action = 'ban_appeal_denied'
  from public.ban_appeals a
 where l.action = 'appeal_denied' and l.reason <> 'Upload review'
   and a.status = 'denied' and a.decided_by = l.actor and a.user_id = l.target_id
   and l.created_at between a.decided_at - interval '5 seconds' and a.decided_at + interval '5 seconds';

-- Old acceptances never got an appeal row: add one per approved appeal (dated when it was decided).
insert into public.mod_log (actor, action, target_id, reason, created_at)
select a.decided_by, 'ban_appeal_approved', a.user_id,
       btrim(coalesce(a.staff_note, '') || case when coalesce(a.ban_reason, '') <> '' then ' (ban: ' || left(a.ban_reason, 200) || ')' else '' end),
       a.decided_at
  from public.ban_appeals a
 where a.status = 'approved' and a.decided_at is not null
   and not exists (select 1 from public.mod_log l where l.action = 'ban_appeal_approved' and l.target_id = a.user_id
                     and l.created_at between a.decided_at - interval '5 seconds' and a.decided_at + interval '5 seconds');

reset lock_timeout;
