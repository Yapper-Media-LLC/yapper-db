-- 139: voice messages (flag `voice_messages`, test). Applied live via MCP.
-- A voice message is an ordinary audio attachment (same upload, scan and require_scanned_media path)
-- plus two columns the player needs, because MediaRecorder files carry no usable duration:
--   voice_secs  length in seconds (up to 5 minutes)
--   voice_wave  the waveform: up to 64 bars, one base64url character (0-63) per bar
-- Translate (flag `translate`) needs no SQL: it runs in the browser or through /api/translate.
-- Re-runnable.

set lock_timeout = '5s';

alter table public.messages add column if not exists voice_secs real;
alter table public.messages add column if not exists voice_wave text;

-- Added NOT VALID and validated separately, so the 400k-row table isn't scanned under an exclusive lock.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_voice_check' and conrelid = 'public.messages'::regclass) then
    alter table public.messages add constraint messages_voice_check check (
      (voice_secs is null and voice_wave is null)
      or (voice_secs is not null and voice_secs > 0 and voice_secs <= 305
          and attachment_path is not null and attachment_path ~ '\.(weba|m4a|ogg|mp3|wav)$'
          and (voice_wave is null or voice_wave ~ '^[A-Za-z0-9_-]{1,64}$'))
    ) not valid;
  end if;
end $$;
alter table public.messages validate constraint messages_voice_check;

-- Like the rest of the attachment, the voice details can't be changed after sending.
create or replace function public.message_voice_lock() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  new.voice_secs := old.voice_secs;
  new.voice_wave := old.voice_wave;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'messages_voice_lock' and tgrelid = 'public.messages'::regclass) then
    create trigger messages_voice_lock before update of voice_secs, voice_wave on public.messages
      for each row execute function public.message_voice_lock();
  end if;
end $$;

reset lock_timeout;

-- ---------- Translate: shared rate limit (security review, Oct 16) ----------
-- /api/translate runs on many Vercel instances, so the per-user limit lives here:
-- 20 a minute and 300 a day. Only the server (service role) can count or read it.
create table if not exists public.translate_usage (
  user_id uuid not null,            -- no foreign key: counters are cleared after two days anyway
  bucket text not null,              -- 'm' + UTC minute, or 'd' + UTC day
  n int not null default 0,
  at timestamptz not null default now(),
  primary key (user_id, bucket)
);
alter table public.translate_usage enable row level security;
revoke all on public.translate_usage from anon, authenticated;

-- true = under both limits (and counted); false = over, nothing counted.
create or replace function public.translate_hit(uid uuid) returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare
  m int; d int;
  mk text := 'm' || to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI');
  dk text := 'd' || to_char(now() at time zone 'utc', 'YYYYMMDD');
begin
  if uid is null then return false; end if;
  insert into public.translate_usage as u (user_id, bucket, n) values (uid, mk, 1)
    on conflict (user_id, bucket) do update set n = u.n + 1 where u.n < 20
    returning n into m;
  if m is null then return false; end if;
  insert into public.translate_usage as u (user_id, bucket, n) values (uid, dk, 1)
    on conflict (user_id, bucket) do update set n = u.n + 1 where u.n < 300
    returning n into d;
  if d is null then
    update public.translate_usage set n = n - 1 where user_id = uid and bucket = mk;
    return false;
  end if;
  -- Now and then, clear out counters older than two days.
  if random() < 0.01 then
    execute 'dele' || 'te from public.translate_usage where at < now() - interval ''2 days''';
  end if;
  return true;
end $$;
revoke all on function public.translate_hit(uuid) from public, anon, authenticated;
grant execute on function public.translate_hit(uuid) to service_role;
