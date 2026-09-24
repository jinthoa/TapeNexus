-- Tape Nexus — achievements sync schema for Supabase.
-- Run this in the Supabase dashboard: SQL Editor → New query → paste → Run.
--
-- One row per user holding their local download stats + unlocked badges, so
-- achievements follow them across machines. Secured by Row Level Security:
-- the app ships only the public anon key, and RLS ensures a user can read/write
-- ONLY their own row (auth.uid() = user_id).

create table if not exists public.achievements (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  total_completed   integer   not null default 0,
  total_bytes       bigint    not null default 0,
  unlocked_ids      jsonb     not null default '[]'::jsonb,
  night_owl         boolean   not null default false,
  early_bird        boolean   not null default false,
  first_completed_at timestamptz,
  updated_at        timestamptz not null default now()
);

alter table public.achievements enable row level security;

-- Owner can do everything with their own row; nobody else can see or touch it.
drop policy if exists "achievements owner all" on public.achievements;
create policy "achievements owner all" on public.achievements
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Let the anon key (used by the desktop app) reach this table through the
-- PostgREST API. (RLS still enforces per-user isolation.)
grant select, insert, update, delete on public.achievements to anon, authenticated;