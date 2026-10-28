-- ============================================================
-- Yapper · No links to porn / hentai sites
-- Messages, bios and names with links to known adult sites are refused.
-- The list lives in a table so admins can add to it without a deploy.
-- ============================================================

create table public.blocked_domains (
  domain text primary key check (domain = lower(domain) and domain !~ '[^a-z0-9./-]'),
  added_at timestamptz not null default now()
);
alter table public.blocked_domains enable row level security;
create policy "admins read blocked domains" on public.blocked_domains for select to authenticated using (public.is_site_admin());
create policy "admins add blocked domains" on public.blocked_domains for insert to authenticated with check (public.is_site_admin());
create policy "admins remove blocked domains" on public.blocked_domains for delete to authenticated using (public.is_site_admin());

insert into public.blocked_domains (domain) values
  ('pornhub.com'), ('xvideos.com'), ('xnxx.com'), ('xhamster.com'), ('redtube.com'), ('youporn.com'),
  ('tube8.com'), ('spankbang.com'), ('eporner.com'), ('porntrex.com'), ('hqporner.com'), ('youjizz.com'),
  ('beeg.com'), ('tnaflix.com'), ('porn.com'), ('pornone.com'), ('thumbzilla.com'), ('pornhat.com'),
  ('chaturbate.com'), ('stripchat.com'), ('livejasmin.com'), ('bongacams.com'), ('cam4.com'), ('myfreecams.com'),
  ('onlyfans.com'), ('fansly.com'), ('manyvids.com'), ('clips4sale.com'),
  ('nhentai.net'), ('nhentai.to'), ('hentaihaven.xxx'), ('hanime.tv'), ('hentai2read.com'), ('hentaifox.com'),
  ('hitomi.la'), ('e-hentai.org'), ('exhentai.org'), ('fakku.net'), ('hentaila.com'), ('doujins.com'),
  ('rule34.xxx'), ('rule34.paheal.net'), ('rule34video.com'), ('rule34.us'), ('gelbooru.com'), ('danbooru.donmai.us'),
  ('xbooru.com'), ('realbooru.com'), ('e621.net'), ('e926.net'), ('kemono.su'), ('kemono.party'), ('coomer.su'), ('coomer.party'),
  ('motherless.com'), ('heavy-r.com'), ('xxxbunker.com'), ('pornpics.com'), ('sex.com'), ('brazzers.com'),
  ('bangbros.com'), ('realitykings.com'), ('naughtyamerica.com'), ('mofos.com'), ('digitalplayground.com'),
  ('f95zone.to'), ('lewdzone.com'), ('iwara.tv'), ('luscious.net'), ('8muses.com'), ('multporn.net'), ('simply-hentai.com'),
  ('xhamsterlive.com'), ('porntube.com'), ('4tube.com'), ('xtube.com'), ('xxxstreams.org'), ('javhd.com'),
  ('reddit.com/r/nsfw'), ('reddit.com/r/gonewild'), ('reddit.com/r/hentai'), ('reddit.com/r/rule34')
on conflict do nothing;

-- Every host (and host+path) mentioned in the text, lower-cased, "www." stripped.
create or replace function public.link_targets(t text)
returns setof text
language sql
immutable
as $$
  select distinct regexp_replace(lower(m[1]), '^www\.', '')
  from regexp_matches(coalesce(t, ''), '(?:https?://|www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[a-z0-9_/.-]*)?)', 'gi') as m;
$$;

create or replace function public.has_adult_link(t text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.link_targets(t) as l
    join public.blocked_domains b
      on l = b.domain
      or l like '%.' || b.domain
      or l like b.domain || '/%'
      or l like '%.' || b.domain || '/%'
  );
$$;

create or replace function public.no_adult_links()
returns trigger
language plpgsql
as $$
declare
  col text;
  val text;
begin
  foreach col in array tg_argv loop
    val := to_jsonb(new) ->> col;
    if val is not null and public.has_adult_link(val) then
      raise exception 'Links to adult sites aren''t allowed on Yapper.' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

create trigger messages_no_adult_links before insert or update of content on public.messages
  for each row execute function public.no_adult_links('content');
create trigger profiles_no_adult_links before insert or update of username, bio on public.profiles
  for each row execute function public.no_adult_links('username', 'bio');
create trigger servers_no_adult_links before insert or update of name on public.servers
  for each row execute function public.no_adult_links('name');
create trigger channels_no_adult_links before insert or update of name on public.channels
  for each row execute function public.no_adult_links('name');

grant execute on function public.has_adult_link(text) to authenticated;
