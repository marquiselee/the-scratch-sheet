-- The Scratch Sheet — migration 009: unique devices.
-- Run once in Supabase → SQL Editor → New query → Run (after 008). Changes no existing data.
-- Each browser gets a random device ID (stored on the device, nothing personal). When it opens a team,
-- the app records one row per device, team and day. Site stats count unique devices from this.

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
