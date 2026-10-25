-- 0170_game_saved_claim.sql
-- The saved discount could not be claimed (docs/changes/2026-10-25-game-saved-claim.md). The owner: "it just says the
-- discount is saved and when u click get my code, nothing happens. And it never pops up again after that".
--
-- A visitor who won a prize and closed the card sees the small "Your 5% off is saved" badge on later pages. Its
-- "Get my code" asks game_start for that saved play, but game_start refused a visitor known by email (any email typed into
-- a form on the site, or a past sign-in on that browser) and a visitor with a booking request in progress before it looked
-- for the saved play, so the card closed at once and the badge came back. Those two rules are for NEW games only; a prize
-- already won and not claimed is now returned as a saved play to anyone who has not claimed one.
-- Nothing else changes: still one claim per visitor, email, phone and device; signed-in visitors get the game in the
-- request-to-book form only; a game that is closed does not show again for game_dismiss_days.

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
  g game_plays;
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

  -- the prize drawn for this visitor (or account), still open
  select * into g from game_plays
   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at > now() - make_interval(days => ps.game_dismiss_days)
   order by created_at desc limit 1;
  v_saved := g.id is not null and g.revealed_at is not null and g.user_id is not distinct from p_user and (g.context = v_ctx or p_user is null);
  -- 0170: a visitor known by email, or with a booking request in progress, gets no NEW game on the site; a prize they
  -- already won here and have not claimed stays theirs to claim (until 0170 the saved badge's "Get my code" did nothing)
  if not v_saved then
    if v_ctx = 'site' and exists (select 1 from visitor_sessions s where s.visitor_id = v_vid and (s.renter_id is not null or s.user_id is not null or s.known_email is not null)) then
      return jsonb_build_object('ok', false, 'reason', 'known');
    end if;
    -- 0100: a booking request in progress (the request form's details typed in, contact capture 0090): no game on the site
    if v_ctx = 'site' and exists (select 1 from contact_captures cc where cc.visitor_id = v_vid and cc.form = 'booking_request' and cc.last_at > now() - interval '30 days') then
      return jsonb_build_object('ok', false, 'reason', 'in_progress');
    end if;
  end if;
  if coalesce((p ->> 'dry')::boolean, false) then
    return jsonb_build_object('ok', true, 'dry', true, 'saved', case when v_saved then app.game_prize_label(g.prize) end);
  end if;

  if v_saved then
    -- 0100: already won and seen: the same play, as a saved prize (no game, no new draw, no "You won")
    r := app.game_play_json(g) || jsonb_build_object('saved', true);
  elsif g.id is not null and g.revealed_at is null and g.context = v_ctx and not g.game = any (v_seen) and g.user_id is not distinct from p_user then
    -- the same page again before this browser showed it: the same play (no new play by reloading)
    r := app.game_play_json(g);
  else
    if not app.rate_limit('game-start:' || v_vid, 10, interval '1 hour') or not app.rate_limit('game-start', 3000, interval '1 hour') then
      return jsonb_build_object('ok', false, 'reason', 'limited');
    end if;
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, created_at)
    values (v_vid, v_sid, app.game_next_kind(v_vid, p_user, v_seen, g.game), coalesce(g.prize, app.game_draw(ps.game_prizes)),
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
            case when v_ctx = 'booking' then 'booking' when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end, v_ctx, p_user, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g);
  end if;
  r := r || jsonb_build_object('context', g.context);
  if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
  return r;
end $$;

revoke all on function app.game_start_core(jsonb, uuid) from public, anon, authenticated;
grant execute on function app.game_start_core(jsonb, uuid) to service_role;
