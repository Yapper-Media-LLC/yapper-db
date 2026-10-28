-- 529: Yapper takes back the 2-character usernames that scripts grabbed (Antic, Oct 26: "take them over for ourselves").
-- On Oct 13-14 scripts signed up 103 accounts on throwaway mail (1sec.email, 5vra.com, grr.la; 59 of them in 30 s,
-- named a8, a9, b6, ...). All are site-banned, but a banned account keeps its username, so those names were stuck.
-- Each one is renamed to banned_<16 hex of its id> and the short name gets a hold until 2999 owned by Antic
-- (username_holds, 246; not 'infinity', which the guard's "on hold until ..." message would print as <NULL>): nobody
-- else can take it (username_holds_guard), and staff can still give it to someone (staff skip the hold check). When
-- staff hand one out, end or move the hold too, or the recipient's later rename turns it into a 7-day hold (246).
-- Logged to mod_log as username_takeover, one row per account.
-- Data only (no DDL). Only banned, non-staff, non-bot accounts on those three domains with a 2-character name, so a
-- second run finds nothing to do. The first run refuses unless exactly 103 match (the count checked on Oct 26), so a
-- ban since then can't quietly widen it (the SQL test sets yapper.takeover_expect to its own count).

do $$
declare
  antic constant uuid := '00000000-0000-4000-8000-00000000a001';
  want int := coalesce(nullif(current_setting('yapper.takeover_expect', true), '')::int, 103);
  n int;
  r record;
begin
  if not exists (select 1 from public.profiles where id = antic) then return; end if;
  create temp table takeover_529 on commit drop as
    select p.id, p.username
      from public.profiles p join auth.users u on u.id = p.id
     where char_length(p.username) = 2
       and split_part(lower(u.email), '@', 2) in ('1sec.email', '5vra.com', 'grr.la')
       and exists (select 1 from public.site_bans b where b.user_id = p.id and (b.expires_at is null or b.expires_at > now()))
       and not exists (select 1 from public.site_admins a where a.user_id = p.id)
       and not exists (select 1 from public.site_moderators m where m.user_id = p.id)
       and not exists (select 1 from public.bots x where x.id = p.id)
       and not exists (select 1 from public.bot_accounts ba where ba.user_id = p.id)
       and not exists (select 1 from public.servers s where s.owner_id = p.id)
     for update of p;
  select count(*) into n from takeover_529;
  if n = 0 then return; end if;
  if n <> want then raise exception '529: % accounts match, expected %. Check them before taking names.', n, want; end if;
  for r in select * from takeover_529 order by username loop
    update public.profiles set username = 'banned_' || left(replace(r.id::text, '-', ''), 16) where id = r.id;
    insert into public.username_holds (name_key, user_id, until)
    values (lower(r.username), antic, '2999-12-31 00:00+00')
    on conflict (name_key) do update set user_id = excluded.user_id, until = excluded.until;
    insert into public.mod_log (actor, action, target_id, reason)
    values (antic, 'username_takeover', r.id, 'Short name ' || r.username || ' taken from a banned bot account, held for Yapper');
  end loop;
end $$;
