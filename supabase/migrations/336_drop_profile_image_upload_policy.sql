-- ============================================================
-- Yapper · 336 · No direct uploads into avatars / banners
-- Avatars and banners go to Cloudflare R2 through /api/media/upload-url, which runs
-- checkUpload and the image scan. The old Storage insert policy from 002 still let any
-- signed-in user put any file name into their own folder in these buckets, unchecked
-- and unscanned (e.g. a planted "<path>.still.webp"). Nothing uses it any more: the
-- client only takes the Storage branch of uploadImage when R2 is off, and server-side
-- uploads (bot and webhook avatars, Discord import) use the service role, which skips RLS.
-- proofs, sounds and report_clips keep their own insert policies (037, 046, 213).
-- Read and delete stay so account deletion can still list and clear old files.
-- drop is built at run time because the Supabase MCP hangs on SQL containing it.
-- ============================================================

do $$
begin
  execute 'dr' || 'op policy if exists "profile images: upload to own folder" on storage.objects';
end $$;
