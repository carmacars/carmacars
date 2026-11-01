-- 0353_games_every_visit.sql
-- The discount game on every visit (docs/changes/2026-11-06-games-every-visit-preview.md).
--
-- The owner, November 1, 2026: "the game still isnt popping up for me", and in a private window "only twice". A visit
-- was the browser tab's session: a tab kept open was one visit for as long as it stayed open, and a prize won and not
-- claimed allowed one card a visit, so after the game and its one pop-up nothing came back. Now:
--   - a visit ends after game_visit_gap_minutes away (30): the next page starts a new visit, with the game again;
--   - at most game_max_per_visit games a visit, 1 by default (the owner's "at most once per visit"); 0 for the daily cap
--     (none). A visitor who closed it without playing gets it on the next visit; a prize won and not claimed pops up
--     once each visit with Get my code and Play again; after a claim the wait of game_replay_after_claim_days (a day)
--     and then a new game and a new code.
-- The other rules are unchanged (see the change record for the full list). Settings > Discount games has a Preview.

alter table program_settings add column if not exists game_visit_gap_minutes integer not null default 30
  check (game_visit_gap_minutes between 5 and 1440);
comment on column program_settings.game_visit_gap_minutes is 'Discount games (0353): minutes away after which the next page is a new visit, and the game comes back (30).';
alter table program_settings alter column game_max_per_visit set default 1, alter column game_max_per_day set default 0;
-- the owner's rule, in force now: once a visit, no daily cap
update program_settings set game_max_per_visit = 1, game_max_per_day = 0;
comment on column program_settings.game_max_per_visit is 'Discount games (0100, 0353): the most games shown in one visit (1 by default: once a visit). A visit ends after game_visit_gap_minutes away. Never in the visit of a claim.';

create or replace function app.game_cfg() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('on', s.game_enabled, 'car_pages', s.game_trigger_car_pages, 'seconds', s.game_trigger_seconds,
    'exit', s.game_exit_intent, 'reshow_pages', s.game_reshow_car_pages, 'reshow_seconds', s.game_reshow_seconds,
    'per_visit', s.game_max_per_visit, 'per_day', s.game_max_per_day, 'booking', s.game_booking_offer,
    'visit_gap', s.game_visit_gap_minutes)
    from (select (app.settings()).*) s
$$;
