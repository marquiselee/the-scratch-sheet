-- The Scratch Sheet — migration 007: schedule import, default PINs, venue and tables.
-- Run once in Supabase → SQL Editor → New query → Run. Changes no existing data.
--
-- • League admins can import a league schedule (Excel/CSV). New teams get PIN 0000 and are
--   locked (no roster or match changes) until a team or league admin sets a real PIN.
-- • Teams remember other spellings of their name (aliases) so later imports match them.
-- • Leagues get a venue; matches carry their table in the match data.

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
