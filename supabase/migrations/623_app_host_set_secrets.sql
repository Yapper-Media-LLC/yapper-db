-- 623: app_host_set_secrets(jsonb): upsert rows into app_host.secrets (migration 600) from server-side code running
-- with the service role. Used once by /api/admin/env-copy on Vercel to copy the production env (Sensitive in Vercel,
-- not readable from any dashboard) into the table the app host reads at start (ops/app/start.mjs), so Antic doesn't
-- retype 15+ keys from 11 provider dashboards. Only service_role may call it; it returns names and lengths, never
-- values. Same name rule and length cap as the table. Re-runnable.

create or replace function public.app_host_set_secrets(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  k text;
  v text;
  done jsonb := '{}'::jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return done;
  end if;
  for k, v in select * from jsonb_each_text(p) loop
    if k !~ '^[A-Z][A-Z0-9_]{1,63}$' or v is null or length(v) < 1 or length(v) > 4096 then
      continue;
    end if;
    insert into app_host.secrets (name, value) values (k, v)
      on conflict (name) do update set value = excluded.value, updated_at = now();
    done := done || jsonb_build_object(k, length(v));
  end loop;
  return done;
end;
$$;

revoke all on function public.app_host_set_secrets(jsonb) from public, anon, authenticated;
grant execute on function public.app_host_set_secrets(jsonb) to service_role;
