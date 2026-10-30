-- 05 row level security, policies, triggers
-- Schema-only dump of the live Yapper database (Postgres 17.11). No rows from any table.
-- Made by scripts/dump-schema.mjs from catalog queries. Policies straight from pg_policy; the same rules are listed readably in access-rules/policies.md.


alter table api_host.reports enable row level security;
alter table api_host.secrets enable row level security;
alter table app_host.secrets enable row level security;
alter table public.account_freezes enable row level security;
alter table public.account_suspensions enable row level security;
alter table public.alert_watches enable row level security;
alter table public.alerts_rate enable row level security;
alter table public.app_settings enable row level security;
alter table public.area_applications enable row level security;
alter table public.ban_appeals enable row level security;
alter table public.ban_leftovers enable row level security;
alter table public.billing_customers enable row level security;
alter table public.billing_fulfilments enable row level security;
alter table public.blocked_domains enable row level security;
alter table public.blocked_email_domains enable row level security;
alter table public.blocks enable row level security;
alter table public.bot_accounts enable row level security;
alter table public.bot_afk enable row level security;
alter table public.bot_commands enable row level security;
alter table public.bot_events enable row level security;
alter table public.bot_hosting enable row level security;
alter table public.bot_hosting_actions enable row level security;
alter table public.bot_interaction_replies enable row level security;
alter table public.bot_interactions enable row level security;
alter table public.bot_perm_rate enable row level security;
alter table public.bot_promotions enable row level security;
alter table public.bot_servers enable row level security;
alter table public.bot_signals enable row level security;
alter table public.bot_voice_rate enable row level security;
alter table public.bots enable row level security;
alter table public.bug_reports enable row level security;
alter table public.calls enable row level security;
alter table public.cancel_requests enable row level security;
alter table public.channel_categories enable row level security;
alter table public.channel_members enable row level security;
alter table public.channel_overrides enable row level security;
alter table public.channel_post_roles enable row level security;
alter table public.channel_reads enable row level security;
alter table public.channel_roles enable row level security;
alter table public.channels enable row level security;
alter table public.checkout_consents enable row level security;
alter table public.community_deco_checks enable row level security;
alter table public.community_decos enable row level security;
alter table public.copyright_strikes enable row level security;
alter table public.creator_applications enable row level security;
alter table public.creator_content enable row level security;
alter table public.creator_link_hits enable row level security;
alter table public.creator_links enable row level security;
alter table public.creator_referrals enable row level security;
alter table public.csam_cases enable row level security;
alter table public.data_exports enable row level security;
alter table public.deco_backup_389 enable row level security;
alter table public.deco_owned enable row level security;
alter table public.deleted_messages enable row level security;
alter table public.deleted_name_holds enable row level security;
alter table public.discover_rank enable row level security;
alter table public.discovery_visits enable row level security;
alter table public.dm_captcha_passes enable row level security;
alter table public.dm_open_log enable row level security;
alter table public.dm_requests enable row level security;
alter table public.email_log enable row level security;
alter table public.emoji_checks enable row level security;
alter table public.emojis enable row level security;
alter table public.evasion_salt enable row level security;
alter table public.feature_flags enable row level security;
alter table public.freeze_held_purges enable row level security;
alter table public.friend_request_declines enable row level security;
alter table public.friendships enable row level security;
alter table public.giveaways enable row level security;
alter table public.gmail_keys enable row level security;
alter table public.group_add_log enable row level security;
alter table public.group_add_optouts enable row level security;
alter table public.image_removal_requests enable row level security;
alter table public.image_reviews enable row level security;
alter table public.invites enable row level security;
alter table public.leaderboard_board enable row level security;
alter table public.leaderboard_exclusions enable row level security;
alter table public.leaderboard_state enable row level security;
alter table public.leaderboard_stats enable row level security;
alter table public.leaderboard_voice_open enable row level security;
alter table public.level_board enable row level security;
alter table public.level_counts enable row level security;
alter table public.link_hosts enable row level security;
alter table public.link_previews enable row level security;
alter table public.lobby_board_cache enable row level security;
alter table public.lobby_feed_posts enable row level security;
alter table public.lobby_feeds enable row level security;
alter table public.lobby_msg_days enable row level security;
alter table public.login_attempts enable row level security;
alter table public.match_cache enable row level security;
alter table public.match_settings enable row level security;
alter table public.media_interests enable row level security;
alter table public.media_links enable row level security;
alter table public.media_migrate_runs enable row level security;
alter table public.media_migrated enable row level security;
alter table public.media_purge enable row level security;
alter table public.media_refresh_log enable row level security;
alter table public.media_scans enable row level security;
alter table public.member_roles enable row level security;
alter table public.messages enable row level security;
alter table public.mfa_backup_codes enable row level security;
alter table public.mfa_recovery_requests enable row level security;
alter table public.mod_assignments enable row level security;
alter table public.mod_burst_alerts enable row level security;
alter table public.mod_burst_rules enable row level security;
alter table public.mod_case_claims enable row level security;
alter table public.mod_log enable row level security;
alter table public.mod_notes enable row level security;
alter table public.notify_settings enable row level security;
alter table public.nsfw_allowed_hashes enable row level security;
alter table public.nsfw_hashes enable row level security;
alter table public.oauth_apps enable row level security;
alter table public.oauth_codes enable row level security;
alter table public.oauth_revocations enable row level security;
alter table public.oauth_tokens enable row level security;
alter table public.onboarding_answers enable row level security;
alter table public.onboarding_choices enable row level security;
alter table public.onboarding_questions enable row level security;
alter table public.online_time enable row level security;
alter table public.partner_applications enable row level security;
alter table public.partner_watch enable row level security;
alter table public.passkey_challenges enable row level security;
alter table public.pending_bot_emails enable row level security;
alter table public.pending_signups enable row level security;
alter table public.pending_verifications enable row level security;
alter table public.people_search_quota enable row level security;
alter table public.ping_roles enable row level security;
alter table public.plus_events enable row level security;
alter table public.plus_gifts enable row level security;
alter table public.poll_answers enable row level security;
alter table public.poll_ballots enable row level security;
alter table public.poll_votes enable row level security;
alter table public.polls enable row level security;
alter table public.post_marks enable row level security;
alter table public.presence enable row level security;
alter table public.profiles enable row level security;
alter table public.promo_invite_marks enable row level security;
alter table public.push_tokens enable row level security;
alter table public.raid_alerts enable row level security;
alter table public.raid_hits enable row level security;
alter table public.reaction_roles enable row level security;
alter table public.reactions enable row level security;
alter table public.reauth_attempts enable row level security;
alter table public.referrals enable row level security;
alter table public.rename_leftovers enable row level security;
alter table public.reports enable row level security;
alter table public.request_throttle enable row level security;
alter table public.roles enable row level security;
alter table public.security_log enable row level security;
alter table public.server_audit_log enable row level security;
alter table public.server_bans enable row level security;
alter table public.server_bots enable row level security;
alter table public.server_first_joins enable row level security;
alter table public.server_hides enable row level security;
alter table public.server_join_requests enable row level security;
alter table public.server_lobby enable row level security;
alter table public.server_members enable row level security;
alter table public.server_mutes enable row level security;
alter table public.server_onboarding enable row level security;
alter table public.server_plus enable row level security;
alter table public.server_promotions enable row level security;
alter table public.server_templates enable row level security;
alter table public.server_timeouts enable row level security;
alter table public.server_voice_bans enable row level security;
alter table public.server_voice_mutes enable row level security;
alter table public.server_watch enable row level security;
alter table public.server_watch_hits enable row level security;
alter table public.server_watch_state enable row level security;
alter table public.server_watch_terms enable row level security;
alter table public.server_xp enable row level security;
alter table public.servers enable row level security;
alter table public.shard_days enable row level security;
alter table public.shard_ledger enable row level security;
alter table public.shard_wallets enable row level security;
alter table public.signup_domain_caps enable row level security;
alter table public.signup_domain_hits enable row level security;
alter table public.signup_domain_ok enable row level security;
alter table public.signup_domain_seen enable row level security;
alter table public.signup_log enable row level security;
alter table public.site_admins enable row level security;
alter table public.site_area_managers enable row level security;
alter table public.site_bans enable row level security;
alter table public.site_community_managers enable row level security;
alter table public.site_developers enable row level security;
alter table public.site_managers enable row level security;
alter table public.site_moderators enable row level security;
alter table public.sounds enable row level security;
alter table public.staff_applications enable row level security;
alter table public.staff_audit_log enable row level security;
alter table public.staff_reauth enable row level security;
alter table public.staff_vote_ballots enable row level security;
alter table public.staff_votes enable row level security;
alter table public.starboard_posts enable row level security;
alter table public.steam_links enable row level security;
alter table public.steam_refresh_log enable row level security;
alter table public.storage_paths_used enable row level security;
alter table public.stripe_cancel_jobs enable row level security;
alter table public.suggestions enable row level security;
alter table public.supercharges enable row level security;
alter table public.thread_follows enable row level security;
alter table public.translate_usage enable row level security;
alter table public.upload_appeals enable row level security;
alter table public.upload_quarantine enable row level security;
alter table public.user_devices enable row level security;
alter table public.user_dm_pins enable row level security;
alter table public.user_notes enable row level security;
alter table public.user_passkeys enable row level security;
alter table public.user_prefs enable row level security;
alter table public.user_server_folders enable row level security;
alter table public.user_warnings enable row level security;
alter table public.username_changes enable row level security;
alter table public.username_holds enable row level security;
alter table public.vanity_changes enable row level security;
alter table public.verification_requests enable row level security;
alter table public.voice_activity enable row level security;
alter table public.webhook_rate enable row level security;
alter table public.webhooks enable row level security;
alter table public.withdrawals enable row level security;
alter table public.wordle_games enable row level security;
alter table public.wordle_words enable row level security;
alter table public.yt_feeds enable row level security;
alter table storage.objects enable row level security;

create policy "api host reads usage" on api_host.secrets as permissive for select to yapper_api
  using ((name = 'usage'::text));
create policy "own suspension; staff see all" on public.account_suspensions as permissive for select to public
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_staff() AS is_staff)));
create policy "admins add blocked domains" on public.blocked_domains as permissive for insert to authenticated
  with check (public.is_site_admin());
create policy "admins read blocked domains" on public.blocked_domains as permissive for select to authenticated
  using (public.is_site_admin());
create policy "admins remove blocked domains" on public.blocked_domains as permissive for delete to authenticated
  using (public.is_site_admin());
create policy "admins manage blocked email domains" on public.blocked_email_domains as permissive for all to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());
create policy "see who you blocked" on public.blocks as permissive for select to authenticated
  using ((blocker = auth.uid()));
create policy "everyone sees bot accounts" on public.bot_accounts as permissive for select to authenticated
  using (true);
create policy "bot commands visible" on public.bot_commands as permissive for select to authenticated
  using (((EXISTS ( SELECT 1
   FROM public.bot_servers bs
  WHERE ((bs.bot_id = bot_commands.bot_id) AND public.is_server_member(bs.server_id)))) OR (EXISTS ( SELECT 1
   FROM public.bots b
  WHERE ((b.id = bot_commands.bot_id) AND (b.owner_id = auth.uid()))))));
create policy "owners see their hosting" on public.bot_hosting as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = owner_id));
create policy "own interaction replies" on public.bot_interaction_replies as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "owners see bot promotions" on public.bot_promotions as permissive for select to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR (EXISTS ( SELECT 1
   FROM public.bots b
  WHERE ((b.id = bot_promotions.bot_id) AND (b.owner_id = ( SELECT auth.uid() AS uid)))))));
create policy "bot servers visible" on public.bot_servers as permissive for select to authenticated
  using ((public.is_server_member(server_id) OR (EXISTS ( SELECT 1
   FROM public.bots b
  WHERE ((b.id = bot_servers.bot_id) AND (b.owner_id = auth.uid()))))));
create policy "bots visible" on public.bots as permissive for select to authenticated
  using (((owner_id = auth.uid()) OR public));
create policy "file a bug" on public.bug_reports as permissive for insert to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (NOT public.am_i_site_banned())));
create policy "own bug reports; staff see all" on public.bug_reports as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)));
create policy "staff update bugs" on public.bug_reports as permissive for update to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)))
  with check ((( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)));
create policy "members see calls" on public.calls as permissive for select to authenticated
  using (public.is_channel_member(channel_id));
create policy "managers remove categories" on public.channel_categories as permissive for delete to authenticated
  using ((public.server_perm(server_id, 'manage_channels'::text) AND public.staff_delete_ok(server_id)));
create policy "see categories of your servers" on public.channel_categories as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "hide your own dms" on public.channel_members as permissive for update to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));
create policy "see members of channels you can access" on public.channel_members as permissive for select to authenticated
  using (public.can_access_channel(channel_id));
create policy "managers add overrides" on public.channel_overrides as permissive for insert to authenticated
  with check (public.can_manage_overrides(server_id));
create policy "managers edit overrides" on public.channel_overrides as permissive for update to authenticated
  using (public.can_manage_overrides(server_id))
  with check (public.can_manage_overrides(server_id));
create policy "managers remove overrides" on public.channel_overrides as permissive for delete to authenticated
  using ((public.can_manage_overrides(server_id) AND public.override_role_ok(server_id, role_id)));
create policy "members read overrides" on public.channel_overrides as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "see who can post in your servers" on public.channel_post_roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "create your own read state" on public.channel_reads as permissive for insert to authenticated
  with check (((user_id = auth.uid()) AND public.can_access_channel(channel_id)));
create policy "remove your own read state" on public.channel_reads as permissive for delete to authenticated
  using ((user_id = auth.uid()));
create policy "see your own read state" on public.channel_reads as permissive for select to authenticated
  using ((user_id = auth.uid()));
create policy "update your own read state" on public.channel_reads as permissive for update to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));
create policy "see channel roles in your servers" on public.channel_roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "managers delete channels" on public.channels as permissive for delete to authenticated
  using (((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_channels'::text) AND public.staff_delete_ok(server_id)));
create policy "managers edit channels" on public.channels as permissive for update to authenticated
  using (((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_channels'::text)))
  with check (((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_channels'::text)));
create policy "see channels you can access" on public.channels as permissive for select to authenticated
  using ((((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)) OR (id IN ( SELECT public.my_channel_ids() AS my_channel_ids))) AND public.can_access_channel(id)));
create policy "approved ones, your own, all for staff" on public.community_decos as permissive for select to authenticated
  using (((status = 'approved'::text) OR (artist_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_site_mod() AS is_site_mod) OR ( SELECT public.is_art_manager() AS is_art_manager)));
create policy "own creator applications" on public.creator_applications as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_site_manager() AS is_site_manager)));
create policy "own creator content" on public.creator_content as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_site_manager() AS is_site_manager)));
create policy "own decos" on public.deco_owned as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "ignore requests to me" on public.dm_requests as permissive for delete to authenticated
  using ((to_id = auth.uid()));
create policy "see requests to me" on public.dm_requests as permissive for select to authenticated
  using ((to_id = auth.uid()));
create policy "add your own emojis" on public.emojis as permissive for insert to authenticated
  with check (((owner_id = auth.uid()) AND (server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_emojis'::text)));
create policy "delete your own emojis" on public.emojis as permissive for delete to authenticated
  using (((owner_id = auth.uid()) OR ((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_emojis'::text))));
create policy "emojis are visible to signed-in users" on public.emojis as permissive for select to authenticated
  using (((owner_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin) OR ((server_id IS NOT NULL) AND public.is_server_member(server_id))));
create policy "rename your own emojis" on public.emojis as permissive for update to authenticated
  using (((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_emojis'::text)))
  with check (((server_id IS NOT NULL) AND public.server_perm(server_id, 'manage_emojis'::text)));
create policy "admins change flags" on public.feature_flags as permissive for update to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());
create policy "admins read flags" on public.feature_flags as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "see your own friendships" on public.friendships as permissive for select to authenticated
  using (((auth.uid() = requester) OR (auth.uid() = addressee)));
create policy "own group add optouts" on public.group_add_optouts as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "delete invites" on public.invites as permissive for delete to authenticated
  using (((created_by = auth.uid()) OR public.server_perm(server_id, 'manage_server'::text)));
create policy "members create invites" on public.invites as permissive for insert to authenticated
  with check (((created_by = auth.uid()) AND public.server_perm(server_id, 'create_invite'::text) AND (NOT vanity) AND (uses = 0) AND (code ~ '^[A-Za-z0-9]{8,16}$'::text) AND (NOT skip_apply)));
create policy "see invites to your servers" on public.invites as permissive for select to authenticated
  using (((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)) AND ((NOT skip_apply) OR (created_by = auth.uid()) OR public.can_review_joins(server_id))));
create policy "admins add link hosts" on public.link_hosts as permissive for insert to authenticated
  with check (public.is_site_admin());
create policy "admins read link hosts" on public.link_hosts as permissive for select to authenticated
  using (public.is_site_admin());
create policy "admins remove link hosts" on public.link_hosts as permissive for delete to authenticated
  using (public.is_site_admin());
create policy "own match settings" on public.match_settings as permissive for all to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "edit own media prefs" on public.media_links as permissive for update to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read media links" on public.media_links as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ((NOT COALESCE(((prefs ->> 'hidden'::text))::boolean, false)) AND ((source <> 'lastfm'::text) OR verified) AND public.sees_user(user_id))));
create policy "unlink own media" on public.media_links as permissive for delete to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "own scans" on public.media_scans as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin)));
create policy "managers assign roles" on public.member_roles as permissive for insert to authenticated
  with check (public.server_perm(server_id, 'manage_roles'::text));
create policy "managers unassign roles" on public.member_roles as permissive for delete to authenticated
  using (public.server_perm(server_id, 'manage_roles'::text));
create policy "see role assignments in your servers" on public.member_roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "delete your own messages" on public.messages as permissive for delete to authenticated
  using ((author_id = auth.uid()));
create policy "edit your own messages" on public.messages as permissive for update to authenticated
  using ((author_id = auth.uid()))
  with check ((author_id = auth.uid()));
create policy "moderators delete messages" on public.messages as permissive for delete to authenticated
  using ((EXISTS ( SELECT 1
   FROM public.channels c
  WHERE ((c.id = messages.channel_id) AND (c.server_id IS NOT NULL) AND public.channel_allows(c.id, 'manage_messages'::text)))));
create policy "read messages in channels you can access" on public.messages as permissive for select to authenticated
  using ((public.can_access_channel(channel_id) AND ((author_id = ( SELECT auth.uid() AS uid)) OR public.channel_history_ok(channel_id) OR public.channel_allows(channel_id, 'manage_messages'::text))));
create policy "send messages as yourself" on public.messages as permissive for insert to authenticated
  with check (((author_id = auth.uid()) AND public.can_access_channel(channel_id) AND (NOT public.dm_blocked(channel_id)) AND public.can_post_channel(channel_id)));
create policy "yapper moderators delete messages" on public.messages as permissive for delete to authenticated
  using (( SELECT public.is_site_mod() AS is_site_mod));
create policy "leads read burst alerts" on public.mod_burst_alerts as permissive for select to authenticated
  using ((( SELECT public.feature_on('mod_burst_alerts'::text, NULL::uuid) AS feature_on) AND (( SELECT public.is_site_admin() AS is_site_admin) OR (( SELECT public.is_head_mod() AS is_head_mod) AND (actor <> ( SELECT auth.uid() AS uid))))));
create policy "leads read burst rules" on public.mod_burst_rules as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_head_mod() AS is_head_mod)));
create policy "admins read the mod log" on public.mod_log as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_head_mod() AS is_head_mod) OR (actor = ( SELECT auth.uid() AS uid))));
create policy "remove own notes" on public.mod_notes as permissive for delete to authenticated
  using (((author = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin)));
create policy "staff add notes" on public.mod_notes as permissive for insert to authenticated
  with check ((public.is_staff() AND (author = auth.uid())));
create policy "staff read notes" on public.mod_notes as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "notify settings: own read" on public.notify_settings as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "admins read online time" on public.online_time as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "members see ping roles" on public.ping_roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "see your own gifts" on public.plus_gifts as permissive for select to authenticated
  using (((recipient_id = ( SELECT auth.uid() AS uid)) OR (gifter_id = ( SELECT auth.uid() AS uid))));
create policy "own ballot read" on public.poll_ballots as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "members read votes" on public.poll_votes as permissive for select to authenticated
  using ((EXISTS ( SELECT 1
   FROM public.polls p
  WHERE ((p.id = poll_votes.poll_id) AND public.can_access_channel(p.channel_id)))));
create policy "members read polls" on public.polls as permissive for select to authenticated
  using (public.can_access_channel(channel_id));
create policy "profiles are visible to signed-in users" on public.profiles as permissive for select to authenticated
  using (true);
create policy "you can edit your own profile" on public.profiles as permissive for update to authenticated
  using ((id = auth.uid()))
  with check ((id = auth.uid()));
create policy "push tokens: own add" on public.push_tokens as permissive for insert to authenticated
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "push tokens: own change" on public.push_tokens as permissive for update to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "push tokens: own read" on public.push_tokens as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "push tokens: own remove" on public.push_tokens as permissive for delete to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "mods and staff read raid alerts" on public.raid_alerts as permissive for select to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR ((server_id IS NOT NULL) AND public.server_perm(server_id, 'ban_members'::text))));
create policy "see reaction roles of your servers" on public.reaction_roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "react as yourself" on public.reactions as permissive for insert to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND public.can_access_channel(public.message_channel(message_id)) AND (NOT public.dm_blocked(public.message_channel(message_id))) AND (public.channel_allows(public.message_channel(message_id), 'add_reactions'::text) OR public.is_reaction_role(message_id, emoji) OR public.reaction_exists(message_id, emoji))));
create policy "remove your own reactions" on public.reactions as permissive for delete to authenticated
  using ((user_id = auth.uid()));
create policy "see reactions in chats you can access" on public.reactions as permissive for select to authenticated
  using (public.can_access_channel(public.message_channel(message_id)));
create policy "admins read reports" on public.reports as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "moderators read reports" on public.reports as permissive for select to authenticated
  using (( SELECT public.is_site_mod() AS is_site_mod));
create policy "server mods read their reports" on public.reports as permissive for select to authenticated
  using (((server_id IS NOT NULL) AND (NOT ( SELECT (public.is_site_admin() OR public.is_site_mod()))) AND public.server_perm(server_id, 'manage_server'::text)));
create policy "managers create roles" on public.roles as permissive for insert to authenticated
  with check (public.server_perm(server_id, 'manage_roles'::text));
create policy "managers delete roles" on public.roles as permissive for delete to authenticated
  using (public.server_perm(server_id, 'manage_roles'::text));
create policy "managers edit roles" on public.roles as permissive for update to authenticated
  using (public.server_perm(server_id, 'manage_roles'::text))
  with check (public.server_perm(server_id, 'manage_roles'::text));
create policy "see roles in your servers" on public.roles as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "admins read the security log" on public.security_log as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "managers see bans" on public.server_bans as permissive for select to authenticated
  using (public.server_perm(server_id, 'manage_server'::text));
create policy "see bots of your servers" on public.server_bots as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "staff read server hides" on public.server_hides as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy server_lobby_read on public.server_lobby as permissive for select to authenticated
  using (public.is_server_member(server_id));
create policy "see members of your servers" on public.server_members as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "own server mutes: add" on public.server_mutes as permissive for insert to authenticated
  with check ((user_id = auth.uid()));
create policy "own server mutes: read" on public.server_mutes as permissive for select to authenticated
  using ((user_id = auth.uid()));
create policy "own server mutes: remove" on public.server_mutes as permissive for delete to authenticated
  using ((user_id = auth.uid()));
create policy "server plus visible to members" on public.server_plus as permissive for select to authenticated
  using (public.is_server_member(server_id));
create policy "managers see promotions" on public.server_promotions as permissive for select to authenticated
  using ((public.is_site_admin() OR (EXISTS ( SELECT 1
   FROM public.servers s
  WHERE ((s.id = server_promotions.server_id) AND (s.owner_id = auth.uid())))) OR public.server_perm(server_id, 'manage_server'::text)));
create policy "templates are readable" on public.server_templates as permissive for select to authenticated
  using (((created_by = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin)));
create policy "mods and the person see server timeouts" on public.server_timeouts as permissive for select to authenticated
  using (((user_id = auth.uid()) OR public.server_perm(server_id, 'manage_messages'::text)));
create policy "voice bans visible" on public.server_voice_bans as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR public.server_perm(server_id, 'move_members'::text) OR public.server_perm(server_id, 'mute_members'::text)));
create policy "voice mutes visible" on public.server_voice_mutes as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR public.server_perm(server_id, 'mute_members'::text) OR public.server_perm(server_id, 'move_members'::text)));
create policy "staff read server watch" on public.server_watch as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "admins read server watch hits" on public.server_watch_hits as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "staff read server watch state" on public.server_watch_state as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "admins add watch terms" on public.server_watch_terms as permissive for insert to authenticated
  with check (( SELECT public.is_site_admin() AS is_site_admin));
create policy "admins change watch terms" on public.server_watch_terms as permissive for update to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin))
  with check (( SELECT public.is_site_admin() AS is_site_admin));
create policy "admins remove watch terms" on public.server_watch_terms as permissive for delete to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "staff read watch terms" on public.server_watch_terms as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "see xp of your servers" on public.server_xp as permissive for select to authenticated
  using ((server_id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "see servers you're in" on public.servers as permissive for select to authenticated
  using ((id IN ( SELECT public.my_server_ids() AS my_server_ids)));
create policy "own ledger" on public.shard_ledger as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "own wallet" on public.shard_wallets as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "admins can see the admin list" on public.site_admins as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "staff see area managers" on public.site_area_managers as permissive for select to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "moderators read bans" on public.site_bans as permissive for select to authenticated
  using (( SELECT public.is_site_mod() AS is_site_mod));
create policy "you can see your own ban; admins see all" on public.site_bans as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin)));
create policy "admins see community managers" on public.site_community_managers as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_site_manager() AS is_site_manager) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "admins see developers" on public.site_developers as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_site_manager() AS is_site_manager) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "staff see managers" on public.site_managers as permissive for select to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "staff see moderators" on public.site_moderators as permissive for select to authenticated
  using ((( SELECT public.is_site_admin() AS is_site_admin) OR ( SELECT public.is_head_mod() AS is_head_mod) OR (user_id = ( SELECT auth.uid() AS uid))));
create policy "managers add sounds" on public.sounds as permissive for insert to authenticated
  with check (((owner_id = auth.uid()) AND public.server_perm(server_id, 'manage_emojis'::text) AND (( SELECT count(*) AS count
   FROM public.sounds s
  WHERE (s.server_id = sounds.server_id)) < 24)));
create policy "managers remove sounds" on public.sounds as permissive for delete to authenticated
  using (public.server_perm(server_id, 'manage_emojis'::text));
create policy "members see sounds" on public.sounds as permissive for select to authenticated
  using (public.is_server_member(server_id));
create policy "admins read the staff audit log" on public.staff_audit_log as permissive for select to authenticated
  using (( SELECT public.is_site_admin() AS is_site_admin));
create policy "staff see ballots" on public.staff_vote_ballots as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "staff see votes" on public.staff_votes as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "edit own steam prefs" on public.steam_links as permissive for update to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read steam links" on public.steam_links as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ((NOT COALESCE(((prefs ->> 'hidden'::text))::boolean, false)) AND public.sees_user(user_id))));
create policy "unlink own steam" on public.steam_links as permissive for delete to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "suggestions: read own or staff" on public.suggestions as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)));
create policy "suggestions: staff update" on public.suggestions as permissive for update to authenticated
  using ((( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)))
  with check ((( SELECT public.is_staff() AS is_staff) OR ( SELECT public.is_site_dev() AS is_site_dev)));
create policy "own follows" on public.thread_follows as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "own dm pins insert" on public.user_dm_pins as permissive for insert to authenticated
  with check (((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT public.feature_on_for_me('pin_dms'::text) AS feature_on_for_me)));
create policy "own dm pins read" on public.user_dm_pins as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "own dm pins update" on public.user_dm_pins as permissive for update to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id))
  with check (((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT public.feature_on_for_me('pin_dms'::text) AS feature_on_for_me)));
create policy "my notes" on public.user_notes as permissive for all to authenticated
  using ((owner_id = auth.uid()))
  with check ((owner_id = auth.uid()));
create policy user_prefs_insert on public.user_prefs as permissive for insert to authenticated
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy user_prefs_select on public.user_prefs as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy user_prefs_update on public.user_prefs as permissive for update to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "own folders insert" on public.user_server_folders as permissive for insert to authenticated
  with check (((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT public.feature_on_for_me('server_folders'::text) AS feature_on_for_me)));
create policy "own folders read" on public.user_server_folders as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "own folders update" on public.user_server_folders as permissive for update to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id))
  with check (((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT public.feature_on_for_me('server_folders'::text) AS feature_on_for_me)));
create policy "own warnings; staff see all" on public.user_warnings as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_staff() AS is_staff)));
create policy "own verification requests" on public.verification_requests as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_site_admin() AS is_site_admin)));
create policy "staff see verification requests" on public.verification_requests as permissive for select to authenticated
  using (( SELECT public.is_staff() AS is_staff));
create policy "members listen to their topics" on realtime.messages as permissive for select to authenticated
  using ((((realtime.topic() ~~ 'server:%'::text) AND (EXISTS ( SELECT 1
   FROM public.server_members m
  WHERE ((m.server_id = (split_part(realtime.topic(), ':'::text, 2))::uuid) AND (m.user_id = auth.uid()))))) OR ((realtime.topic() ~~ 'chan:%'::text) AND public.can_access_channel((split_part(realtime.topic(), ':'::text, 2))::uuid))));
create policy "own topic" on realtime.messages as permissive for select to authenticated
  using ((realtime.topic() = ('user:'::text || (auth.uid())::text)));
create policy "attachments: 10 MB unless Plus" on storage.objects as permissive for insert to authenticated
  with check (false);
create policy "attachments: delete own folder" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "attachments: read own folder" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "attachments: upload to own folder" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text) AND ((COALESCE(((metadata ->> 'size'::text))::bigint, (0)::bigint) <= 10485760) OR public.has_plus(auth.uid()))));
create policy "emoji images: delete own folder" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "emoji images: read own folder" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "emoji images: upload to own folder" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "icons: delete own folder" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "icons: read own folder" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "icons: upload to own folder" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "profile images: delete own folder" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = ANY (ARRAY['avatars'::text, 'banners'::text])) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "profile images: read own folder" on storage.objects as permissive for select to authenticated
  using (((bucket_id = ANY (ARRAY['avatars'::text, 'banners'::text])) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "profile images: update own folder" on storage.objects as permissive for update to authenticated
  using (false);
create policy "proofs: delete own" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = 'proofs'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text) AND (NOT public.proof_is_evidence(name))));
create policy "proofs: developers read bug screenshots" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'proofs'::text) AND ( SELECT public.is_site_dev() AS is_site_dev) AND public.dev_can_see_bug_image(name)));
create policy "proofs: managers read creator proofs" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'proofs'::text) AND ( SELECT public.is_site_manager() AS is_site_manager) AND (name IN ( SELECT c.proof_path
   FROM public.creator_applications c
  WHERE ((c.proof_path IS NOT NULL) AND (c.status = ANY (ARRAY['pending'::text, 'needs_proof'::text])))))));
create policy "proofs: read own or admin" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'proofs'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR public.is_staff())));
create policy "proofs: read proof about me" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'proofs'::text) AND (name IN ( SELECT public.my_standing_proof_images() AS my_standing_proof_images))));
create policy "proofs: upload own" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'proofs'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "report_clips: staff read" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'report_clips'::text) AND ( SELECT public.is_staff() AS is_staff)));
create policy "report_clips: upload own" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'report_clips'::text) AND public.can_upload_report_clip(name)));
create policy "sounds: delete own folder" on storage.objects as permissive for delete to authenticated
  using (((bucket_id = 'sounds'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "sounds: read" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'sounds'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR public.is_site_admin())));
create policy "sounds: upload own folder" on storage.objects as permissive for insert to authenticated
  with check (((bucket_id = 'sounds'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));

CREATE TRIGGER google_identity_guard BEFORE INSERT ON auth.identities FOR EACH ROW EXECUTE FUNCTION public.google_identity_guard();
CREATE TRIGGER ban_email_guard BEFORE INSERT OR UPDATE OF email ON auth.users FOR EACH ROW EXECUTE FUNCTION public.ban_email_guard();
CREATE TRIGGER block_throwaway_emails BEFORE INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.block_throwaway_emails();
CREATE TRIGGER creator_referral_confirmed AFTER UPDATE OF email_confirmed_at ON auth.users FOR EACH ROW WHEN (((old.email_confirmed_at IS NULL) AND (new.email_confirmed_at IS NOT NULL))) EXECUTE FUNCTION public.creator_referral_on_confirm();
CREATE TRIGGER gmail_keys_sync AFTER INSERT OR DELETE OR UPDATE OF email ON auth.users FOR EACH ROW EXECUTE FUNCTION public.gmail_keys_sync();
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
CREATE TRIGGER on_auth_user_created_renames AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.take_rename_leftovers();
CREATE TRIGGER signup_domain_track_confirm AFTER UPDATE OF email_confirmed_at ON auth.users FOR EACH ROW WHEN (((old.email_confirmed_at IS NULL) AND (new.email_confirmed_at IS NOT NULL))) EXECUTE FUNCTION public.signup_domain_track();
CREATE TRIGGER signup_domain_track_ins AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.signup_domain_track();
CREATE TRIGGER signup_pause_guard BEFORE INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.signup_pause_guard();
CREATE TRIGGER signup_route_guard BEFORE INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.signup_route_guard();
CREATE TRIGGER bot_interaction_replies_no_adult_links BEFORE INSERT OR UPDATE OF content, embeds ON public.bot_interaction_replies FOR EACH ROW WHEN (((new.content IS NOT NULL) OR (new.embeds IS NOT NULL))) EXECUTE FUNCTION public.no_adult_links_json('content', 'embeds');
CREATE TRIGGER bot_promotions_sub_cancel BEFORE DELETE ON public.bot_promotions FOR EACH ROW EXECUTE FUNCTION public.placement_sub_cancel_on_delete();
CREATE TRIGGER bot_servers_audit AFTER INSERT OR DELETE ON public.bot_servers FOR EACH ROW EXECUTE FUNCTION public.audit_bots();
CREATE TRIGGER bots_public_submit BEFORE UPDATE OF public, unlisted ON public.bots FOR EACH ROW EXECUTE FUNCTION public.bot_public_submit();
CREATE TRIGGER bots_scanned_media BEFORE INSERT OR UPDATE OF avatar_path ON public.bots FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('avatar_path', 'avatars');
CREATE TRIGGER bots_verified_badge_del AFTER DELETE ON public.bots FOR EACH ROW WHEN (((old.verified_at IS NOT NULL) AND (old.public OR old.unlisted))) EXECUTE FUNCTION public.bot_verified_badge();
CREATE TRIGGER bots_verified_badge_ins AFTER INSERT ON public.bots FOR EACH ROW WHEN (((new.verified_at IS NOT NULL) AND (new.public OR new.unlisted))) EXECUTE FUNCTION public.bot_verified_badge();
CREATE TRIGGER bots_verified_badge_upd AFTER UPDATE ON public.bots FOR EACH ROW WHEN ((((old.verified_at IS NOT NULL) AND (old.public OR old.unlisted)) IS DISTINCT FROM ((new.verified_at IS NOT NULL) AND (new.public OR new.unlisted)))) EXECUTE FUNCTION public.bot_verified_badge();
CREATE TRIGGER bug_reports_bc AFTER INSERT ON public.bug_reports FOR EACH ROW EXECUTE FUNCTION public.bc_bug();
CREATE TRIGGER bug_reports_bug_hunter AFTER UPDATE OF status ON public.bug_reports FOR EACH ROW WHEN (((new.status = 'fixed'::text) AND (old.status IS DISTINCT FROM 'fixed'::text))) EXECUTE FUNCTION public.bug_hunter_on_fix();
CREATE TRIGGER bug_reports_images BEFORE INSERT OR UPDATE OF images ON public.bug_reports FOR EACH ROW EXECUTE FUNCTION public.bug_report_images_guard();
CREATE TRIGGER bug_reports_limit BEFORE INSERT ON public.bug_reports FOR EACH ROW EXECUTE FUNCTION public.bug_report_limit();
CREATE TRIGGER calls_bc AFTER INSERT OR UPDATE ON public.calls FOR EACH ROW EXECUTE FUNCTION public.bc_call();
CREATE TRIGGER calls_note AFTER UPDATE OF ended_at ON public.calls FOR EACH ROW WHEN (((old.ended_at IS NULL) AND (new.ended_at IS NOT NULL))) EXECUTE FUNCTION public.call_note();
CREATE TRIGGER channel_categories_bc AFTER INSERT OR UPDATE ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.bc_category();
CREATE TRIGGER channel_categories_bc_del AFTER DELETE ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.bc_category();
CREATE TRIGGER channel_categories_fancy_name BEFORE INSERT OR UPDATE OF name ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.category_fancy_name();
CREATE TRIGGER channel_categories_first_defaults AFTER INSERT ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.first_category_defaults();
CREATE TRIGGER channel_categories_no_bad_names BEFORE INSERT OR UPDATE OF name ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.no_bad_names('name');
CREATE TRIGGER channel_categories_no_slurs BEFORE INSERT OR UPDATE OF name ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER channel_categories_remove_guard BEFORE DELETE ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.channel_category_remove_guard();
CREATE TRIGGER channel_categories_staff_delete_guard BEFORE DELETE ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.staff_delete_guard();
CREATE TRIGGER channel_categories_zalgo BEFORE INSERT OR UPDATE OF name ON public.channel_categories FOR EACH ROW EXECUTE FUNCTION public.names_strip_zalgo();
CREATE TRIGGER channel_members_bc AFTER INSERT OR DELETE ON public.channel_members FOR EACH ROW EXECUTE FUNCTION public.bc_channel_member();
CREATE TRIGGER channel_members_guard BEFORE UPDATE ON public.channel_members FOR EACH ROW EXECUTE FUNCTION public.channel_member_guard();
CREATE TRIGGER channel_overrides_audit AFTER INSERT OR DELETE OR UPDATE OF allow, deny ON public.channel_overrides FOR EACH ROW EXECUTE FUNCTION public.audit_overrides();
CREATE TRIGGER channel_overrides_bc AFTER INSERT OR DELETE OR UPDATE ON public.channel_overrides FOR EACH ROW EXECUTE FUNCTION public.bc_channel_override();
CREATE TRIGGER channel_overrides_guard BEFORE INSERT OR DELETE OR UPDATE ON public.channel_overrides FOR EACH ROW EXECUTE FUNCTION public.channel_overrides_guard();
CREATE TRIGGER channel_post_roles_bc AFTER INSERT OR DELETE ON public.channel_post_roles FOR EACH ROW EXECUTE FUNCTION public.bc_channel_role();
CREATE TRIGGER channel_roles_bc AFTER INSERT OR DELETE ON public.channel_roles FOR EACH ROW EXECUTE FUNCTION public.bc_channel_role();
CREATE TRIGGER channels_audit AFTER INSERT OR DELETE OR UPDATE OF name, private, read_only, slowmode, no_images, no_gifs, stage, category_id ON public.channels FOR EACH ROW EXECUTE FUNCTION public.audit_channels();
CREATE TRIGGER channels_bc AFTER INSERT OR DELETE OR UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.bc_channel();
CREATE TRIGGER channels_category_move_guard BEFORE UPDATE OF category_id, server_id ON public.channels FOR EACH ROW EXECUTE FUNCTION public.channel_category_move_guard();
CREATE TRIGGER channels_create_limit BEFORE INSERT ON public.channels FOR EACH ROW EXECUTE FUNCTION public.channel_create_limit();
CREATE TRIGGER channels_fancy_name BEFORE INSERT OR UPDATE OF name ON public.channels FOR EACH ROW EXECUTE FUNCTION public.channel_fancy_name();
CREATE TRIGGER channels_guard BEFORE UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.channel_guard();
CREATE TRIGGER channels_no_adult_links BEFORE INSERT OR UPDATE OF name ON public.channels FOR EACH ROW EXECUTE FUNCTION public.no_adult_links('name');
CREATE TRIGGER channels_no_bad_names BEFORE INSERT OR UPDATE OF name ON public.channels FOR EACH ROW EXECUTE FUNCTION public.no_bad_names('name');
CREATE TRIGGER channels_no_slurs BEFORE INSERT OR UPDATE OF name ON public.channels FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER channels_not_banned BEFORE INSERT OR UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER channels_scanned_media BEFORE INSERT OR UPDATE OF icon_path ON public.channels FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('icon_path', 'icons');
CREATE TRIGGER channels_staff_delete_guard BEFORE DELETE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.staff_delete_guard();
CREATE TRIGGER channels_sync_threads AFTER UPDATE OF slowmode, no_images, no_gifs ON public.channels FOR EACH ROW WHEN ((new.kind = ANY (ARRAY['text'::text, 'forum'::text]))) EXECUTE FUNCTION public.channels_sync_threads();
CREATE TRIGGER channels_thread_guard BEFORE UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.channels_thread_guard();
CREATE TRIGGER channels_zalgo BEFORE INSERT OR UPDATE OF name ON public.channels FOR EACH ROW EXECUTE FUNCTION public.names_strip_zalgo();
CREATE TRIGGER community_decos_gone BEFORE DELETE ON public.community_decos FOR EACH ROW EXECUTE FUNCTION public.community_decos_gone();
CREATE TRIGGER community_decos_scanned_media BEFORE INSERT OR UPDATE OF path ON public.community_decos FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('path', 'avatars');
CREATE TRIGGER community_decos_takedown_guard BEFORE UPDATE OF status ON public.community_decos FOR EACH ROW EXECUTE FUNCTION public.deco_takedown_guard();
CREATE TRIGGER dm_requests_bc AFTER INSERT ON public.dm_requests FOR EACH ROW EXECUTE FUNCTION public.bc_dm_request();
CREATE TRIGGER emojis_bc AFTER INSERT OR DELETE OR UPDATE ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.bc_emoji();
CREATE TRIGGER emojis_limit BEFORE INSERT ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.emoji_limit();
CREATE TRIGGER emojis_no_slurs BEFORE INSERT OR UPDATE OF name ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER emojis_not_banned BEFORE INSERT OR UPDATE ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER emojis_scanned_media BEFORE INSERT OR UPDATE OF path ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('path', 'emojis');
CREATE TRIGGER emojis_zz_check_gate BEFORE INSERT OR UPDATE OF path ON public.emojis FOR EACH ROW EXECUTE FUNCTION public.emoji_check_gate();
CREATE TRIGGER feature_flags_bc AFTER INSERT OR DELETE OR UPDATE ON public.feature_flags FOR EACH ROW EXECUTE FUNCTION public.bc_flags();
CREATE TRIGGER friendships_bc AFTER INSERT OR DELETE OR UPDATE ON public.friendships FOR EACH ROW EXECUTE FUNCTION public.bc_friend();
CREATE TRIGGER friendships_not_banned BEFORE INSERT ON public.friendships FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER invites_audit AFTER INSERT OR DELETE ON public.invites FOR EACH ROW EXECUTE FUNCTION public.audit_invites();
CREATE TRIGGER invites_not_banned BEFORE INSERT ON public.invites FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER invites_per_person_cap BEFORE INSERT ON public.invites FOR EACH ROW EXECUTE FUNCTION public.invites_per_person_cap();
CREATE TRIGGER invites_random_code BEFORE INSERT ON public.invites FOR EACH ROW EXECUTE FUNCTION public.invite_random_code();
CREATE TRIGGER match_cache_media_link AFTER UPDATE OF is_public, prefs, verified ON public.media_links FOR EACH ROW WHEN ((old.is_public AND (NOT COALESCE(((old.prefs ->> 'hidden'::text))::boolean, false)) AND ((old.source <> 'lastfm'::text) OR old.verified) AND (NOT (new.is_public AND (NOT COALESCE(((new.prefs ->> 'hidden'::text))::boolean, false)) AND ((new.source <> 'lastfm'::text) OR new.verified))))) EXECUTE FUNCTION public.match_cache_link_changed();
CREATE TRIGGER match_cache_media_link_gone AFTER DELETE ON public.media_links FOR EACH ROW EXECUTE FUNCTION public.match_cache_link_changed();
CREATE TRIGGER media_interests_unlink AFTER DELETE ON public.media_links FOR EACH ROW EXECUTE FUNCTION public.media_interests_unlink();
CREATE TRIGGER member_roles_audit AFTER INSERT OR DELETE ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.audit_member_roles();
CREATE TRIGGER member_roles_bc AFTER INSERT OR DELETE ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.bc_roles();
CREATE TRIGGER member_roles_guard BEFORE INSERT OR DELETE ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.role_guard();
CREATE TRIGGER member_roles_logger AFTER INSERT OR DELETE ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.logger_roles();
CREATE TRIGGER member_roles_mark_manual BEFORE INSERT ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.mark_manual_role();
CREATE TRIGGER member_roles_person BEFORE INSERT ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.member_roles_by_person();
CREATE TRIGGER member_roles_rank_guard BEFORE INSERT ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.role_rank_guard();
CREATE TRIGGER member_roles_staff_guard BEFORE INSERT OR DELETE ON public.member_roles FOR EACH ROW EXECUTE FUNCTION public.staff_role_guard();
CREATE TRIGGER message_onboarding_guard BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_onboarding_guard();
CREATE TRIGGER messages_auto_slowmode AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.auto_slowmode();
CREATE TRIGGER messages_automod BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_automod();
CREATE TRIGGER messages_bot_webhooks AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.bot_webhooks();
CREATE TRIGGER messages_bots AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.bot_on_message();
CREATE TRIGGER messages_bots_only_in_bots BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.bots_only_in_bots();
CREATE TRIGGER messages_broadcast AFTER INSERT OR DELETE OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.broadcast_message_change();
CREATE TRIGGER messages_defaults BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_defaults();
CREATE TRIGGER messages_detect_bots AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.detect_bot_replies();
CREATE TRIGGER messages_edit_guard BEFORE UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_edit_guard();
CREATE TRIGGER messages_edit_slowmode BEFORE UPDATE OF content ON public.messages FOR EACH ROW WHEN ((new.content IS DISTINCT FROM old.content)) EXECUTE FUNCTION public.message_edit_slowmode();
CREATE TRIGGER messages_giveaways AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.giveaway_cmd();
CREATE TRIGGER messages_hate_guard BEFORE INSERT OR UPDATE OF content, embeds ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_hate_guard();
CREATE TRIGGER messages_hq_links BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.hq_link_allowlist();
CREATE TRIGGER messages_invites_only_in_promo BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.invites_only_in_promo();
CREATE TRIGGER messages_keep_deleted BEFORE DELETE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.keep_deleted_message();
CREATE TRIGGER messages_length BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_length();
CREATE TRIGGER messages_log_mod_delete BEFORE DELETE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.log_mod_delete();
CREATE TRIGGER messages_logger AFTER DELETE OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.logger_messages();
CREATE TRIGGER messages_logger_pins AFTER UPDATE OF pinned_at ON public.messages FOR EACH ROW WHEN ((old.pinned_at IS DISTINCT FROM new.pinned_at)) EXECUTE FUNCTION public.logger_pins();
CREATE TRIGGER messages_new_account_media BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.new_account_media_guard();
CREATE TRIGGER messages_no_adult_links BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.no_adult_links('content');
CREATE TRIGGER messages_no_adult_links_json BEFORE INSERT OR UPDATE OF embeds, components ON public.messages FOR EACH ROW WHEN (((new.embeds IS NOT NULL) OR (new.components IS NOT NULL))) EXECUTE FUNCTION public.no_adult_links_json('embeds', 'components');
CREATE TRIGGER messages_no_gifs BEFORE INSERT OR UPDATE OF content, attachment_path ON public.messages FOR EACH ROW EXECUTE FUNCTION public.no_gifs_channel();
CREATE TRIGGER messages_no_images BEFORE INSERT OR UPDATE OF content, attachment_path ON public.messages FOR EACH ROW EXECUTE FUNCTION public.no_images_channel();
CREATE TRIGGER messages_no_slurs BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.no_slurs('content');
CREATE TRIGGER messages_not_banned BEFORE INSERT OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER messages_not_blank BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.messages_not_blank();
CREATE TRIGGER messages_perm_guard BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_perm_guard();
CREATE TRIGGER messages_raid_guard BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_raid_guard();
CREATE TRIGGER messages_require_mfa BEFORE INSERT OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.require_mfa();
CREATE TRIGGER messages_scanned_media BEFORE INSERT OR UPDATE OF attachment_path ON public.messages FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('attachment_path', 'attachments');
CREATE TRIGGER messages_server_timeout BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.block_server_timeouts();
CREATE TRIGGER messages_slowmode BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_slowmode();
CREATE TRIGGER messages_suggestion_lock BEFORE UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.suggestion_edit_lock();
CREATE TRIGGER messages_system_insert BEFORE INSERT ON public.messages FOR EACH ROW WHEN ((new.system IS NOT NULL)) EXECUTE FUNCTION public.message_system_guard();
CREATE TRIGGER messages_system_update BEFORE UPDATE OF system ON public.messages FOR EACH ROW WHEN ((new.system IS DISTINCT FROM old.system)) EXECUTE FUNCTION public.message_system_guard();
CREATE TRIGGER messages_touch_channel AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.touch_channel();
CREATE TRIGGER messages_verification_guard BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_verification_guard();
CREATE TRIGGER messages_verified_email BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.require_verified_email();
CREATE TRIGGER messages_voice_lock BEFORE UPDATE OF voice_secs, voice_wave ON public.messages FOR EACH ROW EXECUTE FUNCTION public.message_voice_lock();
CREATE TRIGGER messages_webhook_insert BEFORE INSERT ON public.messages FOR EACH ROW WHEN ((new.webhook IS NOT NULL)) EXECUTE FUNCTION public.message_webhook_guard();
CREATE TRIGGER messages_webhook_update BEFORE UPDATE OF webhook ON public.messages FOR EACH ROW WHEN ((new.webhook IS DISTINCT FROM old.webhook)) EXECUTE FUNCTION public.message_webhook_guard();
CREATE TRIGGER messages_wordle AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.wordle_cmd();
CREATE TRIGGER messages_zalgo BEFORE INSERT OR UPDATE OF content ON public.messages FOR EACH ROW EXECUTE FUNCTION public.messages_strip_zalgo();
CREATE TRIGGER push_on_message AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.push_on_message();
CREATE TRIGGER mod_log_burst_check AFTER INSERT ON public.mod_log FOR EACH ROW EXECUTE FUNCTION public.mod_burst_alert_check();
CREATE TRIGGER oauth_apps_no_slurs BEFORE INSERT OR UPDATE OF name, description ON public.oauth_apps FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name', 'description');
CREATE TRIGGER oauth_apps_scanned_media BEFORE INSERT OR UPDATE OF icon_path ON public.oauth_apps FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('icon_path', 'icons');
CREATE TRIGGER plus_gifts_gifter_badge AFTER INSERT OR DELETE OR UPDATE OF gifter_id, source, refunded_at ON public.plus_gifts FOR EACH ROW EXECUTE FUNCTION public.plus_gifts_gifter_badge();
CREATE TRIGGER poll_ballots_broadcast AFTER INSERT OR DELETE OR UPDATE ON public.poll_ballots FOR EACH ROW EXECUTE FUNCTION public.broadcast_poll_ballot();
CREATE TRIGGER poll_ballots_quiz_lock BEFORE DELETE OR UPDATE ON public.poll_ballots FOR EACH ROW EXECUTE FUNCTION public.poll_ballot_quiz_lock();
CREATE TRIGGER poll_ballots_rules BEFORE INSERT OR UPDATE ON public.poll_ballots FOR EACH ROW EXECUTE FUNCTION public.poll_ballot_rules();
CREATE TRIGGER name_banner_ok BEFORE INSERT OR UPDATE OF name_banner ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.name_banner_ok();
CREATE TRIGGER profile_cosmetics_ok BEFORE INSERT OR UPDATE OF avatar_deco ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_cosmetics_ok();
CREATE TRIGGER profile_effect_plus_only BEFORE UPDATE OF profile_effect ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_effect_plus_only();
CREATE TRIGGER profiles_00_wide_glyphs BEFORE INSERT OR UPDATE OF display_name ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profiles_strip_wide_glyphs();
CREATE TRIGGER profiles_0_protect BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_profile_columns();
CREATE TRIGGER profiles_check_links BEFORE INSERT OR UPDATE OF links ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.check_links();
CREATE TRIGGER profiles_custom_guard BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_custom_guard();
CREATE TRIGGER profiles_hate_guard BEFORE INSERT OR UPDATE OF username, display_name, bio, custom_status ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_hate_guard();
CREATE TRIGGER profiles_impersonation_guard BEFORE INSERT OR UPDATE OF username, display_name ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_impersonation_guard();
CREATE TRIGGER profiles_join_default_server AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.join_default_server();
CREATE TRIGGER profiles_links_guard BEFORE INSERT OR UPDATE OF links ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profile_links_guard();
CREATE TRIGGER profiles_no_adult_links BEFORE INSERT OR UPDATE OF username, bio ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.no_adult_links('username', 'bio');
CREATE TRIGGER profiles_no_bad_names BEFORE INSERT OR UPDATE OF username ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.no_bad_names('username');
CREATE TRIGGER profiles_no_slurs BEFORE INSERT OR UPDATE OF username, bio ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.no_slurs('username', 'bio');
CREATE TRIGGER profiles_not_banned BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER profiles_plus_role AFTER UPDATE OF plus_until ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.plus_role_on_profile();
CREATE TRIGGER profiles_plus_since BEFORE UPDATE OF plus_until ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.plus_since_on_profile();
CREATE TRIGGER profiles_protect_verified BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_verified_as();
CREATE TRIGGER profiles_require_mfa BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.require_mfa();
CREATE TRIGGER profiles_scanned_media BEFORE INSERT OR UPDATE OF avatar_path, banner_path ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('avatar_path', 'avatars', 'banner_path', 'banners');
CREATE TRIGGER profiles_status_no_slurs BEFORE INSERT OR UPDATE OF custom_status ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.no_slurs('custom_status');
CREATE TRIGGER profiles_temp_avatar BEFORE UPDATE OF avatar_path, avatar_revert_at ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.temp_avatar_guard();
CREATE TRIGGER profiles_username_deleted_hold BEFORE UPDATE OF username ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.deleted_name_guard();
CREATE TRIGGER profiles_username_limit BEFORE UPDATE OF username ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.username_change_limit();
CREATE TRIGGER profiles_username_limit_holds BEFORE INSERT OR UPDATE OF username ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.username_holds_guard();
CREATE TRIGGER profiles_verified_name_guard BEFORE UPDATE OF username, display_name, verified_as ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.verified_name_guard();
CREATE TRIGGER profiles_zalgo BEFORE INSERT OR UPDATE OF display_name, bio, pronouns ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.profiles_strip_zalgo();
CREATE TRIGGER reactions_bot_events AFTER INSERT OR DELETE ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.bot_reaction_events();
CREATE TRIGGER reactions_broadcast AFTER INSERT OR DELETE ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.broadcast_reaction_change();
CREATE TRIGGER reactions_emoji_guard BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_emoji_guard();
CREATE TRIGGER reactions_guard BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_guard();
CREATE TRIGGER reactions_limit BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_limit();
CREATE TRIGGER reactions_not_banned BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER reactions_rate_limit BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_rate_limit();
CREATE TRIGGER reactions_roles AFTER INSERT OR DELETE ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_role_apply();
CREATE TRIGGER reactions_starboard AFTER INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.starboard_react();
CREATE TRIGGER reactions_verification_guard BEFORE INSERT ON public.reactions FOR EACH ROW EXECUTE FUNCTION public.reaction_verification_guard();
CREATE TRIGGER reports_auto_action AFTER INSERT ON public.reports FOR EACH ROW EXECUTE FUNCTION public.auto_action_new_report();
CREATE TRIGGER reports_bc AFTER INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.bc_report();
CREATE TRIGGER reports_claim_clear BEFORE UPDATE OF status ON public.reports FOR EACH ROW WHEN ((new.status <> 'open'::text)) EXECUTE FUNCTION public.report_claim_clear();
CREATE TRIGGER reports_message_gone BEFORE UPDATE OF message_id ON public.reports FOR EACH ROW WHEN (((old.message_id IS NOT NULL) AND (new.message_id IS NULL))) EXECUTE FUNCTION public.report_message_gone();
CREATE TRIGGER reports_nsfw_hash AFTER UPDATE OF status ON public.reports FOR EACH ROW EXECUTE FUNCTION public.nsfw_hash_from_report();
CREATE TRIGGER reports_release_attachment AFTER UPDATE OF status ON public.reports FOR EACH ROW WHEN (((old.status = 'open'::text) AND (new.status <> 'open'::text) AND (new.message_id IS NULL) AND (new.message_attachment IS NOT NULL) AND (new.message_deleted_by = 'author'::text))) EXECUTE FUNCTION public.report_release_attachment();
CREATE TRIGGER reports_release_attachment_gone AFTER DELETE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.report_release_attachment();
CREATE TRIGGER reports_triage BEFORE INSERT ON public.reports FOR EACH ROW EXECUTE FUNCTION public.triage_new_report();
CREATE TRIGGER roles_audit AFTER INSERT OR DELETE OR UPDATE OF name, color, color2, perms, manage_server, manage_messages, mentionable ON public.roles FOR EACH ROW EXECUTE FUNCTION public.audit_roles();
CREATE TRIGGER roles_bc AFTER INSERT OR DELETE OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.bc_roles();
CREATE TRIGGER roles_edit_guard BEFORE INSERT OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.role_edit_guard();
CREATE TRIGGER roles_guard BEFORE INSERT OR DELETE OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.role_guard();
CREATE TRIGGER roles_logger AFTER INSERT OR DELETE OR UPDATE OF name, perms, manage_server, manage_messages ON public.roles FOR EACH ROW EXECUTE FUNCTION public.logger_role_edits();
CREATE TRIGGER roles_no_slurs BEFORE INSERT OR UPDATE OF name ON public.roles FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER roles_resync_manual AFTER UPDATE OF auto, auto_before ON public.roles FOR EACH ROW EXECUTE FUNCTION public.roles_resync_manual();
CREATE TRIGGER roles_staff_guard BEFORE DELETE OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.staff_role_guard();
CREATE TRIGGER roles_sync_legacy BEFORE INSERT OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.roles_sync_legacy();
CREATE TRIGGER roles_zalgo BEFORE INSERT OR UPDATE OF name ON public.roles FOR EACH ROW EXECUTE FUNCTION public.names_strip_zalgo();
CREATE TRIGGER server_bans_audit AFTER INSERT OR DELETE ON public.server_bans FOR EACH ROW EXECUTE FUNCTION public.audit_bans();
CREATE TRIGGER server_bans_logger AFTER INSERT OR DELETE ON public.server_bans FOR EACH ROW EXECUTE FUNCTION public.logger_bans();
CREATE TRIGGER server_bans_no_site_admins BEFORE INSERT ON public.server_bans FOR EACH ROW EXECUTE FUNCTION public.no_ban_site_admins();
CREATE TRIGGER server_bans_no_staff BEFORE INSERT ON public.server_bans FOR EACH ROW EXECUTE FUNCTION public.no_banning_staff();
CREATE TRIGGER match_cache_server_left AFTER DELETE ON public.server_members REFERENCING OLD TABLE AS gone FOR EACH STATEMENT EXECUTE FUNCTION public.match_cache_left_server();
CREATE TRIGGER members_not_banned BEFORE INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER server_members_area_role AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.area_role_on_join();
CREATE TRIGGER server_members_audit AFTER DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.audit_kicks();
CREATE TRIGGER server_members_auto_lock AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.auto_lock_on_raid();
CREATE TRIGGER server_members_bot_events AFTER INSERT OR DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.bot_member_events();
CREATE TRIGGER server_members_bot_goodbye AFTER DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.bot_goodbye();
CREATE TRIGGER server_members_bot_left AFTER DELETE ON public.server_members FOR EACH ROW WHEN ((old.user_id IS NOT NULL)) EXECUTE FUNCTION public.bot_left_server();
CREATE TRIGGER server_members_bot_welcome AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.bot_welcome();
CREATE TRIGGER server_members_broadcast AFTER INSERT OR DELETE OR UPDATE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.broadcast_member_change();
CREATE TRIGGER server_members_count AFTER INSERT OR DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.bump_member_count();
CREATE TRIGGER server_members_drop_tag AFTER DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.drop_tag_on_leave();
CREATE TRIGGER server_members_first_join BEFORE INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.keep_first_join();
CREATE TRIGGER server_members_forget_onboarding AFTER DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.forget_onboarding_on_leave();
CREATE TRIGGER server_members_hidden_guard BEFORE INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.server_hidden_join_guard();
CREATE TRIGGER server_members_hq_role AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.hq_auto_role();
alter table public.server_members disable trigger server_members_hq_role;
CREATE TRIGGER server_members_join_gate BEFORE INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.server_members_join_gate();
CREATE TRIGGER server_members_logger AFTER INSERT OR DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.logger_members();
CREATE TRIGGER server_members_og AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.og_on_join();
CREATE TRIGGER server_members_plus_role AFTER INSERT ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.plus_role_on_join();
CREATE TRIGGER server_members_vanity_drop AFTER DELETE ON public.server_members FOR EACH ROW EXECUTE FUNCTION public.vanity_drop_below_five();
CREATE TRIGGER server_promotions_sub_cancel BEFORE DELETE ON public.server_promotions FOR EACH ROW EXECUTE FUNCTION public.placement_sub_cancel_on_delete();
CREATE TRIGGER server_timeouts_audit AFTER INSERT OR DELETE OR UPDATE OF until ON public.server_timeouts FOR EACH ROW EXECUTE FUNCTION public.audit_timeouts();
CREATE TRIGGER server_timeouts_logger AFTER INSERT OR UPDATE ON public.server_timeouts FOR EACH ROW EXECUTE FUNCTION public.logger_timeouts();
CREATE TRIGGER server_voice_bans_audit AFTER INSERT OR DELETE OR UPDATE OF until, reason ON public.server_voice_bans FOR EACH ROW EXECUTE FUNCTION public.audit_voice_bans();
CREATE TRIGGER server_voice_mutes_audit AFTER INSERT OR DELETE OR UPDATE OF until ON public.server_voice_mutes FOR EACH ROW EXECUTE FUNCTION public.audit_voice_mutes();
CREATE TRIGGER server_watch_terms_changed AFTER INSERT OR DELETE OR UPDATE ON public.server_watch_terms FOR EACH STATEMENT EXECUTE FUNCTION public.server_watch_terms_changed();
CREATE TRIGGER servers_audit AFTER UPDATE OF name, icon_path, banner_path, description, discoverable, tag, tickets_on, locked_until, lock_reason, rules_channel_id, new_account_minutes, new_account_mode, everyone_perms, theme, links, tags ON public.servers FOR EACH ROW EXECUTE FUNCTION public.audit_servers();
CREATE TRIGGER servers_bc AFTER UPDATE ON public.servers FOR EACH ROW EXECUTE FUNCTION public.bc_server();
CREATE TRIGGER servers_check_links BEFORE INSERT OR UPDATE OF links ON public.servers FOR EACH ROW EXECUTE FUNCTION public.check_links();
CREATE TRIGGER servers_daily_cap BEFORE INSERT ON public.servers FOR EACH ROW EXECUTE FUNCTION public.servers_daily_cap();
CREATE TRIGGER servers_keep_hidden BEFORE UPDATE OF discoverable ON public.servers FOR EACH ROW WHEN (((new.staff_hidden_at IS NOT NULL) AND (old.staff_hidden_at IS NOT NULL))) EXECUTE FUNCTION public.servers_keep_hidden();
CREATE TRIGGER servers_name_ok BEFORE INSERT OR UPDATE OF name ON public.servers FOR EACH ROW EXECUTE FUNCTION public.servers_name_ok();
CREATE TRIGGER servers_no_adult_links BEFORE INSERT OR UPDATE OF name ON public.servers FOR EACH ROW EXECUTE FUNCTION public.no_adult_links('name');
CREATE TRIGGER servers_no_bad_names BEFORE INSERT OR UPDATE OF name ON public.servers FOR EACH ROW EXECUTE FUNCTION public.no_bad_names('name');
CREATE TRIGGER servers_no_slurs BEFORE INSERT OR UPDATE OF name ON public.servers FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER servers_not_banned BEFORE INSERT OR UPDATE ON public.servers FOR EACH ROW EXECUTE FUNCTION public.not_site_banned();
CREATE TRIGGER servers_partner_gone BEFORE DELETE ON public.servers FOR EACH ROW WHEN ((old.partner_since IS NOT NULL)) EXECUTE FUNCTION public.partner_server_gone();
CREATE TRIGGER servers_partner_owner AFTER UPDATE OF owner_id ON public.servers FOR EACH ROW WHEN (((old.owner_id IS DISTINCT FROM new.owner_id) AND (new.partner_since IS NOT NULL))) EXECUTE FUNCTION public.partner_owner_moved();
CREATE TRIGGER servers_scanned_media BEFORE INSERT OR UPDATE OF icon_path, banner_path ON public.servers FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('icon_path', 'icons', 'banner_path', 'banners');
CREATE TRIGGER servers_shutdown_clears_tags AFTER UPDATE OF shut_down_at ON public.servers FOR EACH ROW EXECUTE FUNCTION public.server_shutdown_clears_tags();
CREATE TRIGGER servers_sync_tag AFTER UPDATE OF tag ON public.servers FOR EACH ROW EXECUTE FUNCTION public.sync_server_tag();
CREATE TRIGGER servers_untag BEFORE DELETE ON public.servers FOR EACH ROW EXECUTE FUNCTION public.untag_on_server_delete();
CREATE TRIGGER servers_zalgo BEFORE INSERT OR UPDATE OF name ON public.servers FOR EACH ROW EXECUTE FUNCTION public.names_strip_zalgo();
CREATE TRIGGER signup_log_burst AFTER INSERT ON public.signup_log FOR EACH ROW EXECUTE FUNCTION public.signup_burst_check();
CREATE TRIGGER site_area_managers_badge AFTER INSERT OR DELETE ON public.site_area_managers FOR EACH ROW EXECUTE FUNCTION public.sync_area_manager_badge();
CREATE TRIGGER site_area_managers_role AFTER INSERT OR DELETE ON public.site_area_managers FOR EACH ROW EXECUTE FUNCTION public.area_managers_role_sync();
CREATE TRIGGER site_bans_bc AFTER INSERT OR DELETE OR UPDATE ON public.site_bans FOR EACH ROW EXECUTE FUNCTION public.bc_site_ban();
CREATE TRIGGER site_bans_forgive AFTER DELETE ON public.site_bans FOR EACH ROW EXECUTE FUNCTION public.forgive_strikes_on_unban();
CREATE TRIGGER site_bans_proof_reset BEFORE UPDATE OF created_at ON public.site_bans FOR EACH ROW WHEN ((new.created_at IS DISTINCT FROM old.created_at)) EXECUTE FUNCTION public.site_bans_proof_reset();
CREATE TRIGGER site_bans_queue_media AFTER INSERT ON public.site_bans FOR EACH ROW EXECUTE FUNCTION public.queue_banned_media();
CREATE TRIGGER site_bans_queue_media_reban AFTER UPDATE OF expires_at ON public.site_bans FOR EACH ROW WHEN (((old.expires_at IS NOT NULL) AND (old.expires_at <= now()) AND ((new.expires_at IS NULL) OR (new.expires_at > now())))) EXECUTE FUNCTION public.queue_banned_media();
CREATE TRIGGER site_bans_unban_guard BEFORE UPDATE OF expires_at ON public.site_bans FOR EACH ROW EXECUTE FUNCTION public.unban_guard();
CREATE TRIGGER site_managers_badge AFTER INSERT OR DELETE ON public.site_managers FOR EACH ROW EXECUTE FUNCTION public.sync_management_badge();
CREATE TRIGGER mod_assignments_head_changed AFTER UPDATE OF head, suspended_at ON public.site_moderators FOR EACH ROW WHEN (((old.head IS DISTINCT FROM new.head) OR (old.suspended_at IS DISTINCT FROM new.suspended_at))) EXECUTE FUNCTION public.mod_assignments_head_changed();
CREATE TRIGGER site_moderators_badge AFTER INSERT OR DELETE OR UPDATE OF suspended_at, head ON public.site_moderators FOR EACH ROW EXECUTE FUNCTION public.sync_mod_badge();
CREATE TRIGGER site_moderators_management_badge AFTER INSERT OR DELETE OR UPDATE OF head, suspended_at ON public.site_moderators FOR EACH ROW EXECUTE FUNCTION public.sync_management_badge();
CREATE TRIGGER match_cache_steam_link AFTER UPDATE OF games_public, prefs ON public.steam_links FOR EACH ROW WHEN ((old.games_public AND (NOT COALESCE(((old.prefs ->> 'hidden'::text))::boolean, false)) AND COALESCE(((old.prefs ->> 'show_games'::text))::boolean, true) AND (NOT (new.games_public AND (NOT COALESCE(((new.prefs ->> 'hidden'::text))::boolean, false)) AND COALESCE(((new.prefs ->> 'show_games'::text))::boolean, true))))) EXECUTE FUNCTION public.match_cache_link_changed();
CREATE TRIGGER match_cache_steam_link_gone AFTER DELETE ON public.steam_links FOR EACH ROW EXECUTE FUNCTION public.match_cache_link_changed();
CREATE TRIGGER media_interests_unlink AFTER DELETE ON public.steam_links FOR EACH ROW EXECUTE FUNCTION public.media_interests_unlink();
CREATE TRIGGER user_dm_pins_touch BEFORE INSERT OR UPDATE ON public.user_dm_pins FOR EACH ROW EXECUTE FUNCTION public.user_dm_pins_touch();
CREATE TRIGGER user_server_folders_touch BEFORE INSERT OR UPDATE ON public.user_server_folders FOR EACH ROW EXECUTE FUNCTION public.user_server_folders_touch();
CREATE TRIGGER user_warnings_bc AFTER INSERT ON public.user_warnings FOR EACH ROW EXECUTE FUNCTION public.bc_warning();
CREATE TRIGGER webhooks_audit AFTER INSERT OR DELETE ON public.webhooks FOR EACH ROW EXECUTE FUNCTION public.audit_webhooks();
CREATE TRIGGER webhooks_no_slurs BEFORE INSERT OR UPDATE OF name ON public.webhooks FOR EACH ROW EXECUTE FUNCTION public.no_slurs('name');
CREATE TRIGGER webhooks_scanned_media BEFORE INSERT OR UPDATE OF avatar_path ON public.webhooks FOR EACH ROW EXECUTE FUNCTION public.require_scanned_media('avatar_path', 'avatars');
CREATE TRIGGER no_path_reuse BEFORE INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION public.storage_no_path_reuse();
