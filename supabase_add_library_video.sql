-- ============================================================================
-- SmarterPaw Social Image Tool — Video support in the shared media library (v338+)
-- Run in Supabase → SQL Editor → New query → paste → Run.
-- Prereqs:
--   supabase_auth_setup.sql
--   image-library storage bucket already exists (v128+)
--   image_library_items table already exists (v128+)
-- ============================================================================
-- What this migration does:
--   1. Adds `thumbnail_data_uri` column to image_library_items so the app can render a poster
--      frame for video items without downloading the whole file. Nullable, so existing image
--      rows are unaffected.
--   2. Widens the image-library storage bucket's mime-type allowlist to include the video
--      formats the app supports (mp4, webm, mov).
--   3. Bumps the per-file upload limit to 200 MB so short-form video clips fit. (Storage
--      billing is per-GB stored + per-GB egressed regardless — this just lets a single file
--      through the upload endpoint.)
--
-- The companion UGC clip editor project (also a Claude Code app) will read from this same
-- table via the same Supabase project. It can pull every video the user owns with:
--   SELECT id, name, storage_path, mime, file_size_bytes, thumbnail_data_uri, tags, brand,
--          created_at
--     FROM public.image_library_items
--    WHERE mime LIKE 'video/%' OR storage_path ~* '\.(mp4|webm|mov|m4v)$'
--    ORDER BY created_at DESC;
-- and stream the bytes from `storage.objects` at bucket_id='image-library', name=storage_path.
-- RLS on image_library_items already scopes to the current user, so no extra policies needed.
-- ============================================================================

-- 1. thumbnail_data_uri column ---------------------------------------------------------------
ALTER TABLE public.image_library_items
  ADD COLUMN IF NOT EXISTS thumbnail_data_uri text;

COMMENT ON COLUMN public.image_library_items.thumbnail_data_uri IS
  'Base64 JPEG poster frame for video items (nullable). Generated client-side at upload time; ~5-30 KB per row. Images leave this NULL and render from the storage bucket via getPublicUrl.';

-- 2. Widen the storage bucket's allowed mime types + file size ---------------------------------
-- If allowed_mime_types is currently NULL, any type is accepted; keeping it explicit makes the
-- allow-list visible in the dashboard AND documents what the app supports. If a bucket-owner has
-- customized this list, this UPDATE overwrites — adjust the array below to preserve extras.
UPDATE storage.buckets
   SET allowed_mime_types = ARRAY[
         'image/jpeg','image/png','image/gif','image/webp','image/svg+xml','image/avif',
         'image/heic','image/heif','image/bmp','image/x-icon',
         'video/mp4','video/webm','video/quicktime'
       ],
       file_size_limit = 200 * 1024 * 1024   -- 200 MB per file
 WHERE id = 'image-library';

-- 3. Verify -----------------------------------------------------------------------------------
--   SELECT column_name, data_type
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'image_library_items'
--      AND column_name = 'thumbnail_data_uri';
--
--   SELECT id, public, file_size_limit, allowed_mime_types
--     FROM storage.buckets
--    WHERE id = 'image-library';
-- ============================================================================
