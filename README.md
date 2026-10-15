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
| Owner | Email + password | Everything, in every league: create and delete leagues, appoint league admins |
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

## Hosting

The app is a single `index.html` served by GitHub Pages. The Supabase URL and publishable key in it are public by design; access is controlled by the database rules.

A GitHub Action (`.github/workflows/keepalive.yml`) pings Supabase twice a week so the free project doesn't pause, and commits a small dated file (`.github/keepalive.txt`) whenever the repo has gone 30 days without a commit, so GitHub never turns the schedule off.
