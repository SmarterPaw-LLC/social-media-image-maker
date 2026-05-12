-- ============================================================================
-- SmarterPaw Social Image Tool — Folders for designs (v114+)
-- Run in Supabase → SQL Editor → New query → paste → Run
-- Prereq: supabase_social_designs_setup.sql has been run on this project.
-- ============================================================================
-- Adds a hierarchical folder structure to organize designs. Folders are
-- cloud-only (not mirrored to IndexedDB) — the IDB cache stores folder_id on
-- each design record but offline mode falls back to a flat list.
--
-- Nesting via `parent_folder_id` self-reference. NULL = top-level / root.
-- Cycle prevention is enforced at the JS layer (UI won't let you move a
-- folder into one of its own descendants); the table itself accepts any
-- non-self reference so backend operations stay simple.
--
-- On folder delete: designs in that folder orphan to root (`folder_id` set to
-- NULL), don't get cascade-deleted — losing designs because you deleted a
-- folder would be the worst kind of "I lost my work" moment.
-- ============================================================================

create table if not exists public.social_folders (
  id                bigserial primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  parent_folder_id  bigint references public.social_folders(id) on delete cascade,
  name              text not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- Prevent self-parenting at the DB level (cycle prevention via descendants
  -- is enforced in JS — Postgres can't easily express that)
  constraint social_folders_no_self_parent check (id is null or id <> parent_folder_id)
);

create index if not exists social_folders_user_idx
  on public.social_folders(user_id, parent_folder_id, name);

-- Unique name per (user, parent) — can't have two "Promos" folders in the same place
create unique index if not exists social_folders_unique_name_per_parent
  on public.social_folders(user_id, coalesce(parent_folder_id, 0), lower(name));

-- updated_at auto-touch
create or replace function social_folders_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists social_folders_touch_trg on public.social_folders;
create trigger social_folders_touch_trg
  before update on public.social_folders
  for each row execute function social_folders_touch();

-- RLS — per-user isolation, same pattern as social_designs
alter table public.social_folders enable row level security;

drop policy if exists "folders select own" on public.social_folders;
drop policy if exists "folders insert own" on public.social_folders;
drop policy if exists "folders update own" on public.social_folders;
drop policy if exists "folders delete own" on public.social_folders;

create policy "folders select own" on public.social_folders
  for select to authenticated using (auth.uid() = user_id);
create policy "folders insert own" on public.social_folders
  for insert to authenticated with check (auth.uid() = user_id);
create policy "folders update own" on public.social_folders
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "folders delete own" on public.social_folders
  for delete to authenticated using (auth.uid() = user_id);

-- Grants (belt-and-suspenders per the v4.108 forecast gotcha)
grant select, insert, update, delete on public.social_folders to authenticated;
grant usage, select on sequence social_folders_id_seq to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- Add folder_id to social_designs
-- ──────────────────────────────────────────────────────────────────────────
alter table public.social_designs
  add column if not exists folder_id bigint references public.social_folders(id) on delete set null;

create index if not exists social_designs_folder_idx
  on public.social_designs(user_id, folder_id);

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select count(*) from public.social_folders;            -- 0 on fresh install
--   \d+ public.social_folders
--   \d+ public.social_designs                              -- folder_id column visible
-- ============================================================================
