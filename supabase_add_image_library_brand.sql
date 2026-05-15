-- ============================================================================
-- SmarterPaw Social Image Tool — Brand on image library items (v175+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_add_image_library.sql already run.
-- ============================================================================
-- Adds a `brand` dimension to each library item so brand assets can be filtered
-- and bulk-organized by the brand they belong to. Distinct from `category` (a
-- free-form curated grouping) and `tags` (free-form labels) — brand is a small
-- fixed enumeration matching the three SmarterPaw product lines.
--
-- Stored as plain text holding one of: 'meowi' (Meowijuana), 'doggi'
-- (Doggijuana), 'kkz' (Kitty Ka-Zoom), or NULL (unassigned). Not a DB enum so
-- new brands can be added later without a schema migration — the JS client is
-- the source of truth for the valid set.
--
-- A btree index supports `where brand = 'meowi'` style filter queries should the
-- JS client ever move filtering server-side (it currently filters in-memory).
-- ============================================================================

alter table public.image_library_items
  add column if not exists brand text;

create index if not exists image_library_items_brand_idx
  on public.image_library_items(brand);

-- Verify
--   select id, name, brand from public.image_library_items limit 5;
-- ============================================================================
