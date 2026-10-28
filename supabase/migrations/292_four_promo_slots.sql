set lock_timeout = '3s';
-- 292: four Promoted spots on Discovery instead of three (Antic, Oct 19). promo_slots() decides how many run at once
-- (and when a booking starts, next_promo_start); promoted_servers() shows them all, no rotation. Re-runnable.

create or replace function public.promo_slots()
returns integer
language sql
immutable
as $$ select 4 $$;

create or replace function public.promoted_servers(lim integer default 4)
returns table(promo_id uuid, id uuid, name text, icon_path text, banner_path text, banner_x numeric, banner_y numeric,
              banner_zoom numeric, description text, tags text[], members integer, joined boolean)
language sql
security definer
set search_path = public
as $$
  with live as (
    select distinct on (p.server_id) p.id as pid, p.server_id
    from public.server_promotions p
    where p.kind = 'promote' and p.starts_at <= now() and p.ends_at > now()
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
  limit least(coalesce(lim, 4), 6);
$$;
reset lock_timeout;
