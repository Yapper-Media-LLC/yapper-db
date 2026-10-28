-- Creator verification: people apply from Settings with proof that they're the
-- real owner of a channel; a Yapper admin reviews, and approved accounts get a
-- badge (profiles.verified_as, e.g. "YouTube · Antic983").

alter table public.profiles add column if not exists verified_as text;

create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('youtube', 'twitch', 'tiktok', 'instagram', 'x', 'other')),
  handle text not null check (char_length(handle) between 1 and 60),
  link text not null check (link ~* '^https?://' and char_length(link) <= 300),
  note text not null default '' check (char_length(note) <= 1000),
  proof_path text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists verification_requests_status_idx on public.verification_requests (status, created_at);
create index if not exists verification_requests_user_idx on public.verification_requests (user_id, created_at desc);
alter table public.verification_requests enable row level security;

drop policy if exists "own verification requests" on public.verification_requests;
create policy "own verification requests" on public.verification_requests for select to authenticated
  using (user_id = auth.uid() or public.is_site_admin());

-- Apply through the function below, which enforces one open application at a time.
create or replace function public.apply_verification(p_platform text, p_handle text, p_link text, p_note text, p_proof_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; last_rej timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if public.is_site_banned(auth.uid()) then raise exception 'That account is banned'; end if;
  if (select verified_as from public.profiles where id = auth.uid()) is not null then raise exception 'You''re already verified'; end if;
  if exists (select 1 from public.verification_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'You already have an application waiting for review';
  end if;
  select max(reviewed_at) into last_rej from public.verification_requests where user_id = auth.uid() and status = 'rejected';
  if last_rej is not null and last_rej > now() - interval '7 days' then
    raise exception 'You can apply again % days after a rejection', 7;
  end if;
  if p_proof_path is not null and p_proof_path !~ ('^' || auth.uid()::text || '/') then raise exception 'Bad proof'; end if;
  insert into public.verification_requests (user_id, platform, handle, link, note, proof_path)
  values (auth.uid(), p_platform, trim(p_handle), trim(p_link), coalesce(p_note, ''), p_proof_path)
  returning id into rid;
  return rid;
end;
$$;

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; label text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status <> 'pending' then raise exception 'Already reviewed'; end if;
  update public.verification_requests
    set status = case when approve then 'approved' else 'rejected' end, reviewed_by = auth.uid(), reviewed_at = now(), review_note = coalesce(p_note, '')
    where id = rid;
  if approve then
    label := case r.platform when 'youtube' then 'YouTube' when 'twitch' then 'Twitch' when 'tiktok' then 'TikTok'
                             when 'instagram' then 'Instagram' when 'x' then 'X' else 'Creator' end || ' · ' || r.handle;
    update public.profiles set verified_as = label where id = r.user_id;
  end if;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), case when approve then 'verify' else 'verify_reject' end, r.user_id, coalesce(p_note, ''));
end;
$$;

create or replace function public.unverify(uid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  update public.profiles set verified_as = null where id = uid;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'unverify', uid, coalesce(p_note, ''));
end;
$$;

revoke all on function public.apply_verification(text, text, text, text, text), public.review_verification(uuid, boolean, text), public.unverify(uuid, text) from public, anon;
grant execute on function public.apply_verification(text, text, text, text, text), public.review_verification(uuid, boolean, text), public.unverify(uuid, text) to authenticated;

-- Nobody else may edit the badge (profiles update policy is "own row"; block the column with a trigger).
create or replace function public.protect_verified_as()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.verified_as is distinct from old.verified_as and not public.is_site_admin() and current_user <> 'postgres' and current_user <> 'service_role' then
    new.verified_as := old.verified_as;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect_verified on public.profiles;
create trigger profiles_protect_verified before update on public.profiles for each row execute function public.protect_verified_as();

-- Private bucket for proof screenshots: only the applicant and admins can see them.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs', 'proofs', false, 8388608, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;
drop policy if exists "proofs: read own or admin" on storage.objects;
create policy "proofs: read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_site_admin()));
drop policy if exists "proofs: upload own" on storage.objects;
create policy "proofs: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
