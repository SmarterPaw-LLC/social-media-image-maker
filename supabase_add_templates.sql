-- ============================================================================
-- SmarterPaw Social Image Tool — Team-shared templates (v356+)
-- Run in Supabase → SQL Editor → New query → paste → Run.
-- Prereqs:
--   supabase_auth_setup.sql
-- ============================================================================
-- What this migration does:
--   1. Creates public.template_items — metadata (name, thumbnail, storage_path,
--      layers_count, uploaded_by, created_at, updated_at). Every authenticated
--      user can read/insert/update/delete rows (team library semantics — same as
--      image-library). Individual ownership is tracked via uploaded_by but does
--      NOT gate access.
--   2. Creates a public template-states Storage bucket for the actual serialized
--      layers JSON (multi-MB with image base64), same pattern as design-states.
--      50 MB per-file cap so image-heavy templates still fit.
-- ============================================================================

-- 1. template_items table ------------------------------------------------------
create table if not exists public.template_items (
  id            bigserial primary key,
  name          text not null,
  thumbnail     text,                       -- small JPEG data URI for the card
  storage_path  text not null,              -- '{uuid}.json' in template-states bucket
  layers_count  int default 0,
  uploaded_by   uuid references auth.users(id) on delete set null,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

comment on table public.template_items is
  'Team-shared design templates. Metadata + thumbnail here; the actual serialized layers JSON lives in the template-states Storage bucket (referenced by storage_path). Any authenticated user can read + write.';

create index if not exists template_items_updated_at_idx
  on public.template_items (coalesce(updated_at, created_at) desc);

-- 2. RLS on template_items -----------------------------------------------------
alter table public.template_items enable row level security;

drop policy if exists "auth_select_templates" on public.template_items;
create policy "auth_select_templates" on public.template_items
  for select using (auth.uid() is not null);

drop policy if exists "auth_insert_templates" on public.template_items;
create policy "auth_insert_templates" on public.template_items
  for insert with check (auth.uid() is not null);

drop policy if exists "auth_update_templates" on public.template_items;
create policy "auth_update_templates" on public.template_items
  for update using (auth.uid() is not null);

drop policy if exists "auth_delete_templates" on public.template_items;
create policy "auth_delete_templates" on public.template_items
  for delete using (auth.uid() is not null);

-- 3. template-states Storage bucket --------------------------------------------
-- Public read (CDN-served like image-library), auth-gated writes. 50 MB per file
-- covers image-heavy templates without inviting truly extreme uploads.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('template-states', 'template-states', true, 50 * 1024 * 1024, ARRAY['application/json'])
on conflict (id) do update set
  public              = true,
  file_size_limit     = 50 * 1024 * 1024,
  allowed_mime_types  = ARRAY['application/json'];

-- 4. RLS on storage.objects for the template-states bucket ---------------------
-- Names include the bucket to avoid collisions with policies for other buckets
-- (image-library, design-states, etc.).
drop policy if exists "templates_bucket_select" on storage.objects;
create policy "templates_bucket_select" on storage.objects
  for select using (bucket_id = 'template-states');

drop policy if exists "templates_bucket_insert" on storage.objects;
create policy "templates_bucket_insert" on storage.objects
  for insert with check (bucket_id = 'template-states' and auth.uid() is not null);

drop policy if exists "templates_bucket_update" on storage.objects;
create policy "templates_bucket_update" on storage.objects
  for update using (bucket_id = 'template-states' and auth.uid() is not null);

drop policy if exists "templates_bucket_delete" on storage.objects;
create policy "templates_bucket_delete" on storage.objects
  for delete using (bucket_id = 'template-states' and auth.uid() is not null);

-- Verify -----------------------------------------------------------------------
--   select count(*) from public.template_items;
--   select id, public, file_size_limit from storage.buckets where id = 'template-states';
--   select policyname from pg_policies where tablename = 'template_items';
--   select policyname from pg_policies where tablename = 'objects' and policyname like 'templates_bucket%';
