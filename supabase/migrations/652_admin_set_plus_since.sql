-- 652: admin_set_plus_since. An admin sets profiles.plus_since for any user (null resets it), so the Plus tenure
-- badges (611, flag plus_tenure_badges, published to everyone) can be checked on a real profile before anyone has
-- earned one: streaks only count from the Oct 13, 2026 sales, so the oldest real badge is still weeks away.
-- Mod Center > Users shows the row to admins (date picker, 1 mo .. 5 y quick buttons, Reset). Every call writes a
-- mod_log row 'plus_since_set' with the date (or 'reset'). Admins only, no feature flag. Writing plus_since directly
-- does not touch the 611 trigger (it fires on plus_until only), so a later renewal keeps the date. Re-runnable.

create or replace function public.admin_set_plus_since(uid uuid, since timestamptz)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if since > now() then raise exception 'Plus since can''t be in the future'; end if;
  update public.profiles set plus_since = since where id = uid;
  if not found then raise exception 'No such user'; end if;
  insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'plus_since_set', uid, case when since is null then 'reset' else to_char(since, 'YYYY-MM-DD') end);
end $$;
revoke all on function public.admin_set_plus_since(uuid, timestamptz) from public, anon;
grant execute on function public.admin_set_plus_since(uuid, timestamptz) to authenticated;
