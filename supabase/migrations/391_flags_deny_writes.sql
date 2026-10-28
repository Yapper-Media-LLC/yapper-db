-- 391 (written as 381, renumbered: 381 was taken live by deco_autocheck): feature_flags write surface, after an Oct 22 report that "any logged-in account can PATCH flags".
-- Reality at head: the UPDATE grant to authenticated comes from Supabase's default privileges; the row-level
-- policy "admins change flags" (031, admin-only via is_site_admin) is the actual gate. A non-admin PATCH matches
-- no visible rows, so it changes nothing yet PostgREST answers a silent 200 with [] — which is almost certainly
-- what the reporter saw (and reading the flag back through the roadmap/ my_flags shows 'everyone' because most
-- flags are published anyway). Verified 22 Oct: anon over REST now gets permission denied on read (269 took
-- its select grant) and a non-admin UPDATE cannot change a row.
-- Hardening that doesn't break the staff editor (Admin -> Features updates the table directly): anon loses its
-- leftover default UPDATE grant (it never had an update policy, RLS blocked it silently), and signed-in users
-- lose INSERT/DELETE/TRUNCATE/REFERENCES/TRIGGER (again blocked by missing policies, made explicit). UPDATE stays
-- available to authenticated so staff can still edit flags; is_site_admin() is the gate. Re-runnable.

revoke update, insert, delete, truncate, references, trigger on public.feature_flags from anon;
revoke insert, delete, truncate, references, trigger on public.feature_flags from authenticated;
