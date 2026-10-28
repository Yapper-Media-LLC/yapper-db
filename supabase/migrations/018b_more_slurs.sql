-- ============================================================
-- Yapper · Catch the spellings people used to dodge the slur filter
-- (nga, neggre, niggre, niggr, nigr, nig…)
-- ============================================================
create or replace function public.has_slur(t text)
returns boolean
language sql
immutable
as $$
  select
    -- whole words
    (' ' || public.slur_text(t) || ' ') ~ (
      ' (s+a+n+d+)?(n+[iy]+g+(g+)?(e+r+|r+e*|a+|a+h+|a+z+|u+h+|e+r+z+|l+e+t+)?s*'
      || '|n+e+g+g+(e+r+|r+e*|a+)s*|n+g+a+s*'
      || '|f+a+g+(g+[oei]+t+)?s*|k+i+k+e+s*|s+p+i+c+s*|w+e+t+b+a+c+k+s*|t+r+a+n+n+(y+|i+e+)s*'
      || '|r+e+t+a+r+d+(s+|e+d+)?|g+o+o+k+s*|b+e+a+n+e+r+s*) '
    )
    -- the worst ones, even glued inside other words ("xniggerx")
    or replace(public.slur_text(t), ' ', '') ~ 'n+[iy]+g+g+(e+r+|a+|r+e*)|n+e+g+g+(e+r+|r+e*|a+)|f+a+g+g+[oei]+t+';
$$;
