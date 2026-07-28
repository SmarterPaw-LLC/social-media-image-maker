-- ============================================================================
-- SmarterPaw Social Image Tool — Original creation-date on library items (v339+)
-- Run in Supabase → SQL Editor → New query → paste → Run.
-- Prereqs:
--   supabase_auth_setup.sql
--   image_library_items already exists (v128+)
-- Optional dependency:
--   supabase_add_library_video.sql (v338) — parallel columns / concerns
-- ============================================================================
-- What this migration does:
--   1. Adds `original_created_at TIMESTAMPTZ` column to image_library_items — populated at
--      upload time from EXIF DateTimeOriginal (photos) or the mp4/mov mvhd creation_time
--      (videos), or `file.lastModified` as a fallback. Nullable, so historical rows uploaded
--      before this feature landed keep working — the filter falls back to `created_at`
--      (upload date) via COALESCE.
--   2. Adds an index for date-range filters. `created_at` alone isn't a great fallback index
--      because COALESCE prevents a single column index from being used; the expression index
--      below lets a WHERE COALESCE(original_created_at, created_at) BETWEEN … query plan.
--
-- The companion UGC clip editor project can filter the same table by capture date with:
--   SELECT * FROM public.image_library_items
--    WHERE COALESCE(original_created_at, created_at) BETWEEN $1 AND $2
--    ORDER BY COALESCE(original_created_at, created_at) DESC;
-- ============================================================================

-- 1. original_created_at column ---------------------------------------------------------------
ALTER TABLE public.image_library_items
  ADD COLUMN IF NOT EXISTS original_created_at timestamptz;

COMMENT ON COLUMN public.image_library_items.original_created_at IS
  'Wall-clock time the media was originally created (EXIF DateTimeOriginal for photos, mvhd '
  'creation_time for mp4/mov, file.lastModified as fallback). Nullable — historical rows have '
  'this as NULL and the app filter falls back to created_at (upload date) via COALESCE.';

-- 2. Expression index on the effective date ---------------------------------------------------
-- COALESCE(original_created_at, created_at) is what the app filters on, so index that expression
-- directly. IMMUTABLE-safe: both columns are timestamptz and COALESCE of same-type expressions is
-- immutable.
CREATE INDEX IF NOT EXISTS image_library_items_effective_date_idx
  ON public.image_library_items ((COALESCE(original_created_at, created_at)) DESC);

-- 3. Verify -----------------------------------------------------------------------------------
--   SELECT column_name, data_type
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'image_library_items'
--      AND column_name = 'original_created_at';
--
--   SELECT indexname, indexdef
--     FROM pg_indexes
--    WHERE schemaname = 'public'
--      AND tablename  = 'image_library_items'
--      AND indexname  = 'image_library_items_effective_date_idx';
-- ============================================================================
