-- 585: Shards: new accounts earn after 1 day instead of 3 (Antic, Oct 27). shard_config().min_age_days 3 -> 1; the
-- checks in shards_tick and claim_shard_quest read it, so nothing else moves. claim_shard_quest's refusal text said
-- "1 days", so that line is patched into the live text (pg_get_functiondef, like 537/568): skipped where the function
-- isn't there or is already patched; a changed anchor stops the migration. Invite and buyer ages stay 7. Re-runnable.

set lock_timeout = '3s';

create or replace function public.shard_config()
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'daily', 5, 'per_block', 5, 'block_minutes', 5, 'activity_cap', 25, 'streak_days', 7, 'streak_bonus', 30,
    'min_age_days', 1, 'invite', 100, 'invite_age_days', 7, 'invite_active_days', 3, 'invite_cap_30d', 10,
    'artist_share', 80, 'price_min', 25, 'price_max', 5000, 'buyer_age_days', 7, 'level_step', 100, 'level_max', 100);
$$;

create or replace function pg_temp.patch_fn(sig text, marker text, old_text text, new_text text)
returns void language plpgsql as $$
declare f text;
begin
  if to_regprocedure(sig) is null then return; end if;
  f := pg_get_functiondef(sig::regprocedure);
  if position(marker in f) > 0 then return; end if;
  if position(old_text in f) = 0 then raise exception '585: % changed, patch it by hand', sig; end if;
  execute replace(f, old_text, new_text);
end $$;

select pg_temp.patch_fn('public.claim_shard_quest(text)', 'needs to be % old to earn Shards',
  'raise exception ''Your account needs to be % days old to earn Shards'', cfg->>''min_age_days'';',
  'raise exception ''Your account needs to be % old to earn Shards'', case when (cfg->>''min_age_days'')::int = 1 then ''a day'' else (cfg->>''min_age_days'') || '' days'' end;');

reset lock_timeout;
