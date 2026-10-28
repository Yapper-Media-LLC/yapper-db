-- 162: Promote page numbers are for the server's managers only.
-- discovery_rank_tiers (anon could call it too), discovery_rank and promo_availability are security definer and took
-- any server id, so anyone could read another server's rank, boost multiplier, boost end time and next promo slot.
-- Now they need Manage Server on that server (or site admin). Bodies are unchanged otherwise. Re-runnable.

create or replace function public.promo_reader(sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (select auth.uid()) is not null and (public.server_perm(sid, 'manage_server') or public.is_site_admin());
$$;
revoke all on function public.promo_reader(uuid) from public, anon;
grant execute on function public.promo_reader(uuid) to authenticated;

create or replace function public.discovery_rank(sid uuid)
returns integer language plpgsql stable security definer set search_path = public as $$
begin
  if not public.promo_reader(sid) then raise exception 'You need Manage Server for that'; end if;
  return (select r::int from (select o.id, row_number() over (order by o.pos) as r from public.discovery_order('', null) o) x where x.id = sid);
end;
$$;

create or replace function public.discovery_rank_tiers(sid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.promo_reader(sid) then raise exception 'You need Manage Server for that'; end if;
  return jsonb_build_object(
    'now', (select r from (select o.id, row_number() over (order by o.pos) r from public.discovery_order_m('', null, null) o) x where x.id = sid),
    'x2', (select r from (select o.id, row_number() over (order by o.pos) r from public.discovery_order_m('', sid, 2) o) x where x.id = sid),
    'x4', (select r from (select o.id, row_number() over (order by o.pos) r from public.discovery_order_m('', sid, 4) o) x where x.id = sid),
    'x8', (select r from (select o.id, row_number() over (order by o.pos) r from public.discovery_order_m('', sid, 8) o) x where x.id = sid),
    'mult', (select coalesce(max(p.mult), 1) from public.server_promotions p where p.server_id = sid and p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now())
  );
end;
$$;

create or replace function public.promo_availability(sid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.promo_reader(sid) then raise exception 'You need Manage Server for that'; end if;
  return jsonb_build_object(
    'promo_slots', public.promo_slots(),
    'promo_taken', (select count(distinct server_id) from public.server_promotions where kind = 'promote' and starts_at <= now() and ends_at > now()),
    'promo_next', public.next_promo_start(sid),
    'boost_max', 99,
    'boost_live', (select count(*) from public.server_promotions where server_id = sid and kind = 'boost' and starts_at <= now() and ends_at > now()),
    'boost_lifts', 0,
    'boost_mult', (select coalesce(max(mult), 1) from public.server_promotions where server_id = sid and kind = 'boost' and starts_at <= now() and ends_at > now()),
    'boost_until', (select max(ends_at) from public.server_promotions where server_id = sid and kind = 'boost' and ends_at > now())
  );
end;
$$;

revoke all on function public.discovery_rank(uuid) from public, anon;
revoke all on function public.discovery_rank_tiers(uuid) from public, anon;
revoke all on function public.promo_availability(uuid) from public, anon;
grant execute on function public.discovery_rank(uuid) to authenticated;
grant execute on function public.discovery_rank_tiers(uuid) to authenticated;
grant execute on function public.promo_availability(uuid) to authenticated;
