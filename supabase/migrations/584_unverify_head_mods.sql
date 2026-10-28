-- 584: head moderators can take the verified badge away (profiles.verified_as), same as admins.
-- Admins: no reason needed, no cap (unchanged). Head mods (365, flag head_mods): no reason needed, but
-- mod_guard applies (no staff targets, not yourself, the hourly cap for 'unverify': 60). Plain mods: unchanged,
-- only with flag mod_verify, a reason of 5+ characters and mod_guard. Everyone else: refused. Re-runnable.

create or replace function public.unverify(uid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_site_admin() then
    null;
  elsif public.is_head_mod() then
    perform public.mod_guard('unverify', uid, p_note);
  elsif public.is_site_mod() and public.feature_on('mod_verify', null) then
    if length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
    perform public.mod_guard('unverify', uid, p_note);
  else
    raise exception 'Admins and head mods only';
  end if;
  update public.profiles set verified_as = null where id = uid and verified_as is not null;
  if not found then raise exception 'They aren''t verified'; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unverify', uid, coalesce(p_note, ''));
end;
$$;

revoke all on function public.unverify(uuid, text) from public, anon;
grant execute on function public.unverify(uuid, text) to authenticated;
