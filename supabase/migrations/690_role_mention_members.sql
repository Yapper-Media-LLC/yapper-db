-- 690: Who has this role (flag role_mention_members). Clicking an @Role mention in a message opens a small list of the
-- people with that role: names + avatars, search, a count, 40 at a time.
-- One paged call starting from the member_roles(role_id) index. Up to 5000 holders it sorts by shown name (a few ms);
-- above that it pages by user id from the index and only searches with 2+ characters, so a huge role is never sorted
-- whole. Only for members of the role's server, and through member_lookup_ok (524): big servers keep the per-account
-- read limit (a sorted page costs a tenth of the rows it reads, so ~10 pages a minute on a 5000-holder role), and
-- searches use the search limiter.

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('role_mention_members', 'Role mention members',
  'Click an @Role mention to see who has the role (search, count, paging). Test: Antic + HQ test server',
  'test', '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;

-- Already there live (made by hand, 151); here so a fresh database has it too.
create index if not exists member_roles_role_idx on public.member_roles (role_id);

/**
 * One page of the people with role `rid`, sorted by the name they show in that server (nickname, display name,
 * username). `q` filters by any of those names. Pass the last row's sort_key + user_id to get the next page.
 * Nothing for automatic roles. total = how many match, only on the first page (-1 after it).
 */
create or replace function public.role_members(rid uuid, q text default null, after_key text default null, after_id uuid default null, lim int default 40)
returns table (user_id uuid, nickname text, joined_at timestamptz, sort_key text, total bigint)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare sid uuid; n int := least(greatest(coalesce(lim, 40), 1), 100); pat text; holders int; big boolean;
begin
  -- Automatic roles (everyone, or everyone who joined before a date) mostly have no member_roles rows: the app says
  -- who has them instead of listing a whole server.
  select r.server_id into sid from public.roles r where r.id = rid and coalesce(r.auto, 'none') = 'none';
  if sid is null or not public.feature_on('role_mention_members', sid) then return; end if;
  if nullif(btrim(coalesce(q, '')), '') is not null then
    pat := '%' || replace(replace(replace(lower(left(btrim(q), 32)), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  select count(*) into holders from public.member_roles mr where mr.role_id = rid;
  big := holders > 5000;
  if big and pat is not null and char_length(btrim(q)) < 2 then return; end if;
  if not public.member_lookup_ok(sid, case when pat is null then 'ml' else 'mf' end, case when big then n else greatest(n, least(holders, 5000) / 10) end) then return; end if;
  if big and pat is null then
    -- Huge role: straight off the index, by user id. sort_key is '' so the client's cursor still works.
    return query
    select mr.user_id, sm.nickname, sm.joined_at, ''::text,
      case when after_id is null then holders::bigint else -1::bigint end
    from public.member_roles mr
    join public.server_members sm on sm.server_id = mr.server_id and sm.user_id = mr.user_id
    where mr.role_id = rid and mr.server_id = sid and (after_id is null or mr.user_id > after_id)
    order by mr.user_id
    limit n;
    return;
  end if;
  return query
  with m as materialized (
    select mr.user_id, sm.nickname, sm.joined_at,
      lower(coalesce(nullif(sm.nickname, ''), nullif(p.display_name, ''), p.username, '')) as k
    from public.member_roles mr
    join public.server_members sm on sm.server_id = mr.server_id and sm.user_id = mr.user_id
    join public.profiles p on p.id = mr.user_id
    where mr.role_id = rid and mr.server_id = sid
      and (pat is null or lower(p.username) like pat or lower(coalesce(p.display_name, '')) like pat
           or lower(coalesce(sm.nickname, '')) like pat)
  )
  select m.user_id, m.nickname, m.joined_at, m.k,
    case when after_id is null then (select count(*) from m) else -1::bigint end
  from m
  where after_id is null or (m.k, m.user_id) > (coalesce(after_key, ''), after_id)
  order by m.k, m.user_id
  limit n;
end;
$$;
revoke all on function public.role_members(uuid, text, text, uuid, int) from public, anon;
grant execute on function public.role_members(uuid, text, text, uuid, int) to authenticated, service_role;
