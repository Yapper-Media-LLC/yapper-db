# Every table

RLS on or off, whether it is forced for the owner too, how many policies, and which API roles hold any table grant (what the policies then narrow down).

| table | RLS | forced | policies | granted to |
|---|---|---|---|---|
| api_host.reports | on | no | 0 |  |
| api_host.secrets | on | no | 1 |  |
| app_host.secrets | on | no | 0 |  |
| public.account_freezes | on | no | 0 |  |
| public.account_suspensions | on | no | 1 | anon, authenticated |
| public.alert_watches | on | no | 0 |  |
| public.alerts_rate | on | no | 0 |  |
| public.app_settings | on | no | 0 | anon, authenticated |
| public.ban_appeals | on | no | 0 |  |
| public.ban_leftovers | on | no | 0 |  |
| public.billing_customers | on | no | 0 | anon, authenticated |
| public.billing_fulfilments | on | no | 0 |  |
| public.blocked_domains | on | no | 3 | anon, authenticated |
| public.blocked_email_domains | on | no | 1 | anon, authenticated |
| public.blocks | on | no | 1 | anon, authenticated |
| public.bot_accounts | on | no | 1 | anon, authenticated |
| public.bot_afk | on | no | 0 | anon, authenticated |
| public.bot_commands | on | no | 1 | anon, authenticated |
| public.bot_events | on | no | 0 | anon, authenticated |
| public.bot_hosting | on | no | 1 |  |
| public.bot_hosting_actions | on | no | 0 |  |
| public.bot_interaction_replies | on | no | 1 | authenticated |
| public.bot_interactions | on | no | 0 |  |
| public.bot_promotions | on | no | 1 |  |
| public.bot_servers | on | no | 1 | anon, authenticated |
| public.bot_signals | on | no | 0 | anon, authenticated |
| public.bot_voice_rate | on | no | 0 |  |
| public.bots | on | no | 1 |  |
| public.bug_reports | on | no | 3 | anon, authenticated |
| public.calls | on | no | 1 | anon, authenticated |
| public.cancel_requests | on | no | 0 |  |
| public.channel_categories | on | no | 2 | anon, authenticated |
| public.channel_members | on | no | 2 | anon, authenticated |
| public.channel_overrides | on | no | 4 | authenticated |
| public.channel_post_roles | on | no | 1 | anon, authenticated |
| public.channel_reads | on | no | 4 | anon, authenticated |
| public.channel_roles | on | no | 1 | anon, authenticated |
| public.channels | on | no | 3 | anon, authenticated |
| public.checkout_consents | on | no | 0 |  |
| public.community_deco_checks | on | no | 0 |  |
| public.community_decos | on | no | 1 |  |
| public.copyright_strikes | on | no | 0 |  |
| public.creator_applications | on | no | 1 | authenticated |
| public.creator_content | on | no | 1 | authenticated |
| public.creator_link_hits | on | no | 0 |  |
| public.creator_links | on | no | 0 |  |
| public.creator_referrals | on | no | 0 |  |
| public.csam_cases | on | no | 0 |  |
| public.data_exports | on | no | 0 |  |
| public.deco_backup_389 | on | no | 0 |  |
| public.deco_owned | on | no | 1 | authenticated |
| public.deleted_messages | on | no | 0 |  |
| public.deleted_name_holds | on | no | 0 |  |
| public.discover_rank | on | no | 0 |  |
| public.discovery_visits | on | no | 0 | anon, authenticated |
| public.dm_captcha_passes | on | no | 0 |  |
| public.dm_open_log | on | no | 0 |  |
| public.dm_requests | on | no | 2 | anon, authenticated |
| public.email_log | on | no | 0 | anon, authenticated |
| public.emojis | on | no | 4 | anon, authenticated |
| public.evasion_salt | on | no | 0 |  |
| public.feature_flags | on | no | 2 | anon, authenticated |
| public.freeze_held_purges | on | no | 0 |  |
| public.friend_request_declines | on | no | 0 |  |
| public.friendships | on | no | 1 | anon, authenticated |
| public.giveaways | on | no | 0 | anon, authenticated |
| public.gmail_keys | on | no | 0 |  |
| public.group_add_log | on | no | 0 |  |
| public.group_add_optouts | on | no | 1 | authenticated |
| public.image_removal_requests | on | no | 0 |  |
| public.image_reviews | on | no | 0 |  |
| public.invites | on | no | 3 | anon, authenticated |
| public.link_hosts | on | no | 3 | anon, authenticated |
| public.link_previews | on | no | 0 | anon, authenticated |
| public.login_attempts | on | no | 0 | anon, authenticated |
| public.match_cache | on | no | 0 |  |
| public.match_settings | on | no | 1 | authenticated |
| public.media_interests | on | no | 0 |  |
| public.media_links | on | no | 3 | authenticated |
| public.media_migrate_runs | on | no | 0 |  |
| public.media_migrated | on | no | 0 | anon, authenticated |
| public.media_purge | on | no | 0 | anon, authenticated |
| public.media_refresh_log | on | no | 0 |  |
| public.media_scans | on | no | 1 | anon, authenticated |
| public.member_roles | on | no | 3 | anon, authenticated |
| public.messages | on | no | 6 | anon, authenticated |
| public.mod_burst_alerts | on | no | 1 | authenticated |
| public.mod_burst_rules | on | no | 1 | authenticated |
| public.mod_case_claims | on | no | 0 |  |
| public.mod_log | on | no | 1 | anon, authenticated |
| public.mod_notes | on | no | 3 | anon, authenticated |
| public.nsfw_allowed_hashes | on | no | 0 |  |
| public.nsfw_hashes | on | no | 0 |  |
| public.oauth_apps | on | no | 0 |  |
| public.oauth_codes | on | no | 0 |  |
| public.oauth_revocations | on | no | 0 |  |
| public.oauth_tokens | on | no | 0 |  |
| public.onboarding_answers | on | no | 0 |  |
| public.onboarding_choices | on | no | 0 |  |
| public.onboarding_questions | on | no | 0 |  |
| public.online_time | on | no | 1 | anon, authenticated |
| public.pending_bot_emails | on | no | 0 |  |
| public.pending_signups | on | no | 0 |  |
| public.pending_verifications | on | no | 0 |  |
| public.people_search_quota | on | no | 0 |  |
| public.plus_events | on | no | 0 |  |
| public.plus_gifts | on | no | 1 | authenticated |
| public.poll_ballots | on | no | 1 | authenticated |
| public.poll_votes | on | no | 1 | anon, authenticated |
| public.polls | on | no | 1 | anon, authenticated |
| public.post_marks | on | no | 0 | anon, authenticated |
| public.presence | on | no | 0 | anon, authenticated |
| public.profiles | on | no | 2 | anon, authenticated |
| public.promo_invite_marks | on | no | 0 |  |
| public.push_tokens | on | no | 4 | authenticated |
| public.raid_alerts | on | no | 1 | authenticated |
| public.raid_hits | on | no | 0 |  |
| public.reaction_roles | on | no | 1 | anon, authenticated |
| public.reactions | on | no | 3 | anon, authenticated |
| public.reauth_attempts | on | no | 0 |  |
| public.referrals | on | no | 0 |  |
| public.rename_leftovers | on | no | 0 |  |
| public.reports | on | no | 3 | anon, authenticated |
| public.request_throttle | on | no | 0 |  |
| public.roles | on | no | 4 | anon, authenticated |
| public.server_audit_log | on | no | 0 |  |
| public.server_bans | on | no | 1 | anon, authenticated |
| public.server_bots | on | no | 1 | anon, authenticated |
| public.server_first_joins | on | no | 0 | anon, authenticated |
| public.server_hides | on | no | 1 | authenticated |
| public.server_join_requests | on | no | 0 |  |
| public.server_lobby | on | no | 1 | authenticated |
| public.server_members | on | no | 1 | anon, authenticated |
| public.server_mutes | on | no | 3 | anon, authenticated |
| public.server_onboarding | on | no | 0 |  |
| public.server_plus | on | no | 1 | anon, authenticated |
| public.server_promotions | on | no | 1 | anon, authenticated |
| public.server_templates | on | no | 1 | anon, authenticated |
| public.server_timeouts | on | no | 1 | anon, authenticated |
| public.server_voice_bans | on | no | 1 | authenticated |
| public.server_voice_mutes | on | no | 1 | authenticated |
| public.server_watch | on | no | 1 | authenticated |
| public.server_watch_hits | on | no | 1 | authenticated |
| public.server_watch_state | on | no | 1 | authenticated |
| public.server_watch_terms | on | no | 4 | authenticated |
| public.server_xp | on | no | 1 | anon, authenticated |
| public.servers | on | no | 1 | anon, authenticated |
| public.shard_days | on | no | 0 |  |
| public.shard_ledger | on | no | 1 | authenticated |
| public.shard_wallets | on | no | 1 | authenticated |
| public.signup_domain_caps | on | no | 0 |  |
| public.signup_domain_hits | on | no | 0 |  |
| public.signup_domain_ok | on | no | 0 |  |
| public.signup_domain_seen | on | no | 0 |  |
| public.signup_log | on | no | 0 | anon, authenticated |
| public.site_admins | on | no | 1 | anon, authenticated |
| public.site_bans | on | no | 2 | anon, authenticated |
| public.site_community_managers | on | no | 1 | authenticated |
| public.site_developers | on | no | 1 | authenticated |
| public.site_managers | on | no | 1 | authenticated |
| public.site_moderators | on | no | 1 | anon, authenticated |
| public.sounds | on | no | 3 | anon, authenticated |
| public.staff_applications | on | no | 0 |  |
| public.staff_audit_log | on | no | 1 | authenticated |
| public.staff_reauth | on | no | 0 | anon, authenticated |
| public.staff_vote_ballots | on | no | 1 | anon, authenticated |
| public.staff_votes | on | no | 1 | anon, authenticated |
| public.starboard_posts | on | no | 0 | anon, authenticated |
| public.steam_links | on | no | 3 | authenticated |
| public.steam_refresh_log | on | no | 0 |  |
| public.storage_paths_used | on | no | 0 | anon, authenticated |
| public.stripe_cancel_jobs | on | no | 0 |  |
| public.suggestions | on | no | 2 | authenticated |
| public.supercharges | on | no | 0 |  |
| public.thread_follows | on | no | 1 | authenticated |
| public.translate_usage | on | no | 0 |  |
| public.upload_appeals | on | no | 0 |  |
| public.upload_quarantine | on | no | 0 |  |
| public.user_devices | on | no | 0 |  |
| public.user_dm_pins | on | no | 3 | authenticated |
| public.user_notes | on | no | 1 | authenticated |
| public.user_prefs | on | no | 3 | authenticated |
| public.user_server_folders | on | no | 3 | authenticated |
| public.user_warnings | on | no | 1 | anon, authenticated |
| public.username_changes | on | no | 0 |  |
| public.username_holds | on | no | 0 |  |
| public.vanity_changes | on | no | 0 |  |
| public.verification_requests | on | no | 2 | anon, authenticated |
| public.webhook_rate | on | no | 0 |  |
| public.webhooks | on | no | 0 |  |
| public.withdrawals | on | no | 0 |  |
| public.wordle_games | on | no | 0 |  |
| public.wordle_words | on | no | 0 |  |
| public.yt_feeds | on | no | 0 |  |
| storage.buckets | on | no | 0 | anon, authenticated |
| storage.buckets_analytics | on | no | 0 | anon, authenticated |
| storage.buckets_vectors | on | no | 0 | anon, authenticated |
| storage.migrations | on | no | 0 |  |
| storage.objects | on | no | 24 | anon, authenticated |
| storage.s3_multipart_uploads | on | no | 0 | anon, authenticated |
| storage.s3_multipart_uploads_parts | on | no | 0 | anon, authenticated |
| storage.vector_indexes | on | no | 0 | anon, authenticated |
