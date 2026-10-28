-- 299: flag gdpr_delete (test): Settings → Delete account goes through /api/account/delete, which deletes the account
-- the same way (delete_my_account as you) and then emails a GDPR Art. 17 confirmation of what was erased and what is
-- kept for a while. Row only, no schema change. Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gdpr_delete', 'GDPR delete receipt', 'Delete account sends a confirmation email of the erasure (GDPR Art. 17).', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
