-- 233: turn the member_roles live broadcast back on.
-- member_roles_bc (048) was disabled by hand during the Oct 16 load incident and never re-enabled, so nobody saw a
-- role they were given (or lost) until they reloaded: no colour, no perks, no newly opened channels (~8 bug reports).
-- The realtime server also never re-checked channel access after a role was removed. The client side that made it
-- costly is gone: applyMemberRoleChange (lib/actions.ts) patches memberRoles locally instead of reloading roles.
-- Volume: member_roles sees ~4% as many writes as messages, which already broadcast one event each.
-- Re-runnable: enabling an enabled trigger is a no-op.
alter table public.member_roles enable trigger member_roles_bc;
