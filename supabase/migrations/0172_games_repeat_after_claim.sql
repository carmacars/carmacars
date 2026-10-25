-- 0172_games_repeat_after_claim.sql
-- People who win a prize can play again on a later visit (docs/changes/2026-10-25-games-repeat-after-claim.md). The owner:
-- "People that win a prize should be able to play again." Until now a claim ended the games for good: one claim ever per
-- visitor, email, phone and device (0069), and the site never showed a game again.
--
-- 1. A new setting, program_settings.game_replay_after_claim_days (1 by default, 0 to 90; 0 is the old rule: one code
--    ever). A person (this browser, an email, a phone, an account in the request-to-book form) may claim a new code once
--    their latest claim is that many days old. The unique indexes on game_claims (email, phone, visitor) give way to this
--    time rule (plain indexes for the lookups); a code stays unique to its claim and its play. Two claims at the same
--    moment for one browser or one email wait for each other (advisory locks), so the rule holds.
-- 2. The play (app.game_start_core, as 0171 with): within the wait the answer stays reason "claimed", now with
--    again_after (when they may play again; none when the setting is 0); after it, the game comes back on a later visit
--    with the usual triggers as a fresh draw from the whole table (another go included): plays from before the latest
--    claim are left behind, never reused. The same wait for the request-to-book form (the account's and its email's
--    claims). While the 0171 code was in place a brand-new play never drew the replay prize (the open-play lookup came
--    back empty and the draw without the replay was taken); a new play now draws from the whole table, as 0171 meant.
-- 3. "Known by email" (0100, 0170: no new game on the site for a visitor known by email, signed in or a renter): a visitor
--    known only through their own game claim (the claim's name and email on their visits, or a click on the link of the
--    code email it sent) is not "known" for this rule, or a winner would never see a game again. Signed in, a renter
--    (a booking request makes one, as does a claim with an email that already belongs to a renter), or known by email
--    through a booking request, a sign-in link, the chat or any other email: as before. The game's own form opens a bare
--    account and renter for a brand-new email as it is typed (contact capture, 0090), which the claim then put on the
--    visitor's visits: while that renter has no booking it does not count as "a renter" here.
-- 4. The claim (app.server_game_claim_pre0081 and _pre0171, changed in place): the friendly refusals within the wait say
--    when they can play again ("You can play again after Mon, Oct 26 at 5:51 pm."; with the setting at 0 "One per person."
--    as before) and carry again_after; a claim returns again_after too. Each code is still single use, on one booking,
--    never with another code, good for game_code_valid_days with its reminders; earlier unused codes stay valid until
--    they end.
-- 5. Staff: the leads show a repeat claim as the same person (claim_no and claims_total by email: "2nd code"); a repeat
--    claim joins the person's open Sales task (a line with the new code) instead of raising a second one; the report adds
--    the number of people beside the claims (the claims tile keeps counting claims). An account opened later takes every
--    claim of its email (app.game_consent_carry), with the consent of the latest claim that gave it.
-- 6. Words: the game's terms ("One code a day per person, email, phone and device.") and the site terms (section 14,
--    where they still carry our text); the guides.
-- No applied migration is edited (functions of earlier migrations are changed in place, as 0081 and 0171 do).

-- ================================================================ 1. the setting and the table
alter table program_settings add column if not exists game_replay_after_claim_days integer not null default 1
  check (game_replay_after_claim_days between 0 and 90);
comment on column program_settings.game_replay_after_claim_days is 'Discount games (0172): a person (browser, email, phone, account) may win another code once their latest claim is this many days old (1 by default). 0: one code ever, as before 0172.';

drop index if exists game_claims_email_key;
drop index if exists game_claims_phone_key;
drop index if exists game_claims_visitor_key;
create index if not exists game_claims_email_idx on game_claims (email, created_at desc);
create index if not exists game_claims_phone_idx on game_claims (phone, created_at desc) where phone is not null;
create index if not exists game_claims_visitor_idx on game_claims (visitor_id, created_at desc);
create index if not exists game_claims_user_idx on game_claims (user_id) where user_id is not null;
comment on table game_claims is 'Discount games (0069): a prize claimed with a first name and email, its promo code and the lead. 0172: one per person (email, phone, device, account) every game_replay_after_claim_days days, checked by app.server_game_claim; a code belongs to one claim.';

-- ================================================================ 2. the wait after a claim
-- When the person whose latest claim was at p_last may play again: null when they may now (or never claimed);
-- 'infinity' when the setting is 0 (one code ever).
create or replace function app.game_again_after(p_last timestamptz) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when p_last is null then null
              when s.d = 0 then 'infinity'::timestamptz
              when p_last + make_interval(days => s.d) > now() then p_last + make_interval(days => s.d) end
    from (select (app.settings()).game_replay_after_claim_days as d) s
$$;
-- " You can play again after Mon, Oct 26 at 5:51 pm." (the setting at 0: " One per person.")
create or replace function app.game_again_words(p_again timestamptz) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_again is null then ''
              when p_again = 'infinity'::timestamptz then ' One per person.'
              else ' You can play again after ' || app.fmt_at(p_again) || '.' end
$$;
-- A refusal while the wait runs (null when the person may claim): {ok: false, error, message, again_after}.
create or replace function app.game_used(p_error text, p_message text, p_last timestamptz) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when a is not null then
    jsonb_build_object('ok', false, 'error', p_error, 'message', p_message || app.game_again_words(a))
    || case when a <> 'infinity'::timestamptz then jsonb_build_object('again_after', a) else '{}'::jsonb end end
    from (select app.game_again_after(p_last) as a) x
$$;

-- 0170's "known by email", without what the visitor's own claim left: a visitor is known when one of their visits is
-- signed in, or a renter's (not the bare account the game's own form opened for a brand-new email, contact capture 0090,
-- while it has no booking), or carries an email that did not come from their claim (the claim's email on a visit the
-- claim or the code email's link identified is not "known").
create or replace function app.game_known_visitor(p_vid uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from visitor_sessions s where s.visitor_id = p_vid
                   and (s.user_id is not null
                        or (s.renter_id is not null
                            and not exists (select 1 from renters r join capture_accounts ca on ca.user_id = r.user_id
                                             where r.id = s.renter_id and ca.opened_by_capture and ca.opened_form = 'game'
                                               and not exists (select 1 from bookings b where b.renter_id = r.id)))
                        or (s.known_email is not null
                            and not (coalesce(s.identified_by, '') in ('game', 'email_link')
                                     and exists (select 1 from game_claims c where c.visitor_id = p_vid and c.email = lower(s.known_email))))))
$$;

-- ================================================================ 3. a play
-- As 0171, with: the wait after the latest claim of this visitor (and, in the request-to-book form, of the account and
-- its email): reason "claimed" with again_after; after it, plays from before that claim are left behind (a fresh draw
-- from the whole table, another go included); a visitor known only through their own claim is not "known".
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
  v_last timestamptz;
  v_again timestamptz;
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
      select max(c.created_at) into v_last from game_claims c
       where c.user_id = p_user or c.email = v_email or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1);
    end if;
  end if;
  -- 0172: the latest claim of this browser (or account): within the wait, no game; after it, a new one
  v_last := greatest(v_last, (select max(c.created_at) from game_claims c where c.visitor_id = v_vid));
  v_again := app.game_again_after(v_last);
  if v_again is not null then
    return jsonb_build_object('ok', false, 'reason', 'claimed')
           || case when v_again <> 'infinity'::timestamptz then jsonb_build_object('again_after', v_again) else '{}'::jsonb end;
  end if;

  -- 0171: Play again on a replay prize: the second game (a game started by the first, so the rules for new games and the
  -- start limit do not apply; one per replay prize)
  if p ? 'replay_of' then
    select * into o from game_plays where token = p ->> 'replay_of' for update;
    if o.id is null or not (o.visitor_id = v_vid or (p_user is not null and o.user_id = p_user)) or o.user_id is distinct from p_user or o.context <> v_ctx then
      return jsonb_build_object('ok', false, 'reason', 'replay_not_found');
    end if;
    if o.revealed_at is null or o.claimed_at is not null or not app.game_prize_is_replay(o.prize) or o.replayed_at is not null
       or o.created_at <= coalesce(v_last, '-infinity'::timestamptz) then
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

  -- the prize drawn for this visitor (or account), still open: the latest play since their latest claim (0172)
  select * into g from game_plays
   where (visitor_id = v_vid or (p_user is not null and user_id = p_user)) and claimed_at is null
     and created_at > now() - make_interval(days => ps.game_dismiss_days) and created_at > coalesce(v_last, '-infinity'::timestamptz)
   order by created_at desc, id desc limit 1;
  v_saved := g.id is not null and g.revealed_at is not null and g.user_id is not distinct from p_user and (g.context = v_ctx or p_user is null)
             and not (app.game_prize_is_replay(g.prize) and g.replayed_at is not null);
  -- the second game of a replay prize, closed before its prize showed: it stays theirs to finish
  v_cont := g.id is not null and g.replay_of is not null and g.revealed_at is null and g.user_id is not distinct from p_user and g.context = v_ctx;
  -- 0170: a visitor known by email, or with a booking request in progress, gets no NEW game on the site; a prize they
  -- already won here and have not claimed stays theirs (0171: a replay prize not used yet, and its second game, too).
  -- 0172: known only through their own claim is not known (app.game_known_visitor)
  if not v_saved and not v_cont then
    if v_ctx = 'site' and app.game_known_visitor(v_vid) then
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
    -- the prize stays the one drawn for the visitor; a replay already used is not drawn again; nothing open: a fresh
    -- draw from the whole table (0172: another go included)
    insert into game_plays (visitor_id, session_id, game, prize, device, path, trigger, context, user_id, created_at)
    values (v_vid, v_sid, app.game_next_kind(v_vid, p_user, v_seen, g.game),
            case when g.id is null then app.game_draw(ps.game_prizes)
                 when app.game_prize_is_replay(g.prize) and g.replayed_at is not null then app.game_draw(app.game_prizes_real(ps.game_prizes))
                 else g.prize end,
            case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end, left(p ->> 'path', 300),
            case when v_ctx = 'booking' then 'booking' when p ->> 'trigger' in ('pages', 'time', 'exit') then p ->> 'trigger' end, v_ctx, p_user, clock_timestamp())
    returning * into g;
    r := app.game_play_json(g);
  end if;
  r := r || jsonb_build_object('context', g.context);
  if p_user is not null then r := r || jsonb_build_object('account', jsonb_build_object('first', v_first, 'email', v_email)); end if;
  return r;
end $$;

-- ================================================================ 4. the claim: the wait instead of one ever
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0172: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.server_game_claim_pre0081(jsonb, uuid)'::regprocedure,
  $o$  v_mk jsonb;
begin$o$,
  $n$  v_mk jsonb;
  v_used jsonb;
begin$n$);
select pg_temp.patch_fn('app.server_game_claim_pre0081(jsonb, uuid)'::regprocedure,
  $o$  -- one per email, phone and device
  select * into c from game_claims where email = v_email;
  if c.id is not null then
    -- the code goes again to its own address (never shown here), at most once a day, while it can still be used
    if c.expires_at > now() and (c.resent_at is null or c.resent_at < now() - interval '1 day')
       and not exists (select 1 from promo_redemptions r where r.promo_code_id = c.promo_code_id and r.status in ('applied', 'redeemed')) then
      perform app.emit_event('renter_game_code', 'game_claim', c.id, '{}'::jsonb, 'renter_game_code:' || c.id || ':resend:' || app.local_date(now()));
      update game_claims set resent_at = now() where id = c.id;
    end if;
    return jsonb_build_object('ok', false, 'error', 'email_used', 'message', 'This email already has a code. We sent it to that inbox again.');
  end if;
  if v_phone is not null and exists (select 1 from game_claims where phone = v_phone) then
    return jsonb_build_object('ok', false, 'error', 'phone_used', 'message', 'This mobile number already has a code. One per person.');
  end if;
  if exists (select 1 from game_claims where visitor_id = g.visitor_id) then
    return jsonb_build_object('ok', false, 'error', 'device_used', 'message', 'A code was already claimed on this device. One per person.');
  end if;$o$,
  $n$  -- 0172: one code per person every game_replay_after_claim_days days (one ever at 0): the latest claim of this email,
  -- phone or device decides; two claims at once for one device or one email wait for each other
  perform pg_advisory_xact_lock(hashtext('game-claim:' || g.visitor_id::text));
  perform pg_advisory_xact_lock(hashtext('game-claim:' || v_email));
  select * into c from game_claims where email = v_email order by created_at desc, id desc limit 1;
  v_used := app.game_used('email_used', 'This email already has a code. We sent it to that inbox again.', c.created_at);
  if v_used is not null then
    -- the code goes again to its own address (never shown here), at most once a day, while it can still be used
    if c.expires_at > now() and (c.resent_at is null or c.resent_at < now() - interval '1 day')
       and not exists (select 1 from promo_redemptions r where r.promo_code_id = c.promo_code_id and r.status in ('applied', 'redeemed')) then
      perform app.emit_event('renter_game_code', 'game_claim', c.id, '{}'::jsonb, 'renter_game_code:' || c.id || ':resend:' || app.local_date(now()));
      update game_claims set resent_at = now() where id = c.id;
    end if;
    return v_used;
  end if;
  if v_phone is not null then
    v_used := app.game_used('phone_used', 'This mobile number already has a code.', (select max(x.created_at) from game_claims x where x.phone = v_phone));
    if v_used is not null then return v_used; end if;
  end if;
  v_used := app.game_used('device_used', 'A code was already claimed on this device.', (select max(x.created_at) from game_claims x where x.visitor_id = g.visitor_id));
  if v_used is not null then return v_used; end if;$n$);
-- the claim marks a visit as identified by the game only where it brings the email (a visit known otherwise keeps saying
-- how, so app.game_known_visitor can tell)
select pg_temp.patch_fn('app.server_game_claim_pre0081(jsonb, uuid)'::regprocedure,
  $o$renter_id = coalesce(renter_id, v_renter), identified_by = coalesce(identified_by, 'game')$o$,
  $n$renter_id = coalesce(renter_id, v_renter), identified_by = coalesce(identified_by, case when known_email is null then 'game' end)$n$);
-- a repeat claim joins the person's open Sales task (a line with the new code) instead of raising a second one
select pg_temp.patch_fn('app.server_game_claim_pre0081(jsonb, uuid)'::regprocedure,
  $o$  if v_cars >= ps.game_task_min_cars then$o$,
  $n$  v_task := (select t.id from game_claims x join tasks t on t.id = x.task_id
                where x.email = v_email and x.id <> c.id and t.status in ('open', 'in_progress', 'waiting') order by x.created_at desc limit 1);
  if v_task is not null then
    update tasks set detail = concat_ws(' ', detail, format('Another code: %s (%s), expires %s.', pc.code, v_applies, app.fmt_date(pc.valid_until))), updated_at = now()
     where id = v_task;
    update game_claims set task_id = v_task where id = c.id;
  elsif v_cars >= ps.game_task_min_cars then$n$);
select pg_temp.patch_fn('app.server_game_claim_pre0081(jsonb, uuid)'::regprocedure,
  $o$'min_days', pc.min_rental_days, 'email', v_email);$o$,
  $n$'min_days', pc.min_rental_days, 'email', v_email,
    'again_after', case when ps.game_replay_after_claim_days > 0 then c.created_at + make_interval(days => ps.game_replay_after_claim_days) end);$n$);
-- the request-to-book form: the account's own claims
select pg_temp.patch_fn('app.server_game_claim_pre0171(jsonb, uuid)'::regprocedure,
  $o$  if exists (select 1 from game_claims c where c.user_id = p_user or c.email = lower(u.email)
                or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1)) then
    return jsonb_build_object('ok', false, 'error', 'claimed', 'message', 'Your account already has a code. One per person.');
  end if;$o$,
  $n$  -- 0172: the account's latest claim (its email, its renter) and the wait after it
  r := app.game_used('claimed', 'Your account already has a code.', (select max(c.created_at) from game_claims c where c.user_id = p_user or c.email = lower(u.email)
                or c.renter_id = (select rr.id from renters rr where rr.user_id = p_user limit 1)));
  if r is not null then return r; end if;$n$);

-- An account opened later with a claim's email: every claim of that email is linked to it, and the consent of the
-- latest claim that gave it carries over (0069 took one claim per email).
create or replace function app.game_consent_carry() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c game_claims;
begin
  if new.email is null then return new; end if;
  update game_claims set user_id = coalesce(user_id, new.id) where email = lower(new.email);
  select * into c from game_claims where email = lower(new.email) and marketing_consent order by created_at desc limit 1;
  if c.id is not null then perform app.game_consent_apply(new.id, c); end if;
  return new;
end $$;

-- ================================================================ 5. staff: the same person, one task, the people in the report
select pg_temp.patch_fn('app.game_leads(uuid, jsonb)'::regprocedure,
  $o$'reminder_sent_at', c.reminder_sent_at) as r$o$,
  $n$'reminder_sent_at', c.reminder_sent_at,
        'claim_no', (select count(*) from game_claims x where x.email = c.email and (x.created_at, x.id) <= (c.created_at, c.id)),
        'claims_total', (select count(*) from game_claims x where x.email = c.email)) as r$n$);
select pg_temp.patch_fn('app.game_report_pre0081(uuid, jsonb)'::regprocedure,
  $o$    'claims', (select count(*) from claims),$o$,
  $n$    'claims', (select count(*) from claims),
    'people', (select count(distinct email) from claims),$n$);

-- ================================================================ 6. words: the game's terms and the site's terms
select pg_temp.patch_fn('app.game_terms_text()'::regprocedure,
  $o$format('. One use, on one booking, within %s days. One per person, email, phone and device. Not combinable with other promo codes.', ps.game_code_valid_days)$o$,
  $n$format('. One use, on one booking, within %s days. %s Not combinable with other promo codes.', ps.game_code_valid_days,
              case ps.game_replay_after_claim_days when 0 then 'One per person, email, phone and device.'
                   when 1 then 'One code a day per person, email, phone and device.'
                   else format('One code every %s days per person, email, phone and device.', ps.game_replay_after_claim_days) end)$n$);

-- the site terms, section 14 (0069), where they still carry our sentence; an Admin's own edit is left as it is
update site_content_blocks
   set body = replace(body, 'One code per person, email address, mobile number and device.',
                      'Each person, email address, mobile number and device may claim one code a day, or less often as shown with the game, and one code applies per booking.')
 where block_key = 'legal.terms' and body like '%One code per person, email address, mobile number and device.%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 25, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 19, 2026', 'October 20, 2026', 'October 21, 2026', 'October 22, 2026', 'October 23, 2026', 'October 24, 2026');

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['game_start_core', 'server_game_claim_pre0081', 'server_game_claim_pre0171', 'game_again_after', 'game_again_words',
                                                         'game_used', 'game_known_visitor', 'game_leads', 'game_report_pre0081', 'game_terms_text', 'game_consent_carry'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 8. the guides
-- GUIDES 0172 START (generated by supabase/seed/0172_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'discount-games-and-leads', 'chapter', 'text-alerts-email-text-or-both', 'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

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
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.
- After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.
- Won and not claimed: a small badge "Your 5% off is saved" stays on the pages, and the card itself pops up again with the prize ("Your 5% off is still waiting", with the form to get the code) at the moments a game would, until they claim it or the prize ends after 14 days.
- Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- Another go: the card says "You won another go!" and **Play again** starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game (or the card of a prize waiting for them), the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.</li><li>After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.</li><li>Won and not claimed: a small badge &quot;Your 5% off is saved&quot; stays on the pages, and the card itself pops up again with the prize (&quot;Your 5% off is still waiting&quot;, with the form to get the code) at the moments a game would, until they claim it or the prize ends after 14 days.</li><li>Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>Another go: the card says &quot;You won another go!&quot; and <b class="gd-ui">Play again</b> starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows &quot;2nd code of 2&quot; under the name on each of their lines.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, To do shows &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.</li><li>After a visitor closes a game (or the card of a prize waiting for them), the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.</li><li>Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_section('va', 'discount-game-leads', 'chapter', 'texts-and-calls', 'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.

## Game leads

**Live** > **Game leads**.

1. Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.
2. Press **Call** or **Email**. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press **Contacted**.
3. **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.

A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.

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

People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with "2nd code of 2" under the name. It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.

> Tip: Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.

## Contact details typed into forms

The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.
',
  '<p class="gd-p">Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email and sometimes a mobile number. Customer service and Sales follow them up.</p><section class="gd-task" id="discount-game-leads-game-leads" data-gd-task><h2 class="gd-h2">Game leads</h2><p class="gd-p"><b class="gd-ui">Live</b> &gt; <b class="gd-ui">Game leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press <b class="gd-ui">Contacted</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li></ol></div><p class="gd-p">A visitor who viewed 3 cars or more also raises a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request. A visitor who wins another go plays a second game first; only the code they end with shows here.</p><p class="gd-p">People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with &quot;2nd code of 2&quot; under the name. It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.</div></aside></section><section class="gd-task" id="discount-game-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p">The card &quot;Typed into forms&quot; above the game leads lists the name, email and phone people typed into a form on the site without sending it, with &quot;On the site now&quot; and &quot;Email not confirmed&quot;. Call or email to help them finish. Only what they typed; no offers without their consent.</p></section>');
-- GUIDES 0172 END
