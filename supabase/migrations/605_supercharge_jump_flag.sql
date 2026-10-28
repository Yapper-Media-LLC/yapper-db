-- 605: flag for jumping a server to a supercharge level by clicking its gem (components/Supercharge.tsx), test mode
-- for Antic. Data only, no schema reload. Extra supercharges of one checkout are stored as "<sub>#2"... (no DDL).
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('supercharge_jump', 'Supercharge level jump', 'Click a level gem in the Supercharge dialog to boost the server straight to that level: uses your spare supercharges, then buys the rest in one checkout.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
