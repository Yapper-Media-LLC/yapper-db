-- Live events via our own server (ops/realtime on the VPS) instead of Supabase Realtime, applied live Oct 14.
-- app_settings.rt_mode: supabase | both | vps. public.bc(...) wraps realtime.broadcast_changes and, when the
-- mode says so, POSTs the same payload to <rt_url>/publish (vault secrets rt_url, rt_secret) through pg_net.
-- All 18 bc_* / broadcast_* trigger functions were rewritten to call public.bc. Client flag: rt_vps.
alter table public.app_settings add column if not exists rt_mode text not null default 'supabase' check (rt_mode in ('supabase', 'both', 'vps'));
insert into public.feature_flags (key, label, description, mode) values
  ('rt_vps', 'Realtime via our server', 'Live events over rt.yapper.website instead of Supabase Realtime', 'off') on conflict (key) do nothing;
