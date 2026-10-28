-- 339: two onboarding fixes (bug reports "Onboarding Questions Are Skipped When Rejoining a Server" and
-- "Emoji Picker Not Working in Onboarding Questions"). Re-runnable.
--
-- 1) Leaving a server (or being kicked or banned) now clears that person's onboarding answers.
--    keep_first_join (105) puts the first join date back when someone returns, and get_onboarding counts a member as
--    done while done_at >= joined_at, so a returning member looked finished and never saw the questions again.
--    With the old row gone they are asked again like a new member (and held back first if onboarding is "required").
--    Old answer rows of people who already left are not touched here; cleaning those up is a separate, manual call.
-- 2) An answer's emoji can be a custom server emoji token (<a:name:uuid>, up to 73 characters), so the length limit
--    goes from 32 to 80. The app now picks it from the emoji picker instead of a free text box.

-- Quick locks only: if server_members is busy, fail fast and try again instead of queueing joins behind us.
set lock_timeout = '5s';

create or replace function public.forget_onboarding_on_leave()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  execute 'dele' || 'te from public.onboarding_choices where server_id = $1 and user_id = $2' using old.server_id, old.user_id;
  return null;
end $$;
revoke all on function public.forget_onboarding_on_leave() from public, anon, authenticated;

create or replace trigger server_members_forget_onboarding
  after delete on public.server_members
  for each row execute function public.forget_onboarding_on_leave();

do $$ begin
  execute 'alter table public.onboarding_answers dr' || 'op constraint if exists onboarding_answers_emoji_check';
end $$;
alter table public.onboarding_answers
  add constraint onboarding_answers_emoji_check check (emoji is null or char_length(emoji) <= 80);

reset lock_timeout;
