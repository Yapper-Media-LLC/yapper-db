-- Voice log (flag voice_log): every Yapper mod can see recent voice reports, who closed each one, how,
-- and what staff did to the reported person around then. So mods can check each other's calls and
-- reopen ones that were dismissed or guessed. The full mod_log stays admin only (180).

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('voice_log', 'Voice log', 'Mod Center tab for all mods: recent voice reports, who handled them and what was done', 'test', '{}',
        '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

create or replace function public.voice_report_log(lim integer default 100, before timestamptz default null)
returns table (
  id uuid,
  created_at timestamptz,
  reporter_id uuid,
  target_id uuid,
  channel_id uuid,
  channel_name text,
  server_id uuid,
  server_name text,
  reason text,
  details text,
  status text,
  resolved_by uuid,
  resolved_at timestamptz,
  voice_clip_path text,
  reporters integer,
  actions jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  return query
  select r.id, r.created_at, r.reporter_id, r.target_id, r.channel_id, c.name::text, r.server_id, s.name::text,
         r.reason, r.details, r.status, r.resolved_by, r.resolved_at, r.voice_clip_path,
         -- People who reported the same person in the same call within an hour of this one.
         (select count(distinct o.reporter_id)::int from public.reports o
           where o.target_id = r.target_id and o.channel_id is not distinct from r.channel_id
             and o.details like '[voice]%' and o.message_id is null
             and o.created_at between r.created_at - interval '1 hour' and r.created_at + interval '1 hour'),
         -- What staff did to the reported person from the report until 30 minutes after it was closed.
         coalesce((select jsonb_agg(jsonb_build_object('actor', l.actor, 'action', l.action, 'reason', l.reason, 'created_at', l.created_at) order by l.created_at)
                     from (select l2.actor, l2.action, l2.reason, l2.created_at from public.mod_log l2
                            where l2.target_id = r.target_id
                              and l2.created_at >= r.created_at
                              and l2.created_at <= coalesce(r.resolved_at, now()) + interval '30 minutes'
                            order by l2.created_at
                            limit 10) l), '[]'::jsonb)
    from public.reports r
    left join public.channels c on c.id = r.channel_id
    left join public.servers s on s.id = r.server_id
   where r.details like '[voice]%'
     -- Real voice reports (report_voice) have no message and point at a voice channel. Message / user reports
     -- whose note happens to start with "[voice]" stay out (they could name a DM or group chat).
     and r.message_id is null
     and (c.id is null or c.kind = 'voice')
     and (before is null or r.created_at < before)
   order by r.created_at desc
   limit least(greatest(coalesce(lim, 100), 1), 200);
end;
$$;

revoke all on function public.voice_report_log(integer, timestamptz) from public, anon;
grant execute on function public.voice_report_log(integer, timestamptz) to authenticated;

create index if not exists reports_voice_time_idx on public.reports (created_at desc) where details like '[voice]%';

-- Reopening a closed report used to wipe who closed it with no trace, so a mod could hide another mod's call
-- (or redo it as their own). Now the reopen is logged with who had closed it and how. Same as 138 otherwise.
create or replace function public.resolve_report(rid uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare sid uuid; old_status text; old_by uuid; tgt uuid;
begin
  select server_id, status, resolved_by, target_id into sid, old_status, old_by, tgt from public.reports where id = rid;
  if not (public.is_staff() or (sid is not null and public.server_perm(sid, 'manage_server'))) then raise exception 'Not allowed'; end if;
  if new_status not in ('open', 'actioned', 'dismissed') then raise exception 'Bad status'; end if;
  -- Site staff confirming this one report: its picture may go on the take-down list (nsfw_hash_from_report).
  if new_status = 'actioned' and public.is_staff() then
    perform set_config('yapper.nsfw_confirm', '1', true);
  end if;
  update public.reports
     set status = new_status,
         resolved_by = case when new_status = 'open' then null else auth.uid() end,
         resolved_at = case when new_status = 'open' then null else now() end
   where id = rid;
  perform set_config('yapper.nsfw_confirm', '', true);
  if new_status = 'open' and old_status in ('actioned', 'dismissed') and public.is_staff() then
    insert into public.mod_log (actor, action, target_id, reason)
    values (auth.uid(), 'report_reopened', tgt,
            'Was ' || old_status || coalesce(' by ' || (select username from public.profiles where id = old_by), ''));
  end if;
end;
$$;
