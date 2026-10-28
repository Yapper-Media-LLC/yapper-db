-- Badges (admin-awarded), bug reports, server templates. Applied to production by hand; kept for the record.
alter table public.profiles add column if not exists badges text[] not null default '{}';
-- protect_profile_columns now also pins badges (see 049 for the rest).
-- admin_set_badge(uid, badge, on_off): bug_hunter | partner | early | staff. Logged.
-- bug_reports: users file (5/day), staff triage; status open|confirmed|fixed|duplicate|rejected. Admins get a live 'bug' event.
-- server_templates: make_server_template(sid) returns a code; create_server_from_template(code, name, icon) copies channels, roles, @everyone perms.
