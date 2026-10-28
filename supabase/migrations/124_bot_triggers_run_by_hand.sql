-- Run this in the Supabase SQL editor (creating triggers is blocked from the assistant's tools).
-- The functions are already live (migration 123); this only hooks them up.

-- Logger, Starboard, Giveaways
drop trigger if exists messages_logger on public.messages;
create trigger messages_logger after update of content or delete on public.messages for each row execute function public.logger_messages();
drop trigger if exists server_members_logger on public.server_members;
create trigger server_members_logger after insert or delete on public.server_members for each row execute function public.logger_members();
drop trigger if exists server_bans_logger on public.server_bans;
create trigger server_bans_logger after insert or delete on public.server_bans for each row execute function public.logger_bans();
drop trigger if exists server_timeouts_logger on public.server_timeouts;
create trigger server_timeouts_logger after insert or update on public.server_timeouts for each row execute function public.logger_timeouts();
drop trigger if exists member_roles_logger on public.member_roles;
create trigger member_roles_logger after insert or delete on public.member_roles for each row execute function public.logger_roles();
drop trigger if exists reactions_starboard on public.reactions;
create trigger reactions_starboard after insert on public.reactions for each row execute function public.starboard_react();
drop trigger if exists messages_giveaways on public.messages;
create trigger messages_giveaways after insert on public.messages for each row execute function public.giveaway_cmd();

-- Impersonation: no check marks in names, nobody else can take a verified creator's channel name,
-- verified accounts can't use brand or country names.
drop trigger if exists profiles_impersonation_guard on public.profiles;
create trigger profiles_impersonation_guard before insert or update of username, display_name on public.profiles for each row execute function public.profile_impersonation_guard();
drop trigger if exists profiles_verified_name_guard on public.profiles;
create trigger profiles_verified_name_guard before update of username, display_name, verified_as on public.profiles for each row execute function public.verified_name_guard();
