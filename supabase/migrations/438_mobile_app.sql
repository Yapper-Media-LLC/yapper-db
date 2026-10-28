-- 438: Yapin' phone app (flag mobile_app, test): push notification tokens and the push hook.
-- The app (mobile/, a Capacitor shell around the web app) registers its Firebase token through
-- POST /api/push/register, which writes it here with the service role. A new message that would ping someone
-- (a DM or group message; an @mention, role mention or reply in a server) posts one request to
-- /api/push/send on Vercel (pg_net, same pattern as bc_notice), which sends through Firebase Cloud Messaging.
-- The hook costs one indexed read per message while nobody has a token (the exists below) and nothing while the flag is off.
-- Needs two vault secrets: push_url (https://www.yapper.website) and push_secret (= Vercel env PUSH_SECRET).
-- Re-runnable.

set lock_timeout = '5s';

create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_tokens_token_len check (char_length(token) between 20 and 4096)
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;
-- Only your own rows, in every direction (the API route writes with the service role; this is the floor).
drop policy if exists "push tokens: own read" on public.push_tokens;
create policy "push tokens: own read" on public.push_tokens for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "push tokens: own add" on public.push_tokens;
create policy "push tokens: own add" on public.push_tokens for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists "push tokens: own change" on public.push_tokens;
create policy "push tokens: own change" on public.push_tokens for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "push tokens: own remove" on public.push_tokens;
create policy "push tokens: own remove" on public.push_tokens for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.push_tokens from public, anon;
grant select, insert, update, delete on public.push_tokens to authenticated;
grant all on public.push_tokens to service_role;

-- A message lands: who should get a phone notification, and tell Vercel. Mirrors the ping rules in
-- broadcast_message_change (316) and noteIncoming (lib/actions.ts): DMs and groups on every message, servers only on
-- @you / your role / a reply to you; never your own, forwarded ones, people you blocked, DND, a muted DM, a muted
-- server, a private channel you can't see, non-members, or anyone site-banned.
create or replace function public.push_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid; restricted boolean; body text; targets uuid[]; keep uuid[] := '{}'; uid uuid; vis boolean;
  old_claims text; old_sub text; url text; secret text;
  uuid_re constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if current_setting('yapper.bulk', true) = '1' then return null; end if;
  if new.author_id is null then return null; end if;
  if not exists (select 1 from public.feature_flags f where f.key = 'mobile_app' and f.mode in ('test', 'everyone')) then return null; end if;
  if not exists (select 1 from public.push_tokens) then return null; end if;
  body := coalesce(new.content, '');
  if starts_with(body, chr(8618) || ' Forwarded' || chr(10)) then return null; end if;

  select ch.server_id,
         coalesce(ch.private, false)
         or exists (select 1 from public.channel_overrides ov where ov.channel_id = ch.id or (ch.category_id is not null and ov.category_id = ch.category_id))
    into sid, restricted
    from public.channels ch where ch.id = new.channel_id;

  if sid is null then
    select array_agg(cm.user_id) into targets from public.channel_members cm
      where cm.channel_id = new.channel_id and cm.user_id <> new.author_id;
  else
    if strpos(body, '<@') = 0 and new.reply_to_id is null then return null; end if;
    select array_agg(distinct t.x) into targets from (
      (select m[1]::uuid as x from regexp_matches(body, '<@(' || uuid_re || ')>', 'g') m limit 20)
      union all
      (select mr.user_id from public.member_roles mr
        where mr.server_id = sid
          and mr.role_id in (select m[1]::uuid from regexp_matches(body, '<@&(' || uuid_re || ')>', 'g') m limit 10)
        limit 50)
      union all
      (select pm.author_id from public.messages pm where new.reply_to_id is not null and pm.id = new.reply_to_id and pm.channel_id = new.channel_id)
    ) t where t.x is not null and t.x <> new.author_id;
  end if;
  if targets is null then return null; end if;

  old_claims := current_setting('request.jwt.claims', true);
  old_sub := current_setting('request.jwt.claim.sub', true);
  foreach uid in array targets loop
    if not exists (select 1 from public.push_tokens t where t.user_id = uid) then continue; end if;
    if public.is_site_banned(uid) then continue; end if;
    if exists (select 1 from public.blocks b where b.blocker = uid and b.blocked = new.author_id) then continue; end if;
    if exists (select 1 from public.presence p where p.user_id = uid and p.pref = 'dnd') then continue; end if;
    if sid is null then
      if exists (select 1 from public.channel_reads r where r.user_id = uid and r.channel_id = new.channel_id and r.muted) then continue; end if;
    else
      if not exists (select 1 from public.server_members sm where sm.server_id = sid and sm.user_id = uid) then continue; end if;
      if exists (select 1 from public.server_mutes m where m.user_id = uid and m.server_id = sid) then continue; end if;
      if coalesce(restricted, false) then
        perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
        perform set_config('request.jwt.claim.sub', uid::text, true);
        vis := public.can_access_channel(new.channel_id);
        perform set_config('request.jwt.claims', coalesce(nullif(old_claims, ''), '{}'), true);
        perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
        if not coalesce(vis, false) then continue; end if;
      end if;
    end if;
    keep := keep || uid;
  end loop;
  if cardinality(keep) = 0 then return null; end if;

  -- Only here (a real push) is there a sub-transaction: a vault or pg_net problem must never fail the message itself.
  begin
    select decrypted_secret into url from vault.decrypted_secrets where name = 'push_url';
    select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_secret';
    if url is null or secret is null then return null; end if;
    perform net.http_post(
      url := rtrim(url, '/') || '/api/push/send',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
      body := jsonb_build_object('id', new.id, 'channel_id', new.channel_id, 'server_id', sid, 'author_id', new.author_id,
                                 'content', left(body, 300), 'attachment', new.attachment_path is not null, 'to', to_jsonb(keep)),
      timeout_milliseconds := 5000);
  exception when others then
    return null;
  end;
  return null;
end; $$;
revoke all on function public.push_on_message() from public, anon, authenticated;

drop trigger if exists push_on_message on public.messages;
create trigger push_on_message after insert on public.messages
  for each row execute function public.push_on_message();

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mobile_app', 'Yapin'' phone app', 'Push notifications for the Android and iOS app (DMs, @mentions and replies). The app itself is a shell around the site.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

reset lock_timeout;
