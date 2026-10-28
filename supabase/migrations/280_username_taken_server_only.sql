-- 280: username_taken() is for the server only (Oct 19).
-- From Oct 18 ~21:00 UTC someone called it straight on Supabase's REST API at up to ~1.9M calls an hour (one IP did
-- ~400/s), right after the login form stopped telling which usernames exist (57ed72f): a list of real usernames.
-- The only callers that matter are server-side with the service role: /api/signup (behind the captcha, answers
-- "That username is taken"), /api/bots and /api/bots/look. The sign-up form's own check (components/Auth.tsx) ignores
-- an error and carries on to /api/signup, so nothing changes for people. Database functions and policies don't use it.
-- Re-runnable.

revoke execute on function public.username_taken(text) from public, anon, authenticated;
grant execute on function public.username_taken(text) to service_role;
