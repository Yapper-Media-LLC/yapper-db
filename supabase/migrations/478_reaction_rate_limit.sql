-- 478: rate limit on adding reactions. Re-runnable. NOT applied (database freeze Oct 25).
-- Bug 391d2362: someone put loads of reactions on lots of messages in an instant. Reactions are a plain RLS insert
-- on public.reactions and nothing limited how fast one account could add them (reaction_limit only caps 20 emoji
-- per message). A script could fire hundreds in a second, each one broadcast to the whole channel.
-- Now one account can add at most 20 reactions in 10 seconds and 100 in 5 minutes. Counted on reactions_user_idx
-- (user_id, created_at), which is live already; each check stops reading after limit+1 rows, so it stays cheap.
-- Internal inserts (yapper.bot = '1', e.g. reaction roles) and inserts not made by the signed-in user skip it.
-- Removing a reaction deletes its row, so add/remove loops aren't counted; this stops the mass spam, not toggling.
-- Review fixes: created_at is set by the trigger (a backdated created_at sent by the client skipped the windows),
-- and one account's reaction inserts queue behind each other on an advisory lock, so parallel requests can't all
-- pass the count. Other accounts never wait. The DDL runs with lock_timeout 2s (reactions is hot) and the index is
-- only built where it is missing (it is live already).

set lock_timeout = '2s';

do $$ begin
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'reactions_user_idx') then
    create index reactions_user_idx on public.reactions (user_id, created_at);
  end if;
end $$;

create or replace function public.reaction_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or auth.uid() is distinct from new.user_id
     or coalesce(current_setting('yapper.bot', true), '') = '1' then
    return new;
  end if;
  new.created_at := now();
  perform pg_advisory_xact_lock(hashtextextended('react:' || new.user_id::text, 0));
  if (select count(*) from (select 1 from public.reactions r
        where r.user_id = new.user_id and r.created_at > now() - interval '10 seconds' limit 20) x) >= 20
     or (select count(*) from (select 1 from public.reactions r
        where r.user_id = new.user_id and r.created_at > now() - interval '5 minutes' limit 100) y) >= 100 then
    raise exception 'Slow down, you''re reacting too fast. Try again in a bit.' using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke all on function public.reaction_rate_limit() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgrelid = 'public.reactions'::regclass and tgname = 'reactions_rate_limit') then
    create trigger reactions_rate_limit before insert on public.reactions
      for each row execute function public.reaction_rate_limit();
  end if;
end $$;

reset lock_timeout;
