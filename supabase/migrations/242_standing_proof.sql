-- 242: proof on warnings and bans (flag `standing_proof`). "Users should get a proof of what they did."
--
-- Warnings and Yapper bans get an optional `proof`:
--   { message: {content, attachment, channel_name, server_name, kind, created_at, author_id},
--     context: [{content, created_at}] (up to 5 of the person's OWN lines around it),
--     note: text (from the mod), images: [up to 4 paths in the private `proofs` bucket] }
-- Staff attach it in the warn/ban dialog through mod_warn_with_proof / mod_ban_with_proof. Those wrap the live
-- mod_warn / mod_ban / site_ban unchanged (same checks, limits and logging) and add the proof in the same
-- transaction. The reported message comes from the report row, server-side, never from the client.
-- Nothing that could point at the reporter is copied: no reporter id, report id, reason, details, or anyone else's
-- lines. Messages from DMs and group chats can't be attached at all (in a 1:1 DM the reporter is obvious); a note can.
-- The person can select their own user_warnings / site_bans rows, so everything stored is safe for them to see.
-- The person reads the proof of their own active warnings and current ban through my_standing_proof(); staff see
-- it in the mod file (mod_user_case already returns whole rows). A re-ban drops the old ban's proof.
-- Re-runnable. No drop statements (the Supabase MCP hangs on them).

set lock_timeout = '2s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('standing_proof', 'Proof on warnings and bans',
  'Mods attach the reported message, a note and screenshots to warnings and bans. People see it under See why in Account standing and on the ban screen.',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- ---------- shape ----------

create or replace function public.standing_proof_ok(p jsonb)
returns boolean language plpgsql immutable set search_path = public as $$
declare m jsonb; e jsonb; k text;
begin
  if p is null then return true; end if;
  if jsonb_typeof(p) <> 'object' or octet_length(p::text) > 32768 then return false; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('message', 'context', 'note', 'images') then return false; end if;
  end loop;
  m := p -> 'message';
  if m is not null and jsonb_typeof(m) <> 'null' then
    if jsonb_typeof(m) <> 'object' then return false; end if;
    for k in select jsonb_object_keys(m) loop
      if k not in ('content', 'attachment', 'channel_name', 'server_name', 'kind', 'created_at', 'author_id') then return false; end if;
      if jsonb_typeof(m -> k) not in ('string', 'null') then return false; end if;
    end loop;
    if char_length(coalesce(m ->> 'content', '')) > 4000 or char_length(coalesce(m ->> 'attachment', '')) > 300
       or char_length(coalesce(m ->> 'channel_name', '')) > 100 or char_length(coalesce(m ->> 'server_name', '')) > 100 then
      return false;
    end if;
  end if;
  if p ? 'context' then
    if jsonb_typeof(p -> 'context') <> 'array' or jsonb_array_length(p -> 'context') > 5 then return false; end if;
    for e in select jsonb_array_elements(p -> 'context') loop
      if jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'content') is distinct from 'string' or char_length(e ->> 'content') > 300 then return false; end if;
      for k in select jsonb_object_keys(e) loop
        if k not in ('content', 'created_at') then return false; end if;
      end loop;
    end loop;
  end if;
  if p ? 'note' and (jsonb_typeof(p -> 'note') <> 'string' or char_length(p ->> 'note') > 500) then return false; end if;
  if p ? 'images' then
    if jsonb_typeof(p -> 'images') <> 'array' or jsonb_array_length(p -> 'images') > 4 then return false; end if;
    for e in select jsonb_array_elements(p -> 'images') loop
      if jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}\.(png|jpe?g|webp)$' then return false; end if;
    end loop;
  end if;
  return true;
end $$;

alter table public.user_warnings add column if not exists proof jsonb;
alter table public.site_bans add column if not exists proof jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'user_warnings_proof_ok') then
    alter table public.user_warnings add constraint user_warnings_proof_ok check (public.standing_proof_ok(proof));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'site_bans_proof_ok') then
    alter table public.site_bans add constraint site_bans_proof_ok check (public.standing_proof_ok(proof));
  end if;
end $$;

-- A ban that starts over (re-ban: created_at reset) loses the old ban's proof unless the same statement sets a new
-- one. Covers every ban path (mod_ban, site_ban, automatic bans), so old proof never shows next to a new reason.
create or replace function public.site_bans_proof_reset()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.proof is not distinct from old.proof then new.proof := null; end if;
  return new;
end $$;
revoke all on function public.site_bans_proof_reset() from public, anon, authenticated;
create or replace trigger site_bans_proof_reset
  before update of created_at on public.site_bans
  for each row when (new.created_at is distinct from old.created_at)
  execute function public.site_bans_proof_reset();

-- ---------- building it (staff, server-side) ----------

-- Internal: called only by the two functions below, after their staff check. Not callable by anyone else.
create or replace function public.standing_proof_build(uid uuid, rid uuid, with_message boolean, note text, images text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r public.reports;
  ch_kind text;
  ch_name text;
  sv_name text;
  msg jsonb;
  ctx jsonb;
  msg_at timestamptz;
  n text := nullif(left(btrim(coalesce(note, '')), 500), '');
  imgs text[];
  p text;
begin
  -- Screenshots: up to 4, each one this mod uploaded to their own folder in the private `proofs` bucket.
  select coalesce(array_agg(x order by i), '{}') into imgs
    from (select distinct on (btrim(x)) btrim(x) x, i from unnest(coalesce(images, '{}')) with ordinality u(x, i)
          where x is not null and btrim(x) <> '' order by btrim(x), i) d;
  if cardinality(imgs) > 4 then raise exception 'Up to 4 screenshots'; end if;
  foreach p in array imgs loop
    if p !~ ('^' || me::text || '/[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}\.(png|jpe?g|webp)$') then raise exception 'That screenshot can''t be used'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'proofs' and o.name = p) then
      raise exception 'A screenshot didn''t finish uploading. Add it again.';
    end if;
  end loop;

  if rid is not null and coalesce(with_message, true) then
    select * into r from public.reports where id = rid;
    if r.id is null or r.target_id is distinct from uid then raise exception 'That report isn''t about them'; end if;
    if r.message_content is not null or r.message_attachment is not null or r.channel_id is not null then
      select c.kind, c.name, s.name into ch_kind, ch_name, sv_name
        from public.channels c left join public.servers s on s.id = r.server_id where c.id = r.channel_id;
      -- A message report with no server is a DM or group chat, even if the channel is gone.
      ch_kind := coalesce(ch_kind, case when r.server_id is null then 'dm' end);
      if ch_kind in ('dm', 'group') then
        raise exception 'Messages from DMs can''t be attached, it would show who reported. Add a note instead.';
      end if;
    end if;
    if r.message_content is not null or r.message_attachment is not null then
      msg_at := coalesce((select m.created_at from public.messages m where m.id = r.message_id), r.created_at);
      msg := jsonb_build_object(
        'content', left(r.message_content, 4000),
        'attachment', left(r.message_attachment, 300),
        'kind', ch_kind,
        'channel_name', left(ch_name, 100),
        'server_name', left(sv_name, 100),
        'created_at', msg_at,
        'author_id', r.target_id);
    end if;
    -- Context: only the person's own lines (never the reporter's or anyone else's), and only from server channels
    -- that still exist: the channel is looked up, the evidence's own 'kind' isn't trusted.
    select jsonb_agg(jsonb_build_object('content', x.content, 'created_at', x.created_at) order by x.created_at)
      into ctx
      from (
        select left(e ->> 'content', 300) as content, (e ->> 'created_at')::timestamptz as created_at
          from jsonb_array_elements(case when jsonb_typeof(r.evidence) = 'array' then r.evidence else '[]'::jsonb end) e
         where e ->> 'author_id' = uid::text
           and btrim(coalesce(e ->> 'content', '')) <> ''
           and exists (select 1 from public.channels c
                        where c.id = case when e ->> 'channel_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                          then (e ->> 'channel_id')::uuid end
                          and c.kind not in ('dm', 'group'))
         order by abs(extract(epoch from ((e ->> 'created_at')::timestamptz - coalesce(msg_at, r.created_at))))
         limit 5
      ) x;
  elsif rid is not null then
    -- Not attaching the message: still check the report is about them.
    if not exists (select 1 from public.reports where id = rid and target_id = uid) then raise exception 'That report isn''t about them'; end if;
  end if;

  if msg is null and ctx is null and n is null and cardinality(imgs) = 0 then return null; end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'message', msg,
    'context', ctx,
    'note', n,
    'images', case when cardinality(imgs) > 0 then to_jsonb(imgs) end));
end $$;
revoke all on function public.standing_proof_build(uuid, uuid, boolean, text, text[]) from public, anon, authenticated;

-- Warn with proof. Same rules as mod_warn (which it calls as it is live), plus the proof on the new warning.
create or replace function public.mod_warn_with_proof(uid uuid, why text, rid uuid default null, with_message boolean default true,
  note text default null, images text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare pr jsonb;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if not public.feature_on_for_me('standing_proof') then raise exception 'Proof isn''t on for you yet'; end if;
  pr := public.standing_proof_build(uid, rid, with_message, note, images);
  perform public.mod_warn(uid, why);
  if pr is not null then
    -- The warning mod_warn just added: same transaction, so its created_at is exactly now().
    update public.user_warnings set proof = pr
     where id = (select w.id from public.user_warnings w where w.user_id = uid and w."by" = auth.uid() and w.created_at = now() limit 1);
  end if;
end $$;
revoke all on function public.mod_warn_with_proof(uuid, text, uuid, boolean, text, text[]) from public, anon;
grant execute on function public.mod_warn_with_proof(uuid, text, uuid, boolean, text, text[]) to authenticated;

-- Ban with proof. Admins go through site_ban (permanent, optional wipe), moderators through mod_ban (7 days),
-- exactly like the dialog does today, then the proof goes on the ban row that call just (re)started.
create or replace function public.mod_ban_with_proof(uid uuid, why text, wipe boolean default false, rid uuid default null,
  with_message boolean default true, note text default null, images text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare pr jsonb;
begin
  if not public.is_staff() then raise exception 'Moderators only'; end if;
  if not public.feature_on_for_me('standing_proof') then raise exception 'Proof isn''t on for you yet'; end if;
  pr := public.standing_proof_build(uid, rid, with_message, note, images);
  if public.is_site_admin() then
    perform public.site_ban(uid, why, coalesce(wipe, false));
  else
    if coalesce(wipe, false) then raise exception 'Only an admin can delete all their messages'; end if;
    perform public.mod_ban(uid, why);
  end if;
  if pr is not null then
    update public.site_bans set proof = pr where user_id = uid and created_at = now();
  end if;
end $$;
revoke all on function public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[]) from public, anon;
grant execute on function public.mod_ban_with_proof(uuid, text, boolean, uuid, boolean, text, text[]) to authenticated;

-- ---------- reading it (the person) ----------

-- What the person gets back: no author id (it's them; the app shows "You").
create or replace function public.standing_proof_public(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select case when p is null then null else p #- '{message,author_id}' end;
$$;

-- My own proof: active warnings (last 90 days, not removed) and my current ban. Nobody else's, ever.
create or replace function public.my_standing_proof()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then return null; end if;
  if not public.feature_on_for_me('standing_proof') then
    return jsonb_build_object('on', false, 'warnings', '[]'::jsonb, 'ban', null);
  end if;
  return jsonb_build_object(
    'on', true,
    'warnings', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'at', w.created_at, 'proof', public.standing_proof_public(w.proof)) order by w.created_at desc)
        from public.user_warnings w
       where w.user_id = me and w.removed_at is null and w.created_at > now() - interval '90 days' and w.proof is not null), '[]'::jsonb),
    'ban', (select public.standing_proof_public(b.proof) from public.site_bans b
             where b.user_id = me and (b.expires_at is null or b.expires_at > now()) and b.proof is not null));
end $$;
revoke all on function public.my_standing_proof() from public, anon;
grant execute on function public.my_standing_proof() to authenticated;

-- Screenshot paths in my own proof (same set as above), for the storage read policy below.
create or replace function public.my_standing_proof_images()
returns setof text language sql stable security definer set search_path = public as $$
  select x from (
    select jsonb_array_elements_text(w.proof -> 'images') x
      from public.user_warnings w
     where w.user_id = auth.uid() and w.removed_at is null and w.created_at > now() - interval '90 days'
       and jsonb_typeof(w.proof -> 'images') = 'array'
    union
    select jsonb_array_elements_text(b.proof -> 'images')
      from public.site_bans b
     where b.user_id = auth.uid() and (b.expires_at is null or b.expires_at > now())
       and jsonb_typeof(b.proof -> 'images') = 'array'
  ) s
  where public.feature_on_for_me('standing_proof');
$$;
revoke all on function public.my_standing_proof_images() from public, anon;
grant execute on function public.my_standing_proof_images() to authenticated;

-- The person can open (signed link) a screenshot attached to their own warning or ban. Staff already read the
-- whole bucket ("proofs: read own or admin"); uploads stay in the uploader's own folder ("proofs: upload own").
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs: read proof about me') then
    create policy "proofs: read proof about me" on storage.objects for select to authenticated
      using (bucket_id = 'proofs' and name in (select public.my_standing_proof_images()));
  end if;
end $$;
