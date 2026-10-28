-- 456: sponsored GIFs off (flag gif_ads -> off, applied live 24 Oct 07:49 UTC). KLIPY paid about 5 cents per thousand
-- views with a 25% fill after two days; Antic called it. The picker and free GIFs stay; the code path is still there
-- behind the flag. Flag flip only, no DDL.
update public.feature_flags set mode = 'off', updated_at = now() where key = 'gif_ads';
