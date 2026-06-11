-- ============================================================================
-- SmarterPaw Social Image Tool — Design sharing (v258+)
-- Run in Supabase → SQL Editor → New query → paste → Run.
-- Prereqs (in order):
--   supabase_auth_setup.sql
--   supabase_social_designs_setup.sql
--   supabase_add_folders.sql           (optional but recommended)
--   supabase_add_storage.sql           (REQUIRED — design-states bucket)
--   supabase_add_image_storage.sql     (REQUIRED — design-images bucket)
-- ============================================================================
-- Lets a design's owner grant other signed-in users read access. Two modes:
--   1. Per-user share: pick a teammate by email; only that user can load it.
--   2. Public share ("everyone"): any signed-in user of this Supabase project
--      can load it. Useful for org-wide templates.
--
-- v1 scope: VIEW-only (read). No collaborative edit yet — when a recipient
-- loads a shared design they get their own clone on Save (the JS side never
-- sets _currentCloudId for shared loads, so any Save creates a brand-new row
-- owned by the recipient).
--
-- The table is the single source of truth for share grants. The social_designs
-- RLS policy plus the storage bucket RLS policies use it to widen read access
-- for the right people without ever opening either bucket to the world.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. social_design_shares — one row per (design, recipient) grant.
--    shared_with_user_id is the recipient when this is a per-user share.
--    is_public=true means "anyone signed in"; shared_with_user_id must be null
--    for those rows. The check constraint enforces the XOR.
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.social_design_shares (
  id bigserial primary key,
  design_id bigint not null references public.social_designs(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  shared_with_user_id uuid references auth.users(id) on delete cascade,
  is_public boolean not null default false,
  permission text not null default 'view' check (permission in ('view','edit')),
  created_at timestamptz not null default now(),
  constraint design_share_target_xor check (
    (shared_with_user_id is not null and is_public = false) or
    (shared_with_user_id is null and is_public = true)
  )
);

-- One share row per recipient per design. NULL recipients (the public rows) are
-- excluded — covered by the partial index below.
create unique index if not exists social_design_shares_one_per_recipient
  on public.social_design_shares (design_id, shared_with_user_id)
  where shared_with_user_id is not null;

-- At most one "shared with everyone" row per design.
create unique index if not exists social_design_shares_one_public_per_design
  on public.social_design_shares (design_id)
  where is_public = true;

-- Lookup index for the recipient-side query ("designs shared with me")
create index if not exists social_design_shares_by_recipient
  on public.social_design_shares (shared_with_user_id)
  where shared_with_user_id is not null;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. RLS on social_design_shares — owners manage their own; recipients can
--    SEE the rows that target them so the UI can list "shared with me" and
--    show who else a design has been shared with.
-- ──────────────────────────────────────────────────────────────────────────
alter table public.social_design_shares enable row level security;

drop policy if exists "shares: owner full access"  on public.social_design_shares;
drop policy if exists "shares: recipient read"     on public.social_design_shares;

create policy "shares: owner full access" on public.social_design_shares
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "shares: recipient read" on public.social_design_shares
  for select to authenticated
  using (shared_with_user_id = auth.uid() or is_public = true);

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Widen social_designs RLS so recipients can SELECT shared rows.
--    The owner's existing per-user policy is left intact — this just adds a
--    second SELECT path for designs that have been granted to the caller.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "social_designs: read shared" on public.social_designs;

create policy "social_designs: read shared" on public.social_designs
  for select to authenticated
  using (
    exists (
      select 1 from public.social_design_shares s
      where s.design_id = social_designs.id
        and (s.shared_with_user_id = auth.uid() or s.is_public = true)
    )
  );

-- ──────────────────────────────────────────────────────────────────────────
-- 4. Storage RLS — recipients need to download the state.json from the
--    owner's folder in design-states, AND the per-image blobs in design-images
--    that the state references.
--
--    design-states path: `{owner_id}/{design_id}.json`
--    design-images path: `{owner_id}/{sha256_short}.{ext}` (content-addressed)
--
--    For design-states we tie the policy to a row in social_design_shares
--    whose design_id matches the filename (stripping .json) AND whose
--    owner matches the path's first segment.
--
--    For design-images we can't tie a single image to a single design (a
--    given hash blob may be reused across many designs), so the policy
--    widens read access to "any image in the owner's folder, when the
--    caller has at least one share grant from that owner". Practically:
--    once you've been shared even one design from someone, you can read
--    any of their image blobs by their hash path. The hash paths aren't
--    enumerable, so the practical exposure is limited to images that
--    appear in designs you've already been granted.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "design-states: read shared" on storage.objects;
drop policy if exists "design-images: read shared" on storage.objects;

create policy "design-states: read shared" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'design-states'
    and exists (
      select 1 from public.social_design_shares s
      where s.owner_id::text = (storage.foldername(name))[1]
        and s.design_id::text = regexp_replace(
              regexp_replace(name, '^[^/]+/', ''),  -- strip leading "userid/"
              '\.json$', ''                          -- strip trailing ".json"
            )
        and (s.shared_with_user_id = auth.uid() or s.is_public = true)
    )
  );

create policy "design-images: read shared" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'design-images'
    and exists (
      select 1 from public.social_design_shares s
      where s.owner_id::text = (storage.foldername(name))[1]
        and (s.shared_with_user_id = auth.uid() or s.is_public = true)
    )
  );

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Email → user_id lookup for share creation.
--    user_profiles is per-user RLS (you can only see your own row), so the
--    client can't directly query "what's the user_id for foo@bar.com". This
--    SECURITY DEFINER function runs as the table owner, bypassing RLS just
--    for the lookup. Returns NULL if no match.
-- ──────────────────────────────────────────────────────────────────────────
create or replace function public.lookup_user_id_by_email(p_email text)
returns uuid
language sql
security definer
set search_path = public, auth
as $$
  select id from public.user_profiles
   where lower(email) = lower(trim(p_email))
   limit 1;
$$;

revoke all on function public.lookup_user_id_by_email(text) from public;
grant execute on function public.lookup_user_id_by_email(text) to authenticated;

-- Bulk reverse lookup: given a list of user ids, return their emails. Used by the Share modal
-- to render recipient emails next to each grant. SECURITY DEFINER for the same reason as the
-- email→id lookup — user_profiles RLS prevents cross-user reads directly. Returns only the
-- minimum (id, email); no other profile fields.
create or replace function public.lookup_emails_by_user_ids(p_ids uuid[])
returns table(id uuid, email text)
language sql
security definer
set search_path = public, auth
as $$
  select id, email
    from public.user_profiles
   where id = any(p_ids);
$$;

revoke all on function public.lookup_emails_by_user_ids(uuid[]) from public;
grant execute on function public.lookup_emails_by_user_ids(uuid[]) to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- 6. Friendly view: who shared what with me. Joins shares ← designs ← profiles
--    so the UI can render "Holiday Promo (shared by scott@smarterpaw.com)"
--    in one round-trip. RLS on the underlying tables still enforces access.
-- ──────────────────────────────────────────────────────────────────────────
create or replace view public.shared_designs_for_me as
  select
    d.id                as design_id,
    d.name              as design_name,
    d.brand,
    d.canvas_w,
    d.canvas_h,
    d.updated_at,
    s.id                as share_id,
    s.permission,
    s.is_public,
    s.owner_id,
    p.email             as owner_email,
    p.full_name         as owner_name
  from public.social_design_shares s
  join public.social_designs       d on d.id = s.design_id
  left join public.user_profiles    p on p.id = s.owner_id
  where s.shared_with_user_id = auth.uid()
     or s.is_public = true;

grant select on public.shared_designs_for_me to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select count(*) from public.social_design_shares;        -- 0 on fresh install
--   select polname from pg_policy where polname like 'shares:%';
--   select polname from pg_policy where polname like '%shared%';
--   select * from public.shared_designs_for_me limit 5;
-- ============================================================================
