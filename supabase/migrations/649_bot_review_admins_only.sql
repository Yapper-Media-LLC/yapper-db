-- 649: bot review is admins only (Antic, Oct 28: "remove bot review from moderators, head mods, and the other. Just
-- leave it for me."). can_review_bots (366, widened by 634 for Dev Managers) gates bot_review_queue and
-- admin_verify_bot: back to admins. The mod_bot_review flag (366) goes off so the Mod Center stops showing the queue
-- to mods; Dev Managers keep bot promotions, the dev report and suspending a bot (634). Re-runnable.
create or replace function public.can_review_bots()
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select public.is_site_admin();
$$;
update public.feature_flags set mode = 'off', updated_at = now() where key = 'mod_bot_review' and mode <> 'off';
