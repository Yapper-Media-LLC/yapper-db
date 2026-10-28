-- 570: a GIF from the picker is a KLIPY link (components/GifPicker.tsx sends the link as the message), so in a
-- server where Embed Links is off every GIF was refused with "You can't post links here" (bug report a1bac8d7).
-- A message that is nothing but one klipy.com link now skips the link check (a channel's no_gifs and text-only
-- settings still catch it through their own triggers; note the no_gifs flag is still in test mode).
-- message_perm_guard is patched on its live text, one line. Re-runnable.

set lock_timeout = '3s';

create or replace function public.gif_only_link(c text)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(btrim(c, E' \t\r\n'), '') ~* '^https://([a-z0-9-]+\.)*klipy\.com/\S*$'
$$;
revoke execute on function public.gif_only_link(text) from public, anon, authenticated;

do $$
declare f text;
  old_line constant text := E'if new.content ~* ''https?://''\n     and not (case when cp then public.channel_perm(new.channel_id, ''embed_links'')';
  new_line constant text := E'if new.content ~* ''https?://'' and not public.gif_only_link(new.content)\n     and not (case when cp then public.channel_perm(new.channel_id, ''embed_links'')';
begin
  if to_regprocedure('public.message_perm_guard()') is null then return; end if; -- test databases
  f := pg_get_functiondef('public.message_perm_guard()'::regprocedure);
  if position('gif_only_link' in f) > 0 then return; end if; -- already patched
  if (length(f) - length(replace(f, old_line, ''))) / length(old_line) <> 1 then
    raise exception '570: message_perm_guard changed, patch the GIF link check by hand';
  end if;
  execute replace(f, old_line, new_line);
end $$;
