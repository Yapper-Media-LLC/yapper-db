-- Tickets: a member opens a private channel with the mods (like Discord ticket bots). Flag: tickets.
-- Applied live on Oct 14; see open_ticket / close_ticket / set_tickets, servers.tickets_on + ticket_seq, channels.ticket_by.
alter table public.servers add column if not exists tickets_on boolean not null default false;
alter table public.servers add column if not exists ticket_seq int not null default 0;
alter table public.channels add column if not exists ticket_by uuid references public.profiles(id) on delete set null;
create index if not exists channels_ticket_idx on public.channels (server_id) where ticket_by is not null;
insert into public.feature_flags (key, label, description, mode) values
  ('tickets', 'Tickets', 'Members open a private channel with the mods from the server menu', 'off') on conflict (key) do nothing;
