-- The Scratch Sheet — migration 012: KPIs by league and team; feature, platform and Home Screen usage.
-- Run once in Supabase → SQL Editor → New query → Run (after 011). Changes no existing data.
--
-- • Summaries are also kept per team (scope 't:<team id>'), so every KPI and trend can be viewed
--   for all leagues, one league, or one team.
-- • New anonymous events: tab views, report details card, notes window, + Home Screen taps and installs.
-- • Visits now carry the kind of device (phone / tablet / computer), its system (iOS, Android, …) and
--   whether the app was opened from the Home Screen.

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
