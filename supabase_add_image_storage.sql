-- ============================================================================
-- SmarterPaw Social Image Tool — Per-image Storage for design layers (v122+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_add_storage.sql already run on this project.
-- ============================================================================
-- The v119 design-states bucket holds the full state JSON. When designs include
-- many embedded images as base64 data URIs (which is how this tool stored them
-- through v121), the state.json balloons to 60-100+ MB — over Supabase free
-- tier's per-file Storage cap. v122 fixes this by externalizing image bytes:
--
--   - New private bucket `design-images` (one image file per unique image hash)
--   - Image layers in design state hold a tiny `sb-image:{path}` marker instead
--     of the full data URI
--   - On cloud save: each image is uploaded once (content-addressable by SHA256)
--     and the data URI is replaced with the marker in the state copy that goes
--     to the design-states bucket. Original in-memory state and IDB cache keep
--     full data URIs so offline / file-save paths are unaffected.
--   - On cloud load: markers are resolved back to data URIs before applying
--     state to the canvas.
--
-- Result: a design state with 5 image layers shrinks from ~60 MB to ~2 KB.
-- Images themselves live in design-images, deduplicated across designs.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Create the design-images bucket. Private; per-image cap 15 MB (plenty
--    for a single PNG/JPG even at high res). Content-addressable so the same
--    image used in multiple designs only consumes one slot.
-- ──────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
  values ('design-images', 'design-images', false, 15728640)
  on conflict (id) do update set file_size_limit = 15728640;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. RLS — per-user isolation, same pattern as design-states.
--    Paths look like `{user_id}/{sha256_short}.{ext}`, so the first folder
--    segment must equal the caller's auth.uid().
-- ──────────────────────────────────────────────────────────────────────────
-- v138: collapsed to a single `for all` policy. The previous split CRUD policies didn't cover
-- the internal SELECT that `upsert: true` triggers to decide insert-vs-update, which caused
-- silent image upload failures (designs would save with full data URIs still embedded, no
-- size reduction). One policy covering all four ops fixes it cleanly while preserving the
-- per-user isolation (path's first folder segment must equal auth.uid()).
drop policy if exists "design-images: read own"        on storage.objects;
drop policy if exists "design-images: insert own"      on storage.objects;
drop policy if exists "design-images: update own"      on storage.objects;
drop policy if exists "design-images: delete own"      on storage.objects;
drop policy if exists "design-images: full access own" on storage.objects;

create policy "design-images: full access own" on storage.objects
  for all to authenticated
  using (bucket_id = 'design-images' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'design-images' and (storage.foldername(name))[1] = auth.uid()::text);

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select id, file_size_limit, public from storage.buckets where id = 'design-images';
--   select polname from pg_policy where polname like 'design-images%';
-- ============================================================================
