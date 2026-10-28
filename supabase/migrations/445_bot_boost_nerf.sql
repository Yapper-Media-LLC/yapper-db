-- 445: bot boosts give a guaranteed place instead of multiplying servers (Antic, Oct 23: a bot at #15 shouldn't reach
-- #1 with a $12.99 Mega Boost; the $29.99 Promoted spot should be the best deal). A boosted bot now sits just above
-- the organic #19 / #9 / #4 for ×2 / ×4 / ×8 (so top 20 / top 10 / top 5), or where it already is if that's higher.
-- Only bot_order() changes; public_bots(), bot_rank_tiers() and the labels read it. Re-runnable.
create or replace function public.bot_order(extra uuid default null, extra_mult int default null, use_boosts boolean default true)
returns table(id uuid, pos bigint, servers bigint, boost int)
language sql stable security definer set search_path = public as $$
  with boosts as (
    select p.bot_id, max(p.mult)::int as b from public.bot_promotions p
    where use_boosts and p.kind = 'boost' and p.starts_at <= now() and p.ends_at > now() and public.bot_promo_ok(p.bot_id)
    group by p.bot_id
  ),
  base as (
    select b.id, lower(b.name) as ln, coalesce(b.real_servers::bigint, public.bot_real_server_count(b.id)) as n,
           greatest(coalesce(bo.b, 1), case when b.id is not distinct from extra then coalesce(extra_mult, 1) else 1 end) as m
    from public.bots b left join boosts bo on bo.bot_id = b.id
    where b.public and b.verified_at is not null
  ),
  organic as (select n, row_number() over (order by n desc, ln) as r from base where m = 1),
  floors as (
    select coalesce((select n from organic where r = 19), -1) as f2,
           coalesce((select n from organic where r = 9), -1) as f4,
           coalesce((select n from organic where r = 4), -1) as f8
  )
  select e.id,
         row_number() over (order by greatest(e.n::numeric, case e.m when 8 then f.f8 + 0.5 when 4 then f.f4 + 0.5 when 2 then f.f2 + 0.5 else 0 end) desc, e.n desc, e.ln, e.id),
         e.n, case when e.m > 1 then e.m else 0 end
  from base e cross join floors f;
$$;
revoke all on function public.bot_order(uuid, int, boolean) from public, anon, authenticated;
