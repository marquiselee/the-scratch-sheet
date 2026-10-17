-- The Scratch Sheet — migration 010: stat events (long-term site stats).
-- Run once in Supabase → SQL Editor → New query → Run (after 009). Changes no existing data.
--
-- Records what happens in the app as anonymous events: sign-ins, visits, matches created/locked,
-- scratches logged, reports written/viewed/saved, schedule imports. No names, notes or IP addresses
-- are stored. Visits carry an approximate location: the US state for US visitors, otherwise only the
-- country. Raw events are kept for 24 months. Only site admins see the results (Site tab).

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
