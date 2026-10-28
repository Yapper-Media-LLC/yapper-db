-- 604: flag staff_applications back to test (test server + Antic), Antic's call Oct 27 after 590 published it. Data only, re-runnable.
update public.feature_flags set mode = 'test', servers = '{00000000-0000-4000-8000-00000000b001}', users = '{00000000-0000-4000-8000-00000000a001}'
  where key = 'staff_applications' and mode <> 'test';
