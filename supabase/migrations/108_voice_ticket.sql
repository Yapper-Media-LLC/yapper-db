-- One round trip for a voice ticket. /api/livekit-token used to make seven calls in a row
-- (ban, channel, profile, sanctions, server timeout, server ban, settings); under load that
-- took 20 s. Returns {"error": text} when the person may not join, otherwise
-- {"name": text, "voice_muted": bool}.
create or replace function public.voice_ticket(cid uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  me uuid := auth.uid();
  ch record;
  p record;
  ban record;
  until_ts timestamptz;
  st record;
  wait_ms bigint;
begin
  if me is null then return jsonb_build_object('error', 'Not signed in'); end if;
  select user_id, expires_at into ban from public.site_bans where user_id = me;
  if found and (ban.expires_at is null or ban.expires_at > now()) then
    return jsonb_build_object('error', 'Your account is banned from Yapper');
  end if;
  select c.id, c.kind, c.server_id into ch from public.channels c
   where c.id = cid and c.kind in ('voice', 'dm', 'group') and public.can_access_channel(c.id);
  if not found then return jsonb_build_object('error', 'You can’t join that call'); end if;
  select username, created_at, muted_until, voice_muted_until into p from public.profiles where id = me;
  if p.muted_until is not null and p.muted_until > now() then
    return jsonb_build_object('error', 'You’re timed out until ' || to_char(p.muted_until at time zone 'UTC', 'HH24:MI') || ' UTC.');
  end if;
  if ch.server_id is not null then
    select t.until into until_ts from public.server_timeouts t where t.server_id = ch.server_id and t.user_id = me and t.until > now();
    if until_ts is not null then
      return jsonb_build_object('error', 'You’re timed out in this server until ' || to_char(until_ts at time zone 'UTC', 'HH24:MI') || ' UTC.');
    end if;
    if exists (select 1 from public.server_bans b where b.server_id = ch.server_id and b.user_id = me) then
      return jsonb_build_object('error', 'You’re banned from this server');
    end if;
    select default_server_id, new_account_wait into st from public.app_settings limit 1;
    if st.default_server_id = ch.server_id and st.new_account_wait is not null and p.created_at > now() - st.new_account_wait then
      wait_ms := extract(epoch from st.new_account_wait) * 1000;
      return jsonb_build_object('error', 'Welcome! New accounts can join voice here ' || ceil(wait_ms / 60000.0)::int || ' minutes after signing up.');
    end if;
  end if;
  return jsonb_build_object('name', coalesce(p.username, 'someone'),
                            'voice_muted', p.voice_muted_until is not null and p.voice_muted_until > now());
end $$;
revoke all on function public.voice_ticket(uuid) from public, anon;
grant execute on function public.voice_ticket(uuid) to authenticated;
