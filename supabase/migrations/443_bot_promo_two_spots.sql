-- 443: two Promoted bot spots on /bots instead of four (Antic, Oct 23). bot_promo_slots() decides how many run at once,
-- where a new booking starts (next_bot_promo_start) and how many promoted_bots() shows. Re-runnable.
create or replace function public.bot_promo_slots()
returns integer language sql immutable as $$ select 2 $$;
