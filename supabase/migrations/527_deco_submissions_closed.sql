-- 527: pause community deco submissions (flag deco_submissions_closed, published to everyone). Data only, no schema reload.
-- While it's on, Make a decoration shows "we've got enough for now" instead of the upload form. Your own
-- decorations stay listed (take down, delete, prices). Only the app checks it: submit_community_deco doesn't.
-- To open submissions again: set the flag to off in Admin, Features.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('deco_submissions_closed', 'Pause deco submissions', 'Make a decoration says we have enough submissions for now and hides the upload form', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{}')
on conflict (key) do update set mode = 'everyone', updated_at = now();
