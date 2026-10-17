-- The Scratch Sheet — migration 013: private storage for the Claude prompts.
-- Run once in Supabase → SQL Editor → New query → Run. Then run the private ai_prompts file
-- (kept outside GitHub) to load the prompts. Only the match-report Edge Function can read this table.

create table if not exists public.ai_prompts (
  key        text primary key check (key ~ '^[a-z_]{2,40}$'),
  body       text not null,
  updated_at timestamptz not null default now()
);
alter table public.ai_prompts enable row level security;   -- no policies: not readable or writable from the app
revoke all on public.ai_prompts from anon, authenticated;
