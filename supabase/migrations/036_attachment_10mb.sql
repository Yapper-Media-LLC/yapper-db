-- Attachments (images, video, audio) capped at 10 MB, like Discord without Nitro.
update storage.buckets set file_size_limit = 10485760 where id = 'attachments';
