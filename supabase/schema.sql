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

-- ---------- unique devices; site stats with devices (same as migration 009) ----------
create table if not exists public.device_activity (
  device_id text not null check (device_id ~ '^[A-Za-z0-9-]{16,64}$'),
  day       date not null default current_date,
  team_id   uuid not null references public.teams (id) on delete cascade,
  league_id uuid not null references public.leagues (id) on delete cascade,
  role      text not null default 'member',
  primary key (device_id, day, team_id)
);
create index if not exists device_activity_day on public.device_activity (day);
create index if not exists device_activity_league on public.device_activity (league_id, day);
alter table public.device_activity enable row level security;   -- no policies: written by touch_device, read by site_stats
revoke all on public.device_activity from anon, authenticated;

create or replace function public.touch_device(p_device text, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_device !~ '^[A-Za-z0-9-]{16,64}$' or not public.can_access_team(p_team) then return; end if;
  insert into device_activity (device_id, day, team_id, league_id, role)
    select p_device, current_date, t.id, t.league_id,
      coalesce((select role from admins where user_id = auth.uid()), 'member')
    from teams t where t.id = p_team
  on conflict do nothing;
end $$;
revoke all on function public.touch_device(text, uuid) from public, anon;
grant execute on function public.touch_device(text, uuid) to authenticated;

-- site stats, now with unique devices
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
      'ai_writeups', (select coalesce(sum(gen_count), 0) from match_reports),
      'devices_all', (select count(distinct device_id) from device_activity),
      'devices_since', (select min(day) from device_activity)),
    'activity', jsonb_build_object(
      'devices_7', (select count(distinct device_id) from device_activity where day > current_date - 7),
      'devices_30', (select count(distinct device_id) from device_activity where day > current_date - 30),
      'devices_today', (select count(distinct device_id) from device_activity where day = current_date),
      'signins_7', (select count(*) from pin_attempts where ok and at > now() - interval '7 days'),
      'signins_30', (select count(*) from pin_attempts where ok and at > now() - interval '30 days'),
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
        'devices_30', (select count(distinct device_id) from device_activity where league_id = l.id and day > current_date - 30),
        'last_activity', (select max(updated_at) from m where league_id = l.id)) as x
      from leagues l) q), '[]'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'matches', coalesce(mw.n, 0), 'scratches', coalesce(mw.s, 0), 'devices', coalesce(dw.n, 0)) order by wk) from (
      select to_char(generate_series(date_trunc('week', current_date - 77), date_trunc('week', current_date), interval '1 week'), 'YYYY-MM-DD') as wk) wks
      left join (select to_char(date_trunc('week', d::date), 'YYYY-MM-DD') as w, count(*) as n, sum(scr) as s
                 from m where d ~ '^\d{4}-\d{2}-\d{2}$' and (games > 0 or forfeit) and d::date > current_date - 84 and d::date <= current_date group by 1) mw on mw.w = wk
      left join (select to_char(date_trunc('week', day), 'YYYY-MM-DD') as w, count(distinct device_id) as n
                 from device_activity where day > current_date - 84 group by 1) dw on dw.w = wk), '[]')
  ) into r;
  return r;
end $$;

-- ---------- stat events (same as migration 010) ----------
create table if not exists public.events (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  type      text not null check (type ~ '^[a-z_]{2,40}$'),
  league_id uuid references public.leagues (id) on delete set null,
  team_id   uuid references public.teams (id) on delete set null,
  device_id text check (device_id is null or device_id ~ '^[A-Za-z0-9-]{16,64}$'),
  role      text,
  country   text check (country is null or country ~ '^[A-Z]{2}$'),
  region    text check (region is null or char_length(region) <= 40),
  meta      jsonb not null default '{}'
);
create index if not exists events_at on public.events (at);
create index if not exists events_type_at on public.events (type, at);
create index if not exists events_league_at on public.events (league_id, at);
alter table public.events enable row level security;   -- no policies: written by functions, read by site_stats
revoke all on public.events from anon, authenticated;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from admins where user_id = auth.uid()), case when auth.uid() is null then null else 'member' end);
$$;

-- events the app reports itself (views, saves, admin sign-ins, imports)
create or replace function public.log_event(p_type text, p_team uuid default null, p_device text default null, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare lg uuid;
begin
  if auth.uid() is null or p_type not in ('admin_signin', 'report_view', 'report_save', 'schedule_import', 'app_open') then return; end if;
  if p_team is not null then
    if not public.can_access_team(p_team) then return; end if;
    select league_id into lg from teams where id = p_team;
  end if;
  insert into events (type, league_id, team_id, device_id, role, meta)
    values (p_type, lg, p_team, case when p_device ~ '^[A-Za-z0-9-]{16,64}$' then p_device end, public.my_role(),
            coalesce(jsonb_strip_nulls(p_meta), '{}') - 'text' - 'name');
  if random() < 0.01 then delete from events where at < now() - interval '24 months'; end if;
end $$;

-- team PIN sign-in now also records an event (p_device is optional, so older app versions keep working)
drop function if exists public.join_team(uuid, text);
create or replace function public.join_team(p_team uuid, p_pin text, p_device text default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare h text; good boolean; dev text := case when p_device ~ '^[A-Za-z0-9-]{16,64}$' then p_device end;
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
  insert into events (type, league_id, team_id, device_id, role)
    values (case when good then 'signin' else 'signin_failed' end, (select league_id from teams where id = p_team), p_team, dev, 'member');
  if not good then return 'wrong'; end if;
  insert into memberships (user_id, team_id, expires_at) values (auth.uid(), p_team, now() + interval '12 hours')
    on conflict (user_id, team_id) do update set expires_at = excluded.expires_at;
  delete from pin_attempts where at < now() - interval '30 days';
  return 'ok';
end $$;
revoke all on function public.join_team(uuid, text, text) from public;
revoke all on function public.join_team(uuid, text, text) from anon;
grant execute on function public.join_team(uuid, text, text) to authenticated;
revoke all on function public.log_event(text, uuid, text, jsonb), public.my_role() from public, anon;
grant execute on function public.log_event(text, uuid, text, jsonb), public.my_role() to authenticated;

-- match activity, recorded automatically
create or replace function public.match_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare lg uuid; o jsonb; n jsonb; d int;
begin
  if coalesce(current_setting('scratch.import', true), '') = 'on' or coalesce(current_setting('scratch.cascade', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  select league_id into lg from teams where id = coalesce(new.team_id, old.team_id);
  if tg_op = 'INSERT' then
    insert into events (type, league_id, team_id, role) values ('match_created', lg, new.team_id, public.my_role());
  elsif tg_op = 'DELETE' then
    insert into events (type, league_id, team_id, role) values ('match_deleted', lg, old.team_id, public.my_role());
  else
    o := old.data; n := new.data;
    if not coalesce((o ->> 'locked')::boolean, false) and coalesce((n ->> 'locked')::boolean, false) then
      insert into events (type, league_id, team_id, role, meta) values ('match_locked', lg, new.team_id, public.my_role(),
        jsonb_build_object('match', new.id));
    end if;
    if not coalesce((o ->> 'lineupFinal')::boolean, false) and coalesce((n ->> 'lineupFinal')::boolean, false) then
      insert into events (type, league_id, team_id, role) values ('lineup_final', lg, new.team_id, public.my_role());
    end if;
    d := jsonb_array_length(coalesce(n -> 'scratches', '[]')) - jsonb_array_length(coalesce(o -> 'scratches', '[]'));
    if d > 0 then
      insert into events (type, league_id, team_id, role, meta) values ('scratch_logged', lg, new.team_id, public.my_role(), jsonb_build_object('n', d));
    end if;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists matches_events on public.matches;
create trigger matches_events after insert or update or delete on public.matches for each row execute function public.match_events();

create or replace function public.report_events() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.gen_count > coalesce(old.gen_count, 0) then
    insert into events (type, league_id, team_id, meta)
      values ('report_written', (select league_id from teams where id = new.team_id), new.team_id, jsonb_build_object('match', new.match_id));
  end if;
  return new;
end $$;
drop trigger if exists match_reports_events on public.match_reports;
create trigger match_reports_events after insert or update on public.match_reports for each row execute function public.report_events();

-- site stats, now with long-term history and locations
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
      'ai_writeups', (select coalesce(sum(gen_count), 0) from match_reports),
      'devices_all', (select count(distinct device_id) from device_activity),
      'devices_since', (select min(day) from device_activity),
      'signins_all', (select count(*) from events where type in ('signin', 'admin_signin')),
      'events_since', (select min(at)::date from events)),
    'activity', jsonb_build_object(
      'devices_7', (select count(distinct device_id) from device_activity where day > current_date - 7),
      'devices_30', (select count(distinct device_id) from device_activity where day > current_date - 30),
      'devices_today', (select count(distinct device_id) from device_activity where day = current_date),
      'signins_7', (select count(*) from events where type in ('signin', 'admin_signin') and at > now() - interval '7 days'),
      'signins_30', (select count(*) from events where type in ('signin', 'admin_signin') and at > now() - interval '30 days'),
      'failed_pins_7', (select count(*) from events where type = 'signin_failed' and at > now() - interval '7 days'),
      'matches_edited_7', (select count(*) from m where updated_at > now() - interval '7 days'),
      'matches_edited_30', (select count(*) from m where updated_at > now() - interval '30 days'),
      'active_teams_30', (select count(distinct team_id) from m where updated_at > now() - interval '30 days')),
    'events_30', coalesce((select jsonb_object_agg(type, n) from (select type, count(*) as n from events where at > now() - interval '30 days' group by type) e), '{}'),
    'months', coalesce((select jsonb_agg(x order by x ->> 'month') from (
      select jsonb_build_object('month', mo,
        'signins', (select count(*) from events where type in ('signin', 'admin_signin') and date_trunc('month', at) = mo::date),
        'visits', (select count(*) from events where type = 'visit' and date_trunc('month', at) = mo::date),
        'devices', (select count(distinct device_id) from device_activity where date_trunc('month', day) = mo::date),
        'locked', (select count(*) from events where type = 'match_locked' and date_trunc('month', at) = mo::date),
        'scratches', (select coalesce(sum((meta ->> 'n')::int), 0) from events where type = 'scratch_logged' and date_trunc('month', at) = mo::date),
        'reports', (select count(*) from events where type = 'report_written' and date_trunc('month', at) = mo::date)) as x
      from (select to_char(generate_series(date_trunc('month', current_date) - interval '11 months', date_trunc('month', current_date), interval '1 month'), 'YYYY-MM-DD') as mo) ms) q), '[]'),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('country', country, 'region', region, 'visits', v, 'devices', dv) order by dv desc, v desc) from (
      select country, region, count(*) as v, count(distinct device_id) as dv from events
      where type = 'visit' and country is not null and at > now() - interval '90 days'
      group by country, region order by 4 desc, 3 desc limit 25) l), '[]'),
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
        'devices_30', (select count(distinct device_id) from device_activity where league_id = l.id and day > current_date - 30),
        'signins_30', (select count(*) from events where league_id = l.id and type = 'signin' and at > now() - interval '30 days'),
        'last_activity', (select max(updated_at) from m where league_id = l.id)) as x
      from leagues l) q), '[]'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'matches', coalesce(mw.n, 0), 'scratches', coalesce(mw.s, 0), 'devices', coalesce(dw.n, 0)) order by wk) from (
      select to_char(generate_series(date_trunc('week', current_date - 77), date_trunc('week', current_date), interval '1 week'), 'YYYY-MM-DD') as wk) wks
      left join (select to_char(date_trunc('week', d::date), 'YYYY-MM-DD') as w, count(*) as n, sum(scr) as s
                 from m where d ~ '^\d{4}-\d{2}-\d{2}$' and (games > 0 or forfeit) and d::date > current_date - 84 and d::date <= current_date group by 1) mw on mw.w = wk
      left join (select to_char(date_trunc('week', day), 'YYYY-MM-DD') as w, count(distinct device_id) as n
                 from device_activity where day > current_date - 84 group by 1) dw on dw.w = wk), '[]')
  ) into r;
  return r;
end $$;

-- ---------- stat rollups and 100-day retention (same as migration 011) ----------
create table if not exists public.stats_daily (
  day date not null, scope text not null,   -- scope: 'all' or a league id
  signins int not null default 0, signin_failed int not null default 0, visits int not null default 0,
  match_created int not null default 0, match_locked int not null default 0, lineup_final int not null default 0,
  scratches int not null default 0, reports int not null default 0, report_views int not null default 0,
  report_saves int not null default 0, imports int not null default 0,
  primary key (day, scope)
);
create table if not exists public.stats_devices (
  period text not null check (period in ('day', 'week', 'month', 'quarter')), start date not null, scope text not null,
  devices int not null default 0,
  primary key (period, start, scope)
);
create table if not exists public.stats_locations (
  month date not null, country text not null, region text not null default '',
  visits int not null default 0, devices int not null default 0,
  primary key (month, country, region)
);
create table if not exists public.stats_meta (key text primary key, value text);
alter table public.stats_daily enable row level security;
alter table public.stats_devices enable row level security;
alter table public.stats_locations enable row level security;
alter table public.stats_meta enable row level security;
revoke all on public.stats_daily, public.stats_devices, public.stats_locations, public.stats_meta from anon, authenticated;

-- Summarize everything whose raw data is still complete, then delete raw rows older than 100 days.
-- Periods that started before the raw data began to be trimmed keep their stored (final) values.
create or replace function public.stats_rollup_run() returns void
language plpgsql security definer set search_path = public as $$
declare
  since date; cutoff date := current_date - 100; first date;
begin
  perform pg_advisory_xact_lock(4242011);
  since := (select value::date from stats_meta where key = 'raw_since');
  if since is null then
    first := least((select min(at)::date from events), (select min(day) from device_activity), current_date);
    since := date_trunc('quarter', first)::date;   -- nothing existed before tracking began, so its whole quarter is complete
  end if;

  delete from stats_daily where day >= since;
  insert into stats_daily (day, scope, signins, signin_failed, visits, match_created, match_locked, lineup_final, scratches, reports, report_views, report_saves, imports)
  select d, s,
    count(*) filter (where type in ('signin', 'admin_signin')), count(*) filter (where type = 'signin_failed'), count(*) filter (where type = 'visit'),
    count(*) filter (where type = 'match_created'), count(*) filter (where type = 'match_locked'), count(*) filter (where type = 'lineup_final'),
    coalesce(sum((meta ->> 'n')::int) filter (where type = 'scratch_logged'), 0), count(*) filter (where type = 'report_written'),
    count(*) filter (where type = 'report_view'), count(*) filter (where type = 'report_save'), count(*) filter (where type = 'schedule_import')
  from (select at::date as d, type, meta, unnest(array['all'] || case when league_id is null then '{}'::text[] else array[league_id::text] end) as s
        from events where at::date >= since) e
  group by d, s;

  delete from stats_devices where start >= since;
  insert into stats_devices (period, start, scope, devices)
  select p, date_trunc(p, day)::date, s, count(distinct device_id)
  from (select day, device_id, unnest(array['all', league_id::text]) as s from device_activity where day >= since) da
    cross join unnest(array['day', 'week', 'month', 'quarter']) p
  where date_trunc(p, day)::date >= since
  group by p, date_trunc(p, day)::date, s;

  delete from stats_locations where month >= date_trunc('month', since)::date and month >= since;
  insert into stats_locations (month, country, region, visits, devices)
  select date_trunc('month', at)::date, country, coalesce(region, ''), count(*), count(distinct device_id)
  from events where type = 'visit' and country is not null and at::date >= since and date_trunc('month', at)::date >= since
  group by 1, 2, 3;

  -- retention: device-level rows older than 100 days go; summaries stay
  delete from events where at < cutoff;
  delete from device_activity where day < cutoff;
  insert into stats_meta (key, value) values ('raw_since', greatest(since, cutoff)::text), ('last_run', current_date::text)
    on conflict (key) do update set value = excluded.value;
end $$;

create or replace function public.stats_maybe_rollup() returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select value from stats_meta where key = 'last_run'), '') <> current_date::text then perform public.stats_rollup_run(); end if;
end $$;
revoke all on function public.stats_rollup_run(), public.stats_maybe_rollup() from public, anon, authenticated;

-- daily refresh piggybacks on normal use
create or replace function public.touch_device(p_device text, p_team uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_device !~ '^[A-Za-z0-9-]{16,64}$' or not public.can_access_team(p_team) then return; end if;
  insert into device_activity (device_id, day, team_id, league_id, role)
    select p_device, current_date, t.id, t.league_id, coalesce((select role from admins where user_id = auth.uid()), 'member')
    from teams t where t.id = p_team
  on conflict do nothing;
  perform public.stats_maybe_rollup();
end $$;
create or replace function public.log_event(p_type text, p_team uuid default null, p_device text default null, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare lg uuid;
begin
  if auth.uid() is null or p_type not in ('admin_signin', 'report_view', 'report_save', 'schedule_import', 'app_open') then return; end if;
  if p_team is not null then
    if not public.can_access_team(p_team) then return; end if;
    select league_id into lg from teams where id = p_team;
  end if;
  insert into events (type, league_id, team_id, device_id, role, meta)
    values (p_type, lg, p_team, case when p_device ~ '^[A-Za-z0-9-]{16,64}$' then p_device end, public.my_role(),
            coalesce(jsonb_strip_nulls(p_meta), '{}') - 'text' - 'name');
  perform public.stats_maybe_rollup();
end $$;
-- the Site tab's visit recorder (Edge Function, service role) calls this after each new visit
create or replace function public.stats_tick() returns void language sql security definer set search_path = public as $$ select public.stats_maybe_rollup(); $$;
revoke all on function public.stats_tick() from public, anon, authenticated;
grant execute on function public.stats_tick() to service_role;

-- ---------- trends for the Site tab ----------
-- p_period: day (last 30), week (last 26), month (last 12), quarter (last 8), year (all)
-- p_scope: 'all' or a league id. Each row has this period's numbers and the same period a year earlier.
create or replace function public.site_series(p_period text, p_scope text default 'all') returns jsonb
language plpgsql security definer set search_path = public as $$
declare unit text; n int; step interval; back interval; r jsonb;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  if p_period not in ('day', 'week', 'month', 'quarter', 'year') then raise exception 'Unknown period.'; end if;
  perform public.stats_rollup_run();
  unit := p_period;
  n := case p_period when 'day' then 30 when 'week' then 26 when 'month' then 12 when 'quarter' then 8 else 1 end;
  step := case p_period when 'day' then interval '1 day' when 'week' then interval '1 week' when 'month' then interval '1 month' when 'quarter' then interval '3 months' else interval '1 year' end;
  back := case p_period when 'week' then interval '52 weeks' else interval '1 year' end;
  with periods as (
    select s::date as start from generate_series(
      case when p_period = 'year' then date_trunc('year', coalesce((select min(day) from stats_daily where scope = p_scope), current_date))
           else date_trunc(unit, current_date) - step * (n - 1) end,
      date_trunc(unit, current_date), step) s
  ), sums as (
    select p.start, k.yoy,
      (select jsonb_build_object(
         'signins', coalesce(sum(signins), 0), 'signin_failed', coalesce(sum(signin_failed), 0), 'visits', coalesce(sum(visits), 0),
         'match_created', coalesce(sum(match_created), 0), 'locked', coalesce(sum(match_locked), 0), 'lineups', coalesce(sum(lineup_final), 0),
         'scratches', coalesce(sum(scratches), 0), 'reports', coalesce(sum(reports), 0), 'report_views', coalesce(sum(report_views), 0),
         'report_saves', coalesce(sum(report_saves), 0), 'imports', coalesce(sum(imports), 0))
       from stats_daily
       where scope = p_scope and day >= (p.start - case when k.yoy then back else interval '0' end)::date
         and day < (p.start - case when k.yoy then back else interval '0' end + step)::date) as v,
      case when p_period = 'year' then
        (select max(devices) from stats_devices where period = 'quarter' and scope = p_scope
           and start >= (p.start - case when k.yoy then back else interval '0' end)::date and start < (p.start - case when k.yoy then back else interval '0' end + step)::date)
      else (select devices from stats_devices where period = p_period and scope = p_scope
              and start = date_trunc(unit, p.start - case when k.yoy then back else interval '0' end)::date) end as dev
    from periods p cross join (values (false), (true)) k(yoy)
  )
  select jsonb_build_object(
    'period', p_period, 'scope', p_scope, 'generated_at', now(),
    'devices_note', case when p_period = 'year' then 'busiest quarter' else null end,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('start', a.start,
        'now', a.v || jsonb_build_object('devices', a.dev),
        'yoy', b.v || jsonb_build_object('devices', b.dev)) order by a.start)
      from sums a join sums b on b.start = a.start and b.yoy and not a.yoy), '[]'),
    'has_history_since', (select min(day) from stats_daily where scope = p_scope)
  ) into r;
  return r;
end $$;
revoke all on function public.site_series(text, text) from public, anon;
grant execute on function public.site_series(text, text) to authenticated;

-- site stats: all-time totals now come from the summaries (raw events only cover 100 days)
create or replace function public.site_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  perform public.stats_rollup_run();
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
      'ai_writeups', (select coalesce(sum(gen_count), 0) from match_reports),
      'devices_all', (select count(distinct device_id) from device_activity),
      'devices_since', (select min(day) from device_activity),
      'signins_all', (select coalesce(sum(signins), 0) from stats_daily where scope = 'all'),
      'events_since', (select min(day) from stats_daily where scope = 'all')),
    'activity', jsonb_build_object(
      'devices_7', (select count(distinct device_id) from device_activity where day > current_date - 7),
      'devices_30', (select count(distinct device_id) from device_activity where day > current_date - 30),
      'devices_today', (select count(distinct device_id) from device_activity where day = current_date),
      'signins_7', (select count(*) from events where type in ('signin', 'admin_signin') and at > now() - interval '7 days'),
      'signins_30', (select count(*) from events where type in ('signin', 'admin_signin') and at > now() - interval '30 days'),
      'failed_pins_7', (select count(*) from events where type = 'signin_failed' and at > now() - interval '7 days'),
      'matches_edited_7', (select count(*) from m where updated_at > now() - interval '7 days'),
      'matches_edited_30', (select count(*) from m where updated_at > now() - interval '30 days'),
      'active_teams_30', (select count(distinct team_id) from m where updated_at > now() - interval '30 days')),
    'events_30', coalesce((select jsonb_object_agg(type, n) from (select type, count(*) as n from events where at > now() - interval '30 days' group by type) e), '{}'),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('country', country, 'region', region, 'visits', v, 'devices', dv) order by dv desc, v desc) from (
      select country, region, count(*) as v, count(distinct device_id) as dv from events
      where type = 'visit' and country is not null and at > now() - interval '90 days'
      group by country, region order by 4 desc, 3 desc limit 25) l), '[]'),
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
        'devices_30', (select count(distinct device_id) from device_activity where league_id = l.id and day > current_date - 30),
        'signins_30', (select count(*) from events where league_id = l.id and type = 'signin' and at > now() - interval '30 days'),
        'last_activity', (select max(updated_at) from m where league_id = l.id)) as x
      from leagues l) q), '[]'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'matches', coalesce(mw.n, 0), 'scratches', coalesce(mw.s, 0), 'devices', coalesce(dw.n, 0)) order by wk) from (
      select to_char(generate_series(date_trunc('week', current_date - 77), date_trunc('week', current_date), interval '1 week'), 'YYYY-MM-DD') as wk) wks
      left join (select to_char(date_trunc('week', d::date), 'YYYY-MM-DD') as w, count(*) as n, sum(scr) as s
                 from m where d ~ '^\d{4}-\d{2}-\d{2}$' and (games > 0 or forfeit) and d::date > current_date - 84 and d::date <= current_date group by 1) mw on mw.w = wk
      left join (select to_char(date_trunc('week', day), 'YYYY-MM-DD') as w, count(distinct device_id) as n
                 from device_activity where day > current_date - 84 group by 1) dw on dw.w = wk), '[]')
  ) into r;
  return r;
end $$;

-- ---------- KPIs by scope, feature/platform usage (same as migration 012) ----------
alter table public.stats_daily
  add column if not exists tab_matches int not null default 0, add column if not exists tab_stats int not null default 0,
  add column if not exists tab_admin int not null default 0, add column if not exists tab_league int not null default 0,
  add column if not exists tab_rules int not null default 0, add column if not exists tab_site int not null default 0,
  add column if not exists report_details int not null default 0, add column if not exists notes_views int not null default 0,
  add column if not exists install_clicks int not null default 0, add column if not exists installs int not null default 0,
  add column if not exists visits_mobile int not null default 0, add column if not exists visits_tablet int not null default 0,
  add column if not exists visits_desktop int not null default 0, add column if not exists visits_home int not null default 0;

-- app-reported events: more types, small metadata only
create or replace function public.log_event(p_type text, p_team uuid default null, p_device text default null, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare lg uuid; meta jsonb := coalesce(jsonb_strip_nulls(p_meta), '{}') - 'text' - 'name';
begin
  if auth.uid() is null or p_type not in ('admin_signin', 'report_view', 'report_save', 'report_details', 'schedule_import', 'app_open',
                                          'tab_view', 'notes_view', 'install_click', 'installed') then return; end if;
  if length(meta::text) > 400 then meta := '{}'; end if;
  if p_team is not null then
    if not public.can_access_team(p_team) then return; end if;
    select league_id into lg from teams where id = p_team;
  end if;
  insert into events (type, league_id, team_id, device_id, role, meta)
    values (p_type, lg, p_team, case when p_device ~ '^[A-Za-z0-9-]{16,64}$' then p_device end, public.my_role(), meta);
  perform public.stats_maybe_rollup();
end $$;

-- summaries now also per team, plus the new counts
create or replace function public.stats_rollup_run() returns void
language plpgsql security definer set search_path = public as $$
declare since date; cutoff date := current_date - 100; first date; rebuilt boolean;
begin
  perform pg_advisory_xact_lock(4242011);
  since := (select value::date from stats_meta where key = 'raw_since');
  if since is null then
    first := least((select min(at)::date from events), (select min(day) from device_activity), current_date);
    since := date_trunc('quarter', first)::date;
  end if;

  delete from stats_daily where day >= since;
  insert into stats_daily (day, scope, signins, signin_failed, visits, match_created, match_locked, lineup_final, scratches, reports, report_views, report_saves, imports,
                           tab_matches, tab_stats, tab_admin, tab_league, tab_rules, tab_site, report_details, notes_views, install_clicks, installs,
                           visits_mobile, visits_tablet, visits_desktop, visits_home)
  select d, s,
    count(*) filter (where type in ('signin', 'admin_signin')), count(*) filter (where type = 'signin_failed'), count(*) filter (where type = 'visit'),
    count(*) filter (where type = 'match_created'), count(*) filter (where type = 'match_locked'), count(*) filter (where type = 'lineup_final'),
    coalesce(sum((meta ->> 'n')::int) filter (where type = 'scratch_logged'), 0), count(*) filter (where type = 'report_written'),
    count(*) filter (where type = 'report_view'), count(*) filter (where type = 'report_save'), count(*) filter (where type = 'schedule_import'),
    count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'matches'), count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'standings'),
    count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'admin'), count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'league'),
    count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'rules'), count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'site'),
    count(*) filter (where type = 'report_details'), count(*) filter (where type = 'notes_view'),
    count(*) filter (where type = 'install_click'), count(*) filter (where type = 'installed'),
    count(*) filter (where type = 'visit' and meta ->> 'platform' = 'mobile'), count(*) filter (where type = 'visit' and meta ->> 'platform' = 'tablet'),
    count(*) filter (where type = 'visit' and meta ->> 'platform' = 'desktop'), count(*) filter (where type = 'visit' and coalesce((meta ->> 'standalone')::boolean, false))
  from (select at::date as d, type, meta,
          unnest(array['all'] || case when league_id is null then '{}'::text[] else array[league_id::text] end
                              || case when team_id is null then '{}'::text[] else array['t:' || team_id::text] end) as s
        from events where at::date >= since) e
  group by d, s;

  delete from stats_devices where start >= since;
  insert into stats_devices (period, start, scope, devices)
  select p, date_trunc(p, day)::date, s, count(distinct device_id)
  from (select day, device_id, unnest(array['all', league_id::text, 't:' || team_id::text]) as s from device_activity where day >= since) da
    cross join unnest(array['day', 'week', 'month', 'quarter']) p
  where date_trunc(p, day)::date >= since
  group by p, date_trunc(p, day)::date, s;

  delete from stats_locations where month >= since;
  insert into stats_locations (month, country, region, visits, devices)
  select date_trunc('month', at)::date, country, coalesce(region, ''), count(*), count(distinct device_id)
  from events where type = 'visit' and country is not null and at::date >= since and date_trunc('month', at)::date >= since
  group by 1, 2, 3;

  delete from events where at < cutoff;
  delete from device_activity where day < cutoff;
  insert into stats_meta (key, value) values ('raw_since', greatest(since, cutoff)::text), ('last_run', current_date::text)
    on conflict (key) do update set value = excluded.value;
end $$;

-- trends for any scope: 'all', a league id, or 't:<team id>'
create or replace function public.site_series(p_period text, p_scope text default 'all') returns jsonb
language plpgsql security definer set search_path = public as $$
declare unit text; n int; step interval; back interval; r jsonb;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  if p_period not in ('day', 'week', 'month', 'quarter', 'year') then raise exception 'Unknown period.'; end if;
  perform public.stats_rollup_run();
  unit := p_period;
  n := case p_period when 'day' then 30 when 'week' then 26 when 'month' then 12 when 'quarter' then 8 else 1 end;
  step := case p_period when 'day' then interval '1 day' when 'week' then interval '1 week' when 'month' then interval '1 month' when 'quarter' then interval '3 months' else interval '1 year' end;
  back := case p_period when 'week' then interval '52 weeks' else interval '1 year' end;
  with periods as (
    select s::date as start from generate_series(
      case when p_period = 'year' then date_trunc('year', coalesce((select min(day) from stats_daily where scope = p_scope), current_date))
           else date_trunc(unit, current_date) - step * (n - 1) end,
      date_trunc(unit, current_date), step) s
  ), sums as (
    select p.start, k.yoy,
      (select jsonb_build_object(
         'signins', coalesce(sum(signins), 0), 'signin_failed', coalesce(sum(signin_failed), 0), 'visits', coalesce(sum(visits), 0),
         'match_created', coalesce(sum(match_created), 0), 'locked', coalesce(sum(match_locked), 0), 'lineups', coalesce(sum(lineup_final), 0),
         'scratches', coalesce(sum(scratches), 0), 'reports', coalesce(sum(reports), 0), 'report_views', coalesce(sum(report_views), 0),
         'report_saves', coalesce(sum(report_saves), 0), 'report_details', coalesce(sum(report_details), 0), 'imports', coalesce(sum(imports), 0),
         'stats_tab', coalesce(sum(tab_stats), 0), 'rules_tab', coalesce(sum(tab_rules), 0), 'notes_views', coalesce(sum(notes_views), 0),
         'home_visits', coalesce(sum(visits_home), 0), 'mobile_visits', coalesce(sum(visits_mobile), 0), 'tablet_visits', coalesce(sum(visits_tablet), 0),
         'desktop_visits', coalesce(sum(visits_desktop), 0), 'installs', coalesce(sum(installs), 0))
       from stats_daily
       where scope = p_scope and day >= (p.start - case when k.yoy then back else interval '0' end)::date
         and day < (p.start - case when k.yoy then back else interval '0' end + step)::date) as v,
      case when p_period = 'year' then
        (select max(devices) from stats_devices where period = 'quarter' and scope = p_scope
           and start >= (p.start - case when k.yoy then back else interval '0' end)::date and start < (p.start - case when k.yoy then back else interval '0' end + step)::date)
      else (select devices from stats_devices where period = p_period and scope = p_scope
              and start = date_trunc(unit, p.start - case when k.yoy then back else interval '0' end)::date) end as dev
    from periods p cross join (values (false), (true)) k(yoy)
  )
  select jsonb_build_object(
    'period', p_period, 'scope', p_scope, 'generated_at', now(),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('start', a.start,
        'now', a.v || jsonb_build_object('devices', a.dev),
        'yoy', b.v || jsonb_build_object('devices', b.dev)) order by a.start)
      from sums a join sums b on b.start = a.start and b.yoy and not a.yoy), '[]'),
    'has_history_since', (select min(day) from stats_daily where scope = p_scope)
  ) into r;
  return r;
end $$;

-- KPIs for any scope; features and devices from the last 30 days of raw events
drop function if exists public.site_stats();
create or replace function public.site_stats(p_scope text default 'all') returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; lg uuid; tm uuid;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  perform public.stats_rollup_run();
  if p_scope like 't:%' then tm := substr(p_scope, 3)::uuid; lg := (select league_id from teams where id = tm);
  elsif p_scope ~* '^[0-9a-f-]{36}$' then lg := p_scope::uuid; end if;

  with tms as (select t.* from teams t where (lg is null or t.league_id = lg) and (tm is null or t.id = tm)),
  m as (
    select mt.id, mt.team_id, t.league_id, mt.updated_at,
      nullif(mt.data ->> 'date', '') as d,
      coalesce((mt.data ->> 'locked')::boolean, false) as locked,
      coalesce(nullif(mt.data ->> 'forfeit', ''), '') <> '' as forfeit,
      (select count(*) from jsonb_array_elements(coalesce(mt.data -> 'games', '[]')) g where g ->> 'result' in ('W', 'L', 'FF')) as games,
      jsonb_array_length(coalesce(mt.data -> 'scratches', '[]')) as scr
    from matches mt join tms t on t.id = mt.team_id
  ), players as (
    select t.id as team_id, t.league_id, count(*) as n
    from tms t join leagues l on l.id = t.league_id
      join rosters ro on ro.team_id = t.id and ro.season_id = l.current_season_id
      cross join lateral jsonb_array_elements(coalesce(ro.data -> 'players', '[]')) p
    where not coalesce((p ->> 'removed')::boolean, false)
    group by t.id, t.league_id
  ), ev as (select * from events e where (lg is null or e.league_id = lg) and (tm is null or e.team_id = tm)),
  da as (select * from device_activity a where (lg is null or a.league_id = lg) and (tm is null or a.team_id = tm)),
  active30 as (select count(distinct device_id) as n from da where day > current_date - 30)
  select jsonb_build_object(
    'generated_at', now(), 'scope', p_scope, 'league_id', lg, 'team_id', tm,
    'totals', jsonb_build_object(
      'leagues', case when lg is null then (select count(*) from leagues) else 1 end,
      'seasons', (select count(*) from league_seasons where lg is null or league_id = lg),
      'teams', (select count(*) from tms),
      'teams_default_pin', (select count(*) from team_pins tp join tms t on t.id = tp.team_id where tp.is_default),
      'players', (select coalesce(sum(n), 0) from players),
      'site_admins', (select count(*) from admins where role = 'owner'),
      'league_admins', (select count(*) from admins where role = 'league' and (lg is null or league_id = lg)),
      'team_admins', (select count(*) from admins a join tms t on t.id = a.team_id where a.role = 'team'),
      'matches', (select count(*) from m),
      'matches_played', (select count(*) from m where games > 0 or forfeit),
      'matches_locked', (select count(*) from m where locked),
      'matches_upcoming', (select count(*) from m where d >= to_char(current_date, 'YYYY-MM-DD') and games = 0 and not forfeit),
      'games', (select coalesce(sum(games), 0) from m),
      'scratches', (select coalesce(sum(scr), 0) from m),
      'reports', (select count(*) from match_reports mr join tms t on t.id = mr.team_id),
      'ai_writeups', (select coalesce(sum(gen_count), 0) from match_reports mr join tms t on t.id = mr.team_id),
      'devices_all', (select count(distinct device_id) from da),
      'devices_since', (select min(day) from da),
      'signins_all', (select coalesce(sum(signins), 0) from stats_daily where scope = p_scope),
      'events_since', (select min(day) from stats_daily where scope = p_scope)),
    'activity', jsonb_build_object(
      'devices_7', (select count(distinct device_id) from da where day > current_date - 7),
      'devices_30', (select n from active30),
      'devices_today', (select count(distinct device_id) from da where day = current_date),
      'signins_7', (select count(*) from ev where type in ('signin', 'admin_signin') and at > now() - interval '7 days'),
      'signins_30', (select count(*) from ev where type in ('signin', 'admin_signin') and at > now() - interval '30 days'),
      'failed_pins_7', (select count(*) from ev where type = 'signin_failed' and at > now() - interval '7 days'),
      'matches_edited_7', (select count(*) from m where updated_at > now() - interval '7 days'),
      'matches_edited_30', (select count(*) from m where updated_at > now() - interval '30 days'),
      'active_teams_30', (select count(distinct team_id) from m where updated_at > now() - interval '30 days')),
    'features', jsonb_build_object(
      'active_devices', (select n from active30),
      'list', coalesce((select jsonb_agg(jsonb_build_object('key', k, 'uses', uses, 'devices', devs) order by uses desc) from (
        select case when type = 'tab_view' then 'tab_' || coalesce(meta ->> 'tab', '?') else type end as k, count(*) as uses, count(distinct device_id) as devs
        from ev where at > now() - interval '30 days'
          and type in ('tab_view', 'report_view', 'report_details', 'report_save', 'notes_view', 'install_click', 'installed', 'schedule_import')
        group by 1) f), '[]'),
      'scratches_logged', (select coalesce(sum((meta ->> 'n')::int), 0) from ev where type = 'scratch_logged' and at > now() - interval '30 days'),
      'matches_locked', (select count(*) from ev where type = 'match_locked' and at > now() - interval '30 days')),
    'platform', jsonb_build_object(
      'kinds', coalesce((select jsonb_object_agg(k, n) from (select coalesce(meta ->> 'platform', 'unknown') as k, count(distinct device_id) as n
        from ev where type = 'visit' and at > now() - interval '30 days' group by 1) x), '{}'),
      'systems', coalesce((select jsonb_object_agg(k, n) from (select coalesce(meta ->> 'os', 'unknown') as k, count(distinct device_id) as n
        from ev where type = 'visit' and at > now() - interval '30 days' group by 1) x), '{}'),
      'home_devices', (select count(distinct device_id) from ev where type = 'visit' and coalesce((meta ->> 'standalone')::boolean, false) and at > now() - interval '30 days'),
      'home_devices_all', (select count(distinct device_id) from ev where type = 'visit' and coalesce((meta ->> 'standalone')::boolean, false)),
      'visit_devices', (select count(distinct device_id) from ev where type = 'visit' and at > now() - interval '30 days'),
      'installs_30', (select count(*) from ev where type = 'installed' and at > now() - interval '30 days')),
    'events_30', coalesce((select jsonb_object_agg(type, n) from (select type, count(*) as n from ev where at > now() - interval '30 days' group by type) e), '{}'),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('country', country, 'region', region, 'visits', v, 'devices', dv) order by dv desc, v desc) from (
      select country, region, count(*) as v, count(distinct device_id) as dv from ev
      where type = 'visit' and country is not null and at > now() - interval '90 days'
      group by country, region order by 4 desc, 3 desc limit 25) l), '[]'),
    'leagues', case when lg is null then coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', l.id, 'name', l.name, 'city', coalesce(to_jsonb(l) ->> 'city', ''),
        'season', (select name from league_seasons where id = l.current_season_id),
        'teams', (select count(*) from teams where league_id = l.id),
        'players', (select coalesce(sum(n), 0) from players where league_id = l.id),
        'matches', (select count(*) from m where league_id = l.id),
        'played', (select count(*) from m where league_id = l.id and (games > 0 or forfeit)),
        'locked', (select count(*) from m where league_id = l.id and locked),
        'scratches', (select coalesce(sum(scr), 0) from m where league_id = l.id),
        'reports', (select count(*) from match_reports mr join teams t on t.id = mr.team_id where t.league_id = l.id),
        'devices_30', (select count(distinct device_id) from device_activity where league_id = l.id and day > current_date - 30),
        'signins_30', (select count(*) from events where league_id = l.id and type in ('signin', 'admin_signin') and at > now() - interval '30 days'),
        'last_activity', (select max(updated_at) from m where league_id = l.id)) as x
      from leagues l) q), '[]') end,
    'teams', case when lg is not null then coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', t.id, 'name', t.name,
        'default_pin', coalesce((select is_default from team_pins where team_id = t.id), false),
        'players', (select coalesce(sum(n), 0) from players where team_id = t.id),
        'matches', (select count(*) from m where team_id = t.id),
        'played', (select count(*) from m where team_id = t.id and (games > 0 or forfeit)),
        'locked', (select count(*) from m where team_id = t.id and locked),
        'scratches', (select coalesce(sum(scr), 0) from m where team_id = t.id),
        'games', (select coalesce(sum(games), 0) from m where team_id = t.id),
        'reports', (select count(*) from match_reports where team_id = t.id),
        'devices_30', (select count(distinct device_id) from device_activity where team_id = t.id and day > current_date - 30),
        'signins_30', (select count(*) from events where team_id = t.id and type in ('signin', 'admin_signin') and at > now() - interval '30 days'),
        'report_views_30', (select count(*) from events where team_id = t.id and type = 'report_view' and at > now() - interval '30 days'),
        'last_activity', (select max(updated_at) from m where team_id = t.id)) as x
      from teams t where t.league_id = lg) q), '[]') end
  ) into r;
  return r;
end $$;
revoke all on function public.site_stats(text) from public, anon;
grant execute on function public.site_stats(text) to authenticated;
