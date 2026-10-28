-- 531: creator_program published to everyone (Antic, Oct 26: "publish"). 518 (payout safety, invite links) went live
-- first, at 09:31 UTC. Data only, re-runnable.
update public.feature_flags set mode = 'everyone', updated_at = now() where key = 'creator_program' and mode <> 'everyone';
