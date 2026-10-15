-- The Scratch Sheet — migration 004: finalized lineups.
-- Run once in Supabase → SQL Editor → New query → Run. Changes no data.
-- After this, a finalized lineup can't be edited until someone reopens it in the app,
-- and locking a match always finalizes its lineup.

create or replace function public.lineup_of(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_array(coalesce(d -> 'roster', '[]'), coalesce(d -> 'subs', '[]'),
    coalesce((select jsonb_agg(g -> 'p' order by n) from jsonb_array_elements(coalesce(d -> 'games', '[]')) with ordinality as x(g, n)), '[]'));
$$;

create or replace function public.matches_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  was_locked boolean := coalesce((old.data ->> 'locked')::boolean, false);
  now_locked boolean := coalesce((new.data ->> 'locked')::boolean, false);
  was_final  boolean := coalesce((old.data ->> 'lineupFinal')::boolean, false);
  now_final  boolean := coalesce((new.data ->> 'lineupFinal')::boolean, false);
begin
  if tg_op = 'DELETE' then
    -- deleting a whole league, team or season takes its matches with it, locked or not
    if was_locked and coalesce(current_setting('scratch.cascade', true), '') <> 'on' then
      raise exception 'This match is locked. Unlock it before deleting.';
    end if;
    return old;
  end if;
  if new.team_id <> old.team_id then raise exception 'A match cannot move to another team.'; end if;
  if was_locked and now_locked and new.data is distinct from old.data then
    raise exception 'This match is locked. Unlock it to make changes.';
  end if;
  if was_locked and not now_locked and not public.is_team_admin(old.team_id) then
    raise exception 'Only a team admin can unlock a match.';
  end if;
  -- a final lineup (who's playing, subs, pairings and game order) can't change until it's reopened
  if was_final and now_final and public.lineup_of(old.data) is distinct from public.lineup_of(new.data) then
    raise exception 'The lineup is final. Reopen it with Edit lineup to make changes.';
  end if;
  -- locking a match always finalizes its lineup
  if now_locked and not was_locked and not now_final then
    new.data := new.data || jsonb_build_object('lineupFinal', true, 'lineupFinalAt', coalesce(new.data -> 'lockedAt', to_jsonb((extract(epoch from now()) * 1000)::bigint)));
  end if;
  new.updated_at := now();
  return new;
end $$;
