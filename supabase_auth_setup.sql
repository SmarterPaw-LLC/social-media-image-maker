-- ============================================================================
-- SmarterPaw Social Image Tool — Auth + Audit Log Setup
-- Run this FIRST on a fresh Supabase project (before social_designs migration).
-- Supabase → SQL Editor → New query → paste → Run.
-- ============================================================================
-- Adds:
--   1. user_profiles  — links auth.users to app-side info (email, full name, role)
--   2. audit_log      — who-did-what trail
--   3. Trigger        — auto-creates a user_profiles row on signup
--   4. Helper RPC     — log_action (writes audit_log entries)
--   5. Role grants    — `authenticated` gets full table+sequence access by default
--                       (RLS still enforced per-table; this just satisfies the
--                       Postgres-grant layer BENEATH RLS so PostgREST doesn't
--                       403 before policies evaluate).
--
-- Trimmed copy of the forecast project's supabase_auth_setup.sql. The forecast
-- version also enables RLS on a fixed list of business tables — irrelevant here
-- because this project doesn't have those tables.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. user_profiles
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists user_profiles (
  user_id      uuid primary key references auth.users on delete cascade,
  email        text not null,
  full_name    text,
  role         text not null default 'admin' check (role in ('admin','editor','viewer')),
  created_at   timestamptz default now(),
  last_seen_at timestamptz
);

create index if not exists user_profiles_email_idx on user_profiles(email);

-- ──────────────────────────────────────────────────────────────────────────
-- 2. audit_log
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists audit_log (
  id         bigserial primary key,
  ts         timestamptz default now(),
  user_id    uuid references auth.users on delete set null,
  user_email text,
  action     text not null,        -- e.g. 'design.save', 'design.delete', 'design.export'
  details    jsonb default '{}'::jsonb
);

create index if not exists audit_log_ts_idx     on audit_log(ts desc);
create index if not exists audit_log_action_idx on audit_log(action);
create index if not exists audit_log_user_idx   on audit_log(user_id);

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Auto-create user_profiles row on signup
-- ──────────────────────────────────────────────────────────────────────────
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into user_profiles (user_id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', new.email),
    'admin'  -- every invited user starts as admin (per SmarterPaw policy)
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ──────────────────────────────────────────────────────────────────────────
-- 4. log_action — convenience RPC for writing audit entries
-- ──────────────────────────────────────────────────────────────────────────
create or replace function log_action(p_action text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  if auth.uid() is null then return; end if;  -- ignore unauthenticated calls
  select email into v_email from auth.users where id = auth.uid();
  insert into audit_log (user_id, user_email, action, details)
  values (auth.uid(), v_email, p_action, coalesce(p_details, '{}'::jsonb));
end;
$$;

grant execute on function log_action(text, jsonb) to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- 5. RLS on user_profiles + audit_log
-- ──────────────────────────────────────────────────────────────────────────
alter table user_profiles enable row level security;
drop policy if exists "profiles select all" on user_profiles;
drop policy if exists "profiles update own" on user_profiles;
create policy "profiles select all" on user_profiles for select to authenticated using (true);
create policy "profiles update own" on user_profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- INSERT happens via the on_auth_user_created trigger (security definer); no client policy needed.

alter table audit_log enable row level security;
drop policy if exists "audit select all" on audit_log;
create policy "audit select all" on audit_log for select to authenticated using (true);
-- Writes go through log_action RPC only.

-- ──────────────────────────────────────────────────────────────────────────
-- 6. Role grants for `authenticated`
--    RLS layers ON TOP of standard Postgres grants — without these, PostgREST
--    returns 403 BEFORE RLS gets a chance to evaluate. Grant on every existing
--    table+sequence AND set default privileges so future tables (e.g.
--    social_designs added next) inherit the grants automatically.
-- ──────────────────────────────────────────────────────────────────────────
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;

-- ──────────────────────────────────────────────────────────────────────────
-- 7. Backfill profiles for any users that already exist (e.g. ones added
--    via the Supabase dashboard before this script ran).
-- ──────────────────────────────────────────────────────────────────────────
insert into user_profiles (user_id, email, full_name, role)
select id, email, coalesce(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name', email), 'admin'
from auth.users
on conflict (user_id) do nothing;

-- ──────────────────────────────────────────────────────────────────────────
-- Verify:
--   select count(*) from user_profiles;        -- should match auth.users count
--   select * from audit_log order by ts desc;  -- empty until first action
-- Then run supabase_social_designs_setup.sql next.
-- ============================================================================
