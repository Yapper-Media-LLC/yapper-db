# Row level security policies

One entry per policy, straight from `pg_policies`. `USING` decides which rows a role can see or touch; `WITH CHECK` decides which rows it may write. A command with no policy for a role is denied.

## api_host.secrets

### api host reads usage

- command: SELECT
- roles: yapper_api
- permissive

USING

```sql
(name = 'usage'::text)
```

## public.account_suspensions

### own suspension; staff see all

- command: SELECT
- roles: public
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_staff() AS is_staff))
```

## public.blocked_domains

### admins add blocked domains

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
is_site_admin()
```

### admins read blocked domains

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

### admins remove blocked domains

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

## public.blocked_email_domains

### admins manage blocked email domains

- command: ALL
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

WITH CHECK

```sql
is_site_admin()
```

## public.blocks

### see who you blocked

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(blocker = auth.uid())
```

## public.bot_accounts

### everyone sees bot accounts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
true
```

## public.bot_commands

### bot commands visible

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((EXISTS ( SELECT 1
   FROM bot_servers bs
  WHERE ((bs.bot_id = bot_commands.bot_id) AND is_server_member(bs.server_id)))) OR (EXISTS ( SELECT 1
   FROM bots b
  WHERE ((b.id = bot_commands.bot_id) AND (b.owner_id = auth.uid())))))
```

## public.bot_hosting

### owners see their hosting

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT auth.uid() AS uid) = owner_id)
```

## public.bot_interaction_replies

### own interaction replies

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.bot_promotions

### owners see bot promotions

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_staff() AS is_staff) OR (EXISTS ( SELECT 1
   FROM bots b
  WHERE ((b.id = bot_promotions.bot_id) AND (b.owner_id = ( SELECT auth.uid() AS uid))))))
```

## public.bot_servers

### bot servers visible

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(is_server_member(server_id) OR (EXISTS ( SELECT 1
   FROM bots b
  WHERE ((b.id = bot_servers.bot_id) AND (b.owner_id = auth.uid())))))
```

## public.bots

### bots visible

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((owner_id = auth.uid()) OR public)
```

## public.bug_reports

### file a bug

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((user_id = ( SELECT auth.uid() AS uid)) AND (NOT am_i_site_banned()))
```

### own bug reports; staff see all

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

### staff update bugs

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

WITH CHECK

```sql
(( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

## public.calls

### members see calls

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_channel_member(channel_id)
```

## public.channel_categories

### managers remove categories

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(server_perm(server_id, 'manage_channels'::text) AND staff_delete_ok(server_id))
```

### see categories of your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.channel_members

### hide your own dms

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

WITH CHECK

```sql
(user_id = auth.uid())
```

### see members of channels you can access

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
can_access_channel(channel_id)
```

## public.channel_overrides

### managers add overrides

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
can_manage_overrides(server_id)
```

### managers edit overrides

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
can_manage_overrides(server_id)
```

WITH CHECK

```sql
can_manage_overrides(server_id)
```

### managers remove overrides

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(can_manage_overrides(server_id) AND override_role_ok(server_id, role_id))
```

### members read overrides

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.channel_post_roles

### see who can post in your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.channel_reads

### create your own read state

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((user_id = auth.uid()) AND can_access_channel(channel_id))
```

### remove your own read state

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

### see your own read state

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

### update your own read state

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

WITH CHECK

```sql
(user_id = auth.uid())
```

## public.channel_roles

### see channel roles in your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.channels

### managers delete channels

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((server_id IS NOT NULL) AND server_perm(server_id, 'manage_channels'::text) AND staff_delete_ok(server_id))
```

### managers edit channels

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
((server_id IS NOT NULL) AND server_perm(server_id, 'manage_channels'::text))
```

WITH CHECK

```sql
((server_id IS NOT NULL) AND server_perm(server_id, 'manage_channels'::text))
```

### see channels you can access

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(((server_id IN ( SELECT my_server_ids() AS my_server_ids)) OR (id IN ( SELECT my_channel_ids() AS my_channel_ids))) AND can_access_channel(id))
```

## public.community_decos

### approved ones, your own, all for staff

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((status = 'approved'::text) OR (artist_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_site_mod() AS is_site_mod))
```

## public.creator_applications

### own creator applications

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_site_manager() AS is_site_manager))
```

## public.creator_content

### own creator content

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_site_manager() AS is_site_manager))
```

## public.deco_owned

### own decos

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.dm_requests

### ignore requests to me

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(to_id = auth.uid())
```

### see requests to me

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(to_id = auth.uid())
```

## public.emojis

### add your own emojis

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((owner_id = auth.uid()) AND (server_id IS NOT NULL) AND server_perm(server_id, 'manage_emojis'::text))
```

### delete your own emojis

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((owner_id = auth.uid()) OR ((server_id IS NOT NULL) AND server_perm(server_id, 'manage_emojis'::text)))
```

### emojis are visible to signed-in users

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((owner_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin) OR ((server_id IS NOT NULL) AND is_server_member(server_id)))
```

### rename your own emojis

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
((server_id IS NOT NULL) AND server_perm(server_id, 'manage_emojis'::text))
```

WITH CHECK

```sql
((server_id IS NOT NULL) AND server_perm(server_id, 'manage_emojis'::text))
```

## public.feature_flags

### admins change flags

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

WITH CHECK

```sql
is_site_admin()
```

### admins read flags

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

## public.friendships

### see your own friendships

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((auth.uid() = requester) OR (auth.uid() = addressee))
```

## public.group_add_optouts

### own group add optouts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.invites

### delete invites

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((created_by = auth.uid()) OR server_perm(server_id, 'manage_server'::text))
```

### members create invites

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((created_by = auth.uid()) AND server_perm(server_id, 'create_invite'::text) AND (NOT vanity) AND (uses = 0) AND (code ~ '^[A-Za-z0-9]{8,16}$'::text) AND (NOT skip_apply))
```

### see invites to your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((server_id IN ( SELECT my_server_ids() AS my_server_ids)) AND ((NOT skip_apply) OR (created_by = auth.uid()) OR can_review_joins(server_id)))
```

## public.link_hosts

### admins add link hosts

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
is_site_admin()
```

### admins read link hosts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

### admins remove link hosts

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
is_site_admin()
```

## public.match_settings

### own match settings

- command: ALL
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.media_links

### edit own media prefs

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### read media links

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ((NOT COALESCE(((prefs ->> 'hidden'::text))::boolean, false)) AND ((source <> 'lastfm'::text) OR verified) AND sees_user(user_id)))
```

### unlink own media

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.media_scans

### own scans

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin))
```

## public.member_roles

### managers assign roles

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
server_perm(server_id, 'manage_roles'::text)
```

### managers unassign roles

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
server_perm(server_id, 'manage_roles'::text)
```

### see role assignments in your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.messages

### delete your own messages

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(author_id = auth.uid())
```

### edit your own messages

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(author_id = auth.uid())
```

WITH CHECK

```sql
(author_id = auth.uid())
```

### moderators delete messages

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(EXISTS ( SELECT 1
   FROM channels c
  WHERE ((c.id = messages.channel_id) AND (c.server_id IS NOT NULL) AND channel_allows(c.id, 'manage_messages'::text))))
```

### read messages in channels you can access

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(can_access_channel(channel_id) AND ((author_id = ( SELECT auth.uid() AS uid)) OR channel_history_ok(channel_id) OR channel_allows(channel_id, 'manage_messages'::text)))
```

### send messages as yourself

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((author_id = auth.uid()) AND can_access_channel(channel_id) AND (NOT dm_blocked(channel_id)) AND can_post_channel(channel_id))
```

### yapper moderators delete messages

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_mod() AS is_site_mod)
```

## public.mod_burst_alerts

### leads read burst alerts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT feature_on('mod_burst_alerts'::text, NULL::uuid) AS feature_on) AND (( SELECT is_site_admin() AS is_site_admin) OR (( SELECT is_head_mod() AS is_head_mod) AND (actor <> ( SELECT auth.uid() AS uid)))))
```

## public.mod_burst_rules

### leads read burst rules

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_head_mod() AS is_head_mod))
```

## public.mod_log

### admins read the mod log

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_head_mod() AS is_head_mod) OR (actor = ( SELECT auth.uid() AS uid)))
```

## public.mod_notes

### remove own notes

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((author = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin))
```

### staff add notes

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
(is_staff() AND (author = auth.uid()))
```

### staff read notes

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.online_time

### admins read online time

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

## public.plus_gifts

### see your own gifts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((recipient_id = ( SELECT auth.uid() AS uid)) OR (gifter_id = ( SELECT auth.uid() AS uid)))
```

## public.poll_ballots

### own ballot read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.poll_votes

### members read votes

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(EXISTS ( SELECT 1
   FROM polls p
  WHERE ((p.id = poll_votes.poll_id) AND can_access_channel(p.channel_id))))
```

## public.polls

### members read polls

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
can_access_channel(channel_id)
```

## public.profiles

### profiles are visible to signed-in users

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
true
```

### you can edit your own profile

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(id = auth.uid())
```

WITH CHECK

```sql
(id = auth.uid())
```

## public.push_tokens

### push tokens: own add

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### push tokens: own change

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### push tokens: own read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### push tokens: own remove

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.raid_alerts

### mods and staff read raid alerts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_staff() AS is_staff) OR ((server_id IS NOT NULL) AND server_perm(server_id, 'ban_members'::text)))
```

## public.reaction_roles

### see reaction roles of your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.reactions

### react as yourself

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((user_id = ( SELECT auth.uid() AS uid)) AND can_access_channel(message_channel(message_id)) AND (NOT dm_blocked(message_channel(message_id))) AND (channel_allows(message_channel(message_id), 'add_reactions'::text) OR is_reaction_role(message_id, emoji) OR reaction_exists(message_id, emoji)))
```

### remove your own reactions

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

### see reactions in chats you can access

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
can_access_channel(message_channel(message_id))
```

## public.reports

### admins read reports

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

### moderators read reports

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_mod() AS is_site_mod)
```

### server mods read their reports

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((server_id IS NOT NULL) AND (NOT ( SELECT (is_site_admin() OR is_site_mod()))) AND server_perm(server_id, 'manage_server'::text))
```

## public.roles

### managers create roles

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
server_perm(server_id, 'manage_roles'::text)
```

### managers delete roles

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
server_perm(server_id, 'manage_roles'::text)
```

### managers edit roles

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
server_perm(server_id, 'manage_roles'::text)
```

WITH CHECK

```sql
server_perm(server_id, 'manage_roles'::text)
```

### see roles in your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.server_bans

### managers see bans

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
server_perm(server_id, 'manage_server'::text)
```

## public.server_bots

### see bots of your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.server_hides

### staff read server hides

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.server_lobby

### server_lobby_read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_server_member(server_id)
```

## public.server_members

### see members of your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.server_mutes

### own server mutes: add

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
(user_id = auth.uid())
```

### own server mutes: read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

### own server mutes: remove

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = auth.uid())
```

## public.server_plus

### server plus visible to members

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_server_member(server_id)
```

## public.server_promotions

### managers see promotions

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(is_site_admin() OR (EXISTS ( SELECT 1
   FROM servers s
  WHERE ((s.id = server_promotions.server_id) AND (s.owner_id = auth.uid())))) OR server_perm(server_id, 'manage_server'::text))
```

## public.server_templates

### templates are readable

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((created_by = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin))
```

## public.server_timeouts

### mods and the person see server timeouts

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = auth.uid()) OR server_perm(server_id, 'manage_messages'::text))
```

## public.server_voice_bans

### voice bans visible

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR server_perm(server_id, 'move_members'::text) OR server_perm(server_id, 'mute_members'::text))
```

## public.server_voice_mutes

### voice mutes visible

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR server_perm(server_id, 'mute_members'::text) OR server_perm(server_id, 'move_members'::text))
```

## public.server_watch

### staff read server watch

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.server_watch_hits

### admins read server watch hits

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

## public.server_watch_state

### staff read server watch state

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.server_watch_terms

### admins add watch terms

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
( SELECT is_site_admin() AS is_site_admin)
```

### admins change watch terms

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

WITH CHECK

```sql
( SELECT is_site_admin() AS is_site_admin)
```

### admins remove watch terms

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

### staff read watch terms

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.server_xp

### see xp of your servers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(server_id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.servers

### see servers you're in

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(id IN ( SELECT my_server_ids() AS my_server_ids))
```

## public.shard_ledger

### own ledger

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.shard_wallets

### own wallet

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.site_admins

### admins can see the admin list

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR (user_id = ( SELECT auth.uid() AS uid)))
```

## public.site_bans

### moderators read bans

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_mod() AS is_site_mod)
```

### you can see your own ban; admins see all

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin))
```

## public.site_community_managers

### admins see community managers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_site_manager() AS is_site_manager) OR (user_id = ( SELECT auth.uid() AS uid)))
```

## public.site_developers

### admins see developers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_site_manager() AS is_site_manager) OR (user_id = ( SELECT auth.uid() AS uid)))
```

## public.site_managers

### staff see managers

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_staff() AS is_staff) OR (user_id = ( SELECT auth.uid() AS uid)))
```

## public.site_moderators

### staff see moderators

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_site_admin() AS is_site_admin) OR ( SELECT is_head_mod() AS is_head_mod) OR (user_id = ( SELECT auth.uid() AS uid)))
```

## public.sounds

### managers add sounds

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((owner_id = auth.uid()) AND server_perm(server_id, 'manage_emojis'::text) AND (( SELECT count(*) AS count
   FROM sounds s
  WHERE (s.server_id = sounds.server_id)) < 24))
```

### managers remove sounds

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
server_perm(server_id, 'manage_emojis'::text)
```

### members see sounds

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
is_server_member(server_id)
```

## public.staff_audit_log

### admins read the staff audit log

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_site_admin() AS is_site_admin)
```

## public.staff_vote_ballots

### staff see ballots

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.staff_votes

### staff see votes

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## public.steam_links

### edit own steam prefs

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### read steam links

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ((NOT COALESCE(((prefs ->> 'hidden'::text))::boolean, false)) AND sees_user(user_id)))
```

### unlink own steam

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.suggestions

### suggestions: read own or staff

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

### suggestions: staff update

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

WITH CHECK

```sql
(( SELECT is_staff() AS is_staff) OR ( SELECT is_site_dev() AS is_site_dev))
```

## public.thread_follows

### own follows

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.user_dm_pins

### own dm pins insert

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT feature_on_for_me('pin_dms'::text) AS feature_on_for_me))
```

### own dm pins read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT auth.uid() AS uid) = user_id)
```

### own dm pins update

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(( SELECT auth.uid() AS uid) = user_id)
```

WITH CHECK

```sql
((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT feature_on_for_me('pin_dms'::text) AS feature_on_for_me))
```

## public.user_notes

### my notes

- command: ALL
- roles: authenticated
- permissive

USING

```sql
(owner_id = auth.uid())
```

WITH CHECK

```sql
(owner_id = auth.uid())
```

## public.user_prefs

### user_prefs_insert

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### user_prefs_select

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

### user_prefs_update

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

WITH CHECK

```sql
(user_id = ( SELECT auth.uid() AS uid))
```

## public.user_server_folders

### own folders insert

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT feature_on_for_me('server_folders'::text) AS feature_on_for_me))
```

### own folders read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
(( SELECT auth.uid() AS uid) = user_id)
```

### own folders update

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
(( SELECT auth.uid() AS uid) = user_id)
```

WITH CHECK

```sql
((( SELECT auth.uid() AS uid) = user_id) AND ( SELECT feature_on_for_me('server_folders'::text) AS feature_on_for_me))
```

## public.user_warnings

### own warnings; staff see all

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_staff() AS is_staff))
```

## public.verification_requests

### own verification requests

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT is_site_admin() AS is_site_admin))
```

### staff see verification requests

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
( SELECT is_staff() AS is_staff)
```

## storage.objects

### attachments: 10 MB unless Plus

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
false
```

### attachments: delete own folder

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### attachments: read own folder

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### attachments: upload to own folder

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text) AND ((COALESCE(((metadata ->> 'size'::text))::bigint, (0)::bigint) <= 10485760) OR has_plus(auth.uid())))
```

### emoji images: delete own folder

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### emoji images: read own folder

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### emoji images: upload to own folder

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'emojis'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### icons: delete own folder

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### icons: read own folder

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### icons: upload to own folder

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'icons'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### profile images: delete own folder

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = ANY (ARRAY['avatars'::text, 'banners'::text])) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### profile images: read own folder

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = ANY (ARRAY['avatars'::text, 'banners'::text])) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### profile images: update own folder

- command: UPDATE
- roles: authenticated
- permissive

USING

```sql
false
```

### proofs: delete own

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'proofs'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text) AND (NOT proof_is_evidence(name)))
```

### proofs: developers read bug screenshots

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'proofs'::text) AND ( SELECT is_site_dev() AS is_site_dev) AND dev_can_see_bug_image(name))
```

### proofs: managers read creator proofs

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'proofs'::text) AND ( SELECT is_site_manager() AS is_site_manager) AND (name IN ( SELECT c.proof_path
   FROM creator_applications c
  WHERE ((c.proof_path IS NOT NULL) AND (c.status = ANY (ARRAY['pending'::text, 'needs_proof'::text]))))))
```

### proofs: read own or admin

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'proofs'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR is_staff()))
```

### proofs: read proof about me

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'proofs'::text) AND (name IN ( SELECT my_standing_proof_images() AS my_standing_proof_images)))
```

### proofs: upload own

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'proofs'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### report_clips: staff read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'report_clips'::text) AND ( SELECT is_staff() AS is_staff))
```

### report_clips: upload own

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'report_clips'::text) AND can_upload_report_clip(name))
```

### sounds: delete own folder

- command: DELETE
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'sounds'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```

### sounds: read

- command: SELECT
- roles: authenticated
- permissive

USING

```sql
((bucket_id = 'sounds'::text) AND (((storage.foldername(name))[1] = (auth.uid())::text) OR is_site_admin()))
```

### sounds: upload own folder

- command: INSERT
- roles: authenticated
- permissive

WITH CHECK

```sql
((bucket_id = 'sounds'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
```
