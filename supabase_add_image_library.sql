-- ============================================================================
-- SmarterPaw Social Image Tool — Shared image library (v126+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_auth_setup.sql already run on this project.
-- ============================================================================
-- A team-wide reusable image library, so brand assets (product photos, logos,
-- backgrounds) can be uploaded once and used across many designs by anyone on
-- the team. Distinct from `design-images` which is per-user and exists only to
-- shrink saved design states; this is a curated catalog.
--
--   - `image_library_categories` — flat list of category names (e.g. "Products",
--     "Logos", "Backgrounds"). No nesting in MVP; can be added later.
--   - `image_library_items` — one row per image, linking name + category +
--     storage_path. Uploader tracked via auth.users.
--   - `image-library` Storage bucket — public read (so browsers can render
--     thumbnails via direct public URL with no extra signing), authenticated
--     write/delete. Path is content-addressed (sha256) so identical re-uploads
--     dedupe automatically. 15 MB per-file cap.
--   - RLS: any signed-in user can read/write/delete (it's a shared team
--     resource, not per-user).
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Tables
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.image_library_categories (
  id          bigserial primary key,
  name        text not null,
  created_at  timestamptz not null default now(),
  constraint  image_library_categories_name_unique unique (name)
);

create table if not exists public.image_library_items (
  id              bigserial primary key,
  name            text not null,
  storage_path    text not null,  -- path within `image-library` bucket
  category_id     bigint references public.image_library_categories(id) on delete set null,
  mime            text,
  file_size_bytes bigint,
  uploaded_by     uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists image_library_items_category_idx
  on public.image_library_items(category_id, created_at desc);
create index if not exists image_library_items_created_idx
  on public.image_library_items(created_at desc);

-- updated_at auto-touch
create or replace function image_library_items_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists image_library_items_touch_trg on public.image_library_items;
create trigger image_library_items_touch_trg
  before update on public.image_library_items
  for each row execute function image_library_items_touch();

-- ──────────────────────────────────────────────────────────────────────────
-- 2. RLS — shared across the team; any authenticated user can CRUD
-- ──────────────────────────────────────────────────────────────────────────
alter table public.image_library_categories enable row level security;
drop policy if exists "lib categories: all authenticated" on public.image_library_categories;
create policy "lib categories: all authenticated" on public.image_library_categories
  for all to authenticated using (true) with check (true);

alter table public.image_library_items enable row level security;
drop policy if exists "lib items: all authenticated" on public.image_library_items;
create policy "lib items: all authenticated" on public.image_library_items
  for all to authenticated using (true) with check (true);

grant select, insert, update, delete on public.image_library_categories to authenticated;
grant select, insert, update, delete on public.image_library_items to authenticated;
grant usage, select on sequence image_library_categories_id_seq to authenticated;
grant usage, select on sequence image_library_items_id_seq to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Storage bucket — public read, authenticated write/delete.
--    Content-addressed paths (sha256 of base64) mean identical uploads dedupe.
--    15 MB per-file cap fits any reasonable single PNG/JPG; well under free
--    tier's 50 MB project cap.
-- ──────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
  values ('image-library', 'image-library', true, 15728640)
  on conflict (id) do update set public = true, file_size_limit = 15728640;

-- Storage RLS — read is public via the bucket flag, so only insert/update/delete need policies
drop policy if exists "image-library: insert auth" on storage.objects;
drop policy if exists "image-library: update auth" on storage.objects;
drop policy if exists "image-library: delete auth" on storage.objects;

create policy "image-library: insert auth" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'image-library');
create policy "image-library: update auth" on storage.objects
  for update to authenticated
  using (bucket_id = 'image-library')
  with check (bucket_id = 'image-library');
create policy "image-library: delete auth" on storage.objects
  for delete to authenticated
  using (bucket_id = 'image-library');

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select count(*) from public.image_library_categories;  -- 0 on fresh install
--   select count(*) from public.image_library_items;       -- 0
--   select id, public, file_size_limit from storage.buckets where id = 'image-library';
-- ============================================================================
