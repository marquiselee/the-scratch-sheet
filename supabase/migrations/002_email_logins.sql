-- The Scratch Sheet — switch admin sign-in from usernames to real email addresses.
-- Run once in Supabase → SQL Editor → New query → Run. Keeps all teams, seasons and matches.

-- Remove any admin accounts created with the old username logins (their sign-in was <name>@scratchsheet.app).
-- If this removes the league admin, the app shows the setup screen again so you can claim it with your email.
delete from auth.users where id in (select user_id from public.admins where username !~ '@');

alter table public.admins drop constraint if exists admins_username_check;
alter table public.admins add constraint admins_username_check
  check (username ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and length(username) <= 254);
