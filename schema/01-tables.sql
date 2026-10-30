-- 01 roles, schemas, extensions, types, sequences, tables
-- Schema-only dump of the live Yapper database (Postgres 17.11). No rows from any table.
-- Made by scripts/dump-schema.mjs from catalog queries. Restore order: 01..06, after supabase-standins.sql.

set check_function_bodies = off;
set client_min_messages = warning;

-- Our own role (the API host). The Supabase roles come from the stand-ins.
do $$ begin create role yapper_api login noinherit; exception when duplicate_object then null; end $$;
grant anon to yapper_api;
grant authenticated to yapper_api;
grant service_role to yapper_api;
-- live: alter role anon set statement_timeout = '3s';
-- live: alter role authenticated set statement_timeout = '5s';
-- live: alter role authenticator set session_preload_libraries = 'supautils, safeupdate';
-- live: alter role authenticator set statement_timeout = '8s';
-- live: alter role authenticator set lock_timeout = '8s';
-- live: alter role authenticator set pgrst.jwt_cache_max_lifetime = '3600';
-- live: alter role authenticator set pgrst.db_pre_request = 'public.request_guard';
-- live: alter role yapper_api set pgrst.db_pre_request = 'public.request_guard';
-- live: alter role yapper_api set statement_timeout = '8s';
-- live: alter role yapper_api set lock_timeout = '8s';
-- live: alter role yapper_api set pgrst.jwt_cache_max_lifetime = '3600';

-- Schemas
create schema if not exists api_host;
create schema if not exists app_host;
create schema if not exists private;
create schema if not exists public;

-- Extensions on the live database. The ones a vanilla Postgres ships are created; the Supabase-only ones
-- (pg_net, pg_cron, supabase_vault, pg_graphql...) are covered by supabase-standins.sql.
create extension if not exists dblink with schema public;  -- live 1.2
-- extension pg_cron 1.6.4 in pg_catalog: Supabase-provided, see supabase-standins.sql
-- extension pg_net 0.20.4 in extensions: Supabase-provided, see supabase-standins.sql
create extension if not exists pg_stat_statements with schema extensions;  -- live 1.11
create extension if not exists pg_trgm with schema extensions;  -- live 1.6
create extension if not exists pgcrypto with schema extensions;  -- live 1.3
-- extension supabase_vault 0.3.1 in vault: Supabase-provided, see supabase-standins.sql
create extension if not exists unaccent with schema public;  -- live 1.1
create extension if not exists "uuid-ossp" with schema extensions;  -- live 1.1

-- Types

-- Sequences (identity columns make their own)
create sequence api_host.reports_id_seq as bigint increment 1 minvalue 1 maxvalue 9223372036854775807 start 1 cache 1;
create sequence public.bot_events_id_seq as bigint increment 1 minvalue 1 maxvalue 9223372036854775807 start 1 cache 1;
create sequence public.checkout_consents_id_seq as bigint increment 1 minvalue 1 maxvalue 9223372036854775807 start 1 cache 1;

-- Tables: columns, types, not null and identity. Defaults come in 03 (they can call functions), constraints in 04.
create table api_host.reports (
  id bigint not null,
  at timestamp with time zone not null,
  body text not null
);
create table api_host.secrets (
  name text not null,
  value text not null,
  updated_at timestamp with time zone not null
);
create table app_host.secrets (
  name text not null,
  value text not null,
  updated_at timestamp with time zone not null
);
create table public.account_freezes (
  user_id uuid not null,
  reason text not null,
  by uuid,
  created_at timestamp with time zone not null
);
create table public.account_suspensions (
  user_id uuid not null,
  reason text not null,
  until timestamp with time zone,
  by uuid,
  server_id uuid,
  created_at timestamp with time zone not null
);
create table public.alert_watches (
  id uuid not null,
  server_id uuid not null,
  yt_channel_id text not null,
  channel_id uuid not null,
  role_id uuid,
  template text,
  created_by uuid,
  created_at timestamp with time zone not null,
  last_posted_at timestamp with time zone,
  last_video_id text,
  last_test_at timestamp with time zone
);
create table public.alerts_rate (
  k text not null,
  since timestamp with time zone not null,
  n integer not null
);
create table public.app_settings (
  id boolean not null,
  default_server_id uuid,
  new_account_wait interval not null,
  paused boolean not null,
  paused_message text not null,
  rt_mode text not null,
  staff_vote_pct integer not null,
  webhook_user_id uuid,
  signups_paused_until timestamp with time zone,
  mod_limit_boost numeric not null
);
create table public.area_applications (
  id uuid not null,
  user_id uuid not null,
  area text not null,
  why text not null,
  links text not null,
  experience text not null,
  status text not null,
  note text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null
);
create table public.ban_appeals (
  id uuid not null,
  user_id uuid not null,
  ban_at timestamp with time zone not null,
  ban_reason text,
  message text not null,
  status text not null,
  created_at timestamp with time zone not null,
  decided_at timestamp with time zone,
  decided_by uuid,
  staff_note text
);
create table public.ban_leftovers (
  id bigint generated always as identity not null,
  ip text,
  email_hash text,
  until timestamp with time zone not null,
  created_at timestamp with time zone not null
);
create table public.billing_customers (
  user_id uuid not null,
  stripe_customer text not null,
  created_at timestamp with time zone not null
);
create table public.billing_fulfilments (
  business_id text not null,
  kind text not null,
  target uuid,
  event_id text,
  at timestamp with time zone not null
);
create table public.blocked_domains (
  domain text not null,
  added_at timestamp with time zone not null
);
create table public.blocked_email_domains (
  domain text not null,
  added_at timestamp with time zone not null
);
create table public.blocks (
  id uuid not null,
  blocker uuid not null,
  blocked uuid not null,
  created_at timestamp with time zone not null
);
create table public.bot_accounts (
  bot text not null,
  user_id uuid not null
);
create table public.bot_afk (
  server_id uuid not null,
  user_id uuid not null,
  reason text,
  since timestamp with time zone not null,
  away boolean not null
);
create table public.bot_commands (
  bot_id uuid not null,
  name text not null,
  description text not null
);
create table public.bot_events (
  id bigint not null,
  bot_id uuid not null,
  type text not null,
  data jsonb not null,
  created_at timestamp with time zone not null
);
create table public.bot_hosting (
  bot_id uuid not null,
  owner_id uuid not null,
  tier text not null,
  status text not null,
  want_running boolean not null,
  source_type text,
  source_url text,
  source_ref text,
  source_path text,
  source_pkg boolean not null,
  source_at timestamp with time zone,
  until timestamp with time zone,
  free_slot boolean not null,
  stripe_customer text,
  stripe_sub text,
  runner_id text,
  host_token_hash text,
  host_token_prefix text,
  blocked boolean not null,
  blocked_reason text,
  last_started_at timestamp with time zone,
  started_at timestamp with time zone,
  crash_count integer not null,
  oom_count integer not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);
create table public.bot_hosting_actions (
  id bigint generated always as identity not null,
  bot_id uuid not null,
  action text not null,
  at timestamp with time zone not null
);
create table public.bot_interaction_replies (
  id uuid not null,
  interaction_id uuid not null,
  bot_id uuid not null,
  user_id uuid not null,
  channel_id uuid not null,
  message_id uuid not null,
  kind text not null,
  content text,
  embeds jsonb,
  created_at timestamp with time zone not null
);
create table public.bot_interactions (
  id uuid not null,
  token text not null,
  bot_id uuid not null,
  message_id uuid not null,
  channel_id uuid not null,
  server_id uuid,
  user_id uuid not null,
  custom_id text not null,
  created_at timestamp with time zone not null,
  answered_at timestamp with time zone,
  replies integer not null
);
create table public.bot_perm_rate (
  bot_id uuid not null,
  window_start timestamp with time zone not null,
  n integer not null,
  read_window_start timestamp with time zone not null,
  read_n integer not null
);
create table public.bot_promotions (
  id uuid not null,
  bot_id uuid not null,
  starts_at timestamp with time zone not null,
  ends_at timestamp with time zone not null,
  source text not null,
  stripe_event text,
  created_by uuid,
  views integer not null,
  clicks integer not null,
  adds integer not null,
  ended_by uuid,
  created_at timestamp with time zone not null,
  kind text not null,
  mult integer not null,
  stripe_sub text
);
create table public.bot_servers (
  bot_id uuid not null,
  server_id uuid not null,
  added_by uuid,
  added_at timestamp with time zone not null
);
create table public.bot_signals (
  user_id uuid not null,
  hits integer not null,
  first_at timestamp with time zone not null
);
create table public.bot_voice_rate (
  bot_id uuid not null,
  window_start timestamp with time zone not null,
  n integer not null,
  read_window_start timestamp with time zone not null,
  read_n integer not null,
  join_window_start timestamp with time zone not null,
  join_n integer not null
);
create table public.bots (
  id uuid not null,
  owner_id uuid not null,
  name text not null,
  description text not null,
  token_hash text,
  token_prefix text,
  webhook_url text,
  webhook_secret text,
  public boolean not null,
  created_at timestamp with time zone not null,
  last_used_at timestamp with time zone,
  posts bigint not null,
  last_poll_at timestamp with time zone,
  last_event_at timestamp with time zone,
  submitted_at timestamp with time zone,
  verified_at timestamp with time zone,
  review_note text,
  presence jsonb,
  category text not null,
  avatar_path text,
  tag text,
  support_invite text,
  rate_min timestamp with time zone,
  rate_cur integer not null,
  rate_prev integer not null,
  renamed_at timestamp with time zone,
  unlisted boolean not null,
  shareable boolean not null,
  real_servers integer
);
create table public.bug_reports (
  id uuid not null,
  user_id uuid not null,
  title text not null,
  body text not null,
  severity text not null,
  status text not null,
  staff_note text not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone,
  staff_pick boolean not null,
  images text[] not null,
  edited_at timestamp with time zone
);
create table public.calls (
  channel_id uuid not null,
  started_by uuid not null,
  started_at timestamp with time zone not null,
  ended_at timestamp with time zone,
  answered_at timestamp with time zone
);
create table public.cancel_requests (
  id uuid not null,
  email text not null,
  what text not null,
  details text,
  token_hash text not null,
  ip_hash text,
  user_id uuid,
  created_at timestamp with time zone not null,
  confirmed_at timestamp with time zone,
  result text
);
create table public.channel_categories (
  id uuid not null,
  server_id uuid not null,
  name text not null,
  position integer not null,
  created_at timestamp with time zone not null
);
create table public.channel_members (
  channel_id uuid not null,
  user_id uuid not null,
  joined_at timestamp with time zone not null,
  hidden_at timestamp with time zone
);
create table public.channel_overrides (
  id uuid not null,
  server_id uuid not null,
  channel_id uuid,
  category_id uuid,
  role_id uuid,
  allow text[] not null,
  deny text[] not null,
  updated_at timestamp with time zone not null
);
create table public.channel_post_roles (
  channel_id uuid not null,
  role_id uuid not null,
  server_id uuid not null
);
create table public.channel_reads (
  user_id uuid not null,
  channel_id uuid not null,
  last_read_at timestamp with time zone not null,
  muted boolean not null
);
create table public.channel_roles (
  channel_id uuid not null,
  role_id uuid not null,
  server_id uuid not null
);
create table public.channels (
  id uuid not null,
  kind text not null,
  name text,
  dm_key text,
  created_by uuid,
  created_at timestamp with time zone not null,
  last_message_at timestamp with time zone not null,
  icon_path text,
  server_id uuid,
  position integer not null,
  private boolean not null,
  read_only boolean not null,
  slowmode integer not null,
  category_id uuid,
  ticket_by uuid,
  auto_slow_until timestamp with time zone,
  no_images boolean not null,
  ticket_panel text,
  no_gifs boolean not null,
  stage boolean not null,
  parent_id uuid,
  starter_message_id uuid,
  tags text[] not null,
  forum_tags jsonb not null,
  closed_at timestamp with time zone,
  closed_by uuid,
  locked boolean not null,
  pinned_at timestamp with time zone,
  guidelines text,
  require_tag boolean not null,
  default_sort text,
  default_layout text
);
create table public.checkout_consents (
  id bigint not null,
  user_id uuid not null,
  kind text not null,
  target text,
  country text,
  waiver_text text not null,
  terms_version text not null,
  created_at timestamp with time zone not null
);
create table public.community_deco_checks (
  deco_id uuid not null,
  verdict text not null,
  source text not null,
  confidence real not null,
  reason text not null,
  match_id uuid,
  model text not null,
  cost_usd numeric(10,6) not null,
  backfill boolean not null,
  attempts integer not null,
  checked_at timestamp with time zone not null,
  cleared_by uuid,
  cleared_at timestamp with time zone,
  cleared_note text not null
);
create table public.community_decos (
  id uuid not null,
  kind text,
  name text not null,
  artist_id uuid not null,
  path text not null,
  status text not null,
  review_note text not null,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  created_at timestamp with time zone not null,
  event text,
  price integer
);
create table public.copyright_strikes (
  id uuid not null,
  user_id uuid not null,
  server_id uuid,
  notice text not null,
  by uuid,
  created_at timestamp with time zone not null,
  removed_at timestamp with time zone,
  removed_by uuid
);
create table public.creator_applications (
  id uuid not null,
  user_id uuid not null,
  followers integer not null,
  content_link text not null,
  note text not null,
  status text not null,
  tier smallint,
  plus_months integer,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  review_note text not null,
  created_at timestamp with time zone not null,
  recent_link text,
  channel_check jsonb,
  asked_at timestamp with time zone,
  proof_added_at timestamp with time zone,
  proof_link text,
  proof_path text,
  proof_note text not null
);
create table public.creator_content (
  id uuid not null,
  user_id uuid not null,
  link text not null,
  note text not null,
  status text not null,
  reward_months integer not null,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  review_note text not null,
  created_at timestamp with time zone not null,
  format text not null,
  views integer not null,
  views_checked integer,
  title text not null,
  thumb text,
  video_key text,
  review_checks jsonb,
  check_after timestamp with time zone
);
create table public.creator_link_hits (
  code text not null,
  day date not null,
  n integer not null
);
create table public.creator_links (
  user_id uuid not null,
  code text not null,
  settled_at timestamp with time zone,
  created_at timestamp with time zone not null,
  counted integer not null
);
create table public.creator_referrals (
  user_id uuid not null,
  referrer uuid not null,
  created_at timestamp with time zone not null,
  confirmed_at timestamp with time zone,
  seq integer,
  status text not null,
  reason text,
  checked_at timestamp with time zone
);
create table public.csam_cases (
  id uuid not null,
  bucket text not null,
  path text not null,
  source text not null,
  user_id uuid,
  status text not null,
  note text,
  ncmec_report_id text,
  evidence_key text,
  evidence_sha256 text,
  taken_down_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone not null,
  handled_by uuid,
  handled_at timestamp with time zone,
  reported_at timestamp with time zone,
  keep_until timestamp with time zone not null,
  uploader_username text,
  uploader_email text,
  account_created timestamp with time zone,
  signup_ip text,
  context jsonb not null
);
create table public.data_exports (
  id bigint generated always as identity not null,
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.deco_backup_389 (
  id uuid not null,
  avatar_deco text,
  profile_effect text,
  saved_at timestamp with time zone not null
);
create table public.deco_owned (
  user_id uuid not null,
  deco_id uuid not null,
  price_paid integer not null,
  bought_at timestamp with time zone not null
);
create table public.deleted_messages (
  id uuid not null,
  channel_id uuid not null,
  author_id uuid,
  content text,
  attachment_path text,
  webhook jsonb,
  created_at timestamp with time zone,
  deleted_at timestamp with time zone not null,
  deleted_by uuid
);
create table public.deleted_name_holds (
  name_key text not null,
  old_user_id uuid not null,
  why text not null,
  until timestamp with time zone not null,
  created_at timestamp with time zone not null
);
create table public.discover_rank (
  id uuid not null,
  pos integer not null,
  boosts integer not null,
  lifted boolean not null
);
create table public.discovery_visits (
  day date not null,
  user_id uuid not null
);
create table public.dm_captcha_passes (
  user_id uuid not null,
  until timestamp with time zone not null
);
create table public.dm_open_log (
  id bigint generated always as identity not null,
  user_id uuid not null,
  target uuid not null,
  created_at timestamp with time zone not null
);
create table public.dm_requests (
  from_id uuid not null,
  to_id uuid not null,
  created_at timestamp with time zone not null
);
create table public.email_log (
  id bigint generated always as identity not null,
  kind text not null,
  sent_at timestamp with time zone not null
);
create table public.emoji_checks (
  id uuid not null,
  emoji_id uuid,
  server_id uuid,
  owner_id uuid,
  name text,
  path text not null,
  animated boolean not null,
  emoji_created_at timestamp with time zone,
  verdict text not null,
  rating text,
  confidence real,
  reason text,
  model text,
  cost_usd numeric(10,6) not null,
  backfill boolean not null,
  attempts integer not null,
  checked_at timestamp with time zone not null,
  decision text,
  decided_by uuid,
  decided_at timestamp with time zone
);
create table public.emojis (
  id uuid not null,
  owner_id uuid not null,
  name text not null,
  path text not null,
  animated boolean not null,
  created_at timestamp with time zone not null,
  server_id uuid
);
create table public.evasion_salt (
  one boolean not null,
  salt text not null
);
create table public.feature_flags (
  key text not null,
  label text not null,
  description text not null,
  mode text not null,
  servers uuid[] not null,
  updated_at timestamp with time zone not null,
  updated_by uuid,
  users uuid[] not null
);
create table public.freeze_held_purges (
  user_id uuid not null,
  bucket text not null,
  path text not null,
  queued_at timestamp with time zone
);
create table public.friend_request_declines (
  requester uuid not null,
  addressee uuid not null,
  declined_at timestamp with time zone not null
);
create table public.friendships (
  id uuid not null,
  requester uuid not null,
  addressee uuid not null,
  status text not null,
  created_at timestamp with time zone not null,
  accepted_at timestamp with time zone,
  note text,
  via_server uuid
);
create table public.giveaways (
  id uuid not null,
  server_id uuid not null,
  channel_id uuid not null,
  message_id uuid,
  host_id uuid,
  prize text not null,
  winners integer not null,
  ends_at timestamp with time zone not null,
  ended_at timestamp with time zone,
  winner_ids uuid[] not null,
  plus_months integer
);
create table public.gmail_keys (
  key text not null,
  user_id uuid not null
);
create table public.group_add_log (
  id bigint generated always as identity not null,
  actor uuid not null,
  target uuid not null,
  channel_id uuid not null,
  via text not null,
  created_at timestamp with time zone not null
);
create table public.group_add_optouts (
  user_id uuid not null,
  from_user uuid not null,
  created_at timestamp with time zone not null
);
create table public.image_removal_requests (
  id uuid not null,
  created_at timestamp with time zone not null,
  due_at timestamp with time zone not null,
  reporter_id uuid,
  name text not null,
  email text not null,
  for_whom text not null,
  links text[] not null,
  details text not null,
  signature text not null,
  good_faith boolean not null,
  ip_hash text,
  status text not null,
  staff_note text not null,
  handled_by uuid,
  handled_at timestamp with time zone
);
create table public.image_reviews (
  sha256 text not null,
  user_id uuid,
  rating text not null,
  minor boolean not null,
  confidence real not null,
  reason text not null,
  model text not null,
  at timestamp with time zone not null,
  violence text,
  violence_confidence real,
  gore_only boolean not null
);
create table public.invites (
  code text not null,
  server_id uuid not null,
  created_by uuid not null,
  created_at timestamp with time zone not null,
  uses integer not null,
  vanity boolean not null,
  skip_apply boolean not null
);
create table public.leaderboard_board (
  board text not null,
  user_id uuid not null,
  pos integer not null,
  ord integer not null,
  score bigint not null
);
create table public.leaderboard_exclusions (
  user_id uuid not null,
  note text,
  created_at timestamp with time zone not null
);
create table public.leaderboard_state (
  id boolean not null,
  msgs_upto timestamp with time zone,
  shards_upto bigint,
  backfill_before timestamp with time zone,
  backfill_cursor uuid,
  backfill_done boolean not null,
  refreshed_at timestamp with time zone
);
create table public.leaderboard_stats (
  user_id uuid not null,
  week date not null,
  msgs_week integer not null,
  voice_week integer not null,
  shards_week integer not null,
  msgs_all bigint not null,
  gifts integer not null,
  invites integer not null
);
create table public.leaderboard_voice_open (
  user_id uuid not null,
  sid text not null,
  joined_at timestamp with time zone not null,
  since timestamp with time zone not null,
  closed boolean not null
);
create table public.level_board (
  user_id uuid not null,
  pos integer not null,
  ord integer not null,
  level smallint not null
);
create table public.level_counts (
  level smallint not null,
  n integer not null
);
create table public.link_hosts (
  domain text not null,
  kind text not null,
  added_at timestamp with time zone not null
);
create table public.link_previews (
  url text not null,
  data jsonb,
  fetched_at timestamp with time zone not null
);
create table public.lobby_board_cache (
  server_id uuid not null,
  kind text not null,
  rows jsonb not null,
  at timestamp with time zone not null,
  rolled_to timestamp with time zone
);
create table public.lobby_feed_posts (
  id uuid not null,
  feed_id uuid not null,
  server_id uuid not null,
  title text,
  body text,
  url text,
  image text,
  created_at timestamp with time zone not null
);
create table public.lobby_feeds (
  id uuid not null,
  server_id uuid not null,
  name text not null,
  token_hash text not null,
  created_by uuid,
  created_at timestamp with time zone not null,
  last_post_at timestamp with time zone,
  posts bigint not null
);
create table public.lobby_msg_days (
  server_id uuid not null,
  user_id uuid not null,
  day date not null,
  n integer not null
);
create table public.login_attempts (
  id bigint generated always as identity not null,
  ip text not null,
  username text not null,
  ok boolean not null,
  at timestamp with time zone not null
);
create table public.match_cache (
  user_id uuid not null,
  computed_at timestamp with time zone not null,
  results jsonb not null
);
create table public.match_settings (
  user_id uuid not null,
  suggest_me boolean not null,
  updated_at timestamp with time zone not null
);
create table public.media_interests (
  user_id uuid not null,
  source text not null,
  kind text not null,
  item_id text not null,
  title text not null,
  weight real not null
);
create table public.media_links (
  user_id uuid not null,
  source text not null,
  account_id text not null,
  account_name text not null,
  handle text not null,
  avatar_url text,
  profile_url text,
  is_public boolean not null,
  data jsonb not null,
  prefs jsonb not null,
  refreshed_at timestamp with time zone,
  next_refresh_at timestamp with time zone not null,
  linked_at timestamp with time zone not null,
  verified boolean
);
create table public.media_migrate_runs (
  token text not null,
  started_by uuid,
  created_at timestamp with time zone not null,
  last_at timestamp with time zone not null,
  hops integer not null,
  stopped boolean not null
);
create table public.media_migrated (
  bucket text not null,
  path text not null,
  bytes bigint,
  done_at timestamp with time zone not null
);
create table public.media_purge (
  bucket text not null,
  path text not null,
  queued_at timestamp with time zone,
  done_at timestamp with time zone,
  error text
);
create table public.media_refresh_log (
  user_id uuid not null,
  source text not null,
  at timestamp with time zone not null
);
create table public.media_scans (
  bucket text not null,
  path text not null,
  user_id uuid,
  score real not null,
  verdict text not null,
  scanned_at timestamp with time zone not null,
  forgiven boolean not null,
  phash bigint,
  details jsonb,
  animated boolean,
  for_server uuid,
  etag text
);
create table public.member_roles (
  server_id uuid not null,
  user_id uuid not null,
  role_id uuid not null,
  manual boolean not null,
  by_person boolean not null
);
create table public.messages (
  id uuid not null,
  channel_id uuid not null,
  author_id uuid not null,
  content text not null,
  created_at timestamp with time zone not null,
  edited_at timestamp with time zone,
  attachment_path text,
  attachment_width integer,
  attachment_height integer,
  reply_to_id uuid,
  pinned_at timestamp with time zone,
  pinned_by uuid,
  attachment_name text,
  attachment_size bigint,
  embeds jsonb,
  suppress_embeds boolean not null,
  voice_secs real,
  voice_wave text,
  components jsonb,
  webhook jsonb,
  system jsonb
);
create table public.mfa_backup_codes (
  id uuid not null,
  user_id uuid not null,
  code_hash text not null,
  created_at timestamp with time zone not null,
  used_at timestamp with time zone,
  revoked_at timestamp with time zone
);
create table public.mfa_recovery_requests (
  id uuid not null,
  user_id uuid not null,
  confirm_hash text not null,
  cancel_hash text not null,
  status text not null,
  created_at timestamp with time zone not null,
  ready_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  closed_at timestamp with time zone
);
create table public.mod_assignments (
  user_id uuid not null,
  head_id uuid not null,
  assigned_by uuid,
  created_at timestamp with time zone not null
);
create table public.mod_burst_alerts (
  id uuid not null,
  actor uuid not null,
  kind text not null,
  action_count integer not null,
  window_start timestamp with time zone not null,
  window_end timestamp with time zone not null,
  actions text[] not null,
  log_ids uuid[] not null,
  created_at timestamp with time zone not null,
  dismissed_at timestamp with time zone,
  dismissed_by uuid,
  note text not null
);
create table public.mod_burst_rules (
  kind text not null,
  actions text[] not null,
  threshold integer not null,
  window_minutes integer not null,
  enabled boolean not null
);
create table public.mod_case_claims (
  case_key text not null,
  user_id uuid not null,
  claimed_at timestamp with time zone not null
);
create table public.mod_log (
  id uuid not null,
  actor uuid,
  action text not null,
  target_id uuid,
  message_id uuid,
  reason text not null,
  created_at timestamp with time zone not null
);
create table public.mod_notes (
  id uuid not null,
  user_id uuid not null,
  author uuid,
  body text not null,
  created_at timestamp with time zone not null
);
create table public.notify_settings (
  user_id uuid not null,
  server_id uuid not null,
  channel_id uuid,
  level text,
  muted_until timestamp with time zone,
  last_push_at timestamp with time zone,
  updated_at timestamp with time zone not null
);
create table public.nsfw_allowed_hashes (
  id bigint generated always as identity not null,
  sha256 text not null,
  appeal_id uuid,
  added_by uuid,
  added_at timestamp with time zone not null,
  bucket text not null,
  score real not null
);
create table public.nsfw_hashes (
  phash bigint not null,
  source text not null,
  bucket text,
  path text,
  report_id uuid,
  added_by uuid,
  added_at timestamp with time zone not null
);
create table public.oauth_apps (
  id uuid not null,
  owner_id uuid not null,
  name text not null,
  description text not null,
  icon_path text,
  redirect_uris text[] not null,
  secret_hash text not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null,
  disabled_at timestamp with time zone
);
create table public.oauth_codes (
  code_hash text not null,
  app_id uuid not null,
  user_id uuid not null,
  redirect_uri text not null,
  scope text[] not null,
  code_challenge text,
  created_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  used_at timestamp with time zone
);
create table public.oauth_revocations (
  user_id uuid not null,
  app_id uuid not null,
  revoked_at timestamp with time zone not null
);
create table public.oauth_tokens (
  token_hash text not null,
  app_id uuid not null,
  user_id uuid not null,
  scope text[] not null,
  code_hash text,
  created_at timestamp with time zone not null,
  last_used_at timestamp with time zone,
  expires_at timestamp with time zone not null,
  revoked_at timestamp with time zone
);
create table public.onboarding_answers (
  id uuid not null,
  question_id uuid not null,
  server_id uuid not null,
  label text not null,
  emoji text,
  role_ids uuid[] not null,
  position integer not null
);
create table public.onboarding_choices (
  server_id uuid not null,
  user_id uuid not null,
  answer_ids uuid[] not null,
  role_ids uuid[] not null,
  done_at timestamp with time zone not null
);
create table public.onboarding_questions (
  id uuid not null,
  server_id uuid not null,
  title text not null,
  multi boolean not null,
  position integer not null
);
create table public.online_time (
  user_id uuid not null,
  day date not null,
  secs integer not null
);
create table public.partner_applications (
  id uuid not null,
  server_id uuid not null,
  owner_id uuid not null,
  about text not null,
  links text[] not null,
  checks jsonb,
  status text not null,
  staff_note text,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  gave_badge boolean not null,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null
);
create table public.partner_watch (
  server_id uuid not null,
  below_since timestamp with time zone,
  failing text[] not null,
  flagged_at timestamp with time zone,
  checked_at timestamp with time zone not null
);
create table public.passkey_challenges (
  id uuid not null,
  kind text not null,
  user_id uuid,
  rp_id text not null,
  challenge text not null,
  created_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  used_at timestamp with time zone
);
create table public.pending_bot_emails (
  email text not null,
  created_at timestamp with time zone not null
);
create table public.pending_signups (
  email text not null,
  created_at timestamp with time zone not null
);
create table public.pending_verifications (
  user_id uuid not null,
  token text not null,
  email text not null,
  reason text not null,
  enforced boolean not null,
  created_at timestamp with time zone not null,
  sent_at timestamp with time zone,
  verified_at timestamp with time zone
);
create table public.people_search_quota (
  user_id uuid not null,
  minute_start timestamp with time zone not null,
  minute_n integer not null,
  hour_start timestamp with time zone not null,
  hour_n integer not null
);
create table public.ping_roles (
  role_id uuid not null,
  server_id uuid not null,
  emoji text,
  blurb text,
  position integer not null
);
create table public.plus_events (
  id text not null,
  user_id uuid,
  kind text not null,
  created_at timestamp with time zone not null,
  amount integer,
  currency text,
  ref text,
  email text,
  note text,
  state text not null,
  claimed_at timestamp with time zone,
  attempts integer not null,
  business_id text,
  done_at timestamp with time zone
);
create table public.plus_gifts (
  id uuid not null,
  gifter_id uuid,
  recipient_id uuid not null,
  months integer not null,
  source text not null,
  giveaway_id uuid,
  stripe_event text,
  created_at timestamp with time zone not null,
  seen_at timestamp with time zone,
  payment_intent text,
  refunded_at timestamp with time zone
);
create table public.poll_answers (
  poll_id uuid not null,
  correct text[] not null
);
create table public.poll_ballots (
  poll_id uuid not null,
  user_id uuid not null,
  option_ids text[] not null,
  created_at timestamp with time zone not null
);
create table public.poll_votes (
  poll_id uuid not null,
  user_id uuid not null,
  option_id text not null,
  created_at timestamp with time zone not null
);
create table public.polls (
  id uuid not null,
  message_id uuid not null,
  channel_id uuid not null,
  question text not null,
  options jsonb not null,
  multi boolean not null,
  closes_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone not null,
  quiz boolean not null,
  reveal text not null,
  anonymous boolean not null
);
create table public.post_marks (
  channel_id uuid not null,
  author_id uuid not null,
  kind text not null,
  at timestamp with time zone not null,
  album_n integer not null
);
create table public.presence (
  user_id uuid not null,
  status text not null,
  last_seen timestamp with time zone not null,
  online_since timestamp with time zone not null,
  status_at timestamp with time zone not null,
  activity jsonb,
  activity_at timestamp with time zone,
  pref text
);
create table public.profiles (
  id uuid not null,
  username text not null,
  created_at timestamp with time zone not null,
  bio text not null,
  avatar_path text,
  banner_path text,
  banner_x real not null,
  banner_y real not null,
  avatar_x real not null,
  avatar_y real not null,
  avatar_zoom real not null,
  avatar_rot smallint not null,
  banner_zoom real not null,
  muted_until timestamp with time zone,
  muted_reason text,
  voice_muted_until timestamp with time zone,
  links jsonb not null,
  verified_as text,
  display_name text,
  pronouns text,
  accent_color text,
  accent_color2 text,
  plus_until timestamp with time zone,
  plus_badge_hidden boolean not null,
  stripe_customer text,
  dms_from text not null,
  verified_hidden boolean not null,
  badges text[] not null,
  server_tag uuid,
  tag text,
  server_order uuid[],
  shown_badge text,
  verify_required boolean not null,
  profile_effect text,
  custom_status text,
  avatar_deco text,
  discriminator text,
  avatar_revert_at timestamp with time zone,
  avatar_prev jsonb,
  name_style jsonb,
  account_level smallint not null,
  group_adds text not null,
  plus_since timestamp with time zone,
  gifts_given integer not null,
  leaderboard_hidden boolean not null,
  name_banner text
);
create table public.promo_invite_marks (
  server_id uuid not null,
  at timestamp with time zone not null
);
create table public.push_tokens (
  token text not null,
  user_id uuid not null,
  platform text not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);
create table public.raid_alerts (
  id uuid not null,
  kind text not null,
  server_id uuid,
  key text,
  user_ids uuid[] not null,
  staff boolean not null,
  created_at timestamp with time zone not null,
  until timestamp with time zone,
  resolved_at timestamp with time zone,
  resolved_by uuid,
  banned integer not null
);
create table public.raid_hits (
  server_id uuid not null,
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.reaction_roles (
  message_id uuid not null,
  emoji text not null,
  role_id uuid not null,
  server_id uuid not null
);
create table public.reactions (
  id uuid not null,
  message_id uuid not null,
  user_id uuid not null,
  emoji text not null,
  created_at timestamp with time zone not null
);
create table public.reauth_attempts (
  id bigint generated always as identity not null,
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.referrals (
  invitee uuid not null,
  inviter uuid not null,
  invite_code text,
  status text not null,
  reason text not null,
  created_at timestamp with time zone not null,
  paid_at timestamp with time zone
);
create table public.rename_leftovers (
  email_hash text not null,
  at timestamp with time zone not null
);
create table public.reports (
  id uuid not null,
  reporter_id uuid,
  target_id uuid,
  message_id uuid,
  channel_id uuid,
  message_content text,
  message_attachment text,
  reason text not null,
  details text not null,
  status text not null,
  resolved_by uuid,
  resolved_at timestamp with time zone,
  created_at timestamp with time zone not null,
  evidence jsonb not null,
  triage text,
  triage_note text,
  server_id uuid,
  webhook_id uuid,
  message_deleted_at timestamp with time zone,
  message_deleted_by text,
  voice_clip_path text,
  claimed_by uuid,
  claimed_at timestamp with time zone,
  reported_server_id uuid,
  reported_server_name text
);
create table public.request_throttle (
  user_id uuid not null,
  until timestamp with time zone not null,
  enforced boolean not null,
  requests integer not null,
  top_path text not null,
  user_agent text not null,
  hits integer not null,
  first_seen timestamp with time zone not null,
  last_seen timestamp with time zone not null,
  cleared_at timestamp with time zone
);
create table public.roles (
  id uuid not null,
  server_id uuid not null,
  name text not null,
  color text,
  position integer not null,
  manage_server boolean not null,
  manage_messages boolean not null,
  created_at timestamp with time zone not null,
  perms jsonb not null,
  auto text not null,
  auto_before timestamp with time zone,
  color2 text,
  mentionable boolean not null
);
create table public.security_log (
  id bigint generated always as identity not null,
  user_id uuid,
  actor uuid,
  event text not null,
  ip text,
  detail jsonb not null,
  created_at timestamp with time zone not null
);
create table public.server_audit_log (
  id bigint generated always as identity not null,
  server_id uuid not null,
  actor_id uuid,
  action text not null,
  target_kind text,
  target_id uuid,
  target_name text,
  extra jsonb not null,
  created_at timestamp with time zone not null
);
create table public.server_bans (
  server_id uuid not null,
  user_id uuid not null,
  banned_by uuid,
  created_at timestamp with time zone not null
);
create table public.server_bots (
  server_id uuid not null,
  bot text not null,
  enabled boolean not null,
  config jsonb not null
);
create table public.server_first_joins (
  server_id uuid not null,
  user_id uuid not null,
  first_joined_at timestamp with time zone not null,
  last_joined_at timestamp with time zone
);
create table public.server_hides (
  server_id uuid not null,
  hidden_by uuid,
  prev_discoverable boolean,
  reason text,
  created_at timestamp with time zone not null
);
create table public.server_join_requests (
  id uuid not null,
  server_id uuid not null,
  user_id uuid not null,
  invite_code text,
  message text not null,
  answers text[] not null,
  status text not null,
  note text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null
);
create table public.server_lobby (
  server_id uuid not null,
  about text not null,
  faq jsonb not null,
  featured uuid[] not null,
  show_staff boolean not null,
  updated_at timestamp with time zone not null,
  style jsonb not null,
  sections jsonb not null
);
create table public.server_members (
  server_id uuid not null,
  user_id uuid not null,
  joined_at timestamp with time zone not null,
  nickname text
);
create table public.server_mutes (
  user_id uuid not null,
  server_id uuid not null,
  created_at timestamp with time zone not null
);
create table public.server_onboarding (
  server_id uuid not null,
  enabled boolean not null,
  required boolean not null,
  enabled_at timestamp with time zone,
  default_channel_id uuid,
  updated_at timestamp with time zone not null
);
create table public.server_plus (
  server_id uuid not null,
  until timestamp with time zone not null,
  stripe_customer text,
  granted_by uuid,
  updated_at timestamp with time zone not null,
  payer_id uuid,
  stripe_sub text
);
create table public.server_promotions (
  id uuid not null,
  server_id uuid not null,
  starts_at timestamp with time zone not null,
  ends_at timestamp with time zone not null,
  source text not null,
  stripe_event text,
  created_by uuid,
  views integer not null,
  clicks integer not null,
  joins integer not null,
  created_at timestamp with time zone not null,
  kind text not null,
  mult integer not null,
  stripe_sub text
);
create table public.server_templates (
  code text not null,
  server_id uuid,
  created_by uuid,
  name text not null,
  data jsonb not null,
  uses integer not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone not null
);
create table public.server_timeouts (
  server_id uuid not null,
  user_id uuid not null,
  until timestamp with time zone not null,
  reason text not null,
  set_by uuid,
  created_at timestamp with time zone not null
);
create table public.server_voice_bans (
  server_id uuid not null,
  user_id uuid not null,
  until timestamp with time zone,
  reason text not null,
  by uuid,
  created_at timestamp with time zone not null
);
create table public.server_voice_mutes (
  server_id uuid not null,
  user_id uuid not null,
  until timestamp with time zone not null,
  by uuid,
  created_at timestamp with time zone not null
);
create table public.server_watch (
  server_id uuid not null,
  score integer not null,
  reasons jsonb not null,
  text_score integer not null,
  text_reasons jsonb not null,
  text_checked_at timestamp with time zone,
  reports integer not null,
  blocked_images integer not null,
  joins_24h integer not null,
  first_seen timestamp with time zone,
  last_seen timestamp with time zone,
  status text not null,
  cleared_score integer,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  updated_at timestamp with time zone not null
);
create table public.server_watch_hits (
  server_id uuid not null,
  ref text not null,
  src text not null,
  kind text not null,
  term text,
  weight integer not null,
  place text,
  sample text,
  channel_id uuid,
  at timestamp with time zone not null
);
create table public.server_watch_state (
  id boolean not null,
  last_run timestamp with time zone,
  run_no bigint not null,
  terms_changed boolean not null,
  last_ms integer,
  last_stats jsonb
);
create table public.server_watch_terms (
  id uuid not null,
  term text not null,
  kind text not null,
  weight integer not null,
  added_by uuid,
  created_at timestamp with time zone not null
);
create table public.server_xp (
  server_id uuid not null,
  user_id uuid not null,
  xp integer not null,
  level integer not null,
  last_at timestamp with time zone
);
create table public.servers (
  id uuid not null,
  name text not null,
  icon_path text,
  owner_id uuid not null,
  created_at timestamp with time zone not null,
  links jsonb not null,
  banner_path text,
  discoverable boolean not null,
  description text not null,
  tags text[] not null,
  banner_x numeric not null,
  banner_y numeric not null,
  banner_zoom numeric not null,
  everyone_perms jsonb not null,
  tag text,
  tickets_on boolean not null,
  ticket_seq integer not null,
  locked_until timestamp with time zone,
  lock_reason text,
  staff_warning text,
  staff_warned_at timestamp with time zone,
  shut_down_at timestamp with time zone,
  shut_down_reason text,
  member_count integer not null,
  name_ok boolean not null,
  takedown_prev_discoverable boolean,
  takedown_by uuid,
  theme jsonb,
  rules_channel_id uuid,
  new_account_minutes integer,
  new_account_mode text not null,
  staff_hidden_at timestamp with time zone,
  verification_level smallint not null,
  raid_until timestamp with time zone,
  raid_reset_at timestamp with time zone,
  join_apply boolean not null,
  join_questions text[] not null,
  lobby_on boolean not null,
  partner_since timestamp with time zone
);
create table public.shard_days (
  user_id uuid not null,
  day date not null,
  minutes integer not null,
  paid integer not null
);
create table public.shard_ledger (
  id bigint generated always as identity not null,
  user_id uuid not null,
  amount integer not null,
  kind text not null,
  ref text,
  note text not null,
  actor uuid,
  balance_after integer not null,
  created_at timestamp with time zone not null
);
create table public.shard_wallets (
  user_id uuid not null,
  balance integer not null,
  earned_total integer not null,
  spent_total integer not null,
  streak integer not null,
  last_day date,
  frozen boolean not null,
  last_tick timestamp with time zone,
  updated_at timestamp with time zone not null
);
create table public.signup_domain_caps (
  domain text not null,
  logged_at timestamp with time zone not null,
  refused integer not null
);
create table public.signup_domain_hits (
  id bigint generated always as identity not null,
  domain text not null,
  at timestamp with time zone not null
);
create table public.signup_domain_ok (
  domain text not null,
  note text not null,
  added_at timestamp with time zone not null
);
create table public.signup_domain_seen (
  domain text not null,
  first_seen timestamp with time zone not null,
  confirmed integer not null
);
create table public.signup_log (
  id bigint generated always as identity not null,
  ip text not null,
  created_at timestamp with time zone not null,
  user_id uuid
);
create table public.site_admins (
  user_id uuid not null
);
create table public.site_area_managers (
  user_id uuid not null,
  area text not null,
  added_by uuid,
  created_at timestamp with time zone not null
);
create table public.site_bans (
  user_id uuid not null,
  reason text not null,
  banned_by uuid,
  created_at timestamp with time zone not null,
  expires_at timestamp with time zone,
  proof jsonb,
  reviewed_at timestamp with time zone,
  reviewed_by uuid
);
create table public.site_community_managers (
  user_id uuid not null,
  added_by uuid,
  created_at timestamp with time zone not null
);
create table public.site_developers (
  user_id uuid not null,
  added_by uuid,
  created_at timestamp with time zone not null
);
create table public.site_managers (
  user_id uuid not null,
  added_by uuid,
  created_at timestamp with time zone not null
);
create table public.site_moderators (
  user_id uuid not null,
  added_by uuid,
  created_at timestamp with time zone not null,
  suspended_at timestamp with time zone,
  suspended_reason text,
  head boolean not null
);
create table public.sounds (
  id uuid not null,
  server_id uuid not null,
  owner_id uuid not null,
  name text not null,
  emoji text not null,
  path text not null,
  volume numeric not null,
  created_at timestamp with time zone not null
);
create table public.staff_applications (
  id uuid not null,
  user_id uuid not null,
  why text not null,
  hours text not null,
  experience text not null,
  status text not null,
  note text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null,
  adult boolean not null,
  answers jsonb not null
);
create table public.staff_audit_log (
  id bigint generated always as identity not null,
  server_id uuid,
  actor_id uuid,
  action text not null,
  target_kind text,
  target_id uuid,
  target_name text,
  extra jsonb not null,
  created_at timestamp with time zone not null
);
create table public.staff_reauth (
  user_id uuid not null,
  ok_at timestamp with time zone,
  fails integer not null,
  fail_at timestamp with time zone
);
create table public.staff_vote_ballots (
  vote_id uuid not null,
  voter uuid not null,
  created_at timestamp with time zone not null
);
create table public.staff_votes (
  id uuid not null,
  target uuid not null,
  opened_by uuid,
  reason text not null,
  created_at timestamp with time zone not null,
  closed_at timestamp with time zone,
  outcome text
);
create table public.starboard_posts (
  message_id uuid not null,
  server_id uuid not null,
  post_id uuid,
  created_at timestamp with time zone not null
);
create table public.steam_links (
  user_id uuid not null,
  steam_id text not null,
  persona text not null,
  avatar_url text,
  profile_url text,
  games_public boolean not null,
  game_count integer,
  games jsonb not null,
  achievements jsonb not null,
  refreshed_at timestamp with time zone,
  linked_at timestamp with time zone not null,
  prefs jsonb not null
);
create table public.steam_refresh_log (
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.storage_paths_used (
  bucket text not null,
  path text not null,
  at timestamp with time zone not null
);
create table public.stripe_cancel_jobs (
  sub text not null,
  reason text not null,
  attempts integer not null,
  last_error text,
  next_at timestamp with time zone not null,
  created_at timestamp with time zone not null,
  done_at timestamp with time zone
);
create table public.suggestions (
  id uuid not null,
  user_id uuid not null,
  server_id uuid,
  channel_id uuid,
  message_id uuid,
  title text not null,
  area text not null,
  body text not null,
  status text not null,
  staff_note text not null,
  created_at timestamp with time zone not null,
  updated_at timestamp with time zone
);
create table public.supercharges (
  id uuid not null,
  user_id uuid not null,
  server_id uuid,
  source text not null,
  until timestamp with time zone,
  stripe_sub text,
  stripe_customer text,
  applied_at timestamp with time zone,
  last_server_id uuid,
  granted_by uuid,
  created_at timestamp with time zone not null
);
create table public.thread_follows (
  user_id uuid not null,
  thread_id uuid not null,
  created_at timestamp with time zone not null
);
create table public.translate_usage (
  user_id uuid not null,
  bucket text not null,
  n integer not null,
  at timestamp with time zone not null
);
create table public.upload_appeals (
  id uuid not null,
  user_id uuid not null,
  bucket text not null,
  path text not null,
  quarantine_key text,
  phash bigint,
  sha256 text,
  score real,
  details jsonb,
  note text,
  status text not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null,
  allowed boolean not null
);
create table public.upload_quarantine (
  bucket text not null,
  path text not null,
  user_id uuid,
  key text not null,
  content_type text,
  sha256 text,
  created_at timestamp with time zone not null,
  removed_at timestamp with time zone
);
create table public.user_devices (
  user_id uuid not null,
  kind text not null,
  h text not null,
  first_seen timestamp with time zone not null,
  last_seen timestamp with time zone not null
);
create table public.user_dm_pins (
  user_id uuid not null,
  pins uuid[] not null,
  updated_at timestamp with time zone not null
);
create table public.user_notes (
  owner_id uuid not null,
  about_id uuid not null,
  note text not null,
  updated_at timestamp with time zone not null
);
create table public.user_passkeys (
  id uuid not null,
  user_id uuid not null,
  credential_id text not null,
  public_key text not null,
  counter bigint not null,
  transports text[] not null,
  rp_id text not null,
  device_type text not null,
  backed_up boolean not null,
  aaguid text not null,
  name text not null,
  created_at timestamp with time zone not null,
  last_used_at timestamp with time zone
);
create table public.user_prefs (
  user_id uuid not null,
  prefs jsonb not null,
  updated_at timestamp with time zone not null
);
create table public.user_server_folders (
  user_id uuid not null,
  folders jsonb not null,
  updated_at timestamp with time zone not null
);
create table public.user_warnings (
  id uuid not null,
  user_id uuid not null,
  by uuid,
  reason text not null,
  created_at timestamp with time zone not null,
  seen_at timestamp with time zone,
  removed_at timestamp with time zone,
  removed_by uuid,
  server_id uuid,
  proof jsonb
);
create table public.username_changes (
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.username_holds (
  name_key text not null,
  user_id uuid not null,
  until timestamp with time zone not null
);
create table public.vanity_changes (
  id bigint generated always as identity not null,
  server_id uuid not null,
  user_id uuid not null,
  at timestamp with time zone not null
);
create table public.verification_requests (
  id uuid not null,
  user_id uuid not null,
  platform text not null,
  handle text not null,
  link text not null,
  note text not null,
  proof_path text,
  status text not null,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  review_note text not null,
  created_at timestamp with time zone not null,
  proof_added_at timestamp with time zone,
  asked_at timestamp with time zone
);
create table public.voice_activity (
  id bigint generated always as identity not null,
  server_id uuid not null,
  channel_id uuid not null,
  user_id uuid not null,
  kind text not null,
  from_channel uuid,
  at timestamp with time zone not null,
  duration integer,
  lk_sid text
);
create table public.webhook_rate (
  k text not null,
  bucket bigint not null,
  n integer not null,
  at timestamp with time zone not null
);
create table public.webhooks (
  id uuid not null,
  server_id uuid not null,
  channel_id uuid not null,
  name text not null,
  avatar_path text,
  token_hash text not null,
  created_by uuid,
  created_at timestamp with time zone not null,
  last_used_at timestamp with time zone,
  posts bigint not null
);
create table public.withdrawals (
  id uuid not null,
  user_id uuid not null,
  stripe_sub text not null,
  label text,
  paid_cents integer,
  refund_cents integer,
  currency text,
  stripe_refund text,
  status text not null,
  error text,
  note text,
  created_at timestamp with time zone not null,
  handled_by uuid,
  handled_at timestamp with time zone
);
create table public.wordle_games (
  user_id uuid not null,
  day date not null,
  server_id uuid not null,
  channel_id uuid,
  guesses text[] not null,
  won boolean not null,
  finished_at timestamp with time zone,
  created_at timestamp with time zone not null
);
create table public.wordle_words (
  word text not null,
  answer boolean not null
);
create table public.yt_feeds (
  channel_id text not null,
  name text,
  latest jsonb,
  seen_ids text[] not null,
  baseline boolean not null,
  last_published timestamp with time zone,
  last_checked_at timestamp with time zone,
  next_check_at timestamp with time zone not null,
  fails integer not null,
  last_error text,
  pending_req bigint,
  requested_at timestamp with time zone,
  created_at timestamp with time zone not null
);
