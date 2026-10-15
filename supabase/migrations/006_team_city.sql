-- The Scratch Sheet — migration 006: team city.
-- Run once in Supabase → SQL Editor → New query → Run. Changes no existing data.
-- Team admins set the city on the Team tab; match reports use it for local color and match-day weather.

alter table public.teams add column if not exists city text not null default ''
  check (char_length(city) <= 80);
grant update (city) on public.teams to authenticated;
