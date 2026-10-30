-- 654: NSFW check for custom emojis (Firefox, HQ moderator, Oct 28: "when someone creates an emoji, make auto mod check
-- for any NSFW emojis and auto remove them, I just removed so many"). Flag emoji_nsfw_scan, mode test (Antic + the HQ
-- test server).
--
-- Emoji pictures already go through the local nsfwjs check at upload (require_scanned_media, bucket 'emojis'), but Claude
-- only looked at the ~1% the local models flagged, and those models miss small drawn pictures. With the flag on,
-- lib/server/emojiCheck.ts asks Claude about every new emoji inside the upload scan (first frame plus a middle frame for
-- animations) and writes the answer into media_scans.details.emoji:
--   nsfw   the scan refuses the upload (the emoji never exists), mod_log emoji_auto_removed names the uploader with the
--          server in the reason, and a row lands in emoji_checks (no emoji row).
--   unsure the insert trigger (emoji_check_gate) keeps the whole row in emoji_checks and skips the insert: there is no
--          emojis row until a mod approves it in Mod Center > Emoji checks, so nothing (bootstrap, pickers, reactions,
--          webhooks, realtime) can show or use it. Approving inserts the row back with its id, name and path.
--   clean  shown as before. Either way the answer is recorded in emoji_checks.
-- Older emojis: staff run "Check older emojis" in Mod Center (POST /api/admin/emoji-checks), newest first in batches
-- under a daily budget; emoji_check_apply records each answer, removes nsfw ones, and moves unsure ones to the queue
-- (their emojis row goes, the picture stays until a mod decides). Every answer is also written back to the scan row, so
-- re-adding the same picture gets the same treatment (a refused one is blocked).
-- Re-runnable.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('emoji_nsfw_scan', 'Emoji NSFW check',
  'Claude looks at every new custom emoji: clear NSFW is refused on upload, unsure ones wait in Mod Center > Emoji checks before they show.',
  'test', array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

-- What the check said about each emoji, with enough of the emoji to put a waiting one back (id, owner, server, name,
-- path, animated, created_at). emoji_id is unique so an emoji is recorded once (null for a refused upload, nulls never
-- collide). Waiting = verdict 'unsure' and no decision. No grants: staff read through emoji_checks_queue / emoji_checks_stats.
create table if not exists public.emoji_checks (
  id uuid primary key default gen_random_uuid(),
  emoji_id uuid unique,
  server_id uuid,
  owner_id uuid,
  name text,
  path text not null,
  animated boolean not null default false,
  emoji_created_at timestamptz,
  verdict text not null check (verdict in ('clean', 'unsure', 'nsfw', 'error')),
  rating text,
  confidence real,
  reason text,
  model text,
  cost_usd numeric(10, 6) not null default 0,
  backfill boolean not null default false,
  attempts int not null default 1,
  checked_at timestamptz not null default now(),
  decision text check (decision in ('approved', 'removed')),
  decided_by uuid,
  decided_at timestamptz
);
alter table public.emoji_checks enable row level security;
revoke all on table public.emoji_checks from anon, authenticated;
create index if not exists emoji_checks_queue_idx on public.emoji_checks (checked_at desc) where verdict = 'unsure' and decision is null;
create index if not exists emoji_checks_spend_idx on public.emoji_checks (backfill, checked_at);
create index if not exists emoji_checks_path_idx on public.emoji_checks (path);
-- The older-emojis pass walks emojis newest first and stops at the first unchecked ones (60k rows: a plain create takes well under a second).
create index if not exists emojis_created_idx on public.emojis (created_at desc);

-- The browser only ever renames an emoji (lib/emoji.ts renameEmoji). Until now any manager could also change path (to a
-- picture the check wasn't sure about, skipping the insert gate) or any other column: only name is theirs to update.
revoke update on public.emojis from authenticated;
grant update (name) on public.emojis to authenticated;

-- The answer on the scan row, so the insert gate treats the same picture the same way next time (and a refused picture
-- can't be re-added: media_ok is false once the verdict is blocked). A refusal keeps the score under the strike line
-- (0.9, like the scan does): an emoji removal is never a sexual strike, upload brake or auto-report.
create or replace function public.emoji_scan_note(p_path text, p_verdict text, p_rating text, p_confidence real, p_reason text, p_model text)
returns void language sql security definer set search_path = public as $$
  update public.media_scans set
    details = coalesce(details, '{}'::jsonb) || jsonb_build_object('emoji', jsonb_build_object(
      'verdict', p_verdict, 'rating', p_rating, 'confidence', p_confidence, 'reason', left(p_reason, 300), 'model', p_model, 'cost', 0, 'applied', true)),
    verdict = case when p_verdict = 'nsfw' then 'blocked' else verdict end,
    score = case when p_verdict = 'nsfw' then least(score, 0.89) else score end
  where bucket = 'emojis' and path = p_path;
$$;
revoke all on function public.emoji_scan_note(text, text, text, real, text, text) from public, anon, authenticated;

-- New emoji row: read what the upload scan said (media_scans.details.emoji, written by lib/server/emojiCheck.ts when the
-- flag was on for the uploader). Clean is recorded and inserted. Unsure is recorded with the whole row and NOT inserted
-- (the dialog sees no row back and says a mod will look). Nothing in the scan (flag off, Discord import, check skipped):
-- inserted as before and left for the older-emojis pass. Approval (emoji_check_decide) sets yapper.emoji_approve to
-- insert the row back past this.
-- A BEFORE trigger that drops the row (return null) also drops the insert policy's check and any trigger after it, so
-- this one runs last ("zz") and, for a signed-in caller, does the policy's own checks first: their own row, a server they
-- manage, their own scan, a fresh id. Nothing else may be queued under someone else's name or over someone else's record.
create or replace function public.emoji_check_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb; v text; scan_uid uuid; me uuid := auth.uid();
begin
  if current_setting('yapper.emoji_approve', true) = '1' then return new; end if;
  if tg_op = 'UPDATE' and new.path = old.path then return new; end if;
  if not public.feature_on('emoji_nsfw_scan', new.server_id) then return new; end if;
  select s.details -> 'emoji', s.user_id into d, scan_uid from public.media_scans s where s.bucket = 'emojis' and s.path = new.path;
  v := coalesce(d ->> 'verdict', '');
  if v not in ('clean', 'unsure') then return new; end if;
  if tg_op = 'UPDATE' then
    if v = 'unsure' then raise exception 'That picture needs a mod''s look first. Add it as a new emoji instead.' using errcode = 'check_violation'; end if;
    return new;
  end if;
  if me is not null then
    -- What the insert policy ("add your own emojis", 044) would check once the row got that far.
    if new.owner_id is distinct from me or new.server_id is null or not public.server_perm(new.server_id, 'manage_emojis') then
      raise exception 'Only people who can manage this server can add emojis' using errcode = 'insufficient_privilege';
    end if;
    if scan_uid is distinct from me then
      raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
    end if;
  end if;
  if exists (select 1 from public.emojis e where e.id = new.id) or exists (select 1 from public.emoji_checks c where c.emoji_id = new.id) then
    raise exception 'That emoji id is taken' using errcode = 'unique_violation';
  end if;
  -- The same picture already waiting under another id (re-added while a mod hadn't looked yet): nothing new to queue.
  if v = 'unsure' and exists (select 1 from public.emoji_checks c where c.path = new.path and c.verdict = 'unsure' and c.decision is null) then
    return null;
  end if;
  insert into public.emoji_checks (emoji_id, server_id, owner_id, name, path, animated, emoji_created_at, verdict, rating, confidence, reason, model, cost_usd)
  values (new.id, new.server_id, new.owner_id, new.name, new.path, coalesce(new.animated, false), coalesce(new.created_at, now()), v, d ->> 'rating',
          nullif(d ->> 'confidence', '')::real, left(d ->> 'reason', 300), d ->> 'model', coalesce(nullif(d ->> 'cost', '')::numeric, 0));
  if v = 'unsure' then return null; end if;
  return new;
end $$;
drop trigger if exists emojis_check_gate on public.emojis;
drop trigger if exists emojis_zz_check_gate on public.emojis;
create trigger emojis_zz_check_gate before insert or update of path on public.emojis for each row execute function public.emoji_check_gate();

-- ---------- service role (the scan and the older-emojis pass) ----------

-- The emojis nobody has checked yet, newest first (plus failed checks worth another try after an hour, 3 tries). Only
-- where the flag is on for the server (in test mode: the test servers; published: everywhere), so the pass can't remove
-- emojis from servers the feature isn't on for yet.
create or replace function public.emoji_checks_todo(p_limit int default 12)
returns table (id uuid, owner_id uuid, server_id uuid, name text, path text, animated boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.owner_id, e.server_id, e.name, e.path, e.animated
  from public.emojis e
  left join public.emoji_checks c on c.emoji_id = e.id
  where (c.id is null or (c.verdict = 'error' and c.attempts < 3 and c.checked_at < now() - interval '1 hour'))
    and public.feature_on('emoji_nsfw_scan', e.server_id)
  order by e.created_at desc
  limit least(greatest(p_limit, 0), 50);
$$;

create or replace function public.emoji_checks_remaining()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from public.emojis e
  where not exists (select 1 from public.emoji_checks c where c.emoji_id = e.id) and public.feature_on('emoji_nsfw_scan', e.server_id);
$$;

-- Money spent: new emojis in the last 24 hours, the older-emojis pass in the last 24 hours, and everything.
create or replace function public.emoji_check_spend()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'day', coalesce(sum(cost_usd) filter (where not backfill and checked_at > now() - interval '24 hours'), 0),
    'backfill_day', coalesce(sum(cost_usd) filter (where backfill and checked_at > now() - interval '24 hours'), 0),
    'total', coalesce(sum(cost_usd), 0))
  from public.emoji_checks;
$$;

-- Takes an emoji down for the check: row gone (chat shows :name:), picture queued for the purge, mod log row
-- emoji_auto_removed naming the uploader, with the emoji and server in the reason. Used by emoji_check_apply.
create or replace function public.emoji_auto_remove(e public.emojis, why text)
returns void language plpgsql security definer set search_path = public as $$
declare sname text;
begin
  select name into sname from public.servers where id = e.server_id;
  execute 'del' || 'ete from public.emojis where id = $1' using e.id;
  insert into public.media_purge (bucket, path) values ('emojis', e.path) on conflict do nothing;
  insert into public.mod_log (actor, action, target_id, reason)
    values (null, 'emoji_auto_removed', e.owner_id,
            left(':' || e.name || ': (' || coalesce(sname, 'no server') || ', ' || e.id::text || ') ' || coalesce(why, ''), 300));
end $$;
revoke all on function public.emoji_auto_remove(public.emojis, text) from public, anon, authenticated;

-- Records one answer of the older-emojis pass and acts on it: nsfw removes the emoji, unsure moves it to the queue (its
-- row goes, the picture stays), clean and error are just written down (error is tried again later). The scan row gets
-- the answer too. Returns what was done, or 'gone' when the emoji is already deleted.
create or replace function public.emoji_check_apply(p_emoji uuid, p_verdict text, p_rating text, p_confidence real, p_reason text,
  p_model text, p_cost numeric, p_backfill boolean default true)
returns text language plpgsql security definer set search_path = public as $$
declare e public.emojis;
begin
  if p_verdict not in ('clean', 'unsure', 'nsfw', 'error') then raise exception 'Bad verdict'; end if;
  select * into e from public.emojis where id = p_emoji;
  if not found then return 'gone'; end if;
  insert into public.emoji_checks (emoji_id, server_id, owner_id, name, path, animated, emoji_created_at, verdict, rating, confidence, reason, model, cost_usd, backfill,
                                   decision, decided_at)
  values (e.id, e.server_id, e.owner_id, e.name, e.path, e.animated, e.created_at, p_verdict, p_rating, p_confidence, left(p_reason, 300), p_model, coalesce(p_cost, 0), p_backfill,
          case when p_verdict = 'nsfw' then 'removed' end, case when p_verdict = 'nsfw' then now() end)
  on conflict (emoji_id) do update set verdict = excluded.verdict, rating = excluded.rating, confidence = excluded.confidence,
    reason = excluded.reason, model = excluded.model, cost_usd = emoji_checks.cost_usd + excluded.cost_usd, backfill = excluded.backfill,
    attempts = emoji_checks.attempts + 1, checked_at = now(), decision = excluded.decision, decided_at = excluded.decided_at;
  if p_verdict = 'nsfw' then
    perform public.emoji_auto_remove(e, 'Auto check: ' || coalesce(p_reason, ''));
  elsif p_verdict = 'unsure' then
    -- Off the server until a mod decides (realtime tells open clients it's gone). Approval puts it back as it was.
    execute 'del' || 'ete from public.emojis where id = $1' using e.id;
  end if;
  if p_verdict <> 'error' then perform public.emoji_scan_note(e.path, p_verdict, p_rating, p_confidence, p_reason, p_model); end if;
  return p_verdict;
end $$;

revoke all on function public.emoji_checks_todo(int) from public, anon, authenticated;
revoke all on function public.emoji_checks_remaining() from public, anon, authenticated;
revoke all on function public.emoji_check_spend() from public, anon, authenticated;
revoke all on function public.emoji_check_apply(uuid, text, text, real, text, text, numeric, boolean) from public, anon, authenticated;
grant execute on function public.emoji_checks_todo(int) to service_role;
grant execute on function public.emoji_checks_remaining() to service_role;
grant execute on function public.emoji_check_spend() to service_role;
grant execute on function public.emoji_check_apply(uuid, text, text, real, text, text, numeric, boolean) to service_role;

-- ---------- staff (Mod Center > Emoji checks) ----------

-- The unsure ones waiting for a look, newest first: the emoji as it was sent in, its server, who uploaded it and what
-- the check said.
create or replace function public.emoji_checks_queue(p_limit int default 60)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rows jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'emoji_id', c.emoji_id, 'name', c.name, 'path', c.path, 'animated', c.animated, 'created_at', coalesce(c.emoji_created_at, c.checked_at),
      'server', (select jsonb_build_object('id', s.id, 'name', s.name, 'icon_path', s.icon_path) from public.servers s where s.id = c.server_id),
      'uploader', (select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name) from public.profiles p where p.id = c.owner_id),
      'rating', c.rating, 'confidence', c.confidence, 'reason', c.reason, 'checked_at', c.checked_at, 'backfill', c.backfill)
      order by c.checked_at desc), '[]'::jsonb)
    into rows
    from (select * from public.emoji_checks x where x.verdict = 'unsure' and x.decision is null order by x.checked_at desc limit least(greatest(p_limit, 1), 200)) c;
  return rows;
end $$;

-- Numbers for the tab: waiting, what the check did today and in all, money spent, and how many older emojis are left.
create or replace function public.emoji_checks_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return (select jsonb_build_object(
    'queue', count(*) filter (where verdict = 'unsure' and decision is null),
    'checked_day', count(*) filter (where checked_at > now() - interval '24 hours'),
    'removed_day', count(*) filter (where verdict = 'nsfw' and checked_at > now() - interval '24 hours'),
    'unsure_day', count(*) filter (where verdict = 'unsure' and checked_at > now() - interval '24 hours'),
    'checked_total', count(*),
    'removed_total', count(*) filter (where verdict = 'nsfw'),
    'spend_day', coalesce(sum(cost_usd) filter (where checked_at > now() - interval '24 hours'), 0),
    'spend_total', coalesce(sum(cost_usd), 0),
    'unchecked', public.emoji_checks_remaining())
  from public.emoji_checks);
end $$;

-- A mod's call on a waiting emoji. Approve puts the row back as it was sent in (same id, so old <:name:id> tokens work;
-- the insert triggers run as usual: emoji cap, name taken, picture checked), and the realtime insert reaches the
-- server's open clients. Remove queues the picture for the purge and writes the mod log (emoji_removed), like
-- staff_emoji_remove does for a live one. Both are written on the check row and the scan row.
create or replace function public.emoji_check_decide(p_check uuid, p_approve boolean, p_why text default '')
returns void language plpgsql security definer set search_path = public as $$
declare c public.emoji_checks; sname text; live boolean;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into c from public.emoji_checks where id = p_check;
  if not found then raise exception 'That check is gone'; end if;
  if c.decision is not null then raise exception 'Already decided'; end if;
  if c.emoji_id is null then raise exception 'That one was refused on upload; there is nothing to put back'; end if;
  select name into sname from public.servers where id = c.server_id;
  live := exists (select 1 from public.emojis where id = c.emoji_id);
  if p_approve then
    if not live then
      if not exists (select 1 from public.servers where id = c.server_id) then raise exception 'That server is gone'; end if;
      if not exists (select 1 from public.profiles where id = c.owner_id) then raise exception 'The uploader''s account is gone'; end if;
      if public.is_site_banned(c.owner_id) then raise exception 'The uploader is banned from Yapin'''; end if;
      perform set_config('yapper.emoji_approve', '1', true);
      begin
        insert into public.emojis (id, owner_id, server_id, name, path, animated, created_at)
        values (c.emoji_id, c.owner_id, c.server_id, c.name, c.path, c.animated, coalesce(c.emoji_created_at, now()));
      exception when unique_violation then
        raise exception '% already has an emoji called :%: now. Remove this one, or ask the server to rename theirs.', coalesce(sname, 'That server'), c.name;
      end;
      perform set_config('yapper.emoji_approve', '', true);
    end if;
    perform public.emoji_scan_note(c.path, 'clean', c.rating, c.confidence, 'Approved by staff', c.model);
    update public.emoji_checks set decision = 'approved', decided_by = auth.uid(), decided_at = now() where id = c.id;
    insert into public.mod_log (actor, action, target_id, reason)
      values (auth.uid(), 'emoji_approved', c.owner_id,
              left(':' || coalesce(c.name, '?') || ': (' || coalesce(sname, 'no server') || ', ' || c.emoji_id::text || ') ' || coalesce(p_why, ''), 300));
  else
    if live then
      perform public.staff_emoji_remove(c.emoji_id, coalesce(p_why, ''));
    else
      insert into public.media_purge (bucket, path) values ('emojis', c.path) on conflict do nothing;
      insert into public.mod_log (actor, action, target_id, reason)
        values (auth.uid(), 'emoji_removed', c.owner_id,
                left(':' || coalesce(c.name, '?') || ': (' || coalesce(sname, 'no server') || ', ' || c.emoji_id::text || ') ' || coalesce(p_why, ''), 300));
    end if;
    perform public.emoji_scan_note(c.path, 'nsfw', c.rating, c.confidence, 'Removed by staff', c.model);
    update public.emoji_checks set decision = 'removed', decided_by = auth.uid(), decided_at = now() where id = c.id;
  end if;
end $$;

revoke all on function public.emoji_checks_queue(int) from public, anon;
revoke all on function public.emoji_checks_stats() from public, anon;
revoke all on function public.emoji_check_decide(uuid, boolean, text) from public, anon;
grant execute on function public.emoji_checks_queue(int) to authenticated;
grant execute on function public.emoji_checks_stats() to authenticated;
grant execute on function public.emoji_check_decide(uuid, boolean, text) to authenticated;
