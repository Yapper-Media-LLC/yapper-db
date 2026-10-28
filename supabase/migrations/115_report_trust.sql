-- Mass-report abuse (Oct 15: one person with alts got 7 people auto-banned at "8 reports in an hour").
-- Only trusted reporters count now: account older than 3 days, not banned, not a bot, and with at
-- least 5 messages sent. Ban needs 10 of them in an hour (was 8 of anyone), timeout needs 5.

create or replace function public.trusted_reporter(uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid
      and p.created_at < now() - interval '3 days'
      and not ('bot' = any(coalesce(p.badges, '{}'::text[])))
      and not exists (select 1 from public.site_bans b where b.user_id = uid and (b.expires_at is null or b.expires_at > now()))
      and (select count(*) from (select 1 from public.messages m where m.author_id = uid limit 5) x) >= 5
  );
$$;

create or replace function public.apply_auto_action(target uuid, r reports) returns text
language plpgsql security definer set search_path to 'public' as $$
declare reporters_1h int; reporters_7d int; mu timestamptz; slur boolean;
begin
  if target is null or exists (select 1 from public.site_admins where user_id = target) or exists (select 1 from public.site_bans where user_id = target) then return null; end if;
  slur := public.has_slur(coalesce(r.message_content, ''));
  select count(distinct x.reporter_id) into reporters_1h from public.reports x
    where x.target_id = target and x.created_at > now() - interval '1 hour' and public.trusted_reporter(x.reporter_id);
  select count(distinct x.reporter_id) into reporters_7d from public.reports x
    where x.target_id = target and x.created_at > now() - interval '7 days' and public.trusted_reporter(x.reporter_id);
  if (slur and reporters_7d >= 2) or reporters_1h >= 10 then
    insert into public.site_bans (user_id, reason)
    values (target, case when slur then 'Auto-ban: slurs, reported by ' || reporters_7d || ' people' else 'Auto-ban: reported by ' || reporters_1h || ' trusted people in an hour' end)
    on conflict (user_id) do nothing;
    update public.reports set status = 'actioned', triage = 'auto', triage_note = 'Auto-banned', resolved_at = now() where target_id = target and status = 'open';
    return 'Auto-banned';
  end if;
  if reporters_1h >= 5 then
    select muted_until into mu from public.profiles where id = target;
    if mu is null or mu < now() then
      update public.profiles set muted_until = now() + interval '1 hour', muted_reason = 'reported by ' || reporters_1h || ' people' where id = target;
    end if;
    return 'Auto timeout 1h';
  end if;
  return null;
end;
$$;
