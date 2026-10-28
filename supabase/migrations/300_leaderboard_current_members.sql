-- 300: the Levels bot's !top listed people who had left the server or were banned from it (or from Yapper):
-- XP rows stay behind when someone leaves. !top now only counts current members who aren't site-banned. The
-- function is patched from its live text so nothing else in bot_helper changes; it stops loudly if the !top query
-- isn't the one this expects. Re-runnable (skips when already patched). CREATE OR REPLACE keeps owner and grants.
-- The site-ban check is inline (no per-row function call); server_xp_top (server_id, xp desc) keeps the walk short.
do $$
declare f text;
begin
  f := pg_get_functiondef('public.bot_helper(uuid,uuid,uuid,text)'::regprocedure);
  if position('top_m.user_id = x.user_id' in f) > 0 then return; end if;
  if position('where x.server_id = sid order by x.xp desc limit 10' in f) = 0 then
    raise exception '300: bot_helper !top query changed, patch it by hand';
  end if;
  f := replace(f, 'where x.server_id = sid order by x.xp desc limit 10',
    'where x.server_id = sid'
    || ' and exists (select 1 from public.server_members top_m where top_m.server_id = sid and top_m.user_id = x.user_id)'
    || ' and not exists (select 1 from public.site_bans top_b where top_b.user_id = x.user_id and (top_b.expires_at is null or top_b.expires_at > now()))'
    || ' order by x.xp desc limit 10');
  execute f;
end $$;
