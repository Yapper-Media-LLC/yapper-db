-- Discovery counted every server's members on every page (group by over 47k rows, 586 ms, 20k calls a
-- day; the Promote tab's rank preview did it four times). Uses servers.member_count now.
-- Also applied live: every table removed from the supabase_realtime publication (nothing subscribes
-- since realtime moved to the VPS; the replication slot was still decoding all of it).

create or replace function public.discovery_order_m(q text, extra uuid, extra_mult integer)
returns table(id uuid, pos numeric, boosts integer, members integer, lifted boolean)
language sql stable security definer set search_path to 'public' as $$
  with boosts as (select p.server_id, max(p.mult)::int as b from public.server_promotions p
             where p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now() group by p.server_id),
  elig as (
    select s.id, s.member_count as n,
           greatest(coalesce(b.b, 1), case when s.id is not distinct from extra then coalesce(extra_mult, 1) else 1 end) as m
    from public.servers s left join boosts b on b.server_id = s.id
    where s.discoverable and s.member_count >= 5 and (s.locked_until is null or s.locked_until < now())
      and not public.is_site_banned(s.owner_id) and not public.bad_name(s.name)
      and (coalesce(q, '') = '' or s.name ilike '%' || q || '%' or s.description ilike '%' || q || '%' or lower(q) = any(s.tags))
  )
  select e.id, (row_number() over (order by e.n * e.m desc, e.n desc, e.id))::numeric,
         case when e.m > 1 then e.m else 0 end, e.n, e.m > 1
  from elig e;
$$;

-- bad_name() over ~500 eligible servers cost ~0.5 s per discovery page: cache it on the row.
alter table public.servers add column if not exists name_ok boolean not null default true;
create or replace function public.servers_name_ok() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  new.name_ok := not public.bad_name(new.name);
  return new;
end $$;
create or replace trigger servers_name_ok before insert or update of name on public.servers for each row execute function public.servers_name_ok();
-- Backfill (run by hand with lock_timeout: the ALTER waits for a lock on a busy table).
update public.servers set name_ok = false where public.bad_name(name);

create or replace function public.discovery_order_m(q text, extra uuid, extra_mult integer)
returns table(id uuid, pos numeric, boosts integer, members integer, lifted boolean)
language sql stable security definer set search_path to 'public' as $$
  with boosts as (select p.server_id, max(p.mult)::int as b from public.server_promotions p
             where p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now() group by p.server_id),
  banned as (select b.user_id from public.site_bans b where b.expires_at is null or b.expires_at > now()),
  elig as (
    select s.id, s.member_count as n,
           greatest(coalesce(b.b, 1), case when s.id is not distinct from extra then coalesce(extra_mult, 1) else 1 end) as m
    from public.servers s left join boosts b on b.server_id = s.id
    where s.discoverable and s.member_count >= 5 and s.name_ok and (s.locked_until is null or s.locked_until < now())
      and s.owner_id not in (select user_id from banned)
      and (coalesce(q, '') = '' or s.name ilike '%' || q || '%' or s.description ilike '%' || q || '%' or lower(q) = any(s.tags))
  )
  select e.id, (row_number() over (order by e.n * e.m desc, e.n desc, e.id))::numeric,
         case when e.m > 1 then e.m else 0 end, e.n, e.m > 1
  from elig e;
$$;
