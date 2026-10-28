-- The proofs bucket (verification screenshots, bug report screenshots, staff proof for warnings and bans) had an
-- upload policy but no delete policy, so nobody could remove their own file: not even the app, which tries to delete
-- the proof again when a verification application fails (VerifySettings). Bug report Oct 22.
--
-- Now you can delete files in your own folder, except a screenshot attached as proof to a warning or ban (that's
-- moderation evidence the person it's about can open, and it must not vanish from under the decision) or the
-- screenshot of a verification application that's still waiting for review.
-- Safe to apply any time.

create or replace function public.proof_is_evidence(obj text)
returns boolean language sql stable security definer set search_path = public as $$
  -- Only answers about your own files (anything else reads as evidence), so it can't be used to probe other paths.
  select split_part(coalesce(obj, ''), '/', 1) is distinct from (select auth.uid())::text
      or exists (select 1 from public.user_warnings w where jsonb_typeof(w.proof -> 'images') = 'array' and w.proof -> 'images' ? obj)
      or exists (select 1 from public.site_bans b where jsonb_typeof(b.proof -> 'images') = 'array' and b.proof -> 'images' ? obj)
      -- A verification application still waiting for review keeps its screenshot.
      or exists (select 1 from public.verification_requests v where v.proof_path = obj and v.status = 'pending');
$$;
revoke all on function public.proof_is_evidence(text) from public, anon;
grant execute on function public.proof_is_evidence(text) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'proofs: delete own') then
    create policy "proofs: delete own" on storage.objects for delete to authenticated
      using (bucket_id = 'proofs' and (storage.foldername(name))[1] = (select auth.uid())::text and not public.proof_is_evidence(name));
  end if;
end $$;
