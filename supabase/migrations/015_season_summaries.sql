-- The Scratch Sheet — migration 015: Claude-written season progress summaries.
-- Run once in Supabase → SQL Editor → New query → Run (after 014). Changes no existing data; safe to re-run.
--
-- One current summary per team and season, shown at the top of the Stats tab. A new one is written only
-- after a match in that season is locked (as_of = that match's lockedAt). Earlier versions are kept in
-- history so the season's story can be read back. Team members can read them; only the match-report
-- Edge Function writes them.

create table if not exists public.season_summaries (
  team_id    uuid not null references public.teams (id) on delete cascade,
  season_id  text not null,
  as_of      bigint not null,                 -- lockedAt of the latest locked match it covers
  data       jsonb not null default '{}',     -- { headline, summary, voice, matches, record }
  history    jsonb not null default '[]',     -- earlier versions, newest first: [{ as_of, data, at }]
  model      text,
  gen_count  int not null default 0,          -- writes for this as_of (rewrites are capped for team admins)
  updated_at timestamptz not null default now(),
  primary key (team_id, season_id)
);

alter table public.season_summaries enable row level security;
drop policy if exists season_summaries_read on public.season_summaries;
create policy season_summaries_read on public.season_summaries for select using (public.can_access_team(team_id));

revoke all on public.season_summaries from anon, authenticated;
grant select on public.season_summaries to authenticated;

alter table public.season_summaries replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.season_summaries;
exception when duplicate_object then null; when undefined_object then null; end $$;
