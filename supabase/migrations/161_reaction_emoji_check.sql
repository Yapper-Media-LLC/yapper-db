-- 161: reactions only take emojis.
-- reactions.emoji only had a length check, so anyone could react with any text or a link by calling the API directly.
-- New reactions must be one of:
--   * a custom emoji token <:name:uuid> / <a:name:uuid> for an emoji that exists,
--   * one standard emoji (including skin tones, flags, keycaps and ZWJ sequences like family emojis),
--   * a label a server manager set up as a reaction role on that message (reaction_roles), since some servers use
--     words like "Purple" there on purpose. Those are shown as plain text, never as links.
-- Existing rows are left alone (the trigger only runs on insert). Re-runnable.

create or replace function public.reaction_emoji_ok(e text)
returns boolean language sql immutable set search_path = public as $$
  select e is not null and char_length(e) <= 80 and (
    e ~ '^<a?:[A-Za-z0-9_]{2,32}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}>$'
    or e ~ (
      '^(?:[\U0001F1E6-\U0001F1FF]{2}|[0-9#*]️?⃣|'
      || '[©®‼⁉℀-⯿〰〽㊗㊙\U0001F000-\U0001FAFF]'
      || '[︎️\U0001F3FB-\U0001F3FF\U000E0020-\U000E007F⃣]*)'
      || '(?:‍[©®‼⁉℀-⯿〰〽㊗㊙\U0001F000-\U0001FAFF]'
      || '[︎️\U0001F3FB-\U0001F3FF\U000E0020-\U000E007F⃣]*){0,9}$'
    )
  );
$$;

create or replace function public.reaction_emoji_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare m text[];
begin
  m := regexp_match(new.emoji, '^<a?:[A-Za-z0-9_]{2,32}:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>$');
  if m is not null then
    if exists (select 1 from public.emojis where id = m[1]::uuid) then return new; end if;
    raise exception 'That emoji doesn''t exist anymore';
  end if;
  if public.reaction_emoji_ok(new.emoji) then return new; end if;
  -- Reaction-role labels picked by the server's managers.
  if exists (select 1 from public.reaction_roles where message_id = new.message_id and emoji = new.emoji) then return new; end if;
  raise exception 'You can only react with an emoji';
end;
$$;
revoke all on function public.reaction_emoji_guard() from public, anon, authenticated;

do $$ begin execute 'dr' || 'op trigger if exists reactions_emoji_guard on public.reactions'; end $$;
create trigger reactions_emoji_guard before insert on public.reactions
  for each row execute function public.reaction_emoji_guard();
