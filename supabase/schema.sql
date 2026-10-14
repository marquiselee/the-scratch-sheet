-- The Scratch Sheet — Supabase schema
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run once on a new project. Re-running drops and recreates the app's tables (and their data).
--
-- Roles
--   League admin : signs in with email + password. Creates teams, sets PINs, appoints admins,
--                  resets admin passwords, posts league rules. Sees every team.
--   Team admin   : signs in with email + password. Manages one team (seasons, roster, PIN, matches).
--   Team member  : anonymous session that unlocks one team by entering its 4-digit PIN.
--                  Reads the team, creates/edits matches, logs scratches. Cannot delete matches,
--                  change rosters/seasons, or unlock a locked match.
-- Every rule below is enforced by the database (row-level security), not by the web page.

create extension if not exists pgcrypto with schema extensions;

drop table if exists public.team_pins, public.pin_attempts, public.memberships, public.matches, public.seasons, public.admins, public.teams, public.league cascade;

-- ---------- tables ----------
create table public.league (
  id            int primary key default 1 check (id = 1),
  name          text not null default 'League',
  rules_text    text not null default '',
  rules_file    text not null default '',
  rules_updated timestamptz
);
insert into public.league (id) values (1);

create table public.teams (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(trim(name)) between 1 and 80),
  active_season_id text,
  created_at       timestamptz not null default now()
);

-- PIN hashes live in their own table that no client can read (not even via live updates)
create table public.team_pins (
  team_id  uuid primary key references public.teams (id) on delete cascade,
  pin_hash text not null
);

create table public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  username   text not null unique check (username ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and length(username) <= 254), -- the admin's sign-in email
  role       text not null check (role in ('league', 'team')),
  team_id    uuid references public.teams (id) on delete cascade,
  created_at timestamptz not null default now(),
  check (role = 'league' or team_id is not null)
);

create table public.memberships (
  user_id    uuid not null references auth.users (id) on delete cascade,
  team_id    uuid not null references public.teams (id) on delete cascade,
  expires_at timestamptz not null,
  primary key (user_id, team_id)
);

create table public.pin_attempts (
  id      bigserial primary key,
  user_id uuid,
  team_id uuid,
  ok      boolean not null,
  at      timestamptz not null default now()
);
create index on public.pin_attempts (team_id, at);
create index on public.pin_attempts (user_id, at);

create table public.seasons (
  id         text primary key check (id ~ '^[A-Za-z0-9_-]{4,64}$'),
  team_id    uuid not null references public.teams (id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create index on public.seasons (team_id);

create table public.matches (
  id         text primary key check (id ~ '^[A-Za-z0-9_-]{4,64}$'),
  team_id    uuid not null references public.teams (id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create index on public.matches (team_id);

-- ---------- helper checks ----------
create or replace function public.is_league_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid() and role = 'league');
$$;

create or replace function public.is_team_admin(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid() and (role = 'league' or team_id = t));
$$;

create or replace function public.can_access_team(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_team_admin(t)
      or exists (select 1 from memberships where user_id = auth.uid() and team_id = t and expires_at > now());
$$;

-- ---------- row-level security ----------
alter table public.league       enable row level security;
alter table public.teams        enable row level security;
alter table public.admins       enable row level security;
alter table public.memberships  enable row level security;
alter table public.pin_attempts enable row level security;
alter table public.team_pins    enable row level security;
alter table public.seasons      enable row level security;
alter table public.matches      enable row level security;

-- league: anyone may read the rules; only league admins change them
create policy league_read  on public.league for select using (true);
create policy league_write on public.league for update using (public.is_league_admin()) with check (public.is_league_admin());

-- teams: team admins may rename/set season; league admins create/delete
create policy teams_read   on public.teams for select using (public.can_access_team(id));
create policy teams_update on public.teams for update using (public.is_team_admin(id)) with check (public.is_team_admin(id));
create policy teams_insert on public.teams for insert with check (public.is_league_admin());
create policy teams_delete on public.teams for delete using (public.is_league_admin());

-- admins: league admins see everyone; others see only themselves. Changes go through functions.
create policy admins_read on public.admins for select using (public.is_league_admin() or user_id = auth.uid());

-- memberships / pin_attempts: no direct access at all (functions only)

-- seasons: team members read; team admins write
create policy seasons_read  on public.seasons for select using (public.can_access_team(team_id));
create policy seasons_write on public.seasons for insert with check (public.is_team_admin(team_id));
create policy seasons_upd   on public.seasons for update using (public.is_team_admin(team_id)) with check (public.is_team_admin(team_id));
create policy seasons_del   on public.seasons for delete using (public.is_team_admin(team_id));

-- matches: team members read, create and edit; only team admins delete
create policy matches_read on public.matches for select using (public.can_access_team(team_id));
create policy matches_ins  on public.matches for insert with check (public.can_access_team(team_id));
create policy matches_upd  on public.matches for update using (public.can_access_team(team_id)) with check (public.can_access_team(team_id));
create policy matches_del  on public.matches for delete using (public.is_team_admin(team_id));

-- column-level grants (Supabase grants everything by default; narrow it)
revoke all on public.team_pins, public.league, public.teams, public.admins, public.memberships, public.pin_attempts, public.seasons, public.matches from anon, authenticated;
grant select on public.league to anon, authenticated;
grant update (rules_text, rules_file, rules_updated, name) on public.league to authenticated;
grant select on public.teams to authenticated;
grant insert (name), update (name, active_season_id), delete on public.teams to authenticated;
grant select (user_id, username, role, team_id, created_at) on public.admins to authenticated;
grant select, insert, update, delete on public.seasons, public.matches to authenticated;

-- ---------- match lock guard ----------
create or replace function public.matches_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  was_locked boolean := coalesce((old.data ->> 'locked')::boolean, false);
  now_locked boolean := coalesce((new.data ->> 'locked')::boolean, false);
begin
  if tg_op = 'DELETE' then
    if was_locked then raise exception 'This match is locked. Unlock it before deleting.'; end if;
    return old;
  end if;
  if new.team_id <> old.team_id then raise exception 'A match cannot move to another team.'; end if;
  if was_locked and now_locked and new.data is distinct from old.data then
    raise exception 'This match is locked. Unlock it to make changes.';
  end if;
  if was_locked and not now_locked and not public.is_team_admin(old.team_id) then
    raise exception 'Only a team admin can unlock a match.';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger matches_guard before update or delete on public.matches for each row execute function public.matches_guard();

create or replace function public.touch_updated() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger seasons_touch before update on public.seasons for each row execute function public.touch_updated();

-- ---------- functions the app calls ----------
-- Team names for the sign-in screen (no other team data is exposed before a PIN or admin login).
create or replace function public.list_teams() returns table (id uuid, name text, has_pin boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, exists (select 1 from team_pins p where p.team_id = t.id) from teams t order by lower(t.name);
$$;

create or replace function public.league_has_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where role = 'league');
$$;

-- First run only: the first signed-in (non-anonymous) account becomes league admin.
create or replace function public.claim_league_admin(p_username text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Sign in first.';
  end if;
  perform pg_advisory_xact_lock(424242);
  if exists (select 1 from admins where role = 'league') then
    raise exception 'This league already has an admin.';
  end if;
  insert into admins (user_id, username, role) values (auth.uid(), lower(p_username), 'league');
end $$;

-- Who am I? Admin role (if any) and teams unlocked by PIN.
create or replace function public.whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'uid', auth.uid(),
    'admin', (select jsonb_build_object('username', username, 'role', role, 'team_id', team_id) from admins where user_id = auth.uid()),
    'teams', coalesce((select jsonb_agg(team_id) from memberships where user_id = auth.uid() and expires_at > now()), '[]'::jsonb)
  );
$$;

-- Unlock a team with its PIN. Rate limited: 5 misses per device or 30 per team in 15 minutes.
create or replace function public.join_team(p_team uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare h text; good boolean;
begin
  if auth.uid() is null then raise exception 'No session.'; end if;
  if (select count(*) from pin_attempts where user_id = auth.uid() and not ok and at > now() - interval '15 minutes') >= 5
     or (select count(*) from pin_attempts where team_id = p_team and not ok and at > now() - interval '15 minutes') >= 30 then
    return 'locked';
  end if;
  if not exists (select 1 from teams where id = p_team) then return 'no_team'; end if;
  select pin_hash into h from team_pins where team_id = p_team;
  if h is null then return 'no_pin'; end if;
  good := p_pin ~ '^[0-9]{4}$' and crypt(p_pin, h) = h;
  insert into pin_attempts (user_id, team_id, ok) values (auth.uid(), p_team, good);
  if not good then return 'wrong'; end if;
  insert into memberships (user_id, team_id, expires_at) values (auth.uid(), p_team, now() + interval '12 hours')
    on conflict (user_id, team_id) do update set expires_at = excluded.expires_at;
  delete from pin_attempts where at < now() - interval '30 days';
  return 'ok';
end $$;

-- Leave a team (sign out of PIN session)
create or replace function public.leave_team() returns void
language sql security definer set search_path = public as $$
  delete from memberships where user_id = auth.uid();
$$;

-- Set or change a team's PIN (team admin or league admin). Signs everyone out of that team.
create or replace function public.set_team_pin(p_team uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_team_admin(p_team) then raise exception 'Only an admin of this team can change its PIN.'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 digits.'; end if;
  insert into team_pins (team_id, pin_hash) values (p_team, crypt(p_pin, gen_salt('bf')))
    on conflict (team_id) do update set pin_hash = excluded.pin_hash;
  delete from memberships where team_id = p_team;
end $$;

-- League admin: create a team with its PIN
create or replace function public.create_team(p_name text, p_pin text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid;
begin
  if not public.is_league_admin() then raise exception 'Only the league admin can create teams.'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 digits.'; end if;
  insert into teams (name) values (trim(p_name)) returning id into t;
  insert into team_pins (team_id, pin_hash) values (t, crypt(p_pin, gen_salt('bf')));
  return t;
end $$;

-- League admin: give an existing account an admin role (the app creates the account first)
create or replace function public.add_admin(p_user uuid, p_username text, p_role text, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_league_admin() then raise exception 'Only the league admin can appoint admins.'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'That account was not created.'; end if;
  insert into admins (user_id, username, role, team_id)
    values (p_user, lower(p_username), p_role, case when p_role = 'team' then p_team end)
    on conflict (user_id) do update set role = excluded.role, team_id = excluded.team_id;
end $$;

-- League admin: change an admin's role or team
create or replace function public.update_admin(p_user uuid, p_role text, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_league_admin() then raise exception 'Only the league admin can change admins.'; end if;
  if p_user = auth.uid() and p_role <> 'league' and (select count(*) from admins where role = 'league') <= 1 then
    raise exception 'You are the only league admin. Appoint another before changing your own role.';
  end if;
  update admins set role = p_role, team_id = case when p_role = 'team' then p_team end where user_id = p_user;
end $$;

-- League admin: remove an admin (deletes their login)
create or replace function public.remove_admin(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_league_admin() then raise exception 'Only the league admin can remove admins.'; end if;
  if p_user = auth.uid() then raise exception 'You cannot remove yourself.'; end if;
  delete from auth.users where id = p_user;
end $$;

-- League admin: set a new password for an admin who forgot theirs
create or replace function public.reset_admin_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_league_admin() then raise exception 'Only the league admin can reset passwords.'; end if;
  if length(p_password) < 8 then raise exception 'Passwords need at least 8 characters.'; end if;
  if not exists (select 1 from admins where user_id = p_user) then raise exception 'That admin does not exist.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.list_teams(), public.league_has_admin() to anon, authenticated;
grant execute on function public.claim_league_admin(text), public.whoami(), public.join_team(uuid, text), public.leave_team(),
  public.set_team_pin(uuid, text), public.create_team(text, text), public.add_admin(uuid, text, text, uuid),
  public.update_admin(uuid, text, uuid), public.remove_admin(uuid), public.reset_admin_password(uuid, text),
  public.is_league_admin(), public.is_team_admin(uuid), public.can_access_team(uuid) to authenticated;

-- ---------- live updates ----------
alter table public.matches replica identity full;
alter table public.seasons replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.matches, public.seasons, public.teams, public.league;
  exception when duplicate_object then null; end;
end $$;
