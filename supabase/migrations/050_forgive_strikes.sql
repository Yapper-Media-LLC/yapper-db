-- Refused uploads stop counting toward an automatic ban once an admin unbans the person.
alter table public.media_scans add column if not exists forgiven boolean not null default false;

create or replace function public.forgive_strikes_on_unban()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Unbanned means the earlier refused uploads were a mistake: they stop counting toward an auto-ban.
  update public.media_scans set forgiven = true where user_id = old.user_id and verdict = 'blocked' and not forgiven;
  return old;
end;
$$;
revoke execute on function public.forgive_strikes_on_unban() from authenticated;
drop trigger if exists site_bans_forgive on public.site_bans;
create trigger site_bans_forgive after delete on public.site_bans for each row execute function public.forgive_strikes_on_unban();
