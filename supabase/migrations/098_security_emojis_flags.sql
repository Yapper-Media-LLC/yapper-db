-- Security report (2026-10-15).
-- Applied via MCP: emojis_by_ids(ids) (no uploader) and my_flags() (test groups only visible to admins; members see
-- only their own id / their own servers). The client now uses both.
-- Run by hand in the SQL editor AFTER the client using them is deployed (MCP refused permission changes):
alter policy "emojis are visible to signed-in users" on public.emojis
  using (owner_id = auth.uid() or (server_id is not null and public.is_server_member(server_id)) or public.is_site_admin());
revoke select on public.feature_flags from anon, authenticated;
grant select (key, label, description, mode, updated_at) on public.feature_flags to anon, authenticated;
alter role authenticated set statement_timeout = '5s';
