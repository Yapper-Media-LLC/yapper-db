-- ============================================================
-- Yapper · Slur filter and message length
-- Messages, names and bios containing slurs are refused by the database
-- itself, so no app version can get around it. Simple tricks are caught too:
-- capitals, l33t speak (n1gg3r), symbols and spaced-out letters (n i g g a),
-- and stretched letters (niiigga).
-- Messages are limited to 2000 characters (custom emojis count as :name:).
-- ============================================================

-- Lower-case, l33t → letters, everything else → spaces, and glue
-- single spaced-out letters back together ("n i g g a" → "nigga").
create or replace function public.slur_text(t text)
returns text
language sql
immutable
as $$
  select regexp_replace(
    regexp_replace(translate(lower(coalesce(t, '')), '0134578@$!|', 'oieastbasii'), '[^a-z]+', ' ', 'g'),
    '(?<=\m[a-z]) (?=[a-z]\M)', '', 'g'
  );
$$;

create or replace function public.has_slur(t text)
returns boolean
language sql
immutable
as $$
  select
    -- whole words
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+g+(e+r+|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)s*'
      || '|f+a+g+(g+[oei]+t+)?s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*) '
    )
    -- the worst ones, even glued inside other words ("xniggerx")
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+)|f+a+g+g+[oei]+t+';
$$;

create or replace function public.no_slurs()
returns trigger
language plpgsql
as $$
declare
  col text;
  val text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    if val is not null and public.has_slur(val) then
      raise exception 'That contains a slur, so it wasn''t sent. Keep it respectful.'
        using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

create trigger messages_no_slurs before insert or update of content on public.messages
  for each row execute function public.no_slurs('content');
create trigger profiles_no_slurs before insert or update of username, bio on public.profiles
  for each row execute function public.no_slurs('username', 'bio');
create trigger servers_no_slurs before insert or update of name on public.servers
  for each row execute function public.no_slurs('name');
create trigger channels_no_slurs before insert or update of name on public.channels
  for each row execute function public.no_slurs('name');
create trigger roles_no_slurs before insert or update of name on public.roles
  for each row execute function public.no_slurs('name');
create trigger emojis_no_slurs before insert or update of name on public.emojis
  for each row execute function public.no_slurs('name');

-- 2000 characters, counting custom emojis the way you typed them (:name:).
create or replace function public.message_length()
returns trigger
language plpgsql
as $$
begin
  if char_length(regexp_replace(new.content, '<a?:([A-Za-z0-9_]{2,32}):[0-9a-f-]{36}>', ':\1:', 'g')) > 2000 then
    raise exception 'Messages can be up to 2000 characters' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger messages_length before insert or update of content on public.messages
  for each row execute function public.message_length();
