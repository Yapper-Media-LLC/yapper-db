-- Reaction roles (applied live Oct 14): reaction_roles table, set_reaction_roles(mid, pairs), reaction_role_apply
-- trigger on reactions (grants/removes member_roles with the yapper.bot setting so role_guard lets it through).
-- Flag: reaction_roles. Set up from a message's menu (Manage Roles).
create table if not exists public.reaction_roles (
  message_id uuid not null references public.messages(id) on delete cascade,
  emoji text not null,
  role_id uuid not null references public.roles(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  primary key (message_id, emoji)
);
