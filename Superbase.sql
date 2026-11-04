-- RSN eSPORTS Portal: per-account workspace storage
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run

create table if not exists public.portal_workspaces (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Row Level Security: every account can only see and change its own workspace.
alter table public.portal_workspaces enable row level security;

drop policy if exists "Read own workspace"   on public.portal_workspaces;
drop policy if exists "Create own workspace" on public.portal_workspaces;
drop policy if exists "Update own workspace" on public.portal_workspaces;

create policy "Read own workspace"
  on public.portal_workspaces for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Create own workspace"
  on public.portal_workspaces for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Update own workspace"
  on public.portal_workspaces for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
