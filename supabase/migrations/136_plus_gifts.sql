-- 136: Gift Plus (flag gift_plus).
--  * Anyone can buy Yapper Plus for someone else (Stripe one-time payment, ref gplus<months>_<recipient>).
--    The Stripe webhook extends the recipient's plus_until and records the gift here.
--  * Staff can run a giveaway for Plus itself: "!giveaway 1d plus" or "!giveaway 1d plus 3m".
--    Winners get it on their account automatically when the giveaway ends.
--  * The recipient sees a "you got Plus" note once (seen_at).

create table if not exists public.plus_gifts (
  id uuid primary key default gen_random_uuid(),
  gifter_id uuid references public.profiles(id) on delete set null,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  months int not null check (months between 1 and 12),
  source text not null check (source in ('stripe', 'giveaway')),
  giveaway_id uuid references public.giveaways(id) on delete set null,
  stripe_event text unique,
  created_at timestamptz not null default now(),
  seen_at timestamptz
);
create index if not exists plus_gifts_unseen on public.plus_gifts (recipient_id) where seen_at is null;
alter table public.plus_gifts enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'plus_gifts' and policyname = 'see your own gifts') then
    create policy "see your own gifts" on public.plus_gifts for select to authenticated
      using (recipient_id = (select auth.uid()) or gifter_id = (select auth.uid()));
  end if;
end $$;
revoke all on public.plus_gifts from anon, authenticated;
grant select on public.plus_gifts to authenticated;

create or replace function public.plus_gifts_seen()
returns void language sql security definer set search_path to 'public' as $$
  update public.plus_gifts set seen_at = now() where recipient_id = auth.uid() and seen_at is null;
$$;
revoke all on function public.plus_gifts_seen() from public, anon;
grant execute on function public.plus_gifts_seen() to authenticated;

alter table public.giveaways add column if not exists plus_months int check (plus_months between 1 and 12);

-- giveaway_cmd: a Plus prize from site staff (flag on) becomes "Yapper Plus (N months)" with plus_months set.
do $$ declare d text; begin
  d := pg_get_functiondef('public.giveaway_cmd()'::regprocedure);
  if position('plus_months' in d) = 0 then
    d := replace(d, 'declare plus boolean;', 'declare pm int; pmm text[]; plus boolean;');
    d := replace(d, E'  prize := left(btrim(m[4]), 200);\n', E'  prize := left(btrim(m[4]), 200);\n'
      || E'  -- Staff can give away Plus itself ("!giveaway 1d plus", "!giveaway 1d plus 3m"): winners get it automatically.\n'
      || E'  pmm := regexp_match(prize, ''^(?:yapper\\s+)?plus(?:\\s+(\\d{1,2})\\s*(?:m|mo|mos|months?))?$'', ''i'');\n'
      || E'  if pmm is not null and public.is_site_admin() and public.feature_on(''gift_plus'', sid) then\n'
      || E'    pm := least(greatest(coalesce(pmm[1]::int, 1), 1), 12);\n'
      || E'    prize := ''Yapper Plus ('' || pm || '' month'' || case when pm > 1 then ''s'' else '''' end || '')'';\n'
      || E'  end if;\n');
    d := replace(d, E'|| E''\\nReact with 🎉 to enter!''', E'|| E''\\nReact with 🎉 to enter!''\n    || case when pm is not null then E''\\nWinners get Plus on their account automatically ✨'' else '''' end');
    d := replace(d, E'insert into public.giveaways (server_id, channel_id, message_id, host_id, prize, winners, ends_at)\n  values (sid, new.channel_id, mid, new.author_id, prize, nwin, ends);',
                    E'insert into public.giveaways (server_id, channel_id, message_id, host_id, prize, winners, ends_at, plus_months)\n  values (sid, new.channel_id, mid, new.author_id, prize, nwin, ends, pm);');
    execute d;
  end if;
end $$;

-- giveaway_end: Plus giveaways put Plus on the winners' accounts and record the gift.
do $$ declare d text; begin
  d := pg_get_functiondef('public.giveaway_end(uuid, boolean)'::regprocedure);
  if position('plus_months' in d) = 0 then
    d := replace(d, E'|| case when reroll then '' (reroll)'' else '''' end || ''.'';',
                    E'|| case when reroll then '' (reroll)'' else '''' end || ''.''\n      || case when coalesce(g.plus_months, 0) > 0 then '' Plus is on your account now ✨'' else '''' end;');
    d := replace(d, E'winner_ids = case when reroll then winner_ids || picks else picks end where id = gid;\n',
                    E'winner_ids = case when reroll then winner_ids || picks else picks end where id = gid;\n'
      || E'  if coalesce(g.plus_months, 0) > 0 and coalesce(array_length(picks, 1), 0) > 0 then\n'
      || E'    update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * g.plus_months) where id = any(picks);\n'
      || E'    insert into public.plus_gifts (gifter_id, recipient_id, months, source, giveaway_id) select g.host_id, x, g.plus_months, ''giveaway'', g.id from unnest(picks) x;\n'
      || E'  end if;\n');
    execute d;
  end if;
end $$;

-- Review fixes (applied live):
-- Nobody calls these directly: the trigger and the cron run them as the owner.
revoke execute on function public.giveaway_end(uuid, boolean), public.giveaways_tick() from public, anon, authenticated;
create index if not exists plus_gifts_recipient on public.plus_gifts (recipient_id);
create index if not exists plus_gifts_gifter on public.plus_gifts (gifter_id);
create index if not exists plus_gifts_giveaway on public.plus_gifts (giveaway_id);
-- giveaway_end: "for update" on the giveaway row (tick and !gend can't both grant), and a reroll only
--   hands out more Plus when Yapper staff run it.
-- giveaway_cmd: only Yapper staff can !gend / !greroll a Plus giveaway.
-- reorder_roles: duplicate ids are collapsed (min position in the list wins).

-- Paid gifts: one transaction for plus_until + the gift row. Only the Stripe webhook (service role) calls it.
create or replace function public.grant_plus_gift(p_to uuid, p_from uuid, p_months int, p_event text)
returns timestamptz language plpgsql security definer set search_path to 'public' as $$
declare until timestamptz;
begin
  if p_months not in (1, 3, 12) then raise exception 'bad months'; end if;
  update public.profiles set plus_until = greatest(coalesce(plus_until, now()), now()) + make_interval(days => 31 * p_months)
    where id = p_to returning plus_until into until;
  if until is null then raise exception 'recipient not found'; end if;
  insert into public.plus_gifts (gifter_id, recipient_id, months, source, stripe_event)
    values ((select id from public.profiles where id = p_from), p_to, p_months, 'stripe', p_event);
  return until;
end $$;
revoke all on function public.grant_plus_gift(uuid, uuid, int, text) from public, anon, authenticated;
grant execute on function public.grant_plus_gift(uuid, uuid, int, text) to service_role;
