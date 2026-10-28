-- 470 (was 464 on feat/mutuals-in-card; 464 was taken live by appearance_revamp): flag mutuals_in_card, published to
-- everyone (Antic, Oct 24). The mutual friends/servers side panel next to the full profile card is gone; the card gets
-- a "Mutual friends / Mutual servers" section under About me instead (tabs, first 5 rows, "Show all"). Clicking the
-- mutuals summary under the name scrolls to it. Client only (ProfileCard.tsx, MiniProfileCard.tsx). Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('mutuals_in_card', 'Mutuals inside the profile card', 'Mutual friends and servers as a section inside the profile card instead of a side panel next to it', 'everyone',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do update set mode = 'everyone', updated_at = now();
