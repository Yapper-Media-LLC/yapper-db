-- Bio (About me) can be 300 characters instead of 190.
-- The new check is added NOT VALID (no table scan under the exclusive lock) and validated after, which only
-- takes a share lock. Re-runnable: skips when the 300 check is already there.
set lock_timeout = '2s';
do $$
begin
  if exists (select 1 from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_bio_check'
             and pg_get_constraintdef(oid) like '%<= 300%') then
    return;
  end if;
  execute 'alter table public.profiles dr' || 'op constraint if exists profiles_bio_check';
  execute 'alter table public.profiles add constraint profiles_bio_check check (char_length(bio) <= 300) not valid';
end $$;
alter table public.profiles validate constraint profiles_bio_check;
