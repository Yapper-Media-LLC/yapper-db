-- 449: the in-app Community bots list (bot_directory, Bots page of a server) uses the boosted Most used order from
-- bot_order() (444/445) like /bots does, and returns the boost tier for the Boosted / Mega Boosted label. A Mega
-- buyer saw #4 on /bots but his old place in the app (Oct 23). Body otherwise as live. Re-runnable.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'bot_directory' and pronamespace = 'public'::regnamespace
             and pg_get_function_identity_arguments(oid) = 'q text, cat text, sort text'
             and pg_get_function_result(oid) not like '%boost%') then
    execute 'dr' || 'op function public.bot_directory(text, text, text)';
  end if;
end $$;
create or replace function public.bot_directory(q text default '', cat text default '', sort text default 'popular')
returns table(id uuid, name text, description text, category text, owner_id uuid, owner_name text, owner_plus boolean, servers bigint,
              commands bigint, online boolean, created_at timestamptz, verified_at timestamptz, command_list jsonb, boost int)
language sql stable security definer set search_path = public as $$
  select b.id, b.name, b.description, b.category, b.owner_id, coalesce(p.display_name, p.username), coalesce(p.plus_until > now(), false),
         o.servers,
         (select count(*) from public.bot_commands c where c.bot_id = b.id),
         (b.last_poll_at > now() - interval '90 seconds' or b.last_event_at > now() - interval '5 minutes'),
         b.created_at, b.verified_at,
         coalesce((select jsonb_agg(jsonb_build_object('name', c.name, 'description', c.description) order by c.name)
                   from (select * from public.bot_commands c where c.bot_id = b.id order by c.name limit 25) c), '[]'::jsonb),
         o.boost
  from public.bot_order(null, null, public.feature_on_for_me('bot_promoted')) o
  join public.bots b on b.id = o.id
  join public.profiles p on p.id = b.owner_id
  where (coalesce(cat, '') = '' or b.category = cat)
    and (coalesce(q, '') = '' or b.name ilike '%' || q || '%' or b.description ilike '%' || q || '%'
         or exists (select 1 from public.bot_commands c where c.bot_id = b.id and c.name ilike '%' || q || '%'))
  order by case when sort = 'new' then extract(epoch from b.verified_at) else 0 end desc,
           case when sort = 'name' then lower(b.name) end asc,
           o.pos, b.name
  limit 100;
$$;
revoke all on function public.bot_directory(text, text, text) from public, anon, authenticated;
grant execute on function public.bot_directory(text, text, text) to authenticated;
