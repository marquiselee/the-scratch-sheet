# The Scratch Sheet

Lineups, results, scratches and stats for 8-ball doubles league teams. Built for phones at the table.

- **Pairings** follow the league rules: 5 doubles games, everyone present plays once before anyone plays twice, no repeat partners, 4-player and forfeit handling, sub rules.
- **Results** per game (W, L, forfeit, not played), match ties, doubleheaders, match comments, match lock with two-step unlock.
- **Scratches** by player and type (table, pocket, off-table, 8-ball), with errors and error % on the Stats tab.
- **Rules** tab with the posted league rulebook (PDF, Word, text or pasted).

## Who signs in how

| Role | Sign-in | Can do |
|---|---|---|
| League admin | Username + password | Everything: create/delete teams, set any team's PIN, appoint and remove admins, reset admin passwords, post league rules |
| Team admin | Username + password | Their team only: seasons, roster, team PIN, matches, unlock and delete matches |
| Team member | Pick team + 4-digit PIN, every session | Their team: build lineups, record results, log scratches, lock matches |

All permissions are enforced by the database (Supabase row-level security), not by the web page. PINs are stored as bcrypt hashes in a table no client can read. Wrong PINs are rate limited (5 per device, 30 per team, per 15 minutes).

## Setup (one time)

1. **Database:** in Supabase, open **SQL Editor → New query**, paste all of [`supabase/schema.sql`](supabase/schema.sql), and run it.
2. **Authentication → Sign In / Providers:**
   - **Email:** turn **off** "Confirm email" (admins use usernames; no emails are sent).
   - **Allow anonymous sign-ins:** turn **on** (team members use these with the PIN).
   - Leave "Allow new users to sign up" **on** (the league admin creates admin accounts from the app).
3. **Open the app.** The first screen asks you to create the league admin. Do this yourself right away.
4. In the **League** tab, create teams with their PINs and add admins.

## Hosting

The app is a single `index.html` served by GitHub Pages. The Supabase URL and publishable key in it are public by design; access is controlled by the database rules.

A GitHub Action (`.github/workflows/keepalive.yml`) pings Supabase twice a week so the free project doesn't pause.
