-- Verification: "Needs proof" step. Admin asks for the bio line; the applicant presses
-- "Done, check again" and the application comes back to the queue marked ready.
alter table public.verification_requests drop constraint if exists verification_requests_status_check;
alter table public.verification_requests add constraint verification_requests_status_check check (status in ('pending','needs_proof','approved','rejected'));
alter table public.verification_requests add column if not exists proof_added_at timestamptz;
alter table public.verification_requests add column if not exists asked_at timestamptz;

create or replace function public.ask_verification_proof(rid uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
  update public.verification_requests set status = 'needs_proof',
    review_note = coalesce(nullif(btrim(p_note), ''), 'Put "yapper: ' || (select username from public.profiles where id = r.user_id) || '" in your channel bio or description so we can see it''s really you.'),
    asked_at = now(), proof_added_at = null, reviewed_by = auth.uid() where id = rid;
  perform realtime.broadcast_changes('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $$;

create or replace function public.verification_proof_added(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.verification_requests set status = 'pending', proof_added_at = now()
    where id = rid and user_id = auth.uid() and status = 'needs_proof';
  if not found then raise exception 'Nothing to re-check'; end if;
end; $$;

create or replace function public.review_verification(rid uuid, approve boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; label text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into r from public.verification_requests where id = rid for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status not in ('pending', 'needs_proof') then raise exception 'Already reviewed'; end if;
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
  perform realtime.broadcast_changes('user:' || r.user_id, 'verification', 'UPDATE', 'verification_requests', 'public', null, null);
end; $$;
grant execute on function public.ask_verification_proof(uuid, text), public.verification_proof_added(uuid) to authenticated;
