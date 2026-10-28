-- Poll votes were readable per person: "members read ballots" let anyone who could see a poll's channel
-- select every ballot with its user_id (GET /rest/v1/poll_ballots?user_id=eq.<id> gave someone's whole voting
-- history), and the live 'poll' broadcast to chan:<id> carried the voter's id too (bug report, Oct 23).
-- The app only ever reads aggregates (poll_results, definer) and writes through vote_poll (definer).
-- Now: you can only select your own ballot, and the channel broadcast goes out without user_id. The voter
-- still gets the full row on their own user:<id> topic, so their other tabs know to re-fetch "mine".

do $$ begin execute 'dr' || 'op policy if exists "members read ballots" on public.poll_ballots'; end $$;
do $$ begin execute 'dr' || 'op policy if exists "own ballot read" on public.poll_ballots'; end $$;
create policy "own ballot read" on public.poll_ballots for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.poll_ballots from anon;

create or replace function public.broadcast_poll_ballot()
returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; sid uuid; uid uuid; voter uuid; n public.poll_ballots; o public.poll_ballots;
begin
  if tg_op = 'UPDATE' and new.option_ids is not distinct from old.option_ids then return null; end if;
  select channel_id into cid from public.polls where id = coalesce(new.poll_id, old.poll_id);
  if cid is null then return null; end if;
  voter := coalesce(new.user_id, old.user_id);
  -- Copies without the voter, for everyone else.
  if tg_op <> 'DELETE' then n := new; n.user_id := null; end if;
  if tg_op <> 'INSERT' then o := old; o.user_id := null; end if;
  select server_id into sid from public.channels where id = cid;
  if sid is not null then
    perform public.bc('chan:' || cid, 'poll', tg_op, tg_table_name, tg_table_schema,
      case when tg_op = 'DELETE' then null else n end, case when tg_op = 'INSERT' then null else o end);
    perform public.bc('user:' || voter, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
  else
    for uid in select user_id from public.channel_members where channel_id = cid loop
      if uid = voter then
        perform public.bc('user:' || uid, 'poll', tg_op, tg_table_name, tg_table_schema, new, old);
      else
        perform public.bc('user:' || uid, 'poll', tg_op, tg_table_name, tg_table_schema,
          case when tg_op = 'DELETE' then null else n end, case when tg_op = 'INSERT' then null else o end);
      end if;
    end loop;
  end if;
  return null;
end;
$$;
revoke all on function public.broadcast_poll_ballot() from public, anon, authenticated;
