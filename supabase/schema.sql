-- The Scratch Sheet — Supabase schema (v2: leagues and seasons)
-- New project: paste this whole file into Supabase → SQL Editor → New query → Run.
-- Existing project with data: run supabase/migrations/003_leagues_and_seasons.sql instead (it keeps your data).
-- Re-running this file on its own drops and recreates the app's tables (and their data).
--
-- Structure
--   League  → has seasons (one marked current), its own rulebook, and teams.
--   Season  → a league season; season_teams lists which teams play in it (teams can join or drop out).
--   Team    → carries over between seasons (name, PIN, match history); has one roster per season.
--
-- Roles (all enforced here by row-level security, not by the web page)
--   Owner        : email + password. Runs every league: creates leagues, appoints league admins.
--   League admin : email + password. One league: seasons, teams, team PINs, rules, team admins.
--   Team admin   : email + password. One team: rosters, team PIN, matches (incl. unlock/delete).
--   Team member  : anonymous session that unlocks one team with its 4-digit PIN. Reads the team,
--                  creates/edits matches, logs scratches. Cannot delete or unlock matches or edit rosters.

create extension if not exists pgcrypto with schema extensions;

drop table if exists public.season_teams, public.rosters, public.team_pins, public.pin_attempts, public.memberships,
  public.matches, public.seasons, public.admins, public.teams, public.league_seasons, public.leagues, public.league cascade;

-- functions from v1 whose signatures changed
drop function if exists public.is_league_admin() cascade;
drop function if exists public.claim_league_admin(text) cascade;
drop function if exists public.create_team(text, text) cascade;
drop function if exists public.add_admin(uuid, text, text, uuid) cascade;
drop function if exists public.update_admin(uuid, text, uuid) cascade;
drop function if exists public.list_teams() cascade;

-- ---------- tables ----------
create table public.leagues (
  id                uuid primary key default gen_random_uuid(),
  name              text not null check (length(trim(name)) between 1 and 80),
  current_season_id text,
  rules_text        text not null default '',
  rules_file        text not null default '',
  rules_updated     timestamptz,
  created_at        timestamptz not null default now()
);

create table public.league_seasons (
  id         text primary key default gen_random_uuid()::text check (id ~ '^[A-Za-z0-9_-]{4,64}$'),
  league_id  uuid not null references public.leagues (id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 60),
  created_at timestamptz not null default now()
);
create index on public.league_seasons (league_id);
alter table public.leagues add constraint leagues_current_season_fk
  foreign key (current_season_id) references public.league_seasons (id) on delete set null;

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references public.leagues (id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 80),
  created_at timestamptz not null default now()
);
create index on public.teams (league_id);

create table public.season_teams (
  season_id text not null references public.league_seasons (id) on delete cascade,
  team_id   uuid not null references public.teams (id) on delete cascade,
  primary key (season_id, team_id)
);

-- PIN hashes live in their own table that no client can read (not even via live updates)
create table public.team_pins (
  team_id  uuid primary key references public.teams (id) on delete cascade,
  pin_hash text not null
);

create table public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  username   text not null unique check (username ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and length(username) <= 254), -- sign-in email
  role       text not null check (role in ('owner', 'league', 'team')),
  league_id  uuid references public.leagues (id) on delete cascade,
  team_id    uuid references public.teams (id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((role = 'owner') or (role = 'league' and league_id is not null) or (role = 'team' and team_id is not null))
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

-- one roster per team per league season ({ players: [...] } plus app fields)
create table public.rosters (
  team_id    uuid not null references public.teams (id) on delete cascade,
  season_id  text not null references public.league_seasons (id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (team_id, season_id)
);

create table public.matches (
  id         text primary key check (id ~ '^[A-Za-z0-9_-]{4,64}$'),
  team_id    uuid not null references public.teams (id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create index on public.matches (team_id);

-- ---------- helper checks ----------
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid() and role = 'owner');
$$;

create or replace function public.is_league_admin(l uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid() and (role = 'owner' or (role = 'league' and league_id = l)));
$$;

create or replace function public.team_league(t uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select league_id from teams where id = t;
$$;

create or replace function public.season_league(s text) returns uuid
language sql stable security definer set search_path = public as $$
  select league_id from league_seasons where id = s;
$$;

create or replace function public.is_team_admin(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_league_admin(public.team_league(t))
      or exists (select 1 from admins where user_id = auth.uid() and role = 'team' and team_id = t);
$$;

create or replace function public.can_access_team(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_team_admin(t)
      or exists (select 1 from memberships where user_id = auth.uid() and team_id = t and expires_at > now());
$$;

-- may the caller manage an admin with this role/scope?
create or replace function public.can_manage_admin(p_role text, p_league uuid, p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner()
      or (p_role = 'team' and p_team is not null and public.is_league_admin(public.team_league(p_team)));
$$;

-- season and team must belong to the same league
create or replace function public.season_teams_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.season_league(new.season_id) is distinct from public.team_league(new.team_id) then
    raise exception 'That team is in a different league.';
  end if;
  return new;
end $$;
create trigger season_teams_check before insert or update on public.season_teams for each row execute function public.season_teams_check();

create or replace function public.leagues_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.current_season_id is not null and public.season_league(new.current_season_id) is distinct from new.id then
    raise exception 'That season belongs to a different league.';
  end if;
  return new;
end $$;
create trigger leagues_check before insert or update on public.leagues for each row execute function public.leagues_check();

-- ---------- row-level security ----------
alter table public.leagues        enable row level security;
alter table public.league_seasons enable row level security;
alter table public.teams          enable row level security;
alter table public.season_teams   enable row level security;
alter table public.team_pins      enable row level security;
alter table public.admins         enable row level security;
alter table public.memberships    enable row level security;
alter table public.pin_attempts   enable row level security;
alter table public.rosters        enable row level security;
alter table public.matches        enable row level security;

-- leagues & seasons: names and rules are public (the sign-in screen lists them)
create policy leagues_read   on public.leagues for select using (true);
create policy leagues_update on public.leagues for update using (public.is_league_admin(id)) with check (public.is_league_admin(id));
create policy leagues_insert on public.leagues for insert with check (public.is_owner());
create policy leagues_delete on public.leagues for delete using (public.is_owner());

create policy seasons_read  on public.league_seasons for select using (true);
create policy seasons_ins   on public.league_seasons for insert with check (public.is_league_admin(league_id));
create policy seasons_upd   on public.league_seasons for update using (public.is_league_admin(league_id)) with check (public.is_league_admin(league_id));
create policy seasons_del   on public.league_seasons for delete using (public.is_league_admin(league_id));

create policy st_read on public.season_teams for select using (true);
create policy st_ins  on public.season_teams for insert with check (public.is_league_admin(public.season_league(season_id)));
create policy st_del  on public.season_teams for delete using (public.is_league_admin(public.season_league(season_id)));

-- teams: visible to their members and admins; league admins create (via function) and delete
create policy teams_read   on public.teams for select using (public.can_access_team(id) or public.is_league_admin(league_id));
create policy teams_update on public.teams for update using (public.is_team_admin(id)) with check (public.is_team_admin(id));
create policy teams_delete on public.teams for delete using (public.is_league_admin(league_id));

-- admins: you see yourself plus the admins you manage
create policy admins_read on public.admins for select using (user_id = auth.uid() or public.can_manage_admin(role, league_id, team_id));

-- rosters: team members read; team admins write
create policy rosters_read on public.rosters for select using (public.can_access_team(team_id));
create policy rosters_ins  on public.rosters for insert with check (public.is_team_admin(team_id) and public.season_league(season_id) = public.team_league(team_id));
create policy rosters_upd  on public.rosters for update using (public.is_team_admin(team_id)) with check (public.is_team_admin(team_id));
create policy rosters_del  on public.rosters for delete using (public.is_team_admin(team_id));

-- matches: team members read, create and edit; only team admins delete
create policy matches_read on public.matches for select using (public.can_access_team(team_id));
create policy matches_ins  on public.matches for insert with check (public.can_access_team(team_id));
create policy matches_upd  on public.matches for update using (public.can_access_team(team_id)) with check (public.can_access_team(team_id));
create policy matches_del  on public.matches for delete using (public.is_team_admin(team_id));

-- column-level grants (Supabase grants everything by default; narrow it)
revoke all on public.leagues, public.league_seasons, public.teams, public.season_teams, public.team_pins, public.admins,
  public.memberships, public.pin_attempts, public.rosters, public.matches from anon, authenticated;
grant select on public.leagues, public.league_seasons, public.season_teams to anon, authenticated;
grant insert (name), update (name, current_season_id, rules_text, rules_file, rules_updated), delete on public.leagues to authenticated;
grant insert (id, league_id, name), update (name), delete on public.league_seasons to authenticated;
grant insert, delete on public.season_teams to authenticated;
grant select, update (name), delete on public.teams to authenticated;
grant select (user_id, username, role, league_id, team_id, created_at) on public.admins to authenticated;
grant select, insert, update, delete on public.rosters, public.matches to authenticated;

-- ---------- match lock guard ----------
create or replace function public.lineup_of(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_array(coalesce(d -> 'roster', '[]'), coalesce(d -> 'subs', '[]'),
    coalesce((select jsonb_agg(g -> 'p' order by n) from jsonb_array_elements(coalesce(d -> 'games', '[]')) with ordinality as x(g, n)), '[]'));
$$;

create or replace function public.matches_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  was_locked boolean := coalesce((old.data ->> 'locked')::boolean, false);
  now_locked boolean := coalesce((new.data ->> 'locked')::boolean, false);
  was_final  boolean := coalesce((old.data ->> 'lineupFinal')::boolean, false);
  now_final  boolean := coalesce((new.data ->> 'lineupFinal')::boolean, false);
begin
  if tg_op = 'DELETE' then
    -- deleting a whole league, team or season takes its matches with it, locked or not
    if was_locked and coalesce(current_setting('scratch.cascade', true), '') <> 'on' then
      raise exception 'This match is locked. Unlock it before deleting.';
    end if;
    return old;
  end if;
  if new.team_id <> old.team_id then raise exception 'A match cannot move to another team.'; end if;
  if was_locked and now_locked and new.data is distinct from old.data then
    raise exception 'This match is locked. Unlock it to make changes.';
  end if;
  if was_locked and not now_locked and not public.is_team_admin(old.team_id) then
    raise exception 'Only a team admin can unlock a match.';
  end if;
  -- a final lineup (who's playing, subs, pairings and game order) can't change until it's reopened
  if was_final and now_final and public.lineup_of(old.data) is distinct from public.lineup_of(new.data) then
    raise exception 'The lineup is final. Reopen it with Edit lineup to make changes.';
  end if;
  -- locking a match always finalizes its lineup
  if now_locked and not was_locked and not now_final then
    new.data := new.data || jsonb_build_object('lineupFinal', true, 'lineupFinalAt', coalesce(new.data -> 'lockedAt', to_jsonb((extract(epoch from now()) * 1000)::bigint)));
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger matches_guard before update or delete on public.matches for each row execute function public.matches_guard();

-- league/team/season deletes: allow their matches to go too, and remove matches from a deleted season
create or replace function public.cascade_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('scratch.cascade', 'on', true);
  if tg_table_name = 'league_seasons' then
    delete from matches where data ->> 'seasonId' = old.id and team_id in (select id from teams where league_id = old.league_id);
  end if;
  return old;
end $$;
create trigger leagues_cascade before delete on public.leagues for each row execute function public.cascade_delete();
create trigger teams_cascade before delete on public.teams for each row execute function public.cascade_delete();
create trigger seasons_cascade before delete on public.league_seasons for each row execute function public.cascade_delete();

create or replace function public.touch_updated() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger rosters_touch before update on public.rosters for each row execute function public.touch_updated();

-- ---------- functions the app calls ----------
create or replace function public.list_leagues() returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select id, name from leagues order by lower(name);
$$;

-- Teams playing in a league's current season (sign-in screen)
create or replace function public.list_signin_teams(p_league uuid) returns table (id uuid, name text, has_pin boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, exists (select 1 from team_pins p where p.team_id = t.id)
  from leagues l join season_teams st on st.season_id = l.current_season_id join teams t on t.id = st.team_id
  where l.id = p_league order by lower(t.name);
$$;

create or replace function public.league_has_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where role = 'owner');
$$;

-- First run only: the first signed-in (non-anonymous) account becomes the owner.
create or replace function public.claim_owner(p_username text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Sign in first.';
  end if;
  perform pg_advisory_xact_lock(424242);
  if exists (select 1 from admins where role = 'owner') then
    raise exception 'The Scratch Sheet already has an owner.';
  end if;
  insert into admins (user_id, username, role) values (auth.uid(), lower(p_username), 'owner');
end $$;

create or replace function public.whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'uid', auth.uid(),
    'admin', (select jsonb_build_object('username', username, 'role', role, 'league_id', league_id, 'team_id', team_id) from admins where user_id = auth.uid()),
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

create or replace function public.leave_team() returns void
language sql security definer set search_path = public as $$
  delete from memberships where user_id = auth.uid();
$$;

create or replace function public.set_team_pin(p_team uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_team_admin(p_team) then raise exception 'Only an admin of this team can change its PIN.'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 digits.'; end if;
  insert into team_pins (team_id, pin_hash) values (p_team, crypt(p_pin, gen_salt('bf')))
    on conflict (team_id) do update set pin_hash = excluded.pin_hash;
  delete from memberships where team_id = p_team;
end $$;

-- Owner: create a league with its first season (made current)
create or replace function public.create_league(p_name text, p_season text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l uuid; s text;
begin
  if not public.is_owner() then raise exception 'Only the owner can create leagues.'; end if;
  insert into leagues (name) values (trim(p_name)) returning id into l;
  if coalesce(trim(p_season), '') <> '' then
    insert into league_seasons (league_id, name) values (l, trim(p_season)) returning id into s;
    update leagues set current_season_id = s where id = l;
  end if;
  return l;
end $$;

-- League admin: create a team with its PIN, optionally entered in a season
create or replace function public.create_team(p_league uuid, p_name text, p_pin text, p_season text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid;
begin
  if not public.is_league_admin(p_league) then raise exception 'Only an admin of this league can create teams.'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 digits.'; end if;
  insert into teams (league_id, name) values (p_league, trim(p_name)) returning id into t;
  insert into team_pins (team_id, pin_hash) values (t, crypt(p_pin, gen_salt('bf')));
  if p_season is not null then insert into season_teams (season_id, team_id) values (p_season, t); end if;
  return t;
end $$;

-- Give an existing account an admin role (the app creates the account first)
create or replace function public.add_admin(p_user uuid, p_username text, p_role text, p_league uuid, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_admin(p_role, p_league, p_team) then raise exception 'You can''t appoint that kind of admin.'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'That account was not created.'; end if;
  insert into admins (user_id, username, role, league_id, team_id)
    values (p_user, lower(p_username), p_role, case when p_role = 'league' then p_league end, case when p_role = 'team' then p_team end);
end $$;

create or replace function public.update_admin(p_user uuid, p_role text, p_league uuid, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  select * into a from admins where user_id = p_user;
  if not found then raise exception 'That admin does not exist.'; end if;
  if not public.can_manage_admin(a.role, a.league_id, a.team_id) or not public.can_manage_admin(p_role, p_league, p_team) then
    raise exception 'You can''t make that change.';
  end if;
  if a.role = 'owner' and p_role <> 'owner' and (select count(*) from admins where role = 'owner') <= 1 then
    raise exception 'This is the only owner. Make someone else an owner first.';
  end if;
  update admins set role = p_role,
    league_id = case when p_role = 'league' then p_league end,
    team_id = case when p_role = 'team' then p_team end
  where user_id = p_user;
end $$;

create or replace function public.remove_admin(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  select * into a from admins where user_id = p_user;
  if not found then raise exception 'That admin does not exist.'; end if;
  if p_user = auth.uid() then raise exception 'You cannot remove yourself.'; end if;
  if not public.can_manage_admin(a.role, a.league_id, a.team_id) then raise exception 'You can''t remove that admin.'; end if;
  delete from auth.users where id = p_user;
end $$;

create or replace function public.reset_admin_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a admins;
begin
  select * into a from admins where user_id = p_user;
  if not found then raise exception 'That admin does not exist.'; end if;
  if not public.can_manage_admin(a.role, a.league_id, a.team_id) then raise exception 'You can''t reset that admin''s password.'; end if;
  if length(p_password) < 8 then raise exception 'Passwords need at least 8 characters.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.list_leagues(), public.list_signin_teams(uuid), public.league_has_admin() to anon, authenticated;
grant execute on function public.claim_owner(text), public.whoami(), public.join_team(uuid, text), public.leave_team(),
  public.set_team_pin(uuid, text), public.create_league(text, text), public.create_team(uuid, text, text, text),
  public.add_admin(uuid, text, text, uuid, uuid), public.update_admin(uuid, text, uuid, uuid), public.remove_admin(uuid),
  public.reset_admin_password(uuid, text), public.is_owner(), public.is_league_admin(uuid), public.is_team_admin(uuid),
  public.can_access_team(uuid), public.team_league(uuid), public.season_league(text), public.can_manage_admin(text, uuid, uuid)
  to authenticated;

-- ---------- live updates ----------
alter table public.matches replica identity full;
alter table public.rosters replica identity full;
do $$
declare t text;
begin
  foreach t in array array['matches', 'rosters', 'teams', 'leagues', 'league_seasons', 'season_teams'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ---------- Claude-written match reports (same as migration 005) ----------

create table if not exists public.match_reports (
  match_id   text primary key references public.matches (id) on delete cascade,
  team_id    uuid not null references public.teams (id) on delete cascade,
  locked_at  bigint,                       -- the match's lockedAt this write-up belongs to
  data       jsonb not null default '{}',  -- { headline, summary, highs[], lows[] }
  model      text,
  gen_count  int not null default 0,       -- how many times it's been written (capped by the function)
  updated_at timestamptz not null default now()
);
create index if not exists match_reports_team on public.match_reports (team_id);

alter table public.match_reports enable row level security;
drop policy if exists match_reports_read on public.match_reports;
create policy match_reports_read on public.match_reports for select using (public.can_access_team(team_id));

revoke all on public.match_reports from anon, authenticated;
grant select on public.match_reports to authenticated;

alter table public.match_reports replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.match_reports;
exception when duplicate_object then null; end $$;

-- ---------- league city (same as migration 006) ----------
alter table public.leagues add column if not exists city text not null default ''
  check (char_length(city) <= 80);
grant update (city) on public.leagues to authenticated;

-- ---------- schedule import, default PINs, venue (same as migration 007) ----------
-- ---------- columns ----------
alter table public.teams   add column if not exists aliases text[] not null default '{}';
alter table public.leagues add column if not exists venue text not null default '' check (char_length(venue) <= 200);
alter table public.team_pins add column if not exists is_default boolean not null default false;
grant update (venue) on public.leagues to authenticated;

-- ---------- default-PIN lock ----------
create or replace function public.team_pin_is_default(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.can_access_team(p_team) and coalesce((select is_default from team_pins where team_id = p_team), false);
$$;

-- league admins: which of this league's teams still have the default PIN
create or replace function public.league_default_pins(p_league uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select tp.team_id from team_pins tp join teams t on t.id = tp.team_id
  where t.league_id = p_league and tp.is_default and public.is_league_admin(p_league);
$$;

create or replace function public.default_pin_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('scratch.import', true), '') = 'on' then return new; end if;
  if exists (select 1 from team_pins where team_id = new.team_id and is_default) then
    raise exception 'This team still has the default PIN. A team or league admin needs to set a new PIN first.';
  end if;
  return new;
end $$;
drop trigger if exists rosters_default_pin on public.rosters;
create trigger rosters_default_pin before insert or update on public.rosters for each row execute function public.default_pin_guard();
drop trigger if exists matches_default_pin on public.matches;
create trigger matches_default_pin before insert or update on public.matches for each row execute function public.default_pin_guard();

-- setting a PIN clears the default flag
create or replace function public.set_team_pin(p_team uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_team_admin(p_team) then raise exception 'Only an admin of this team can change its PIN.'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'The PIN must be exactly 4 digits.'; end if;
  if p_pin = '0000' then raise exception 'Choose a PIN other than 0000.'; end if;
  insert into team_pins (team_id, pin_hash, is_default) values (p_team, crypt(p_pin, gen_salt('bf')), false)
    on conflict (team_id) do update set pin_hash = excluded.pin_hash, is_default = false;
  delete from memberships where team_id = p_team;
end $$;

-- ---------- import ----------
-- p_teams:   [{ key, name, existing_id (uuid or null), aliases: [text] }]
-- p_creates: [{ id, team_key, data }]            new matches
-- p_fills:   [{ id, team_key, set: { opponent?, time?, table? } }]   only empty fields are filled; locked matches are skipped
create or replace function public.import_schedule(p_league uuid, p_season text, p_venue text, p_teams jsonb, p_creates jsonb, p_fills jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  t jsonb; c jsonb; f jsonb; k text; v text; tid uuid; ids jsonb := '{}';
  n_teams int := 0; n_linked int := 0; n_created int := 0; n_filled int := 0; n_skipped int := 0; d jsonb; changed boolean;
begin
  if not public.is_league_admin(p_league) then raise exception 'Only an admin of this league can import its schedule.'; end if;
  if public.season_league(p_season) is distinct from p_league then raise exception 'That season belongs to a different league.'; end if;
  perform set_config('scratch.import', 'on', true);

  if coalesce(trim(p_venue), '') <> '' then
    update leagues set venue = left(trim(p_venue), 200) where id = p_league and coalesce(venue, '') = '';
  end if;

  for t in select * from jsonb_array_elements(coalesce(p_teams, '[]')) loop
    if nullif(t ->> 'existing_id', '') is not null then
      tid := (t ->> 'existing_id')::uuid;
      if (select league_id from teams where id = tid) is distinct from p_league then raise exception 'A linked team is not in this league.'; end if;
      update teams set aliases = (select coalesce(array_agg(distinct a), '{}') from unnest(aliases || array(select jsonb_array_elements_text(coalesce(t -> 'aliases', '[]')))) a
                                  where lower(a) <> lower(name))
        where id = tid;
      n_linked := n_linked + 1;
    else
      insert into teams (league_id, name, aliases) values (p_league, left(trim(t ->> 'name'), 80),
        array(select a from jsonb_array_elements_text(coalesce(t -> 'aliases', '[]')) a where lower(a) <> lower(trim(t ->> 'name'))))
        returning id into tid;
      insert into team_pins (team_id, pin_hash, is_default) values (tid, crypt('0000', gen_salt('bf')), true);
      n_teams := n_teams + 1;
    end if;
    insert into season_teams (season_id, team_id) values (p_season, tid) on conflict do nothing;
    ids := ids || jsonb_build_object(t ->> 'key', tid::text);
  end loop;

  for c in select * from jsonb_array_elements(coalesce(p_creates, '[]')) loop
    tid := (ids ->> (c ->> 'team_key'))::uuid;
    if tid is null then continue; end if;
    insert into matches (id, team_id, data) values (c ->> 'id', tid, (c -> 'data') || jsonb_build_object('seasonId', p_season))
      on conflict (id) do nothing;
    if found then n_created := n_created + 1; end if;
  end loop;

  for f in select * from jsonb_array_elements(coalesce(p_fills, '[]')) loop
    tid := (ids ->> (f ->> 'team_key'))::uuid;
    select data into d from matches where id = f ->> 'id' and team_id = tid for update;
    if d is null then continue; end if;
    if coalesce((d ->> 'locked')::boolean, false) then n_skipped := n_skipped + 1; continue; end if;
    changed := false;
    for k, v in select * from jsonb_each_text(coalesce(f -> 'set', '{}')) loop
      if k in ('opponent', 'time', 'table') and coalesce(trim(d ->> k), '') = '' and coalesce(trim(v), '') <> '' then
        d := d || jsonb_build_object(k, v); changed := true;
      end if;
    end loop;
    if changed then update matches set data = d where id = f ->> 'id'; n_filled := n_filled + 1; end if;
  end loop;

  return jsonb_build_object('teams_created', n_teams, 'teams_linked', n_linked, 'matches_created', n_created, 'matches_filled', n_filled, 'locked_skipped', n_skipped, 'team_ids', ids);
end $$;

revoke all on function public.import_schedule(uuid, text, text, jsonb, jsonb, jsonb), public.team_pin_is_default(uuid), public.league_default_pins(uuid) from public, anon;
grant execute on function public.import_schedule(uuid, text, text, jsonb, jsonb, jsonb), public.team_pin_is_default(uuid), public.league_default_pins(uuid) to authenticated;

-- ---------- site stats (same as migration 008) ----------
create or replace function public.site_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  with m as (
    select mt.id, mt.team_id, t.league_id, mt.data, mt.updated_at,
      nullif(mt.data ->> 'date', '') as d,
      coalesce((mt.data ->> 'locked')::boolean, false) as locked,
      coalesce(nullif(mt.data ->> 'forfeit', ''), '') <> '' as forfeit,
      (select count(*) from jsonb_array_elements(coalesce(mt.data -> 'games', '[]')) g where g ->> 'result' in ('W', 'L', 'FF')) as games,
      jsonb_array_length(coalesce(mt.data -> 'scratches', '[]')) as scr
    from matches mt join teams t on t.id = mt.team_id
  ), cur_players as (
    select l.id as league_id, count(*) as n
    from leagues l join teams t on t.league_id = l.id
      join rosters ro on ro.team_id = t.id and ro.season_id = l.current_season_id
      cross join lateral jsonb_array_elements(coalesce(ro.data -> 'players', '[]')) p
    where not coalesce((p ->> 'removed')::boolean, false)
    group by l.id
  )
  select jsonb_build_object(
    'generated_at', now(),
    'totals', jsonb_build_object(
      'leagues', (select count(*) from leagues),
      'seasons', (select count(*) from league_seasons),
      'teams', (select count(*) from teams),
      'teams_default_pin', (select count(*) from team_pins where is_default),
      'players', (select coalesce(sum(n), 0) from cur_players),
      'site_admins', (select count(*) from admins where role = 'owner'),
      'league_admins', (select count(*) from admins where role = 'league'),
      'team_admins', (select count(*) from admins where role = 'team'),
      'matches', (select count(*) from m),
      'matches_played', (select count(*) from m where games > 0 or forfeit),
      'matches_locked', (select count(*) from m where locked),
      'matches_upcoming', (select count(*) from m where d >= to_char(current_date, 'YYYY-MM-DD') and games = 0 and not forfeit),
      'games', (select coalesce(sum(games), 0) from m),
      'scratches', (select coalesce(sum(scr), 0) from m),
      'reports', (select count(*) from match_reports),
      'ai_writeups', (select coalesce(sum(gen_count), 0) from match_reports)),
    'activity', jsonb_build_object(
      'signins_7', (select count(*) from pin_attempts where ok and at > now() - interval '7 days'),
      'signins_30', (select count(*) from pin_attempts where ok and at > now() - interval '30 days'),
      'people_30', (select count(distinct user_id) from pin_attempts where ok and at > now() - interval '30 days'),
      'failed_pins_7', (select count(*) from pin_attempts where not ok and at > now() - interval '7 days'),
      'matches_edited_7', (select count(*) from m where updated_at > now() - interval '7 days'),
      'matches_edited_30', (select count(*) from m where updated_at > now() - interval '30 days'),
      'active_teams_30', (select count(distinct team_id) from m where updated_at > now() - interval '30 days')),
    'leagues', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', l.id, 'name', l.name, 'city', coalesce(to_jsonb(l) ->> 'city', ''),
        'season', (select name from league_seasons where id = l.current_season_id),
        'teams', (select count(*) from teams where league_id = l.id),
        'players', coalesce((select n from cur_players where league_id = l.id), 0),
        'matches', (select count(*) from m where league_id = l.id),
        'played', (select count(*) from m where league_id = l.id and (games > 0 or forfeit)),
        'locked', (select count(*) from m where league_id = l.id and locked),
        'scratches', (select coalesce(sum(scr), 0) from m where league_id = l.id),
        'reports', (select count(*) from match_reports mr join teams t on t.id = mr.team_id where t.league_id = l.id),
        'last_activity', (select max(updated_at) from m where league_id = l.id)) as x
      from leagues l) q), '[]'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'matches', n, 'scratches', s) order by wk) from (
      select to_char(date_trunc('week', d::date), 'YYYY-MM-DD') as wk, count(*) as n, sum(scr) as s
      from m where d ~ '^\d{4}-\d{2}-\d{2}$' and (games > 0 or forfeit) and d::date > current_date - 84 and d::date <= current_date
      group by 1) w), '[]')
  ) into r;
  return r;
end $$;

revoke all on function public.site_stats() from public, anon;
grant execute on function public.site_stats() to authenticated;
