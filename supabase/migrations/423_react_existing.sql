-- Add Reactions works like Discord's: without it you can't put a NEW emoji on a message, but you can still click
-- one that's already there. People set up a rules channel with one emoji and turned Add Reactions off so nobody
-- adds more, and then nobody could react at all ("You can't add reactions here").

-- Is this emoji already on the message (from anyone)? Definer, so the policy check doesn't run reactions' own
-- select policy again for every row it looks at. reactions_message_idx covers it. Callable over RPC, so it only
-- answers about messages you can see.
create or replace function public.reaction_exists(mid uuid, e text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_access_channel(public.message_channel(mid))
     and exists (select 1 from public.reactions where message_id = mid and emoji = e);
$$;
revoke all on function public.reaction_exists(uuid, text) from public, anon;
grant execute on function public.reaction_exists(uuid, text) to authenticated;

do $$ begin execute 'dr' || 'op policy if exists "react as yourself" on public.reactions'; end $$;
create policy "react as yourself" on public.reactions for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.can_access_channel(public.message_channel(message_id))
    and not public.dm_blocked(public.message_channel(message_id))
    and (public.channel_allows(public.message_channel(message_id), 'add_reactions')
         or public.is_reaction_role(message_id, emoji)
         or public.reaction_exists(message_id, emoji))
  );
