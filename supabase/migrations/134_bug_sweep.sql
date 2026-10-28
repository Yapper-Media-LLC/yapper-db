-- 134: bug report sweep (16 Oct). Applied live through the SQL editor; recorded here for reference.
-- Function bodies were patched in place (pg_get_functiondef + replace), so this file lists what changed.

-- Profiles outage 11:25-12:05 UTC: the new column had no SELECT grant, so every profile read failed.
grant select (discriminator) on public.profiles to anon, authenticated;

-- promo_event: "column reference kind is ambiguous" -> qualified as promo_event.kind.
-- server_builtin_bots(sid): built-in bots listed in the member list "Bots" group.

-- message_edit_guard:
--   * edits follow the send rules: @everyone/@here neutralised without mention_everyone,
--     new links refused without embed_links (report f83ccd73).
--   * pinned_at/pinned_by are only kept from the user when yapper.pin is not set, so
--     pin_message() (which sets it) works again. Pins had silently never saved.
-- pin_message(): sets yapper.pin around its update.

-- detect_bot_replies: skips commands and short messages, threshold 25 (humans tagged as bots).

-- Moderation permissions without Administrator:
--   outranks(sid, target): owner, or a higher top role than the target.
--   ban_member / unban_member -> ban_members, kick_member -> kick_members, server_timeout -> timeout_members.

-- reorder_roles: Manage Roles without Administrator can shuffle the roles below their highest role,
--   among the positions those roles already hold.

-- roles_sync_legacy: no longer raises manage_server / manage_messages from the per-permission list,
--   so turning one implied permission off (e.g. Mention @everyone) sticks.

-- bootstrap() and channel_messages(): profile rows now include verify_required, profile_effect,
--   custom_status, avatar_deco, discriminator (decorations and statuses vanished after reload).

-- message_defaults: a DM to someone who only takes messages from friends is refused when the sender
--   isn't a friend and the recipient never wrote in that DM (covers DMs opened before the setting).
