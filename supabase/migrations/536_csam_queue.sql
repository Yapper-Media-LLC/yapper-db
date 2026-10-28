-- 536: CSAM match queue (flag csam_queue, test). Legal list B2.
-- Cloudflare's CSAM Scanning Tool blocks a matched file at the edge and emails a daily list of file paths. An admin
-- pastes those (or a link from a report) into Mod Center, CSAM; each file becomes a case here with who uploaded it.
-- From the case: freeze + lock the uploader (admin_freeze_account, 281), "Secure and remove" (app/api/admin/csam:
-- a private copy goes to the "evidence" bucket, then takeDown removes the file and everywhere it's shown), and the
-- NCMEC report number once it's filed. Evidence is kept at least a year after the report (keep_until); nothing
-- here deletes it.
-- Admins only, everything through security definer functions; the table has RLS and no policies. Re-runnable.

insert into storage.buckets (id, name, public, file_size_limit)
values ('evidence', 'evidence', false, 104857600)
on conflict (id) do update set public = false;

create table if not exists public.csam_cases (
  id uuid primary key default gen_random_uuid(),
  bucket text not null check (bucket in ('attachments', 'avatars', 'banners', 'icons', 'emojis')),
  path text not null,
  source text not null default 'cloudflare' check (source in ('cloudflare', 'report', 'manual')),
  -- No foreign key: the record has to outlive the account.
  user_id uuid,
  status text not null default 'open' check (status in ('open', 'confirmed', 'not_csam', 'reported')),
  note text,
  ncmec_report_id text,
  evidence_key text,
  evidence_sha256 text,
  taken_down_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  handled_by uuid,
  handled_at timestamptz,
  reported_at timestamptz,
  keep_until timestamptz not null default now() + interval '1 year',
  -- Copied when the case is made, so the report still has them after the file is removed, the sign-up IP ages
  -- out (90 days) or the account is deleted.
  uploader_username text,
  uploader_email text,
  account_created timestamptz,
  signup_ip text,
  -- The uploader's messages that carried the file: [{id, channel_id, created_at, content}].
  context jsonb not null default '[]',
  unique (bucket, path)
);
create index if not exists csam_cases_user_idx on public.csam_cases (user_id);
create index if not exists csam_cases_status_idx on public.csam_cases (status, created_at desc);
-- The case list and csam_add look up sign-up IPs by user (small table, so not concurrently).
create index if not exists signup_log_user_idx on public.signup_log (user_id, created_at desc);
alter table public.csam_cases enable row level security;
revoke all on public.csam_cases from anon, authenticated;

-- Adds a file as a case (or returns the one already there). The uploader comes from the upload check's record,
-- else from the path, whose first part is the uploader's id for every upload made through the app.
create or replace function public.csam_add(p_bucket text, p_path text, p_source text default 'cloudflare', p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  cid uuid;
  who uuid;
  first text;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  if p_bucket is null or p_bucket not in ('attachments', 'avatars', 'banners', 'icons', 'emojis') then raise exception 'Unknown bucket'; end if;
  if p_path is null or p_path !~ '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' or p_path ~ '/\.\.?$' or length(p_path) > 300 then raise exception 'That doesn''t look like a file path'; end if;
  if p_source not in ('cloudflare', 'report', 'manual') then raise exception 'Unknown source'; end if;
  select id into cid from public.csam_cases where bucket = p_bucket and path = p_path;
  if cid is not null then return cid; end if;
  select user_id into who from public.media_scans where bucket = p_bucket and path = p_path;
  if who is null then
    first := split_part(p_path, '/', 1);
    if first ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select id into who from public.profiles where id = first::uuid;
    end if;
  end if;
  insert into public.csam_cases (bucket, path, source, user_id, note, created_by,
    uploader_username, uploader_email, account_created, signup_ip, context)
  select p_bucket, p_path, p_source, who, nullif(left(coalesce(p_note, ''), 1000), ''), auth.uid(),
    (select p.username from public.profiles p where p.id = who),
    (select u.email::text from auth.users u where u.id = who),
    (select u.created_at from auth.users u where u.id = who),
    (select s.ip from public.signup_log s where s.user_id = who order by s.created_at desc limit 1),
    -- messages_author_created_idx narrows this to the uploader's own messages.
    coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'channel_id', m.channel_id, 'created_at', m.created_at, 'content', left(m.content, 2000)))
      from (select * from public.messages m where who is not null and p_bucket = 'attachments' and m.author_id = who and m.attachment_path = p_path limit 20) m), '[]')
  on conflict (bucket, path) do nothing
  returning id into cid;
  if cid is null then select id into cid from public.csam_cases where bucket = p_bucket and path = p_path; end if;
  insert into public.mod_log (actor, action, target_id, reason) values (auth.uid(), 'csam_case', who, left(cid::text || ' ' || p_bucket || '/' || p_path, 120));
  return cid;
end $$;

-- The queue, with what an NCMEC report needs about the uploader. p_status: 'open' (open + confirmed), 'done'
-- (reported + not_csam) or 'all'.
create or replace function public.csam_cases_list(p_status text default 'open')
returns table (
  id uuid, bucket text, path text, source text, status text, note text, ncmec_report_id text,
  evidence_saved boolean, taken_down_at timestamptz, created_at timestamptz, reported_at timestamptz, keep_until timestamptz,
  user_id uuid, username text, email text, account_created timestamptz, last_sign_in timestamptz,
  signup_ip text, uploaded_at timestamptz, frozen boolean, banned boolean, context jsonb
) language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  return query
  select c.id, c.bucket, c.path, c.source, c.status, c.note, c.ncmec_report_id,
    c.evidence_key is not null, c.taken_down_at, c.created_at, c.reported_at, c.keep_until,
    c.user_id, coalesce(c.uploader_username, p.username), coalesce(c.uploader_email, u.email::text),
    coalesce(c.account_created, u.created_at), u.last_sign_in_at,
    coalesce(c.signup_ip, (select s.ip from public.signup_log s where s.user_id = c.user_id order by s.created_at desc limit 1)),
    (select m.scanned_at from public.media_scans m where m.bucket = c.bucket and m.path = c.path),
    exists (select 1 from public.account_freezes f where f.user_id = c.user_id),
    exists (select 1 from public.site_bans b where b.user_id = c.user_id),
    c.context
  from public.csam_cases c
  left join public.profiles p on p.id = c.user_id
  left join auth.users u on u.id = c.user_id
  where p_status = 'all'
    or (p_status = 'open' and c.status in ('open', 'confirmed'))
    or (p_status = 'done' and c.status in ('reported', 'not_csam'))
  order by c.created_at desc
  limit 200;
end $$;

-- Moves a case on. 'reported' needs the NCMEC report number and keeps the evidence a year from now at least;
-- 'not_csam' (a false match) needs a note.
create or replace function public.csam_set(p_id uuid, p_status text, p_ncmec text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.csam_cases;
begin
  if not public.is_site_admin() then raise exception 'Admins only'; end if;
  select * into c from public.csam_cases where id = p_id for update;
  if not found then raise exception 'No such case'; end if;
  if p_status not in ('open', 'confirmed', 'not_csam', 'reported') then raise exception 'Unknown status'; end if;
  if p_status = 'reported' and length(trim(coalesce(p_ncmec, ''))) < 3 then raise exception 'Add the NCMEC report number'; end if;
  if p_status = 'not_csam' and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say why it isn''t'; end if;
  update public.csam_cases set
    status = p_status,
    ncmec_report_id = case when p_status = 'reported' then left(trim(p_ncmec), 100) else ncmec_report_id end,
    note = coalesce(nullif(left(trim(coalesce(p_note, '')), 1000), ''), note),
    reported_at = case when p_status = 'reported' then coalesce(reported_at, now()) else reported_at end,
    keep_until = case when p_status = 'reported' then greatest(keep_until, now() + interval '1 year') else keep_until end,
    handled_by = auth.uid(),
    handled_at = now()
  where id = p_id;
  insert into public.mod_log (actor, action, target_id, reason)
  values (auth.uid(), 'csam_' || p_status, c.user_id, left(p_id::text || ' ' || coalesce(p_ncmec, p_note, ''), 120));
end $$;

revoke all on function public.csam_add(text, text, text, text) from public, anon;
revoke all on function public.csam_cases_list(text) from public, anon;
revoke all on function public.csam_set(uuid, text, text, text) from public, anon;
grant execute on function public.csam_add(text, text, text, text) to authenticated;
grant execute on function public.csam_cases_list(text) to authenticated;
grant execute on function public.csam_set(uuid, text, text, text) to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('csam_queue', 'CSAM match queue', 'Mod Center, CSAM (admins): cases from Cloudflare CSAM matches, freeze + lock, secure evidence and remove, NCMEC report number. Test: Antic only', 'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
