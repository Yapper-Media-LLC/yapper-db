-- Sign-up check for suspicious accounts (applied live Oct 15), feature flag `verify_suspicious`:
--   test      only record who would have been asked (pending_verifications, enforced = false)
--   everyone  flagged sign-ups get an email link and can't post until they click it
-- Needs RESEND_API_KEY (and optionally MAIL_FROM) in Vercel for the mail to go out.
alter table public.profiles add column if not exists verify_required boolean not null default false;
grant select (verify_required) on public.profiles to authenticated, anon;
create table if not exists public.pending_verifications (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  token text not null unique,
  email text not null,
  reason text not null default '',
  enforced boolean not null default false,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  verified_at timestamptz
);
alter table public.pending_verifications enable row level security;
create or replace function public.require_verified_email()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if current_setting('yapper.bot', true) = '1' then return new; end if;
  if exists (select 1 from public.profiles p where p.id = new.author_id and p.verify_required) then
    raise exception 'Check your email and click the link we sent you, then you can post.' using errcode = 'check_violation';
  end if;
  return new;
end; $function$;
drop trigger if exists messages_verified_email on public.messages;
create trigger messages_verified_email before insert on public.messages
  for each row execute function public.require_verified_email();
insert into public.feature_flags (key, label, description, mode, users)
  values ('verify_suspicious', 'Email check for suspicious sign-ups', 'test = only record who would be asked; everyone = they must click the email link before posting', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
