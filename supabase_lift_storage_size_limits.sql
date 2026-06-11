-- ============================================================================
-- SmarterPaw Social Image Tool — lift Supabase storage bucket file_size_limits
-- ============================================================================
-- The original setup scripts capped buckets at conservative sizes appropriate
-- for free-tier sanity-checks (design-states = 200 MiB; design-images = 15
-- MiB). On paid Supabase plans these per-bucket caps are unnecessary — the
-- plan ceiling (single-file 50 GB on Pro) is the only ceiling that matters.
--
-- This migration removes the per-bucket file_size_limit for both buckets so
-- saves of large designs (image-heavy compositions with many embedded base64
-- data URLs) don't hit "The object exceeded the maximum allowed size".
--
-- Run via: Supabase dashboard → SQL Editor → New query → paste → Run.
-- Idempotent — safe to re-run.
-- ============================================================================

-- design-states: per-design JSON payload, can grow large with many image layers
update storage.buckets
   set file_size_limit = null
 where id = 'design-states';

-- design-images: shared image library uploads, can be high-res photos
update storage.buckets
   set file_size_limit = null
 where id = 'design-images';

-- Verify with:
--   select id, file_size_limit from storage.buckets
--   where id in ('design-states', 'design-images');
-- Both rows should show file_size_limit = NULL.
-- ============================================================================
