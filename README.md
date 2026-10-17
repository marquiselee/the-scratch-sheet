# The Scratch Sheet

Lineups, results, scratches and stats for 8-ball doubles league teams. Built for phones at the table.

- **Pairings** follow the league rules: 5 doubles games, everyone present plays once before anyone plays twice, no repeat partners, 4-player and forfeit handling, sub rules.
- **Results** per game (W, L, forfeit, not played), match ties, doubleheaders, match comments, match lock with two-step unlock.
- **Scratches** by player and type (table, pocket, off-table, 8-ball), with errors and error % on the Stats tab.
- **Rules** tab with the posted league rulebook (PDF, Word, text or pasted).

## How it's organized

- **Leagues** each have their own **seasons** (one marked current), **rulebook** and **teams**.
- **Teams** carry over from season to season (name, PIN, match history). Each season lists which teams play in it, so new teams can join and others can drop out.
- **Rosters** are per team, per season. Team admins can copy last season's roster in one tap.

## Who signs in how

| Role | Sign-in | Can do |
|---|---|---|
| Site admin | Email + password | Everything, in every league: create and delete leagues, appoint league admins |
| League admin | Email + password | One league: seasons (and which is current), teams in each season, team PINs, rules, team admins |
| Team admin | Email + password | One team: rosters, team PIN, matches, unlock and delete matches |
| Team member | League → Team → 4-digit PIN, every session | Their team: build lineups, record results, log scratches, lock matches |

Players only see teams in their league's current season on the sign-in screen.

All permissions are enforced by the database (Supabase row-level security), not by the web page. PINs are stored as bcrypt hashes in a table no client can read. Wrong PINs are rate limited (5 per device, 30 per team, per 15 minutes).

## Setup (one time)

1. **Database:** in Supabase, open **SQL Editor → New query**, paste all of [`supabase/schema.sql`](supabase/schema.sql), and run it.
2. **Authentication → Sign In / Providers:**
   - **Email:** turn **off** "Confirm email" so the league admin can create admin accounts directly.
   - **Allow anonymous sign-ins:** turn **on** (team members use these with the PIN).
   - Leave "Allow new users to sign up" **on** (the league admin creates admin accounts from the app).
3. **Authentication → URL Configuration:** set **Site URL** to `https://marquiselee.github.io/the-scratch-sheet/` and add the same address under **Redirect URLs** (password-reset links open the app).
4. **Open the app.** The first screen asks you to create the owner account. Do this yourself right away.
5. On the **League** tab, create a league with its first season, add teams with their PINs, and appoint admins.

## Password resets

Admins can tap **Forgot password?** on the sign-in screen to get a reset link by email. Supabase's built-in email sender only delivers to members of your Supabase organization and sends a few emails per hour; to email other admins, add a free SMTP provider (such as Resend) under **Authentication → Emails → SMTP Settings**. The owner and league admins can always reset the passwords of admins they manage from the League tab.

## Upgrading an existing database

- `supabase/migrations/002_email_logins.sql` switches admin sign-in from usernames to email addresses.
- `supabase/migrations/003_leagues_and_seasons.sql` adds leagues and league seasons, keeping all existing teams, rosters, matches and admins (they move into one league called "My League").
- `supabase/migrations/004_final_lineup.sql` enforces finalized lineups (and auto-finalizes on match lock).
- `supabase/migrations/005_match_reports.sql` adds the table for Claude-written match reports.
- `supabase/migrations/009_devices.sql` records anonymous device IDs (one row per device, team and day) for unique-device stats.
- `supabase/migrations/008_site_stats.sql` adds the Site tab's stats for site admins.
- `supabase/migrations/007_schedule_import.sql` adds schedule import (League tab), default-PIN locking for imported teams, team aliases and the league venue.
- `supabase/migrations/006_league_city.sql` adds a league city (League tab), used for local color and match-day weather in reports.

## Importing a league schedule

On the League tab, a league admin can upload the league schedule (Excel or CSV) for the selected season. The app reads "Team vs Team" grids with date headers, or one-match-per-row sheets with Date/Home/Away columns; anything else is read by Claude through the same `match-report` function. A preview shows the teams (spelling variants merged, likely matches to existing teams flagged for a check), matches to add, details to fill in and conflicts. Nothing existing is overwritten: only empty opponent, time and table fields are filled, locked matches are skipped, and existing teams keep their names (the schedule's spelling is remembered as an alias). New teams get PIN 0000 and can't change rosters or matches until a team or league admin sets a new PIN.

## Claude-written match reports

When a match is locked, the app asks the `match-report` Edge Function (`supabase/functions/match-report/index.ts`) to write the report's headline, summary, highlights and lowlights with Claude (Haiku). The function checks that the caller can see the match and that it's locked, writes once per lock (a few rewrites at most), and saves the result in `match_reports`. If the function isn't set up or fails, the card uses the app's own wording.

Setup: run migration 005; deploy the function from the Supabase dashboard (Edge Functions → Deploy a new function → Via Editor, name `match-report`) and turn off its legacy JWT check; add the secret `ANTHROPIC_API_KEY` under Edge Functions → Secrets. The Anthropic key never goes in `index.html`. Optional secrets: `REPORT_MODEL` overrides the model; `REPORT_WEB_SEARCH=off` turns off the one quick web search per write-up (used for something current to joke about; it's skipped automatically if web search isn't enabled on the Anthropic account). Match-day weather comes from Open-Meteo (free, no key).

## Hosting

The app is a single `index.html` served by GitHub Pages. The Supabase URL and publishable key in it are public by design; access is controlled by the database rules.

A GitHub Action (`.github/workflows/keepalive.yml`) pings Supabase twice a week so the free project doesn't pause, and commits a small dated file (`.github/keepalive.txt`) whenever the repo has gone 30 days without a commit, so GitHub never turns the schedule off.
