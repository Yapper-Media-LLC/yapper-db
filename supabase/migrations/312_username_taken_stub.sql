-- 312: put a cheap public.username_taken() back in the API schema (Oct 20).
-- 307 moved username_taken out of public so the script calls (~35 a second, anon, no referer) would get a 404 from
-- PostgREST's schema cache. But for a missing function PostgREST runs a fuzzy "did you mean" search over every function
-- in the schema cache on each 404, on the same box as Postgres: from 12:50 UTC, the minute 307 went in, every API request
-- went from ~105 ms to ~2,000 ms. This stub lets PostgREST find the function again. It reads nothing and always answers
-- null, so it tells a script nothing; the real check stays in srv_username_taken (service role only, 306). Re-runnable.

create or replace function public.username_taken(name text)
returns boolean language sql immutable set search_path to 'public' as $$ select null::boolean $$;
revoke all on function public.username_taken(text) from public;
grant execute on function public.username_taken(text) to anon, authenticated;
