-- Profile effects: an animated frame around your avatar, picked in Settings → My Account. Free for everyone.
-- Flag `profile_effects` gates the picker and the rendering.

alter table public.profiles add column if not exists profile_effect text;
grant select (profile_effect) on public.profiles to anon, authenticated;
grant update (profile_effect) on public.profiles to authenticated;

-- Only the known effects (the trigger name is historical: effects started as a Plus perk).
create or replace function public.profile_effect_plus_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.profile_effect is not null and new.profile_effect not in ('glow', 'rainbow', 'fire', 'ice', 'gold', 'sparkle', 'galaxy', 'neon', 'hearts', 'toxic') then
    raise exception 'Unknown profile effect';
  end if;
  return new;
end; $$;
create or replace trigger profile_effect_plus_only before update of profile_effect on public.profiles
  for each row execute function public.profile_effect_plus_only();

insert into public.feature_flags (key, label, description, mode, users)
  values ('profile_effects', 'Profile effects', 'Animated avatar frames (Settings → My Account)', 'test', array['00000000-0000-4000-8000-00000000a001']::uuid[])
  on conflict (key) do nothing;
