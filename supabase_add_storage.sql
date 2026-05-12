-- ============================================================================
-- SmarterPaw Social Image Tool — Move design state to Supabase Storage (v119+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_social_designs_setup.sql already run on this project.
-- ============================================================================
-- v118 stored the full design state (including base64 image data URIs) in the
-- social_designs.state jsonb column. For image-heavy designs the payload would
-- balloon to 10+ MB, which hit Cloudflare's gateway timeouts — Supabase
-- returned 520/502 errors with the request body never reaching PostgREST in
-- time. This migration moves state out to Supabase Storage:
--
--   - New bucket `design-states` (private) holds one JSON file per design
--   - Path convention: `{user_id}/{design_id}.json`
--   - Per-user RLS via storage.objects: users can only read/write their own folder
--   - social_designs.state jsonb is now nullable; new saves leave it null and
--     upload the payload to Storage. Old rows still have state in jsonb and the
--     JS client reads from whichever location is populated (back-compat).
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Relax NOT NULL on state so new rows can leave it empty while the payload
--    lives in Storage instead.
-- ──────────────────────────────────────────────────────────────────────────
alter table public.social_designs alter column state drop not null;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Create the storage bucket (idempotent). Private — access only via the
--    authenticated client; not publicly downloadable. file_size_limit raised
--    from the 50 MB default to 200 MB so image-heavy design states (with
--    base64 data URIs embedded) can fit.
--    Note: each 100 MB design consumes 10% of the free tier's 1 GB total
--    storage quota. The proper long-term fix is to move image data URIs out
--    of state.json into separate Storage files referenced by URL, so design
--    state stays under a few KB.
-- ──────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
  values ('design-states', 'design-states', false, 209715200)
  on conflict (id) do update set file_size_limit = 209715200;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Storage RLS — per-user isolation on storage.objects, scoped to this bucket.
--    File names start with `{user_id}/`, so `(storage.foldername(name))[1]`
--    returns the user_id segment.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "design-states: read own"   on storage.objects;
drop policy if exists "design-states: insert own" on storage.objects;
drop policy if exists "design-states: update own" on storage.objects;
drop policy if exists "design-states: delete own" on storage.objects;

create policy "design-states: read own" on storage.objects
  for select to authenticated
  using (bucket_id = 'design-states' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "design-states: insert own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'design-states' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "design-states: update own" on storage.objects
  for update to authenticated
  using (bucket_id = 'design-states' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'design-states' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "design-states: delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'design-states' and (storage.foldername(name))[1] = auth.uid()::text);

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select id, public from storage.buckets where id = 'design-states';
--   select polname from pg_policy where polname like 'design-states%';
-- ============================================================================
