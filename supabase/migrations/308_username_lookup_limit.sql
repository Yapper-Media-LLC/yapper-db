-- 308: a limit on looking up accounts by username (Oct 20). Scripts hunt for free rare usernames by asking
-- GET /rest/v1/profiles?username=eq.<name> while signed in (up to ~40k an hour on Oct 19). People in the app do this a
-- handful of times (adding a friend by name). The request-limits cron (app/api/cron/request-limits, every 3 minutes)
-- now also counts these per account from Supabase's gateway logs and hands accounts over the limit to this function,
-- which holds them back the same way request_limits_apply does: request_throttle row for 15 minutes, enforced by
-- request_guard on every request from that account, logged in mod_log once. Staff are never held. Follows the
-- request_limits flag (off / test / everyone). Re-runnable.

create or replace function public.username_lookup_limits_apply(hits jsonb, threshold integer default 60, window_min integer default 10)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  f public.feature_flags;
  h jsonb;
  uid uuid;
  n int;
  enf boolean;
  was public.request_throttle;
  had boolean;
  held int := 0;
  noticed int := 0;
  logged int := 0;
begin
  select * into f from public.feature_flags where key = 'request_limits';
  if not found or f.mode = 'off' then
    return jsonb_build_object('mode', coalesce(f.mode, 'missing'), 'held', 0, 'noticed', 0, 'logged', 0);
  end if;
  for h in select * from jsonb_array_elements(case when jsonb_typeof(hits) = 'array' then hits else '[]'::jsonb end) limit 200 loop
    if coalesce(h ->> 'u', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then continue; end if;
    uid := (h ->> 'u')::uuid;
    n := case when coalesce(h ->> 'c', '') ~ '^\d{1,9}$' then (h ->> 'c')::int else 0 end;
    -- Never below 20, whatever the caller sends: a person adding friends by name stays far under it.
    if n < greatest(threshold, 20) then continue; end if;
    if not exists (select 1 from public.profiles where id = uid) then continue; end if;
    select * into was from public.request_throttle where user_id = uid for update;
    -- An admin cleared it just now: leave them alone for a window.
    if found and was.cleared_at > now() - make_interval(mins => greatest(window_min, 10)) then continue; end if;
    had := found and was.until > now();
    enf := (f.mode = 'everyone' or (f.mode = 'test' and uid = any(f.users)))
      and not exists (select 1 from public.site_admins where user_id = uid)
      and not exists (select 1 from public.site_moderators where user_id = uid);
    insert into public.request_throttle as t (user_id, until, enforced, requests, top_path, user_agent)
    values (uid, now() + interval '15 minutes', enf, n, 'GET /rest/v1/profiles?username=', left(coalesce(h ->> 'ua', ''), 200))
    on conflict (user_id) do update set
      until = greatest(t.until, excluded.until),
      -- An old, finished hold's value doesn't carry over into a new one (a since-promoted moderator stays free).
      enforced = case when t.until > now() then t.enforced or excluded.enforced else excluded.enforced end,
      requests = greatest(t.requests, excluded.requests),
      top_path = excluded.top_path,
      user_agent = excluded.user_agent,
      hits = case when t.until > now() then t.hits + 1 else 1 end,
      first_seen = case when t.until > now() then t.first_seen else now() end,
      last_seen = now(),
      cleared_at = null;
    if enf then held := held + 1; else noticed := noticed + 1; end if;
    if not had or (enf and not was.enforced) then
      insert into public.mod_log (actor, action, target_id, reason)
      values (null, case when enf then 'request_limit' else 'request_limit_seen' end, uid,
              format('%s username lookups in %s min (hunting for usernames)', n, window_min));
      logged := logged + 1;
    end if;
  end loop;
  return jsonb_build_object('mode', f.mode, 'held', held, 'noticed', noticed, 'logged', logged);
end $function$;
revoke all on function public.username_lookup_limits_apply(jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.username_lookup_limits_apply(jsonb, integer, integer) to service_role;
