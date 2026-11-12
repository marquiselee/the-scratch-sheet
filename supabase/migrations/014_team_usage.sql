-- The Scratch Sheet — migration 014: team usage leaderboard for site admins.
-- Run once in Supabase → SQL Editor → New query → Run (after 013). Changes no existing data; safe to re-run.
--
-- site_team_usage(scope, days) returns one row per team with how much it used the app and which features,
-- over the last 7, 30 or 90 days. Scope is 'all', a league id, or 't:<team id>' (same as site_stats).
-- Read from the raw events and device_activity tables, which keep 100 days of detail.

create or replace function public.site_team_usage(p_scope text default 'all', p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare lg uuid; tm uuid; d int := case when p_days in (7, 30, 90) then p_days else 30 end; since timestamptz; r jsonb;
begin
  if not public.is_owner() then raise exception 'Only a site admin can see site stats.'; end if;
  if p_scope like 't:%' then tm := substr(p_scope, 3)::uuid; lg := (select league_id from teams where id = tm);
  elsif p_scope ~* '^[0-9a-f-]{36}$' then lg := p_scope::uuid; end if;
  since := now() - make_interval(days => d);

  with tms as (select t.id, t.name, t.league_id from teams t where (lg is null or t.league_id = lg) and (tm is null or t.id = tm)),
  da as (
    select team_id, count(distinct device_id) as devices, count(*) as device_days, max(day) as last_day
    from device_activity where day > current_date - d and team_id in (select id from tms) group by team_id
  ), ev as (
    select team_id,
      count(*) filter (where type = 'visit') as visits,
      count(distinct device_id) filter (where type = 'visit' and coalesce((meta ->> 'standalone')::boolean, false)) as home_devices,
      count(distinct device_id) filter (where type = 'visit' and meta ->> 'platform' = 'mobile') as phone_devices,
      count(distinct device_id) filter (where type = 'visit' and meta ->> 'platform' = 'desktop') as computer_devices,
      count(*) filter (where type in ('signin', 'admin_signin')) as signins,
      count(*) filter (where type = 'report_view') as report_views,
      count(distinct device_id) filter (where type = 'report_view') as report_viewers,
      count(*) filter (where type = 'report_details') as report_details,
      count(*) filter (where type = 'report_save') as report_saves,
      count(*) filter (where type = 'report_written') as reports_written,
      count(*) filter (where type = 'notes_view') as notes_views,
      count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'standings') as stats_tab,
      count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'rules') as rules_tab,
      count(*) filter (where type = 'tab_view' and meta ->> 'tab' = 'admin') as admin_tab,
      coalesce(sum((meta ->> 'n')::int) filter (where type = 'scratch_logged'), 0) as scratches_logged,
      count(*) filter (where type = 'match_locked') as matches_locked,
      count(*) filter (where type = 'lineup_final') as lineups,
      max(at) as last_event
    from events where at > since and team_id in (select id from tms) group by team_id
  )
  select jsonb_build_object('days', d, 'scope', p_scope, 'teams', coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'name', t.name, 'league', l.name, 'league_id', t.league_id,
      'devices', coalesce(da.devices, 0), 'device_days', coalesce(da.device_days, 0),
      'visits', coalesce(ev.visits, 0), 'signins', coalesce(ev.signins, 0),
      'home_devices', coalesce(ev.home_devices, 0), 'phone_devices', coalesce(ev.phone_devices, 0), 'computer_devices', coalesce(ev.computer_devices, 0),
      'report_views', coalesce(ev.report_views, 0), 'report_viewers', coalesce(ev.report_viewers, 0),
      'report_details', coalesce(ev.report_details, 0), 'report_saves', coalesce(ev.report_saves, 0), 'reports_written', coalesce(ev.reports_written, 0),
      'notes_views', coalesce(ev.notes_views, 0), 'stats_tab', coalesce(ev.stats_tab, 0), 'rules_tab', coalesce(ev.rules_tab, 0), 'admin_tab', coalesce(ev.admin_tab, 0),
      'scratches_logged', coalesce(ev.scratches_logged, 0), 'matches_locked', coalesce(ev.matches_locked, 0), 'lineups', coalesce(ev.lineups, 0),
      'last_seen', greatest(ev.last_event, da.last_day::timestamptz))
    order by coalesce(da.device_days, 0) desc, t.name), '[]'))
  into r
  from tms t join leagues l on l.id = t.league_id left join da on da.team_id = t.id left join ev on ev.team_id = t.id;
  return r;
end $$;
revoke all on function public.site_team_usage(text, int) from public, anon;
grant execute on function public.site_team_usage(text, int) to authenticated;
