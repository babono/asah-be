-- =============================================================================
-- Training videos in Supabase Storage
--
-- Cloudflare Stream stays the home for videos (stream-upload, stream-tus-upload).
-- Until it is set up, and for short demo clips, an MP4 can live in the
-- asah-media bucket instead: stream-playback returns a signed Storage URL for
-- any media_files row with bucket = 'asah-media'. Free-plan Storage caps a file
-- at 50 MB, which the bucket limit already matches.
-- =============================================================================
update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf',
                                  'video/mp4', 'video/quicktime']
 where id = 'asah-media';
