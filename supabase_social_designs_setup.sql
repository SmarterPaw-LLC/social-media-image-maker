-- ============================================================================
-- SmarterPaw Social Image Tool — Designs cloud-sync table
-- Run SECOND on this project (after supabase_auth_setup.sql).
-- Supabase → SQL Editor → New query → paste → Run.
-- Prereq: supabase_auth_setup.sql has been run on this project — provides the
--         `authenticated` role grants and user_profiles/audit_log scaffolding.
-- ============================================================================
-- Stores each user's saved designs from the social image tool.
-- The `state` JSONB column holds the full `gatherDesignState()` payload
-- (layers + canvas + brand + app meta) — same shape as the existing
-- .spdesign.json export file, so import/export round-trips are trivial.
--
-- Previously stored only in IndexedDB (per-browser, per-device). With this
-- table, designs follow the user across devices and survive cache clears.
-- The .spdesign.json file download stays as a portable / shareable fallback.
-- ============================================================================

create table if not exists public.social_designs (
  id              bigserial primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  brand           text,                                  -- 'meowi' | 'kkz' (per the brand switcher)
  canvas_w        int,
  canvas_h        int,
  schema_version  int not null default 1,
  app_version     text,
  state           jsonb not null,                        -- full design payload (layers, etc.)
  thumbnail       text,                                  -- optional data URI / URL for My Designs grid
  is_autosave     boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists social_designs_user_idx       on public.social_designs(user_id, updated_at desc);
create index if not exists social_designs_user_brand_idx on public.social_designs(user_id, brand);
-- One autosave row per user (enforce at write time; partial-unique index makes upsert clean):
create unique index if not exists social_designs_one_autosave_per_user
  on public.social_designs(user_id) where is_autosave = true;

-- ──────────────────────────────────────────────────────────────────────────
-- updated_at auto-touch
-- ──────────────────────────────────────────────────────────────────────────
create or replace function social_designs_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists social_designs_touch_trg on public.social_designs;
create trigger social_designs_touch_trg
  before update on public.social_designs
  for each row execute function social_designs_touch();

-- ──────────────────────────────────────────────────────────────────────────
-- RLS — per-user isolation
-- (Forecast project uses "authenticated full access" for shared business
--  data. Designs are personal, so we narrow to auth.uid() = user_id.)
-- ──────────────────────────────────────────────────────────────────────────
alter table public.social_designs enable row level security;

drop policy if exists "designs select own" on public.social_designs;
drop policy if exists "designs insert own" on public.social_designs;
drop policy if exists "designs update own" on public.social_designs;
drop policy if exists "designs delete own" on public.social_designs;

create policy "designs select own" on public.social_designs
  for select to authenticated using (auth.uid() = user_id);
create policy "designs insert own" on public.social_designs
  for insert to authenticated with check (auth.uid() = user_id);
create policy "designs update own" on public.social_designs
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "designs delete own" on public.social_designs
  for delete to authenticated using (auth.uid() = user_id);

-- ──────────────────────────────────────────────────────────────────────────
-- Grants
-- The forecast auth_setup ran `alter default privileges ... grant ... to
-- authenticated` so this new table SHOULD inherit grants automatically.
-- Re-stating them explicitly here is belt-and-suspenders and matches the
-- "v4.108 gotcha" note in the forecast CLAUDE.md: without table grants,
-- PostgREST 403s BEFORE RLS gets to evaluate.
-- ──────────────────────────────────────────────────────────────────────────
grant select, insert, update, delete on public.social_designs to authenticated;
grant usage, select on sequence social_designs_id_seq to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- Verify
--   select count(*) from public.social_designs;
--   \d+ public.social_designs
-- ============================================================================
