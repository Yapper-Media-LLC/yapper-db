-- 484: gore check for pictures (flag gore_check, test). Oct 25: three accounts a few minutes old posted gore in
-- Yapin' HQ; the image check only knows sexual content and scored one 0.04. Now Claude also rates violence on every
-- picture sent in a message by an account under a day old, and on every picture for HQ (lib/server/media.ts
-- goreCheck, ~2,650 a day, about $16 a month on Haiku). Graphic gore is refused; a sure one is a strike, and two in a
-- day ban an account under a day old for 7 days.
--   * image_reviews gets the violence answer, so the same bytes are never paid for twice.
--   * Which server an upload is for comes from the browser, so a raider could leave it out and skip the HQ check.
--     require_scanned_media therefore refuses a picture in an HQ message from a person (not bots or webhooks, which
--     have no auth.uid()) unless its scan went through the gore check (media_scans.details has 'gore'). Staff who
--     can manage messages in that channel are left out, like the stricter HQ line from 092. Only while the flag is
--     on for the sender.
-- Re-runnable. Only create or replace / add column if not exists.

set lock_timeout = '5s';

insert into public.feature_flags (key, label, description, mode, servers, users)
values ('gore_check', 'Gore check for pictures',
  'Claude checks pictures from accounts under a day old and pictures in Yapin'' HQ for gore and graphic violence.',
  'test', array['00000000-0000-4000-8000-00000000b001']::uuid[], array['00000000-0000-4000-8000-00000000a001']::uuid[])
on conflict (key) do nothing;

alter table public.image_reviews add column if not exists violence text;
alter table public.image_reviews add column if not exists violence_confidence real;
-- Asked by the gore check (not the sexual second opinion): each has its own daily allowance per person.
alter table public.image_reviews add column if not exists gore_only boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'image_reviews_violence_known') then
    alter table public.image_reviews add constraint image_reviews_violence_known
      check (violence is null or violence in ('none', 'mild', 'graphic')) not valid;
  end if;
end $$;

-- The live text (092, with channel_allows since), plus the HQ gore rule.
create or replace function public.require_scanned_media()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  i int; col text; b text; val text; old_val text; sid uuid; strict_server boolean := false; cid uuid;
  gore_rule boolean := null;
begin
  -- This trigger also guards avatars, banners and server icons, whose rows have no channel.
  cid := (to_jsonb(new) ->> 'channel_id')::uuid;
  if cid is not null then
    select c.server_id into sid from public.channels c where c.id = cid;
    strict_server := sid is not null and sid = (select default_server_id from public.app_settings limit 1)
                     and not public.channel_allows(cid, 'manage_messages');
  end if;
  for i in 0 .. (tg_nargs / 2) - 1 loop
    col := tg_argv[i * 2];
    b := tg_argv[i * 2 + 1];
    val := to_jsonb(new) ->> col;
    old_val := case when tg_op = 'UPDATE' then to_jsonb(old) ->> col else null end;
    if val is not null and val is distinct from old_val then
      if not public.media_ok(b, val) then
        raise exception 'That image hasn''t been checked yet. Try sending it again.' using errcode = 'check_violation';
      end if;
      if strict_server and exists (select 1 from public.media_scans s where s.bucket = b and s.path = val and s.score >= 0.6) then
        raise exception 'That picture is too close to the line for Yapper HQ. It is fine in smaller servers.' using errcode = 'check_violation';
      end if;
      -- Gore check (484): a person's picture in HQ must have been through it. Worked out once per row, only here.
      -- Videos too (a new account's are refused at upload; anyone else's carry details.gore.skipped). KLIPY GIFs are
      -- picked from our own PG-13 search and stored by the server (gifs/attach), not uploaded: left out.
      if strict_server and b = 'attachments' and val ~* '\.(png|jpe?g|webp|gif|mp4|webm|mov)$' then
        gore_rule := coalesce(gore_rule, (select auth.uid()) is not null and public.feature_on_for_me('gore_check'));
        if gore_rule and not exists (select 1 from public.media_scans s where s.bucket = b and s.path = val
                                     and (s.details ? 'gore' or s.details ->> 'source' = 'klipy')) then
          raise exception 'Send that picture again so it can be checked for Yapin'' HQ.' using errcode = 'check_violation';
        end if;
      end if;
    end if;
  end loop;
  return new;
end;
$function$;

reset lock_timeout;
