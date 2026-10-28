-- 494: flag export_status (test): Download your data says when the copy isn't complete (security pass 2, O3). The
-- file always ends with per-section counts, what was cut at a limit and what couldn't be loaded, plus complete:
-- true/false; with the flag the app shows that under the Download button instead of a plain "downloading" toast.
-- Data only, re-runnable.
insert into public.feature_flags (key, label, description, mode, servers, users)
values ('export_status', 'Data export: say when it is partial', 'Download your data warns when sections were cut short or could not be loaded', 'test',
        '{00000000-0000-4000-8000-00000000b001}', '{00000000-0000-4000-8000-00000000a001}')
on conflict (key) do nothing;
