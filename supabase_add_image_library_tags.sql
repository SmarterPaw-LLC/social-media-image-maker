-- ============================================================================
-- SmarterPaw Social Image Tool — Tags on image library items (v142+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_add_image_library.sql already run.
-- ============================================================================
-- Adds a free-form tag list to each library item. Stored as text[] (array
-- column) rather than a separate join table because the team's library is
-- small enough that per-row tags read/write/index cleanly without joins.
-- Tags are stored lowercase, deduped on the JS side before save.
--
-- A GIN index supports fast `tags @> ARRAY['logo']` style contains queries
-- when we add tag-based filtering in the JS client.
-- ============================================================================

alter table public.image_library_items
  add column if not exists tags text[] not null default '{}'::text[];

create index if not exists image_library_items_tags_gin
  on public.image_library_items using gin (tags);

-- Verify
--   select id, name, tags from public.image_library_items limit 5;
-- ============================================================================
