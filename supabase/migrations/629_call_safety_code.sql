-- 629: safety code for encrypted calls (flag call_safety_code). Clicking the lock in a call shows a 6-group number
-- derived from everyone's public keys (lib/callCrypto.ts); two people who read the same code know the keys they
-- exchanged are real. Rows only, no DDL: no schema cache reload. Same test group as call_e2ee (288). Re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('call_safety_code', 'Call safety code', 'Click the lock in an encrypted call to see a code you can compare with the other person to check nobody swapped keys.', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
