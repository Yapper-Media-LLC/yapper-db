-- 226: ban appeals in the app (flag `ban_appeals`), so banned people stop emailing hello@yapper.website.
--
-- The ban screen gets an "Appeal" box: one appeal per ban (a new ban can be appealed again). Staff see them in
-- Mod Center > Ban appeals and either lift the ban (through site_unban, so its rules hold: only an admin lifts a
-- confirmed ban) or deny it with an optional note the person sees.
-- Nobody touches the table directly; everything goes through the functions below.
-- Re-runnable.

set lock_timeout = '5s';

create table if not exists public.ban_appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  ban_at timestamptz not null,               -- site_bans.created_at of the ban this is about
  ban_reason text,
  message text not null check (char_length(message) between 10 and 1500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null,
  staff_note text check (staff_note is null or char_length(staff_note) <= 500),
  unique (user_id, ban_at)
);
create index if not exists ban_appeals_pending_idx on public.ban_appeals (created_at) where status = 'pending';
create index if not exists ban_appeals_decided_idx on public.ban_appeals (decided_at desc) where status <> 'pending';
create index if not exists ban_appeals_decided_by_idx on public.ban_appeals (decided_by);

alter table public.ban_appeals enable row level security;
revoke all on public.ban_appeals from public, anon, authenticated;

-- ---------- the banned person ----------

create or replace function public.submit_ban_appeal(msg text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b public.site_bans;
  m text := btrim(coalesce(msg, ''));
  n int;
begin
  if me is null then raise exception 'Log in first'; end if;
  if not public.feature_on_for_me('ban_appeals') then raise exception 'Appeals aren''t open yet'; end if;
  select * into b from public.site_bans where user_id = me and (expires_at is null or expires_at > now());
  if b.user_id is null then raise exception 'Your account isn''t banned'; end if;
  if char_length(m) < 10 then raise exception 'Tell us a bit more (at least 10 characters)'; end if;
  if char_length(m) > 1500 then raise exception 'Keep it under 1500 characters'; end if;
  insert into public.ban_appeals (user_id, ban_at, ban_reason, message)
    values (me, b.created_at, b.reason, m)
    on conflict (user_id, ban_at) do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You already appealed this ban'; end if;
end; $$;
revoke all on function public.submit_ban_appeal(text) from public, anon;
grant execute on function public.submit_ban_appeal(text) to authenticated;

-- What the ban screen shows: whether appeals are open for me (the flag; a banned app may not have loaded flags)
-- and my appeal for the ban I have now (null if none).
create or replace function public.my_ban_appeal()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'open', public.feature_on_for_me('ban_appeals'),
    'appeal', (select to_jsonb(x) from (
      select a.status, a.created_at, a.decided_at, a.staff_note
      from public.site_bans b
      join public.ban_appeals a on a.user_id = b.user_id and a.ban_at = b.created_at
      where b.user_id = auth.uid() and (b.expires_at is null or b.expires_at > now())
    ) x));
$$;
revoke all on function public.my_ban_appeal() from public, anon;
grant execute on function public.my_ban_appeal() to authenticated;

-- ---------- staff ----------

create or replace function public.staff_ban_appeals(st text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_at) from (
      select a.id, a.user_id, a.message, a.status, a.created_at, a.decided_at, a.staff_note, a.ban_reason, a.ban_at,
             p.username, p.display_name, p.avatar_path,
             d.username as decided_by_name,
             b.expires_at as ban_expires_at,
             (b.user_id is not null and (b.expires_at is null or b.expires_at > now())) as still_banned,
             -- Mods can't lift a confirmed ban (site_unban): say so up front instead of failing on the button.
             (public.is_site_admin() or b.banned_by is null or b.expires_at is not null) as can_lift,
             case when st = 'pending' then extract(epoch from a.created_at) else -extract(epoch from a.decided_at) end as sort_at
      from public.ban_appeals a
      join public.profiles p on p.id = a.user_id
      left join public.profiles d on d.id = a.decided_by
      -- Only the ban this appeal is about: after a re-ban an old appeal shows as "not banned any more".
      left join public.site_bans b on b.user_id = a.user_id and b.created_at = a.ban_at
      where (st = 'pending' and a.status = 'pending')
         or (st <> 'pending' and a.status <> 'pending' and a.decided_at > now() - interval '14 days')
      order by case when st = 'pending' then a.created_at end asc, a.decided_at desc
      limit 200
    ) x
  ), '[]'::jsonb);
end; $$;
revoke all on function public.staff_ban_appeals(text) from public, anon;
grant execute on function public.staff_ban_appeals(text) to authenticated;

create or replace function public.decide_ban_appeal(aid uuid, approve boolean, note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.ban_appeals;
  b public.site_bans;
  n text := nullif(left(btrim(coalesce(note, '')), 500), '');
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into a from public.ban_appeals where id = aid for update;
  if a.id is null then raise exception 'That appeal is gone'; end if;
  if a.status <> 'pending' then raise exception 'Someone already decided this one'; end if;
  if approve then
    -- Only the ban this appeal is about (a re-ban since gets its own appeal), and only while it's still on.
    select * into b from public.site_bans where user_id = a.user_id for update;
    if b.user_id is null or b.created_at <> a.ban_at then
      raise exception 'They were banned again since. This appeal is for an older ban, so deny it';
    end if;
    -- Lifting goes through site_unban, so its rules (and its limits and log line) apply as is.
    if b.expires_at is null or b.expires_at > now() then perform public.site_unban(a.user_id); end if;
  else
    perform public.mod_guard('appeal_denied', a.user_id, null);
  end if;
  update public.ban_appeals set status = case when approve then 'approved' else 'denied' end,
    decided_at = now(), decided_by = auth.uid(), staff_note = n
    where id = aid;
  if not approve then
    insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'appeal_denied', a.user_id, coalesce(n, ''));
  end if;
end; $$;
revoke all on function public.decide_ban_appeal(uuid, boolean, text) from public, anon;
grant execute on function public.decide_ban_appeal(uuid, boolean, text) to authenticated;

-- Flag (test only until Antic says publish): Antic and his test server.
insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('ban_appeals', 'Ban appeals', 'Banned people can appeal from the ban screen; staff decide in Mod Center > Ban appeals', 'test',
   '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
