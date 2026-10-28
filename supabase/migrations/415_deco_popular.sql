-- 415: the community decoration picker shows the most worn ones first (flag deco_popular, test). Approved ones by how
-- many profiles wear them now, newest first among equals, one page at a time (lib/communityDecos.ts loadPopular).
-- Counts come off profiles_community_deco_idx (360); about 10 ms for ~2000 wearers and ~900 decorations (Oct 22).
-- Runs when the picker opens, not on app load. Re-runnable.

set lock_timeout = '5s';

create or replace function public.community_decos_popular(p_offset int default 0, p_limit int default 200)
returns table (id uuid, name text, artist_id uuid, path text, status text, review_note text, created_at timestamptz,
  event text, wearers int)
language sql
stable
security definer
set search_path = public
as $$
  with worn as (
    select substr(p.avatar_deco, 3) as path, count(*)::int as n
    from public.profiles p where p.avatar_deco like 'c:%' group by 1
  )
  select d.id, d.name, d.artist_id, d.path, d.status, d.review_note, d.created_at, d.event, coalesce(w.n, 0)
  from public.community_decos d left join worn w on w.path = d.path
  where d.status = 'approved'
  order by coalesce(w.n, 0) desc, d.created_at desc, d.id
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 200), 0), 200);
$$;

revoke all on function public.community_decos_popular(int, int) from public, anon;
grant execute on function public.community_decos_popular(int, int) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_popular', 'Decorations: most worn first', 'The community decoration picker shows the most worn ones at the top.', 'test',
        array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

reset lock_timeout;
