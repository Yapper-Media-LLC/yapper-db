-- One badge at a time: people pick which of their badges shows next to their name (Settings → My Account).
-- null = their first badge; 'none' = hide them all.
alter table public.profiles add column if not exists shown_badge text;
grant select (shown_badge) on public.profiles to anon, authenticated;

-- bootstrap() and channel_messages() (061) return the new column too: re-run 061 after this.
