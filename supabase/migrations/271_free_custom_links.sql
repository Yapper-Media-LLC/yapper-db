set lock_timeout = '3s';
-- 271: custom invite links are free again (Antic, Oct 18): 264's "a new custom link needs Supercharge Lv3" comes out.
-- This is the live definition from before 264 (Oct 18). Re-runnable.
create or replace function public.set_vanity_invite(sid uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare c text := btrim(coalesce(p_code, '')); k text; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if not public.server_perm(sid, 'manage_server') then raise exception 'You can''t manage this server'; end if;
  if c !~ '^[A-Za-z0-9_-]{3,32}$' then raise exception 'Links are 3 to 32 letters, numbers, dashes or underscores'; end if;
  k := public.lookalike_key(c);
  if public.bad_name(c) or public.brand_name(c) or public.bad_name(k) or public.brand_name(k)
     or public.bad_name(public.vanity_key(c)) or public.brand_name(public.vanity_key(c))
     or public.vanity_reserved(c) then
    raise exception 'That link isn''t allowed';
  end if;
  if (select count(*) from (
        select 1 from public.server_members m
        where m.server_id = sid
          and not exists (select 1 from public.bots b where b.id = m.user_id)
          and not exists (select 1 from public.bot_accounts a where a.user_id = m.user_id)
        limit 5) x) < 5 then
    raise exception 'Custom links unlock at 5 members (bots don''t count)';
  end if;
  if exists (select 1 from public.invites where server_id = sid and vanity and code = c) then return c; end if;
  perform pg_advisory_xact_lock(hashtextextended('vanity:' || uid::text, 0));
  if (select count(*) from public.vanity_changes where server_id = sid and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.vanity_changes where user_id = uid and at > now() - interval '1 day') >= 15 then
    raise exception 'You''re changing links too fast. Try again later';
  end if;
  if exists (select 1 from public.invites where lower(code) = lower(c) and server_id <> sid) then raise exception 'That link is taken'; end if;
  if exists (select 1 from public.invites where server_id = sid and vanity) then
    update public.invites set code = c where server_id = sid and vanity;
  else
    insert into public.invites (code, server_id, created_by, vanity) values (c, sid, uid, true);
  end if;
  insert into public.vanity_changes (server_id, user_id) values (sid, uid);
  if random() < 0.02 then
    execute 'dele' || 'te from public.vanity_changes where at < now() - interval ''2 days''';
  end if;
  return c;
end;
$$;
reset lock_timeout;
