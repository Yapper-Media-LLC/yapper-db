-- ============================================================
-- Yapper · Membership checks that don't melt the CPU
-- "Which servers am I in?" used to be answered once per row (a function
-- call for each of HQ's thousand members). Now it's one small lookup per
-- query, which Postgres runs once and reuses.
-- ============================================================

create or replace function public.my_server_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select server_id from public.server_members where user_id = auth.uid();
$$;
grant execute on function public.my_server_ids() to authenticated;

alter policy "see servers you're in" on public.servers
  using (id in (select public.my_server_ids()));
alter policy "see members of your servers" on public.server_members
  using (server_id in (select public.my_server_ids()));
alter policy "see roles in your servers" on public.roles
  using (server_id in (select public.my_server_ids()));
alter policy "see role assignments in your servers" on public.member_roles
  using (server_id in (select public.my_server_ids()));
alter policy "see invites to your servers" on public.invites
  using (server_id in (select public.my_server_ids()));
alter policy "see channel roles in your servers" on public.channel_roles
  using (server_id in (select public.my_server_ids()));
alter policy "see who can post in your servers" on public.channel_post_roles
  using (server_id in (select public.my_server_ids()));

create index if not exists messages_channel_created_idx on public.messages (channel_id, created_at desc);
create index if not exists channel_reads_user_idx on public.channel_reads (user_id, channel_id);
