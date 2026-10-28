-- Server lobby (flag server_lobby, new look): a landing page per server, like the top of a subreddit. What the server
-- is about, an FAQ, its main channels and who runs it, next to the banner, description, tags, links and rules channel
-- the server already has. One row per server, written only through set_server_lobby (managers), read by members.
-- Not applied live yet.

create table if not exists public.server_lobby (
  server_id uuid primary key references public.servers(id) on delete cascade,
  about text not null default '' check (char_length(about) <= 2000),
  -- [{ "q": "...", "a": "..." }], at most 10
  faq jsonb not null default '[]'::jsonb check (jsonb_typeof(faq) = 'array' and jsonb_array_length(faq) <= 10),
  -- Main channels, in the order the lobby shows them
  featured uuid[] not null default '{}' check (cardinality(featured) <= 6),
  show_staff boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.server_lobby enable row level security;

-- Members read their server's lobby. Writes only go through set_server_lobby (no insert/update/delete policies).
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'server_lobby' and policyname = 'server_lobby_read') then
    create policy server_lobby_read on public.server_lobby for select to authenticated
      using (public.is_server_member(server_id));
  end if;
end $$;

revoke all on public.server_lobby from public, anon, authenticated;
grant select on public.server_lobby to authenticated;

insert into public.feature_flags (key, label, description, mode, servers, users) values
  ('server_lobby', 'Server lobby',
   'New look: a lobby page for each server (about, FAQ, main channels, staff, links). Managers fill it in Server settings, Lobby. Test: Antic only',
   'test', '{}', '{00000000-0000-4000-8000-00000000a001}')
  on conflict (key) do nothing;

-- Long lobby text gets the checks other long text gets (bios, messages), not the name filter: that one rejected plain
-- FAQ lines like "no porn" or "therapist". Returns why it's refused, or null.
create or replace function public.lobby_text_problem(t text)
returns text
language plpgsql
stable
set search_path to 'public'
as $$
begin
  if coalesce(t, '') = '' then return null; end if;
  if public.has_adult_link(t) then return 'Links to that site aren''t allowed on Yapper.'; end if;
  if public.has_slur(t) or public.has_sexual_spam(t) then return 'Some of that text isn''t allowed'; end if;
  return null;
end $$;
revoke all on function public.lobby_text_problem(text) from public, anon, authenticated;

-- Save the lobby. Text is trimmed and filtered; FAQ items keep only q and a; featured channels must be this server's
-- own (not tickets), repeats skipped. Each save goes in the server's audit log.
create or replace function public.set_server_lobby(sid uuid, p_about text, p_faq jsonb, p_featured uuid[], p_show_staff boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  about text := btrim(coalesce(p_about, ''));
  item jsonb;
  q text;
  a text;
  faq jsonb := '[]'::jsonb;
  feat uuid[] := '{}';
  f uuid;
  problem text;
begin
  if auth.uid() is null or not public.server_perm(sid, 'manage_server') then
    raise exception 'Only server managers can change the lobby' using errcode = 'insufficient_privilege';
  end if;
  if not public.feature_on('server_lobby', sid) then
    raise exception 'Lobbies aren''t on in this server yet' using errcode = 'check_violation';
  end if;

  -- Size first, before any per-item work (blank and repeated entries are skipped below, so a little slack).
  if p_faq is not null and jsonb_typeof(p_faq) <> 'array' then
    raise exception 'The FAQ has to be a list' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(coalesce(p_faq, '[]'::jsonb)) > 20 or coalesce(cardinality(p_featured), 0) > 12 then
    raise exception 'That''s too much for a lobby' using errcode = 'check_violation';
  end if;
  if char_length(about) > 2000 then
    raise exception 'The about text can be up to 2000 characters' using errcode = 'check_violation';
  end if;
  problem := public.lobby_text_problem(about);
  if problem is not null then
    raise exception '%', problem using errcode = 'check_violation';
  end if;
  for item in select value from jsonb_array_elements(coalesce(p_faq, '[]'::jsonb)) loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'Each FAQ entry needs a question and an answer' using errcode = 'check_violation';
    end if;
    q := btrim(coalesce(item ->> 'q', ''));
    a := btrim(coalesce(item ->> 'a', ''));
    continue when q = '' and a = '';
    if q = '' or a = '' then
      raise exception 'Each FAQ entry needs a question and an answer' using errcode = 'check_violation';
    end if;
    if char_length(q) > 200 or char_length(a) > 1000 then
      raise exception 'FAQ questions can be up to 200 characters and answers up to 1000' using errcode = 'check_violation';
    end if;
    problem := coalesce(public.lobby_text_problem(q), public.lobby_text_problem(a));
    if problem is not null then
      raise exception '%', problem using errcode = 'check_violation';
    end if;
    faq := faq || jsonb_build_array(jsonb_build_object('q', q, 'a', a));
  end loop;
  if jsonb_array_length(faq) > 10 then
    raise exception 'The FAQ can have up to 10 questions' using errcode = 'check_violation';
  end if;

  foreach f in array coalesce(p_featured, '{}') loop
    continue when f is null or f = any(feat);
    if not exists (select 1 from public.channels c where c.id = f and c.server_id = sid and c.ticket_by is null) then
      raise exception 'Main channels have to be channels in this server' using errcode = 'check_violation';
    end if;
    feat := feat || f;
  end loop;
  if cardinality(feat) > 6 then
    raise exception 'Pick up to 6 main channels' using errcode = 'check_violation';
  end if;

  insert into public.server_lobby (server_id, about, faq, featured, show_staff, updated_at)
  values (sid, about, faq, feat, coalesce(p_show_staff, true), now())
  on conflict (server_id) do update
    set about = excluded.about, faq = excluded.faq, featured = excluded.featured,
        show_staff = excluded.show_staff, updated_at = excluded.updated_at;

  perform public.audit_add(sid, 'server_update_lobby', 'server', sid, (select s.name from public.servers s where s.id = sid),
    jsonb_build_object('faq', jsonb_array_length(faq), 'featured', cardinality(feat)));
end $$;

revoke all on function public.set_server_lobby(uuid, text, jsonb, uuid[], boolean) from public, anon;
grant execute on function public.set_server_lobby(uuid, text, jsonb, uuid[], boolean) to authenticated;
