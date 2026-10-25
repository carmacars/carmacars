-- 0171_games_again_replay.sql
-- The discount game comes back, and one prize is another go (docs/changes/2026-10-25-games-again-replay.md). The owner:
-- "It should pop up again and one of the prizes should actually be to play again."
--
-- 1. A prize won and not claimed pops up again: the browser opens the full card ("Your 5% off is still waiting", its
--    claim form) on the usual triggers (the first-show rules on a later visit, the re-show rules after a close, at most
--    game_max_per_visit a visit), with the small "saved" badge between pops, until it is claimed or the visitor's prize
--    ends (game_dismiss_days, 14 days). The database already returned such a play as saved (0100, 0170); only the browser
--    changes. A game closed before its prize showed already comes back on the next visit (0081: game_dismiss_days is how
--    long a visitor keeps the prize drawn for them, not a wait after a close), so that setting stays at 14 days.
-- 2. A new prize: "another go" (a second game). In the prize table {"key": "replay", "replay": true, "weight": 15}, at most
--    one, never the only prize. Revealed, the card says "You won another go!" with a "Play again" button: game_start
--    with p.replay_of = the play's token (the browser's RPC on the site, /api/games in the request-to-book form) checks
--    the play is this visitor's, revealed, not claimed, a replay prize and not replayed yet, marks it replayed and starts
--    a new play: a different game (app.game_next_kind) and a prize drawn from the table without the replay prize, so the
--    second game always ends in a discount; one replay per chain. Not counted in the per-visitor start limit. A replay
--    prize is never claimed (server_game_claim refuses it) and never the saved discount: a revealed replay not used yet
--    comes back as a saved play the card offers to play again. The terms say so; the report counts plays by prize.
--    The default table becomes: 5% off 54, 10% off 25, another go 15, 15% off 4, $50 off 3+ days 1, 25% off up to $150
--    0.6, $100 off 4+ days 0.3, a free day 0.1 (the 15 come from 5% off; the rare prizes of 0081 stay). Live tables get
--    the replay prize the same way: the most common prize gives 15 to it (an Admin's table of 8 prizes is left as is).
-- 3. The guides.
-- No applied migration is edited (functions of earlier migrations are changed in place, as 0081 does).

-- ================================================================ 1. the prize table: the replay prize
create or replace function app.game_prize_is_replay(p jsonb) returns boolean
language sql immutable as $$ select coalesce(jsonb_typeof(p -> 'replay') = 'boolean' and (p ->> 'replay')::boolean, false) $$;
-- the prizes a second game draws from: every prize but the replay
create or replace function app.game_prizes_real(p jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(p) with ordinality t(x, o) where not app.game_prize_is_replay(x)
$$;

-- As 0081, with the replay prize: {"key", "replay": true, "weight"} and nothing else, at most one, never alone.
create or replace function app.game_prizes_ok(p jsonb) returns boolean
language plpgsql immutable as $$
declare
  x jsonb;
  v_keys text[] := '{}';
  v_replays integer := 0;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 8 then return false; end if;
  for x in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(x) <> 'object' then return false; end if;
    if coalesce(x ->> 'key', '') !~ '^[a-z0-9_]{1,20}$' or (x ->> 'key') = any (v_keys) then return false; end if;
    v_keys := v_keys || (x ->> 'key');
    if jsonb_typeof(x -> 'weight') <> 'number' or (x ->> 'weight')::numeric <= 0 then return false; end if;
    if x ? 'replay' then
      if jsonb_typeof(x -> 'replay') <> 'boolean' or not (x ->> 'replay')::boolean then return false; end if;
      if (select count(*) from jsonb_object_keys(x) k where k not in ('key', 'replay', 'weight')) > 0 then return false; end if;
      v_replays := v_replays + 1;
      continue;
    end if;
    if ((x ? 'percent_bps')::int + (x ? 'amount_cents')::int + (x ? 'free_days')::int) <> 1 then return false; end if;
    if x ? 'percent_bps' and (jsonb_typeof(x -> 'percent_bps') <> 'number' or (x ->> 'percent_bps')::numeric not between 1 and 5000) then return false; end if;
    if x ? 'amount_cents' and (jsonb_typeof(x -> 'amount_cents') <> 'number' or (x ->> 'amount_cents')::numeric not between 100 and 100000) then return false; end if;
    if x ? 'free_days' and (jsonb_typeof(x -> 'free_days') <> 'number' or (x ->> 'free_days')::numeric not in (1, 2, 3, 4, 5, 6, 7)) then return false; end if;
    if x ? 'min_days' and (jsonb_typeof(x -> 'min_days') <> 'number' or (x ->> 'min_days')::numeric not between 1 and 30) then return false; end if;
    if x ? 'max_cents' and (jsonb_typeof(x -> 'max_cents') <> 'number' or (x ->> 'max_cents')::numeric not between 100 and 100000 or x ? 'amount_cents') then return false; end if;
    -- free days need a longer rental than the days given
    if x ? 'free_days' and coalesce((x ->> 'min_days')::numeric, 0) <= (x ->> 'free_days')::numeric then return false; end if;
  end loop;
  -- at most one replay, and a discount for the second game to draw
  return v_replays <= 1 and v_replays < jsonb_array_length(p);
end $$;

-- The table with the replay prize: the most common prize gives it 15 (its chance stays the table's total), placed after
-- the prizes at 15 or more so the table stays from most to least likely. A table that has one, or has 8 prizes, as is.
create function pg_temp.with_replay(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_top integer;
  v_out jsonb := '[]'::jsonb;
  v_placed boolean := false;
  x record;
  v_w numeric;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) >= 8 or exists (select 1 from jsonb_array_elements(p) e where e ? 'replay' or e ->> 'key' = 'replay') then return p; end if;
  select o into v_top from jsonb_array_elements(p) with ordinality t(e, o) order by (e ->> 'weight')::numeric desc, o limit 1;
  for x in select e, o from jsonb_array_elements(p) with ordinality t(e, o) order by o loop
    v_w := (x.e ->> 'weight')::numeric;
    if x.o = v_top and v_w > 15 then x.e := jsonb_set(x.e, '{weight}', to_jsonb(v_w - 15)); v_w := v_w - 15; end if;
    if not v_placed and v_w < 15 then v_out := v_out || jsonb_build_array('{"key": "replay", "replay": true, "weight": 15}'::jsonb); v_placed := true; end if;
    v_out := v_out || jsonb_build_array(x.e);
  end loop;
  if not v_placed then v_out := v_out || jsonb_build_array('{"key": "replay", "replay": true, "weight": 15}'::jsonb); end if;
  return v_out;
end $$;

alter table program_settings alter column game_prizes set default
  '[{"key": "pct5", "percent_bps": 500, "weight": 54}, {"key": "pct10", "percent_bps": 1000, "weight": 25}, {"key": "replay", "replay": true, "weight": 15},
    {"key": "pct15", "percent_bps": 1500, "weight": 4}, {"key": "amt50", "amount_cents": 5000, "min_days": 3, "weight": 1},
    {"key": "pct25", "percent_bps": 2500, "max_cents": 15000, "weight": 0.6}, {"key": "amt100", "amount_cents": 10000, "min_days": 4, "weight": 0.3},
    {"key": "day1", "free_days": 1, "min_days": 3, "max_cents": 15000, "weight": 0.1}]'::jsonb;
-- the owner asked for it: every settings row gets the replay prize (the current one included)
update program_settings set game_prizes = pg_temp.with_replay(game_prizes) where pg_temp.with_replay(game_prizes) is distinct from game_prizes;
comment on column program_settings.game_prizes is 'Discount games: the prize table. Each prize: key, weight (its chance), one of percent_bps, amount_cents or free_days, and min_days for a minimum rental length and max_cents for its own cap (a percentage or free days without one takes game_max_discount_cents). 0171: or "replay": true, another go (a second game drawn from the other prizes), at most one. Every play wins one.';
comment on column program_settings.game_dismiss_days is 'Discount games: a visitor keeps the prize drawn for them this many days (14 by default): closing a game and seeing another never draws again, and a prize won and not claimed pops up again until then (0171). Not a wait after a close.';

-- words: "another go"; on a wheel slice, a reel or a Plinko slot "REPLAY"
create or replace function app.game_prize_label(p jsonb) returns text
language sql immutable as $$
  select case when app.game_prize_is_replay(p) then 'another go'
              when p ? 'percent_bps' then trim(trailing '.' from trim(trailing '0' from to_char((p ->> 'percent_bps')::numeric / 100, 'FM990.00'))) || '% off'
              when p ? 'free_days' then (p ->> 'free_days') || case when (p ->> 'free_days')::integer = 1 then ' free day' else ' free days' end
              else '$' || trim(trailing '.' from trim(trailing '0' from to_char((p ->> 'amount_cents')::numeric / 100, 'FM999990.00'))) || ' off' end
$$;
create or replace function app.game_prize_short(p jsonb) returns text
language sql immutable as $$
  select case when app.game_prize_is_replay(p) then 'REPLAY' when p ? 'free_days' then 'FREE' else replace(app.game_prize_label(p), ' off', '') end
$$;

-- The short terms of 0081, with the replay prize named for what it is.
create or replace function app.game_terms_text() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_pct text[];
  v_other text[];
  v_caps text[];
  v_list text;
  v_top jsonb;
  v_total numeric;
  v_replay boolean;
begin
  select array_agg(replace(app.game_prize_label(x), ' off', '') order by (x ->> 'percent_bps')::numeric) filter (where x ? 'percent_bps'),
         array_agg(app.game_prize_label(x) || case when x ? 'min_days' then format(' %s+ day rentals', x ->> 'min_days') when x ? 'free_days' then '' else ' your rental' end
                   order by (x ? 'free_days'), (x ->> 'amount_cents')::numeric) filter (where not x ? 'percent_bps' and not app.game_prize_is_replay(x)),
         array_agg(app.game_prize_label(x) || ': up to ' || replace(app.fmt_money((x ->> 'max_cents')::bigint), '.00', '')) filter (where x ? 'max_cents'),
         sum((x ->> 'weight')::numeric),
         bool_or(app.game_prize_is_replay(x))
    into v_pct, v_other, v_caps, v_total, v_replay
    from jsonb_array_elements(ps.game_prizes) x;
  v_other := (select array_agg(replace(o, ' free day ', ' free day on ')) from unnest(v_other) o);
  select x into v_top from jsonb_array_elements(ps.game_prizes) x order by (x ->> 'weight')::numeric desc limit 1;
  v_list := concat_ws(', or ',
    case when cardinality(v_pct) = 1 then v_pct[1] || ' off'
         when cardinality(v_pct) > 1 then array_to_string(v_pct[1:cardinality(v_pct) - 1], ', ') || ' or ' || v_pct[cardinality(v_pct)] || ' off' end,
    array_to_string(v_other, ', or '),
    case when v_replay then 'another go (a second game, which always ends in a discount)' end);
  return 'Prizes: ' || v_list || '. '
    || case when (v_top ->> 'weight')::numeric * 2 > v_total then 'The chances differ: most players win ' || app.game_prize_label(v_top) || '. '
            else 'The chances differ by prize. ' end
    || 'Off the rental charge only' || case when ps.game_max_discount_cents is not null then ', up to ' || replace(app.fmt_money(ps.game_max_discount_cents), '.00', '') || ' per code' else '' end
    || case when cardinality(v_caps) > 0 then ' (' || array_to_string(v_caps, ', ') || ')' else '' end
    || format('. One use, on one booking, within %s days. One per person, email, phone and device. Not combinable with other promo codes.', ps.game_code_valid_days);
end $$;

-- ================================================================ 2. plays: a replay and the play it came from
alter table game_plays
  add column if not exists replayed_at timestamptz,
  add column if not exists replay_of uuid references game_plays (id) on delete set null;
create unique index if not exists game_plays_replay_of_key on game_plays (replay_of) where replay_of is not null;
comment on column game_plays.replayed_at is '0171: the visitor pressed Play again on this play''s replay prize (once).';
comment on column game_plays.replay_of is '0171: the play whose replay prize started this one (its prize was drawn without the replay prize).';

-- The prize as the browser sees it (0081), with: whether it is the replay prize, and whether this is a second game.
create or replace function app.game_play_json(g game_plays) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true, 'token', g.token, 'game', g.game,
    'prize', jsonb_build_object('key', g.prize ->> 'key', 'label', app.game_prize_label(g.prize), 'short', app.game_prize_short(g.prize),
                                'min_days', (g.prize ->> 'min_days')::integer, 'replay', app.game_prize_is_replay(g.prize),
                                'rare', coalesce((select (g.prize ->> 'weight')::numeric * 100 <= sum((x ->> 'weight')::numeric)
                                                    from jsonb_array_elements((app.settings()).game_prizes) x), false)),
    'prizes', (select jsonb_agg(jsonb_build_object('key', x ->> 'key', 'short', app.game_prize_short(x), 'label', app.game_prize_label(x), 'replay', app.game_prize_is_replay(x)) order by o)
                 from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)),
    'terms', app.game_terms_text(), 'consent', app.game_marketing_text() ->> 'text', 'revealed', g.revealed_at is not null,
    'second', g.replay_of is not null)
$$;

-- ================================================================ 3. a play: play again, and the saved prize
-- As 0170, with: p.replay_of (a revealed, unclaimed replay prize of this visitor, not replayed yet) starts the second
-- game: a different game, a prize drawn without the replay prize, marked on the first play, outside the per-visitor start
-- limit (one per replay prize). The saved play is the latest play's prize: a revealed replay not used yet comes back as
-- saved (the card offers Play again), never as a saved discount; a dry check names only a saved discount.
create or replace function app.game_start_core(p jsonb, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_vid uuid := case when p ->> 'vid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'vid')::uuid end;
  v_sid uuid := case when p ->> 'sid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'sid')::uuid end;
  v_ctx text := case when p ->> 'context' = 'booking' then 'booking' else 'site' end;
  v_seen text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p -> 'seen') = 'array' then p -> 'seen' else '[]'::jsonb end) x
                              where x = any (app.game_kinds())), '{}');
  v_email text;
  v_first text;
  v_saved boolean;
  v_cont boolean;
  v_kind text;
  g game_plays;
  o game_plays;
  r jsonb;
begin
  if not ps.game_enabled then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
  if v_vid is null then return jsonb_build_object('ok', false, 'reason', 'bad ids'); end if;
  if v_ctx = 'site' and p_user is not null then return jsonb_build_object('ok', false, 'reason', 'signed_in'); end if;
  if v_ctx = 'booking' then
    if not ps.game_booking_offer then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
    if p_user is not null then
      if app.user_is_staff(p_user) or exists (select 1 from user_roles ur where ur.user_id = p_user and ur.role::text in ('admin', 'va', 'field')) then
        return jsonb_build_object('ok', false, 'reason', 'staff');
      end if;
      select lower(u.email), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), '') into v_email, v_first from users u where u.id = p_user;
      if exists (select 1 from game_claims c where c.user_id = p_user or c.email = v_email
                    or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1)) then
        return jsonb_build_object('ok', false, 'reason', 'claimed');
      end if;
    end if;
  end if;
  if exists (select 1 from game_claims c where c.visitor_id = v_vid) then return jsonb_build_object('ok', false, 'reason', 'claimed'); end if;

  -- 0171: Play again on a replay prize: the second game (a game started by the first, so the rules for new games and the
  -- start limit do not apply; one per replay prize)
  if p ? 'replay_of' then
    select * into o from game_plays where token = p ->> 'replay_of' for update;
    if o.id is null or not (o.visitor_id = v_vid or (p_user is not null and o.user_id = p_user)) or o.user_id is distinct from p_user or o.context <> v_ctx then
      return jsonb_build_object('ok', false, 'reason', 'replay_not_found');
    end if;
    if o.revealed_at is null or o.claimed_at is not null or not app.game_prize_is_replay(o.prize) or o.replayed_at is not null then
      return jsonb_build_object('ok', false, 'reason', 'replay_used');
    end if;
    if coalesce((p ->> 'dry')::boolean, false) then return jsonb_build_object('ok', true, 'dry', true, 'replay', true); end if;
    v_kind := app.game_next_kind(v_vid, p_user, v_seen || o.game, o.game);
    if v_kind = o.game then
      v_kind := coalesce((select k from unnest(app.game_kinds_on()) k where k <> o.game order by random() limit 1), v_kind);
    end if;
    update game_plays set replayed_at = clock_timestamp() where id = o.id;
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, replay_of, created_at)
    values (v_vid, coalesce(v_sid, o.session_id), v_kind, app.game_draw(app.game_prizes_real(ps.game_prizes)),
            coalesce(case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, o.device), coalesce(left(p ->> 'path', 300), o.path),
            o.trigger, o.context, o.user_id, o.id, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g) || jsonb_build_object('context', g.context);
    if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
    return r;
  end if;

  -- the prize drawn for this visitor (or account), still open: the latest play
  select * into g from game_plays
   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at > now() - make_interval(days => ps.game_dismiss_days)
   order by created_at desc, id desc limit 1;
  v_saved := g.id is not null and g.revealed_at is not null and g.user_id is not distinct from p_user and (g.context = v_ctx or p_user is null)
             and not (app.game_prize_is_replay(g.prize) and g.replayed_at is not null);
  -- the second game of a replay prize, closed before its prize showed: it stays theirs to finish
  v_cont := g.id is not null and g.replay_of is not null and g.revealed_at is null and g.user_id is not distinct from p_user and g.context = v_ctx;
  -- 0170: a visitor known by email, or with a booking request in progress, gets no NEW game on the site; a prize they
  -- already won here and have not claimed stays theirs (0171: a replay prize not used yet, and its second game, too)
  if not v_saved and not v_cont then
    if v_ctx = 'site' and exists (select 1 from visitor_sessions s where s.visitor_id = v_vid and (s.renter_id is not null or s.user_id is not null or s.known_email is not null)) then
      return jsonb_build_object('ok', false, 'reason', 'known');
    end if;
    -- 0100: a booking request in progress (the request form's details typed in, contact capture 0090): no game on the site
    if v_ctx = 'site' and exists (select 1 from contact_captures cc where cc.visitor_id = v_vid and cc.form = 'booking_request' and cc.last_at > now() - interval '30 days') then
      return jsonb_build_object('ok', false, 'reason', 'in_progress');
    end if;
  end if;
  if coalesce((p ->> 'dry')::boolean, false) then
    -- the request-to-book form's "Your 5% off is saved" names a discount only; a replay not used yet is offered as a game
    return jsonb_build_object('ok', true, 'dry', true, 'saved', case when v_saved and not app.game_prize_is_replay(g.prize) then app.game_prize_label(g.prize) end);
  end if;

  if v_saved then
    -- 0100: already won and seen: the same play, as a saved prize (no game, no new draw, no "You won")
    r := app.game_play_json(g) || jsonb_build_object('saved', true);
  elsif v_cont or (g.id is not null and g.revealed_at is null and g.context = v_ctx and not g.game = any (v_seen) and g.user_id is not distinct from p_user) then
    -- the same page again before this browser showed it: the same play (no new play by reloading); 0171: a second game
    -- closed before its prize showed comes back as it was
    r := app.game_play_json(g);
  else
    if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
      return jsonb_build_object('ok', false, 'reason', 'limited');
    end if;
    -- the prize stays the one drawn for the visitor; a replay already used is not drawn again
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, created_at)
    values (v_vid, v_sid, app.game_next_kind(v_vid, p_user, v_seen, g.game),
            coalesce(case when not (app.game_prize_is_replay(g.prize) and g.replayed_at is not null) then g.prize end, app.game_draw(app.game_prizes_real(ps.game_prizes)),
                     app.game_draw(ps.game_prizes)),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
            case when v_ctx = 'booking' then 'booking' when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end, v_ctx, p_user, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g);
  end if;
  r := r || jsonb_build_object('context', g.context);
  if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
  return r;
end $$;

-- ================================================================ 4. a replay prize is never claimed
alter function app.server_game_claim(jsonb, uuid) rename to server_game_claim_pre0171;
create or replace function app.server_game_claim(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from game_plays g where g.token = p ->> 'token' and app.game_prize_is_replay(g.prize)) then
    return jsonb_build_object('ok', false, 'error', 'replay', 'message', 'This prize is another go, not a code. Press Play again for your second game.');
  end if;
  return app.server_game_claim_pre0171(p, p_user);
end $$;

-- ================================================================ 5. the report: plays by prize, the replay as "Play again"
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0171: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;
select pg_temp.patch_fn('app.game_report_pre0081(uuid, jsonb)'::regprocedure,
  $o$jsonb_build_object('prize', app.game_prize_label(x), 'claims',$o$,
  $n$jsonb_build_object('prize', case when app.game_prize_is_replay(x) then 'Play again' else app.game_prize_label(x) end, 'replay', app.game_prize_is_replay(x),
                 'plays', (select count(*) from plays where prize ->> 'key' = x ->> 'key'), 'claims',$n$);
select pg_temp.patch_fn('app.game_report_pre0081(uuid, jsonb)'::regprocedure,
  $o$'revealed', (select count(*) from plays where revealed_at is not null),$o$,
  $n$'revealed', (select count(*) from plays where revealed_at is not null),
    'replays', (select count(*) from plays where replay_of is not null),$n$);

-- ================================================================ 6. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['game_start_core', 'server_game_claim', 'server_game_claim_pre0171', 'game_play_json', 'game_terms_text', 'game_report_pre0081'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- pure checks the Admin's settings form and the table's check use, as game_prizes_ok (0069)
  revoke all on function app.game_prize_is_replay(jsonb), app.game_prizes_real(jsonb) from public, anon, authenticated;
  grant execute on function app.game_prize_is_replay(jsonb) to authenticated, service_role;
  grant execute on function app.game_prizes_real(jsonb) to service_role;
  grant execute on function app.game_prizes_ok(jsonb) to authenticated, service_role;
end $$;

-- ================================================================ 7. the guides
-- GUIDES 0171 START (generated by supabase/seed/0171_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'discount-games-and-leads', 'chapter', 'text-alerts-email-text-or-both', 'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (1 car page, 15 seconds, exit intent), the days a visitor keeps their prize (14), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game, a different one shows on their 2nd page view after the close (any page) or 60 seconds later, whichever first; at most 3 in one visit and 6 a day in one browser. All four are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit. After claiming, never again.
- Won and not claimed: a small badge "Your 5% off is saved" stays on the pages, and the card itself pops up again with the prize ("Your 5% off is still waiting", with the form to get the code) at the moments a game would, until they claim it or the prize ends after 14 days.
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game (or the card of a prize waiting for them), the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit. After claiming, never again.</li><li>Won and not claimed: a small badge &quot;Your 5% off is saved&quot; stays on the pages, and the card itself pops up again with the prize (&quot;Your 5% off is still waiting&quot;, with the form to get the code) at the moments a game would, until they claim it or the prize ends after 14 days.</li><li>Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>Another go: the card says &quot;You won another go!&quot; and <b class="gd-ui">Play again</b> starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, To do shows &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.</li><li>After a visitor closes a game (or the card of a prize waiting for them), the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.</li><li>Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_section('va', 'discount-game-leads', 'chapter', 'texts-and-calls', 'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**Live** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
', 'Discount game leads', 'Game leads to call or email, the code they won, whether it is used, and the Sales task.',
  'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**Live** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
',
  '<p class="gd-p">Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">Live</b> &gt; <b class="gd-ui">Game leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section><section class="gd-task" id="discount-game-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p">The card &quot;Typed into forms&quot; above the game leads lists the name, email and phone people typed into a form on the site without sending it, with &quot;On the site now&quot; and &quot;Email not confirmed&quot;. Call or email to help them finish. Only what they typed; no offers without their consent.</p></section>');
-- GUIDES 0171 END
