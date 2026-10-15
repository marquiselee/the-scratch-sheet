-- The Scratch Sheet — migration 006: league city.
-- Run once in Supabase → SQL Editor → New query → Run. Changes no existing data.
-- League admins set the city on the League tab; match reports use it for local color and match-day weather.

alter table public.leagues add column if not exists city text not null default ''
  check (char_length(city) <= 80);
grant update (city) on public.leagues to authenticated;

-- an earlier draft put the city on teams; remove it if it was added
alter table public.teams drop column if exists city;
