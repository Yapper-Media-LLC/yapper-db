-- 222: index for profiles.server_tag (the FK's on delete set null and 221's server delete trigger scan it).
-- Run on its own (concurrently can't be inside a transaction). Re-runnable.
create index concurrently if not exists profiles_server_tag_idx on public.profiles (server_tag) where server_tag is not null;
