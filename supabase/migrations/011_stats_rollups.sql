-- The Scratch Sheet — migration 011: stat rollups and 100-day retention for device-level data.
-- Run once in Supabase → SQL Editor → New query → Run (after 010). Changes no existing data until it ages out.
--
-- Raw events and device records are summarized into daily counts and per-period unique-device counts
-- (day, week, month, quarter), for all leagues together and for each league. Raw rows older than
-- 100 days are then deleted; only the summaries are kept. Summaries refresh at most once a day, the
-- first time anyone uses the app or a site admin opens the Site tab.

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
