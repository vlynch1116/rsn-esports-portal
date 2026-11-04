-- =====================================================================
-- RSN eSPORTS Portal: SHARED version
-- Everyone can view. Signed-in users can add. Only the person who added
-- something can edit or delete it. Player contact info is private to
-- whoever registered that player.
--
-- Run once in Supabase: SQL Editor > New query > paste all > Run
-- Safe to run again.
-- =====================================================================

-- ---------- Profiles (public display names) ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Player',
  created_at   timestamptz not null default now()
);

-- Create a profile automatically when someone signs up
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Player'))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Give profiles to accounts that already exist
insert into public.profiles (id, display_name)
select id, coalesce(nullif(trim(raw_user_meta_data ->> 'display_name'), ''), 'Player')
from auth.users
on conflict (id) do nothing;

-- ---------- Teams ----------
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 60),
  region     text not null default '' check (char_length(region) <= 60),
  created_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- Tournaments ----------
create table if not exists public.tournaments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 80),
  game       text not null default '' check (char_length(game) <= 60),
  starts_at  timestamptz,
  created_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- Players (public part) ----------
create table if not exists public.players (
  id            uuid primary key default gen_random_uuid(),
  tag           text not null check (char_length(tag) between 1 and 40),
  team_id       uuid references public.teams (id) on delete set null,        -- null = Free Agent
  tournament_id uuid references public.tournaments (id) on delete set null,  -- null = not entered
  psn           text not null default '' check (char_length(psn) <= 40),
  xbox          text not null default '' check (char_length(xbox) <= 40),
  steam         text not null default '' check (char_length(steam) <= 60),
  created_by    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now()
);

-- ---------- Player contact info (private) ----------
create table if not exists public.player_private (
  player_id  uuid primary key references public.players (id) on delete cascade,
  full_name  text not null default '' check (char_length(full_name) <= 80),
  email      text not null default '' check (char_length(email) <= 120),
  phone      text not null default '' check (char_length(phone) <= 30),
  created_by uuid not null default auth.uid() references public.profiles (id) on delete cascade
);

-- ---------- Access grants ----------
grant select on public.profiles, public.teams, public.tournaments, public.players to anon, authenticated;
grant update on public.profiles to authenticated;
grant insert, update, delete on public.teams, public.tournaments, public.players to authenticated;
grant select, insert, update, delete on public.player_private to authenticated;

-- ---------- Row Level Security ----------
alter table public.profiles       enable row level security;
alter table public.teams          enable row level security;
alter table public.tournaments    enable row level security;
alter table public.players        enable row level security;
alter table public.player_private enable row level security;

-- Profiles
drop policy if exists "Profiles are public"  on public.profiles;
drop policy if exists "Update own profile"   on public.profiles;
create policy "Profiles are public" on public.profiles
  for select to anon, authenticated using (true);
create policy "Update own profile" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Teams, tournaments, players: public read, owner-only write
do $$
declare t text;
begin
  foreach t in array array['teams', 'tournaments', 'players'] loop
    execute format('drop policy if exists "Anyone can view" on public.%I', t);
    execute format('drop policy if exists "Signed-in users can add" on public.%I', t);
    execute format('drop policy if exists "Owners can edit" on public.%I', t);
    execute format('drop policy if exists "Owners can delete" on public.%I', t);

    execute format('create policy "Anyone can view" on public.%I for select to anon, authenticated using (true)', t);
    execute format('create policy "Signed-in users can add" on public.%I for insert to authenticated with check ((select auth.uid()) = created_by)', t);
    execute format('create policy "Owners can edit" on public.%I for update to authenticated using ((select auth.uid()) = created_by) with check ((select auth.uid()) = created_by)', t);
    execute format('create policy "Owners can delete" on public.%I for delete to authenticated using ((select auth.uid()) = created_by)', t);
  end loop;
end $$;

-- Player contact info: only the person who registered the player
drop policy if exists "Owner reads contact"   on public.player_private;
drop policy if exists "Owner adds contact"    on public.player_private;
drop policy if exists "Owner edits contact"   on public.player_private;
drop policy if exists "Owner deletes contact" on public.player_private;

create policy "Owner reads contact" on public.player_private
  for select to authenticated using ((select auth.uid()) = created_by);
create policy "Owner adds contact" on public.player_private
  for insert to authenticated
  with check (
    (select auth.uid()) = created_by
    and exists (select 1 from public.players p where p.id = player_id and p.created_by = (select auth.uid()))
  );
create policy "Owner edits contact" on public.player_private
  for update to authenticated
  using ((select auth.uid()) = created_by) with check ((select auth.uid()) = created_by);
create policy "Owner deletes contact" on public.player_private
  for delete to authenticated using ((select auth.uid()) = created_by);

-- ---------- Live updates (pushes changes to everyone's open page) ----------
do $$
declare t text;
begin
  foreach t in array array['teams', 'tournaments', 'players', 'profiles'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
