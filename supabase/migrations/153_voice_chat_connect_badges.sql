-- 153: voice channel chat (flag voice_chat): unread badges only for voice chats you can join.
-- Members who can see a voice channel but are denied Connect by an override can't open its chat
-- (145), so its unread count never cleared. Only costs anything for voice channels with live overrides.
-- Re-runnable: patches unread_counts_v2 in place (works on the 146 body that already has the vc branch).
do $$ declare d text; begin
  d := pg_get_functiondef('public.unread_counts_v2()'::regprocedure);
  if position('channel_perm(c.id, ''connect'')' in d) = 0 then
    d := replace(d,
      E'or (vc.mode = ''test'' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users)))))\n',
      E'or (vc.mode = ''test'' and (c.server_id = any(vc.servers) or auth.uid() = any(vc.users))))\n'
      || E'             and (not public.channel_overrides_live(c.id) or public.channel_perm(c.id, ''connect'')))\n');
    if position('channel_perm(c.id, ''connect'')' in d) = 0 then
      raise exception 'unread_counts_v2 voice connect patch did not apply';
    end if;
    execute d;
  end if;
end $$;
