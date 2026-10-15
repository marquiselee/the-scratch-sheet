-- The Scratch Sheet — migration 005: Claude-written match reports.
-- Run once in Supabase → SQL Editor → New query → Run. Changes no existing data.
-- Stores the headline, summary, highlights and lowlights Claude writes when a match is locked.
-- Team members can read them; only the match-report Edge Function writes them.

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
