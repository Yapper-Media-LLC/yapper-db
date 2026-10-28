-- 516: Stage channels (flag stage_channels, test: HQ test server). Asked for in HQ for Q&As: "so people come
-- in muted". channels.stage turns a voice channel into a stage: people who join are listeners and can't talk (the
-- LiveKit ticket has no publish right, app/api/livekit-token, so a modified app can't get around it). Stage mods
-- (Mute Members, which Administrator and the owner have, and Yapin' staff) always can. Listeners raise a hand (a
-- LiveKit participant attribute, nothing stored) and a mod brings them up or sends them back (/api/voice/moderate
-- stage_up / stage_down, which flip the publish right on LiveKit). Being brought up lasts until you leave the call.
--   stage_role(cid)          as the signed-in user: 'mod', 'listener', or null (not a stage, flag off, can't see it)
--   stage_role_for(uid, cid) the same for someone else (service role only: moves, bot tickets, the moderate route);
--                            on a live stage it never says null: anyone who isn't a mod is a listener (fail closed)
-- The flag is read per server only (no per-user test list), so everyone in a server gets the same answer.
-- Re-runnable, no data changes.
set lock_timeout = '3s';

alter table public.channels add column if not exists stage boolean not null default false;

-- Only voice channels can be stages. not valid: existing rows all have stage = false, no need to scan them.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'channels_stage_voice' and conrelid = 'public.channels'::regclass) then
    alter table public.channels add constraint channels_stage_voice check (not stage or kind = 'voice') not valid;
  end if;
end $$;

create or replace function public.stage_role(cid uuid)
returns text
language plpgsql
stable security definer
set search_path = public
as $$
declare
  c record;
begin
  if auth.uid() is null or cid is null then return null; end if;
  select ch.id, ch.server_id, ch.stage into c from public.channels ch where ch.id = cid and ch.kind = 'voice';
  if not found or not c.stage or c.server_id is null then return null; end if;
  if not exists (select 1 from public.feature_flags f where f.key = 'stage_channels'
                  and (f.mode = 'everyone' or (f.mode = 'test' and c.server_id = any(f.servers)))) then
    return null;
  end if;
  if not public.can_access_channel(cid) then return null; end if;
  if public.is_staff() or public.server_perm(c.server_id, 'mute_members') then return 'mod'; end if;
  return 'listener';
end $$;
revoke all on function public.stage_role(uuid) from public, anon;
grant execute on function public.stage_role(uuid) to authenticated, service_role;

-- Same claims swap as voice_ticket_for (151): auth.uid() is uid for this one call, then the caller's claims go back.
create or replace function public.stage_role_for(uid uuid, cid uuid)
returns text
language plpgsql
volatile security definer
set search_path = public
as $$
declare
  old_claims text := current_setting('request.jwt.claims', true);
  old_sub text := current_setting('request.jwt.claim.sub', true);
  res text;
begin
  if uid is null or cid is null then return null; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  res := public.stage_role(cid);
  perform set_config('request.jwt.claims', coalesce(old_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
  -- stage_role says null for a channel they can't see. Callers here treat null as "free to talk", so on a live stage
  -- anyone who isn't a mod is a listener, whatever else their access says.
  if res is null and exists (
    select 1 from public.channels ch join public.feature_flags f on f.key = 'stage_channels'
     where ch.id = cid and ch.kind = 'voice' and ch.stage and ch.server_id is not null
       and (f.mode = 'everyone' or (f.mode = 'test' and ch.server_id = any(f.servers)))) then
    res := 'listener';
  end if;
  return res;
end $$;
revoke all on function public.stage_role_for(uuid, uuid) from public, anon, authenticated;
grant execute on function public.stage_role_for(uuid, uuid) to service_role;

-- The server audit log (232, 424) records the switch: 424's audit_channels() with 'stage' added to the key list.
create or replace function public.audit_channels() returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null or coalesce(current_setting('yapper.bulk', true), '') = '1' then return null; end if;
  -- Tickets open and close all day: not worth a line each.
  if coalesce(new.ticket_by, old.ticket_by) is not null then return null; end if;
  if tg_op = 'INSERT' then
    if new.server_id is not null then
      perform public.audit_add(new.server_id, 'channel_create', 'channel', new.id, new.name, jsonb_build_object('kind', new.kind));
    end if;
  elsif tg_op = 'DELETE' then
    if old.server_id is not null then
      perform public.audit_add(old.server_id, 'channel_delete', 'channel', old.id, old.name, jsonb_build_object('kind', old.kind));
    end if;
  elsif new.server_id is not null then
    -- A deleted category clears category_id on its channels (cascade): that's not a channel edit.
    if pg_trigger_depth() > 1 and new.category_id is null and old.category_id is not null then return null; end if;
    d := public.audit_diff(to_jsonb(old), to_jsonb(new), array['name', 'private', 'read_only', 'slowmode', 'no_images', 'no_gifs', 'stage', 'category_id']);
    if jsonb_array_length(d) > 0 then
      perform public.audit_add(new.server_id, 'channel_update', 'channel', new.id, new.name, jsonb_build_object('changes', d));
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger channels_audit after insert or delete or update of name, private, read_only, slowmode, no_images, no_gifs, stage, category_id
  on public.channels for each row execute function public.audit_channels();

-- Servers only, no users: the database decides per server (stage_role), so the app must too.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('stage_channels', 'Stage channels', 'Voice channels for Q&As: people join as listeners, raise a hand, and mods bring them up to talk', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{}')
on conflict (key) do nothing;
reset lock_timeout;
