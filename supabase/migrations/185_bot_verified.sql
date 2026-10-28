-- 185: verified bots (flag bot_verified, test mode).
-- 1. Community bots Yapper approved (bots.public and verified_at set) get a 'verified_bot' entry in profiles.badges,
--    kept in step by a trigger on bots, so chat shows "✓ BOT" with no extra query per message. Nobody can give it by
--    hand: admin_set_badge only knows bug_hunter/partner/early/staff, users can't update badges (085 column grants,
--    protect_profile_columns), and the bot API / PATCH /api/bots never write badges.
-- 2. bots.support_invite: an invite code for the bot's support server, set by the owner through PATCH /api/bots
--    (which only takes invites to servers the owner made the invite for or is in). FK to invites(code).
-- 3. public_bots(): the public /bots page (anon too), verified public bots only, safe columns only, nothing unless
--    the flag is on for the caller (everyone mode, or test and feature_on_for_me).
-- 4. bot_add_targets(bid): the servers the caller can add a bot to (Manage Server, bot_api on), for /bots' Add button.
-- Re-runnable.

-- ---------- 2. Support server ----------
alter table public.bots add column if not exists support_invite text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bots_support_invite_check' and conrelid = 'public.bots'::regclass) then
    alter table public.bots add constraint bots_support_invite_check
      check (support_invite is null or support_invite ~ '^[A-Za-z0-9_-]{3,32}$');
  end if;
end $$;
-- Follows the invite: a renamed vanity link (047/163 update invites set code = ...) carries over, a deleted invite
-- clears it, so a released code later claimed by another server can't keep pointing people there.
-- invites.code is the primary key (010).
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bots_support_invite_fkey' and conrelid = 'public.bots'::regclass) then
    alter table public.bots add constraint bots_support_invite_fkey
      foreign key (support_invite) references public.invites(code) on update cascade on delete set null;
  end if;
end $$;
create index if not exists bots_support_invite_idx on public.bots (support_invite) where support_invite is not null;
grant select (support_invite) on public.bots to authenticated;

-- ---------- 1. The verified_bot badge ----------
create or replace function public.bot_verified_badge()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  bid uuid := case when tg_op = 'DELETE' then old.id else new.id end;
  want boolean := tg_op <> 'DELETE' and new.public and new.verified_at is not null;
begin
  if want then
    update public.profiles set badges = coalesce(badges, '{}'::text[]) || 'verified_bot'::text
     where id = bid and not ('verified_bot' = any(coalesce(badges, '{}'::text[])));
  else
    update public.profiles set badges = array_remove(badges, 'verified_bot')
     where id = bid and 'verified_bot' = any(coalesce(badges, '{}'::text[]));
  end if;
  return null;
end $$;
revoke all on function public.bot_verified_badge() from public, anon, authenticated;

-- Only when "verified and public" actually flips: bots rows are updated all the time (posts, last_used_at...).
do $$ begin
  execute 'dr' || 'op trigger if exists bots_verified_badge_ins on public.bots';
  execute 'dr' || 'op trigger if exists bots_verified_badge_upd on public.bots';
  execute 'dr' || 'op trigger if exists bots_verified_badge_del on public.bots';
end $$;
create trigger bots_verified_badge_ins after insert on public.bots for each row
  when (new.public and new.verified_at is not null) execute function public.bot_verified_badge();
create trigger bots_verified_badge_upd after update on public.bots for each row
  when ((old.public and old.verified_at is not null) is distinct from (new.public and new.verified_at is not null))
  execute function public.bot_verified_badge();
create trigger bots_verified_badge_del after delete on public.bots for each row
  when (old.public and old.verified_at is not null) execute function public.bot_verified_badge();

-- Backfill: every verified public bot has it, nobody else does.
update public.profiles p set badges = coalesce(p.badges, '{}'::text[]) || 'verified_bot'::text
  from public.bots b
 where b.id = p.id and b.public and b.verified_at is not null
   and not ('verified_bot' = any(coalesce(p.badges, '{}'::text[])));
update public.profiles p set badges = array_remove(p.badges, 'verified_bot')
 where 'verified_bot' = any(coalesce(p.badges, '{}'::text[]))
   and not exists (select 1 from public.bots b where b.id = p.id and b.public and b.verified_at is not null);

-- ---------- 3. Public directory ----------
create index if not exists bots_verified_idx on public.bots (verified_at desc) where public and verified_at is not null;

create or replace function public.public_bots(q text default null, cat text default null, sort text default 'popular', lim int default 60, off int default 0)
returns table (id uuid, name text, tag text, description text, category text, avatar_path text, support_invite text,
               servers bigint, verified_at timestamptz, created_at timestamptz, owner_name text)
language plpgsql stable security definer set search_path = public as $$
declare
  term text := nullif(btrim(left(coalesce(q, ''), 64)), '');
  pat text;
  take int := least(greatest(coalesce(lim, 60), 1), 100);
  skip int := least(greatest(coalesce(off, 0), 0), 10000);
begin
  if not public.feature_on_for_me('bot_verified') then return; end if;
  -- ilike wildcards in the search box are matched literally.
  if term is not null then
    pat := '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  return query
  select b.id, b.name, b.tag, b.description, coalesce(b.category, 'other'), coalesce(bp.avatar_path, b.avatar_path), b.support_invite,
         c.n, b.verified_at, b.created_at, coalesce(op.display_name, op.username)
  from public.bots b
  join public.profiles bp on bp.id = b.id
  left join public.profiles op on op.id = b.owner_id
  cross join lateral (select count(*) as n from public.bot_servers s where s.bot_id = b.id) c
  where b.public and b.verified_at is not null
    and (coalesce(cat, '') = '' or coalesce(b.category, 'other') = cat)
    and (pat is null or b.name ilike pat escape '\' or b.description ilike pat escape '\')
  order by case when sort = 'new' then b.verified_at end desc nulls last,
           case when sort = 'name' then lower(b.name) end asc,
           c.n desc, lower(b.name), b.id
  limit take offset skip;
end $$;
revoke all on function public.public_bots(text, text, text, int, int) from public;
grant execute on function public.public_bots(text, text, text, int, int) to anon, authenticated;

-- ---------- 4. Where can I add this bot? ----------
create or replace function public.bot_add_targets(bid uuid)
returns table (id uuid, name text, icon_path text, added boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.icon_path, exists (select 1 from public.bot_servers bs where bs.bot_id = bid and bs.server_id = s.id)
  from public.server_members m
  join public.servers s on s.id = m.server_id
  where m.user_id = (select auth.uid())
    and public.server_perm(s.id, 'manage_server')
    and public.feature_on('bot_api', s.id)
  order by lower(s.name)
  limit 200;
$$;
revoke all on function public.bot_add_targets(uuid) from public, anon;
grant execute on function public.bot_add_targets(uuid) to authenticated;

-- ---------- Flag ----------
insert into public.feature_flags (key, label, description, mode, servers)
values ('bot_verified', 'Verified bots', 'Verified bot tag in chat plus a public /bots directory', 'test', '{}')
on conflict (key) do nothing;
