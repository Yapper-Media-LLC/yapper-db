-- Paid "Promoted" slots on the Discovery page + Yapper Plus nudge flag.
-- A promotion is a time window for one server. Paid through a Stripe Payment Link
-- (client_reference_id = 'promo_<server id>', see app/api/stripe/webhook) or granted by an admin.

create table if not exists public.server_promotions (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  source text not null default 'stripe' check (source in ('stripe', 'admin')),
  stripe_event text unique,
  created_by uuid,
  views int not null default 0,
  clicks int not null default 0,
  joins int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists server_promotions_live on public.server_promotions (ends_at, starts_at);
create index if not exists server_promotions_server on public.server_promotions (server_id, ends_at desc);
alter table public.server_promotions enable row level security;

-- Server managers see their own promotions (and the numbers); admins see all. No direct writes.
create policy "managers see promotions" on public.server_promotions for select to authenticated
  using (public.is_site_admin() or exists (select 1 from public.servers s where s.id = server_id and s.owner_id = auth.uid())
         or public.server_perm(server_id, 'manage_server'));

-- Live promotions shown at the top of Discovery: random order, at most `lim`.
-- Same safety rules as the normal list (discoverable, owner not banned, name not blocked, not locked).
create or replace function public.promoted_servers(lim int default 3)
returns table(promo_id uuid, id uuid, name text, icon_path text, banner_path text, banner_x numeric, banner_y numeric, banner_zoom numeric,
              description text, tags text[], members int, joined boolean)
language sql volatile security definer set search_path = public as $$
  with live as (
    select distinct on (p.server_id) p.id as pid, p.server_id
    from public.server_promotions p
    where p.starts_at <= now() and p.ends_at > now()
    order by p.server_id, p.ends_at desc
  )
  select l.pid, s.id, s.name, s.icon_path, s.banner_path, s.banner_x, s.banner_y, s.banner_zoom, s.description, s.tags,
         (select count(*)::int from public.server_members m where m.server_id = s.id),
         exists (select 1 from public.server_members m where m.server_id = s.id and m.user_id = auth.uid())
  from live l
  join public.servers s on s.id = l.server_id
  where s.discoverable
    and not public.is_site_banned(s.owner_id)
    and not public.bad_name(s.name)
    and (s.locked_until is null or s.locked_until < now())
  order by random()
  limit least(coalesce(lim, 3), 6);
$$;

-- Count what a promotion got. Views are sent once per Discovery visit.
create or replace function public.promo_event(pids uuid[], kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or kind not in ('view', 'click', 'join') then return; end if;
  update public.server_promotions set
    views = views + (kind = 'view')::int,
    clicks = clicks + (kind = 'click')::int,
    joins = joins + (kind = 'join')::int
  where id = any(pids[1:6]) and ends_at > now();
end $$;

-- Admin: promote a server for free (testing, giveaways, partners). Stacks after any current promotion.
create or replace function public.admin_promote_server(sid uuid, days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_start timestamptz; v_end timestamptz;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if days is null or days < 1 or days > 60 then raise exception 'Pick 1 to 60 days'; end if;
  select greatest(now(), coalesce(max(ends_at), now())) into v_start from public.server_promotions where server_id = sid;
  v_end := v_start + make_interval(days => days);
  insert into public.server_promotions (server_id, starts_at, ends_at, source, created_by) values (sid, v_start, v_end, 'admin', auth.uid());
  return v_end;
end $$;

-- Admin: end a promotion now (refunds, rule breaks).
create or replace function public.admin_end_promotion(pid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.server_promotions set ends_at = now() where id = pid and ends_at > now();
end $$;

revoke all on function public.promoted_servers(int), public.promo_event(uuid[], text), public.admin_promote_server(uuid, int), public.admin_end_promotion(uuid) from public, anon;
grant execute on function public.promoted_servers(int), public.promo_event(uuid[], text), public.admin_promote_server(uuid, int), public.admin_end_promotion(uuid) to authenticated;

insert into public.feature_flags (key, label, description, mode, users) values
  ('promoted', 'Promoted servers', 'Paid Promoted slots at the top of Discovery, and the Promote card in server settings.', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[]),
  ('plus_nudge', 'Plus pop-up', 'A rare Yapper Plus pop-up for people without Plus (and when a file is too big).', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;
