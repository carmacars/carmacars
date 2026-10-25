-- 0146_review_requests.sql
-- The review request program (docs/changes/2026-10-24-review-requests.md). The owner, October 24, 2026: ask every
-- renter for a review at the right moment, by email and text, never while charges are still open, stop as soon as they
-- reviewed, and make the review itself fast: the renter picks what they liked, says one sentence, and gets a short draft
-- made only of their own answers and the facts of their booking, to copy and post on Google.
--
-- 1. Settings (Program settings, review_*; Admin > Settings > Reviews): on by default. Mid-trip check-in for rentals of
--    2 days or more (24 hours after the pickup; no review ask in it), the review request at the return (1 hour after the
--    check-in), a reminder 24 hours later and a final follow-up 7 days after the request. Sent only from 9 am to 9 pm
--    Toronto time; a step due outside those hours goes at 9 am. Site settings: the Google review link (else the one
--    made from the Google place id).
-- 2. review_requests: one row per booking (made when the booking is on a trip, returned or closed), its token for the
--    review page without sign-in (/review/<token>), each step's time, the hold and why, the stop and why.
-- 3. The sequence: app.job_review_requests (every 10 minutes): check-in, request, reminder, final. Email and text follow
--    the person's channel (0096); the request and its follow-ups are marketing under the existing business relationship:
--    never after an unsubscribe (implied consent), and the outbox adds the unsubscribe link and the mailing address.
-- 4. The hold: a booking with a return charge or a later charge (late return, kilometres, fuel, cleaning, smoking,
--    damage, tolls and tickets, other charges after the return) not yet settled or waived, a toll or damage matched to
--    the renter and not yet charged, or an open incident or dispute, gets no review request. It is on the "Review
--    requests on hold" list (Admin > Reviews, customer service's Review requests) and released by itself when the
--    charges are settled or waived; staff may press Send anyway. Replaces 0025's decision task while the program is on.
-- 5. The stop: the renter presses "I already left a review", staff mark it reviewed, an on-site review is left, or a
--    Google review is matched to the renter.
-- 6. Google: the Business Profile reviews sync (the Worker's job reads accounts.locations.reviews.list with the
--    refresh token of rent@carmacars.ca kept in the vault), reviews matched to renters by name within a time window
--    after the return; staff confirm, reject or assign a match. Without the API's approval the screen says so and
--    everything else works.
-- 7. Staff: "Ask for a review" on any booking (now, or at 9 am), Mark reviewed, Send anyway; Admin > Reviews: requests
--    sent, on hold, reviews detected, average rating, the hold list and the Google matches.
-- 8. The four notifications (renter_trip_checkin, renter_review_ask, renter_review_reminder, renter_review_final) and
--    their texts. While the program is on, 0023's and 0061's review emails are not sent (they would ask twice).
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists review_program_enabled boolean not null default true,
  add column if not exists review_checkin_enabled boolean not null default true,
  add column if not exists review_checkin_min_days integer not null default 2 check (review_checkin_min_days between 1 and 30),
  add column if not exists review_checkin_after_hours integer not null default 24 check (review_checkin_after_hours between 1 and 240),
  add column if not exists review_ask_after_minutes integer not null default 60 check (review_ask_after_minutes between 0 and 10080),
  add column if not exists review_reminder_hours integer not null default 24 check (review_reminder_hours between 1 and 336),
  add column if not exists review_final_days integer not null default 7 check (review_final_days between 1 and 60),
  add column if not exists review_send_from_hour integer not null default 9 check (review_send_from_hour between 0 and 23),
  add column if not exists review_send_until_hour integer not null default 21 check (review_send_until_hour between 1 and 24),
  add column if not exists review_hold_incidentals boolean not null default true,
  add column if not exists review_ask_max_days integer not null default 45 check (review_ask_max_days between 1 and 365),
  add column if not exists review_google_match_days integer not null default 30 check (review_google_match_days between 1 and 365),
  add column if not exists review_google_auto_match boolean not null default true;
alter table program_settings add constraint program_settings_review_hours_check check (review_send_from_hour < review_send_until_hour);
alter table program_settings add constraint program_settings_review_final_check check (review_final_days * 24 > review_reminder_hours);

comment on column program_settings.review_program_enabled is 'Review requests (0146): the mid-trip check-in, the review request at the return, the reminder and the final follow-up, by email and text. Off: nothing is sent (0023''s and 0061''s review emails come back).';
comment on column program_settings.review_checkin_enabled is 'Review requests: the mid-trip check-in ("How''s the car? Reply or call if anything''s off"), no review ask in it.';
comment on column program_settings.review_checkin_min_days is 'Review requests: the check-in goes only to rentals of at least this many days.';
comment on column program_settings.review_checkin_after_hours is 'Review requests: the check-in goes this many hours after the pickup (never in the last 6 hours before the return).';
comment on column program_settings.review_ask_after_minutes is 'Review requests: the review request goes this many minutes after the check-in (the car returned).';
comment on column program_settings.review_reminder_hours is 'Review requests: the reminder goes this many hours after the review request.';
comment on column program_settings.review_final_days is 'Review requests: the final follow-up goes this many days after the review request.';
comment on column program_settings.review_send_from_hour is 'Review requests: emails and texts go from this Toronto hour (9 is 9 am). A step due earlier waits for it.';
comment on column program_settings.review_send_until_hour is 'Review requests: and until this Toronto hour (21 is 9 pm). A step due later waits for the next morning.';
comment on column program_settings.review_hold_incidentals is 'Review requests: no review request while a return charge or a later charge (late, kilometres, fuel, cleaning, smoking, damage, tolls) is not settled or waived; released by itself.';
comment on column program_settings.review_ask_max_days is 'Review requests: a review request not sent this many days after the return (held all that time) is not sent any more.';
comment on column program_settings.review_google_match_days is 'Review requests: a Google review is matched to renters who returned a car in this many days before it.';
comment on column program_settings.review_google_auto_match is 'Review requests: a Google review whose name clearly matches one renter is matched at once (and stops their reminders); otherwise staff confirm it.';

alter table site_settings add column if not exists google_review_link text;
alter table site_settings add constraint site_settings_google_review_link_check
  check (google_review_link is null or google_review_link ~ '^https://[^[:space:]<>"]+$');
comment on column site_settings.google_review_link is 'The link that opens the Google review form (for example https://g.page/r/.../review). Empty: made from google_place_id (0146).';

-- the Google review form: the link set in Site settings, else the one made from the place id (0061)
create or replace function app.google_review_url() returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(s.google_review_link), ''),
                  case when nullif(btrim(s.google_place_id), '') is not null then 'https://search.google.com/local/writereview?placeid=' || s.google_place_id end)
    from site_settings s limit 1
$$;

-- ================================================================ 2. the requests
create table if not exists review_requests (
  booking_id        uuid primary key references bookings (id) on delete cascade,
  token             uuid not null unique default gen_random_uuid(),
  status            text not null default 'waiting' check (status in ('waiting', 'held', 'asked', 'finished', 'stopped')),
  checkin_sent_at   timestamptz,
  ask_sent_at       timestamptz,
  reminder_sent_at  timestamptz,
  final_sent_at     timestamptz,
  manual_asks       integer not null default 0,
  last_manual_at    timestamptz,
  manual_pending    boolean not null default false,
  manual_by         uuid references users (id) on delete set null,
  hold_reasons      text[] not null default '{}',
  held_since        timestamptz,
  released_at       timestamptz,
  send_anyway_at    timestamptz,
  send_anyway_by    uuid references users (id) on delete set null,
  stop_reason       text check (stop_reason in ('renter_said_reviewed', 'staff_marked_reviewed', 'onsite_review', 'google_review',
                                                'staff_declined', 'unsubscribed', 'too_late')),
  stopped_at        timestamptz,
  stopped_by        uuid references users (id) on delete set null,
  helper_opened_at  timestamptz,
  copied_at         timestamptz,
  google_opened_at  timestamptz,
  unhappy_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check ((status = 'stopped') = (stop_reason is not null)),
  check ((stop_reason is null) = (stopped_at is null))
);
create index if not exists review_requests_status on review_requests (status);
create trigger review_requests_updated before update on review_requests for each row execute function app.set_updated_at();
create trigger audit_review_requests after insert or update or delete on review_requests for each row execute function app.audit_row();
alter table review_requests enable row level security;
create policy admin_all on review_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on review_requests from anon, authenticated;
grant all on review_requests to service_role;
comment on table review_requests is 'The review request of a booking (0146): the token of its review page (/review/<token>, no sign-in), each step sent, the hold (open charges) and the stop (reviewed, unsubscribed, too late).';
comment on column review_requests.token is 'The secret of the review page without sign-in, in the emails and texts. Shows only the renter''s first name and the booking''s car, length and handover.';

create table if not exists google_reviews (
  id             text primary key check (length(id) between 1 and 300),
  reviewer_name  text,
  star_rating    smallint check (star_rating between 1 and 5),
  comment        text,
  reply          text,
  reviewed_at    timestamptz not null,
  updated_at_google timestamptz,
  booking_id     uuid references bookings (id) on delete set null,
  match_status   text not null default 'unmatched' check (match_status in ('unmatched', 'suggested', 'matched', 'confirmed', 'rejected')),
  match_score    numeric(4, 3),
  match_by       uuid references users (id) on delete set null,
  match_at       timestamptz,
  first_seen_at  timestamptz not null default now(),
  synced_at      timestamptz not null default now(),
  check (match_status not in ('suggested', 'matched', 'confirmed') or booking_id is not null)
);
create index if not exists google_reviews_booking on google_reviews (booking_id);
create index if not exists google_reviews_when on google_reviews (reviewed_at desc);
create trigger audit_google_reviews after insert or update or delete on google_reviews for each row execute function app.audit_row();
alter table google_reviews enable row level security;
create policy admin_all on google_reviews for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on google_reviews from anon, authenticated;
grant all on google_reviews to service_role;
comment on table google_reviews is 'Reviews of the CarmaCars Business Profile read from Google (0146) and the renter each is matched to: matched (by name, clearly one renter), suggested (staff confirm), confirmed or rejected by staff.';

create table if not exists review_google_link (
  id             boolean primary key default true check (id),
  status         text not null default 'not_connected' check (status in ('not_connected', 'connected', 'api_not_approved', 'error')),
  account_email  text,
  account_name   text check (account_name is null or account_name ~ '^accounts/[0-9A-Za-z_-]+$'),
  location_name  text check (location_name is null or location_name ~ '^locations/[0-9A-Za-z_-]+$'),
  location_title text,
  connected_at   timestamptz,
  connected_by   uuid references users (id) on delete set null,
  last_sync_at   timestamptz,
  last_ok_at     timestamptz,
  last_error     text,
  reviews_seen   integer not null default 0,
  updated_at     timestamptz not null default now()
);
insert into review_google_link (id) values (true) on conflict do nothing;
create trigger review_google_link_updated before update on review_google_link for each row execute function app.set_updated_at();
create trigger audit_review_google_link after insert or update or delete on review_google_link for each row execute function app.audit_row();
alter table review_google_link enable row level security;
create policy admin_all on review_google_link for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on review_google_link from anon, authenticated;
grant all on review_google_link to service_role;
comment on table review_google_link is 'The Google Business Profile connection for the reviews sync (0146). The refresh token is in the vault (google_reviews_refresh_token), never here.';

-- ================================================================ 3. the facts: hold, stop, timing
-- A charge type's reason on the hold list.
create or replace function app.review_charge_reason(p_type text) returns text
language sql immutable as $$
  select case
    when p_type in ('late_return_fee', 'late_return_extra_days') then 'late'
    when p_type = 'mileage_overage' then 'km'
    when p_type in ('fuel', 'recharging', 'fuel_service_fee') then 'fuel'
    when p_type in ('cleaning', 'cleaning_heavy', 'pet_cleaning') then 'cleaning'
    when p_type = 'smoking' then 'smoking'
    when p_type in ('damage_at_cost', 'deductible', 'loss_of_use', 'admin_fee_claim') then 'damage'
    when p_type in ('toll_amount', 'toll_admin_fee', 'ticket_amount', 'ticket_admin_fee') then 'tolls'
    when p_type in ('lost_key_cost', 'lost_key_fee', 'admin_fee_other', 'roadside_callout', 'recovery_cost', 'collection_cost',
                    'interest', 'declined_payment') then 'other'
  end
$$;

-- What keeps a booking's review request on hold: each open item with its reason. A return or later charge line not on a
-- statement yet, or on one not paid (the deposit or the card did not cover it); a toll or damage matched to the renter
-- and not charged yet; an open incident or dispute. A waived line is voided (0130), so it never counts.
create or replace function app.review_hold_items(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'reason', x ->> 'label'), '[]'::jsonb) from (
    select jsonb_build_object('reason', app.review_charge_reason(li.charge_type), 'label', coalesce(nullif(li.description, ''), ft.label),
             'amount_cents', li.amount_cents + li.hst_cents, 'kind', 'charge',
             'state', case when li.statement_id is null then 'not on a statement yet' else 'statement not paid' end) x
      from booking_line_items li join fee_types ft on ft.code = li.charge_type
      left join booking_statements s on s.id = li.statement_id
     where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.amount_cents > 0
       and li.stage in ('check_in', 'after_return') and app.review_charge_reason(li.charge_type) is not null
       and (li.statement_id is null
            or (s.paid_at is null and s.charges_cents + s.hst_cents - s.deposit_applied_cents - s.charged_to_card_cents > 0))
    union all
    select jsonb_build_object('reason', 'tolls', 'label', initcap(replace(t.kind, '_', ' ')), 'amount_cents', t.amount_cents, 'kind', 'toll',
             'state', 'matched, not charged yet')
      from toll_tickets t
     where t.booking_id = p_booking and t.matched_to = 'renter' and t.status in ('logged', 'matched', 'disputed')
    union all
    select jsonb_build_object('reason', 'damage', 'label', 'Damage found after the rental', 'amount_cents', d.cost_cents, 'kind', 'damage',
             'state', 'matched, not charged yet')
      from damage_intakes d
     where d.booking_id = p_booking and d.matched_to = 'renter' and d.status in ('logged', 'matched')
    union all
    select jsonb_build_object('reason', 'incident', 'label', 'Incident ' || coalesce(i.incident_number, ''), 'amount_cents', null, 'kind', 'incident', 'state', 'open')
      from incidents i where i.booking_id = p_booking and i.status <> 'closed'
    union all
    select jsonb_build_object('reason', 'dispute', 'label', 'Card dispute', 'amount_cents', null, 'kind', 'dispute', 'state', 'open')
      from disputes d where d.booking_id = p_booking and d.status in ('open', 'evidence_submitted')
  ) q
$$;

create or replace function app.review_hold_reasons(p_booking uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct x ->> 'reason' order by x ->> 'reason'), '{}') from jsonb_array_elements(app.review_hold_items(p_booking)) x
$$;

-- The moment the car came back: the check-in, else the change to returned, else the return time.
create or replace function app.review_returned_at(p_booking uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.checked_in_at,
                  (select max(h.changed_at) from status_history h where h.entity = 'booking' and h.entity_id = b.id and h.to_status = 'returned'),
                  b.return_at)
    from bookings b where b.id = p_booking
$$;

-- Inside the sending hours (Toronto)?
create or replace function app.review_in_window(p_now timestamptz, p_from integer, p_until integer) returns boolean
language sql immutable as $$
  select extract(hour from p_now at time zone 'America/Toronto') >= p_from and extract(hour from p_now at time zone 'America/Toronto') < p_until
$$;

-- The first moment at or after p_due inside the sending hours.
create or replace function app.review_next_window(p_due timestamptz, p_from integer, p_until integer) returns timestamptz
language plpgsql immutable as $$
declare
  l timestamp := p_due at time zone 'America/Toronto';
begin
  if extract(hour from l) >= p_from and extract(hour from l) < p_until then return p_due; end if;
  if extract(hour from l) >= p_until then l := date_trunc('day', l) + interval '1 day'; else l := date_trunc('day', l); end if;
  return (l + make_interval(hours => p_from)) at time zone 'America/Toronto';
end $$;

-- May the renter be asked (marketing under implied consent): not unsubscribed; a renter without an account by the
-- address's own suppression.
create or replace function app.review_may_ask(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when r.user_id is not null then app.has_marketing_consent(r.user_id, 'implied')
              else nullif(btrim(coalesce(r.email, '')), '') is null or not app.email_suppressed(r.email, true) end
    from bookings b join renters r on r.id = b.renter_id where b.id = p_booking
$$;

-- Reviewed already? (the stop reasons that come from facts)
create or replace function app.review_found(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when exists (select 1 from reviews r where r.booking_id = p_booking) then 'onsite_review'
              when exists (select 1 from google_reviews g where g.booking_id = p_booking and g.match_status in ('matched', 'confirmed')) then 'google_review'
              when exists (select 1 from review_request_decisions d where d.booking_id = p_booking and d.status = 'skip') then 'staff_declined' end
$$;

create or replace function app.review_request_row(p_booking uuid) returns review_requests
language plpgsql security definer set search_path = public, app as $$
declare
  rr review_requests;
begin
  insert into review_requests (booking_id) values (p_booking) on conflict (booking_id) do nothing;
  select * into rr from review_requests where booking_id = p_booking;
  return rr;
end $$;

create or replace function app.review_stop(p_booking uuid, p_reason text, p_by uuid default null) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.review_request_row(p_booking);
  update review_requests set status = 'stopped', stop_reason = p_reason, stopped_at = now(), stopped_by = p_by, manual_pending = false
   where booking_id = p_booking and status <> 'stopped';
  return found;
end $$;

-- The notification of one step. Emitted once per booking and step (the dedupe key of app.ntf_emit).
create or replace function app.review_emit(p_code text, p_booking uuid, p_disc text) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  return app.ntf_emit(p_code, 'booking', p_booking, p_disc, jsonb_build_object('booking_id', p_booking)) is not null;
end $$;

-- ================================================================ 4. the sequence
-- One booking, one tick: what is due now. Returns the step sent ('checkin', 'ask', 'reminder', 'final', 'manual'),
-- 'held', 'stopped:<reason>' or null.
create or replace function app.review_step(p_booking uuid, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  b bookings;
  rr review_requests;
  v_found text;
  v_reasons text[];
  v_back timestamptz;
  v_open boolean := app.review_in_window(p_now, s.review_send_from_hour, s.review_send_until_hour);
  v_start timestamptz;
begin
  if not s.review_program_enabled then return null; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.status not in ('on_rent', 'returned', 'closed') then return null; end if;
  rr := app.review_request_row(p_booking);
  if rr.status in ('stopped', 'finished') then return null; end if;
  -- reviewed already: stop
  v_found := app.review_found(p_booking);
  if v_found is not null then
    perform app.review_stop(p_booking, v_found);
    return 'stopped:' || v_found;
  end if;

  -- the mid-trip check-in (no review ask, no hold, not marketing)
  if b.status = 'on_rent' then
    v_start := coalesce(b.handed_over_at, b.pickup_at);
    if s.review_checkin_enabled and rr.checkin_sent_at is null and v_open
       and b.return_at - v_start >= make_interval(days => s.review_checkin_min_days)
       and p_now >= v_start + make_interval(hours => s.review_checkin_after_hours)
       and p_now <= b.return_at - interval '6 hours' then
      if app.review_emit('renter_trip_checkin', p_booking, 'checkin') then
        update review_requests set checkin_sent_at = p_now where booking_id = p_booking;
        return 'checkin';
      end if;
    end if;
    return null;
  end if;

  v_back := app.review_returned_at(p_booking);
  -- a request that could not go within the window (held all that time): no more
  if rr.ask_sent_at is null and not rr.manual_pending and p_now > v_back + make_interval(days => s.review_ask_max_days) then
    perform app.review_stop(p_booking, 'too_late');
    return 'stopped:too_late';
  end if;
  -- held: open charges (only when the hold is on); staff's Send anyway overrides
  v_reasons := case when s.review_hold_incidentals and rr.send_anyway_at is null then app.review_hold_reasons(p_booking) else '{}' end;
  if cardinality(v_reasons) > 0 and rr.final_sent_at is null then
    update review_requests set status = 'held', hold_reasons = v_reasons, held_since = coalesce(held_since, p_now), manual_pending = false
     where booking_id = p_booking;
    return 'held';
  end if;
  if rr.status = 'held' then
    update review_requests set status = case when ask_sent_at is null then 'waiting' else 'asked' end, hold_reasons = '{}', released_at = p_now
     where booking_id = p_booking returning * into rr;
  end if;

  -- the request
  if rr.ask_sent_at is null then
    if not rr.manual_pending and p_now < v_back + make_interval(mins => s.review_ask_after_minutes) then return null; end if;
    if not app.review_may_ask(p_booking) then
      perform app.review_stop(p_booking, 'unsubscribed');
      return 'stopped:unsubscribed';
    end if;
    if not v_open then return null; end if;
    perform app.review_emit('renter_review_ask', p_booking, 'ask');
    update review_requests set ask_sent_at = p_now, status = 'asked', manual_pending = false where booking_id = p_booking;
    return case when rr.manual_pending then 'manual' else 'ask' end;
  end if;

  -- a staff member's ask again (after the request): once, inside the sending hours
  if rr.manual_pending then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then
      perform app.review_stop(p_booking, 'unsubscribed');
      return 'stopped:unsubscribed';
    end if;
    perform app.review_emit('renter_review_ask', p_booking, 'manual:' || rr.manual_asks);
    update review_requests set manual_pending = false where booking_id = p_booking;
    return 'manual';
  end if;

  -- the reminder, then the final follow-up
  if rr.reminder_sent_at is null and p_now >= rr.ask_sent_at + make_interval(hours => s.review_reminder_hours) then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then perform app.review_stop(p_booking, 'unsubscribed'); return 'stopped:unsubscribed'; end if;
    perform app.review_emit('renter_review_reminder', p_booking, 'reminder');
    update review_requests set reminder_sent_at = p_now where booking_id = p_booking;
    return 'reminder';
  end if;
  if rr.final_sent_at is null and p_now >= rr.ask_sent_at + make_interval(days => s.review_final_days) then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then perform app.review_stop(p_booking, 'unsubscribed'); return 'stopped:unsubscribed'; end if;
    perform app.review_emit('renter_review_final', p_booking, 'final');
    update review_requests set final_sent_at = p_now, status = 'finished' where booking_id = p_booking;
    return 'final';
  end if;
  return null;
end $$;

-- Every booking that may have a step: on a trip now, or back within the request's window (plus the final follow-up).
create or replace function app.job_review_requests(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  v text;
  n jsonb := '{}'::jsonb;
begin
  if not s.review_program_enabled then return 'review requests are off'; end if;
  for r in
    select b.id from bookings b
     where b.booking_type <> 'owner'
       and ((b.status = 'on_rent' and b.return_at > p_now)
            or (b.status in ('returned', 'closed') and coalesce(b.checked_in_at, b.return_at) > p_now - make_interval(days => s.review_ask_max_days + s.review_final_days + 1)))
       and not exists (select 1 from review_requests x where x.booking_id = b.id and x.status in ('stopped', 'finished'))
     order by b.return_at
  loop
    v := app.review_step(r.id, p_now);
    if v is not null then
      v := split_part(v, ':', 1);
      n := n || jsonb_build_object(v, coalesce((n ->> v)::integer, 0) + 1);
    end if;
  end loop;
  return 'review requests: ' || coalesce((select string_agg(k || ' ' || x, ', ' order by k) from jsonb_each_text(n) e(k, x)), 'nothing due');
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-review-requests', '3,13,23,33,43,53 * * * *', $q$select app.job_review_requests()$q$);
  end if;
end $$;

-- An on-site review stops the sequence at once.
create or replace function app.review_requests_on_review() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.review_stop(new.booking_id, 'onsite_review');
  return null;
end $$;
create trigger reviews_stop_review_requests after insert on reviews for each row execute function app.review_requests_on_review();

-- ================================================================ 5. the earlier review emails while the program is on
-- 0023's renter_review_request and 0061's renter_google_review_request would ask a second time: not recorded, so not sent.
create or replace function app.review_program_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.code in ('renter_review_request', 'renter_google_review_request') and (app.settings()).review_program_enabled then
    return null;
  end if;
  return new;
end $$;
create trigger marketing_sends_review_program before insert on marketing_sends for each row execute function app.review_program_guard();

-- 0025's decision task for a problem booking: the hold list replaces it while the program is on.
alter function app.hold_review_request(uuid) rename to hold_review_request_pre0146;
create or replace function app.hold_review_request(p_booking uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if (app.settings()).review_program_enabled then return false; end if;
  return app.hold_review_request_pre0146(p_booking);
end $$;
select pg_temp.copy_grants('app.hold_review_request(uuid)'::regprocedure, 'app.hold_review_request_pre0146(uuid)'::regprocedure);

-- 0025's yes or no (Admin > Reviews, a task left from before): yes is Send anyway, no stops the requests.
alter function app.decide_review_request(uuid, uuid, boolean, text) rename to decide_review_request_pre0146;
create or replace function app.decide_review_request(p_booking uuid, p_by uuid, p_send boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.settings()).review_program_enabled then return app.decide_review_request_pre0146(p_booking, p_by, p_send, p_note); end if;
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Customer service or an Admin decides' using errcode = '42501';
  end if;
  update review_request_decisions set status = case when p_send then 'send' else 'skip' end, decided_by = p_by, decided_at = now(), note = p_note
   where booking_id = p_booking and status = 'pending';
  perform app.resolve_tasks(array['review_request_decision'], p_booking, null, case when p_send then 'Yes' else 'No' end);
  if p_send then return app.review_send_anyway(p_by, p_booking); end if;
  perform app.review_stop(p_booking, 'staff_declined', p_by);
  return jsonb_build_object('sent', false, 'reason', 'staff said no');
end $$;
select pg_temp.copy_grants('app.decide_review_request(uuid, uuid, boolean, text)'::regprocedure, 'app.decide_review_request_pre0146(uuid, uuid, boolean, text)'::regprocedure);

-- ================================================================ 6. staff
create or replace function app.review_may_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and app.user_is_staff(p_user)
$$;

create or replace function app.review_booking_id(p_ref text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select id from bookings where id::text = p_ref or booking_number = p_ref limit 1
$$;

-- One booking's review request for the booking page: where it is, what comes next and when, the hold, the stop.
create or replace function app.review_request_panel(p_user uuid, p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  b bookings;
  rr review_requests;
  v_back timestamptz;
  v_next text;
  v_next_at timestamptz;
  v_start timestamptz;
begin
  if not app.review_may_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into rr from review_requests where booking_id = p_booking;
  v_back := case when b.status in ('returned', 'closed') then app.review_returned_at(p_booking) end;
  v_start := coalesce(b.handed_over_at, b.pickup_at);
  if s.review_program_enabled and coalesce(rr.status, 'waiting') not in ('stopped', 'finished') and b.booking_type <> 'owner' then
    if b.status in ('confirmed', 'on_rent') and rr.checkin_sent_at is null and s.review_checkin_enabled
       and b.return_at - v_start >= make_interval(days => s.review_checkin_min_days) then
      v_next := 'checkin'; v_next_at := v_start + make_interval(hours => s.review_checkin_after_hours);
    elsif b.status in ('confirmed', 'on_rent') then
      v_next := 'ask'; v_next_at := b.return_at + make_interval(mins => s.review_ask_after_minutes);
    elsif rr.ask_sent_at is null then
      v_next := 'ask'; v_next_at := v_back + make_interval(mins => s.review_ask_after_minutes);
    elsif rr.reminder_sent_at is null then
      v_next := 'reminder'; v_next_at := rr.ask_sent_at + make_interval(hours => s.review_reminder_hours);
    elsif rr.final_sent_at is null then
      v_next := 'final'; v_next_at := rr.ask_sent_at + make_interval(days => s.review_final_days);
    end if;
    if v_next_at is not null then
      v_next_at := app.review_next_window(greatest(v_next_at, now()), s.review_send_from_hour, s.review_send_until_hour);
    end if;
  end if;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'booking_status', b.status, 'owner_booking', b.booking_type = 'owner',
    'enabled', s.review_program_enabled,
    'status', coalesce(rr.status, 'waiting'), 'stop_reason', rr.stop_reason, 'stopped_at', rr.stopped_at,
    'checkin_sent_at', rr.checkin_sent_at, 'ask_sent_at', rr.ask_sent_at, 'reminder_sent_at', rr.reminder_sent_at, 'final_sent_at', rr.final_sent_at,
    'manual_asks', coalesce(rr.manual_asks, 0), 'last_manual_at', rr.last_manual_at, 'manual_pending', coalesce(rr.manual_pending, false),
    'held', rr.status = 'held', 'hold_items', case when b.status in ('returned', 'closed') then app.review_hold_items(p_booking) else '[]'::jsonb end,
    'held_since', rr.held_since, 'send_anyway_at', rr.send_anyway_at,
    'returned_at', v_back, 'pickup_at', v_start, 'return_at', b.return_at,
    'next', v_next, 'next_at', v_next_at,
    'helper_opened_at', rr.helper_opened_at, 'google_opened_at', rr.google_opened_at, 'unhappy_at', rr.unhappy_at,
    'may_ask', b.booking_type <> 'owner' and b.status in ('on_rent', 'returned', 'closed') and coalesce(rr.status, '') <> 'stopped',
    'consent', app.review_may_ask(p_booking),
    'onsite_review', (select jsonb_build_object('rating', r.rating, 'status', r.status) from reviews r where r.booking_id = p_booking),
    'google_review', (select jsonb_build_object('rating', g.star_rating, 'status', g.match_status, 'reviewer', g.reviewer_name, 'at', g.reviewed_at)
                        from google_reviews g where g.booking_id = p_booking and g.match_status in ('matched', 'confirmed', 'suggested') order by g.reviewed_at desc limit 1),
    'settings', jsonb_build_object('from_hour', s.review_send_from_hour, 'until_hour', s.review_send_until_hour, 'reminder_hours', s.review_reminder_hours,
                                   'final_days', s.review_final_days, 'ask_after_minutes', s.review_ask_after_minutes,
                                   'checkin_after_hours', s.review_checkin_after_hours, 'checkin_min_days', s.review_checkin_min_days, 'checkin_enabled', s.review_checkin_enabled));
end $$;

-- "Ask for a review": now inside the sending hours, else at the next opening. Any staff member, any booking on a trip,
-- returned or closed. A held booking is sent anyway (the staff member decided). Not twice within 24 hours.
create or replace function app.review_ask_now(p_user uuid, p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  b bookings;
  rr review_requests;
  v_step text;
begin
  if not app.review_may_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking gets no review request' using errcode = '23514'; end if;
  if b.status not in ('on_rent', 'returned', 'closed') then raise exception 'Ask once the renter has the car or has returned it' using errcode = '23514'; end if;
  if not s.review_program_enabled then raise exception 'Review requests are off (Admin > Settings > Reviews)' using errcode = '23514'; end if;
  rr := app.review_request_row(p_booking);
  if rr.status = 'stopped' and rr.stop_reason in ('renter_said_reviewed', 'staff_marked_reviewed', 'onsite_review', 'google_review') then
    raise exception 'Already reviewed: the requests stopped' using errcode = '23514';
  end if;
  if not app.review_may_ask(p_booking) then raise exception 'The renter unsubscribed from these messages' using errcode = '23514'; end if;
  if rr.last_manual_at > p_now - interval '24 hours' or rr.ask_sent_at > p_now - interval '24 hours' then
    raise exception 'A review request went less than 24 hours ago' using errcode = '23514';
  end if;
  update review_requests
     set manual_pending = true, manual_asks = manual_asks + 1, last_manual_at = p_now, manual_by = p_user,
         send_anyway_at = case when status = 'held' then p_now else send_anyway_at end,
         send_anyway_by = case when status = 'held' then p_user else send_anyway_by end,
         status = case when status in ('stopped', 'finished') then case when ask_sent_at is null then 'waiting' else 'asked' end else status end,
         stop_reason = null, stopped_at = null, stopped_by = null
   where booking_id = p_booking;
  perform app.log_booking_event(p_booking, 'review_request', b.status::text, b.status::text, b.current_offer_version, 'Staff asked the renter for a review', p_user);
  v_step := case when b.status = 'on_rent' then null else app.review_step(p_booking, p_now) end;
  if b.status = 'on_rent' then
    -- on a trip: the request now (the renter has the car; the staff member decided)
    if app.review_in_window(p_now, s.review_send_from_hour, s.review_send_until_hour) then
      perform app.review_emit('renter_review_ask', p_booking, 'manual:' || (rr.manual_asks + 1));
      update review_requests set manual_pending = false where booking_id = p_booking;
      v_step := 'manual';
    end if;
  end if;
  return jsonb_build_object('sent', coalesce(v_step in ('manual', 'ask'), false),
    'at', case when coalesce(v_step in ('manual', 'ask'), false) then p_now else app.review_next_window(p_now, s.review_send_from_hour, s.review_send_until_hour) end);
end $$;

create or replace function app.review_send_anyway(p_user uuid, p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_step text;
begin
  if not app.review_may_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  perform app.review_request_row(p_booking);
  update review_requests set send_anyway_at = p_now, send_anyway_by = p_user,
         status = case when status = 'held' then case when ask_sent_at is null then 'waiting' else 'asked' end else status end,
         hold_reasons = '{}', released_at = p_now
   where booking_id = p_booking and status <> 'stopped';
  perform app.log_booking_event(p_booking, 'review_request', b.status::text, b.status::text, b.current_offer_version, 'Staff released the review request: send anyway', p_user);
  v_step := app.review_step(p_booking, p_now);
  return jsonb_build_object('sent', coalesce(v_step in ('ask', 'manual', 'reminder', 'final'), false), 'step', v_step);
end $$;

create or replace function app.review_mark_reviewed(p_user uuid, p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not app.review_may_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  perform app.review_request_row(p_booking);
  update review_requests set status = 'stopped', stop_reason = 'staff_marked_reviewed', stopped_at = now(), stopped_by = p_user, manual_pending = false
   where booking_id = p_booking;
  perform app.log_booking_event(p_booking, 'review_request', b.status::text, b.status::text, b.current_offer_version, 'Staff marked the booking reviewed: no more review requests', p_user);
  return jsonb_build_object('stopped', true);
end $$;

-- Admin > Reviews and customer service's Review requests: the counts, the hold list and the Google matches.
create or replace function app.review_overview(p_user uuid, p_days integer default 30) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 3650)));
  g review_google_link;
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'sales')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into g from review_google_link;
  return jsonb_build_object(
    'days', p_days, 'enabled', (app.settings()).review_program_enabled, 'google_url', app.google_review_url(),
    'sent', jsonb_build_object(
      'checkin', (select count(*) from review_requests where checkin_sent_at >= v_since),
      'ask', (select count(*) from review_requests where ask_sent_at >= v_since),
      'reminder', (select count(*) from review_requests where reminder_sent_at >= v_since),
      'final', (select count(*) from review_requests where final_sent_at >= v_since),
      'manual', (select coalesce(sum(manual_asks), 0) from review_requests where last_manual_at >= v_since)),
    'on_hold', (select count(*) from review_requests where status = 'held'),
    'detected', jsonb_build_object(
      'onsite', (select count(*) from reviews where created_at >= v_since),
      'google', (select count(*) from google_reviews where reviewed_at >= v_since),
      'google_matched', (select count(*) from google_reviews where reviewed_at >= v_since and match_status in ('matched', 'confirmed')),
      'renter_said', (select count(*) from review_requests where stop_reason = 'renter_said_reviewed' and stopped_at >= v_since),
      'staff_marked', (select count(*) from review_requests where stop_reason = 'staff_marked_reviewed' and stopped_at >= v_since)),
    'rating', jsonb_build_object(
      'onsite_avg', (select round(avg(rating), 2) from reviews where created_at >= v_since),
      'onsite_n', (select count(*) from reviews where created_at >= v_since),
      'google_avg', (select round(avg(star_rating), 2) from google_reviews where reviewed_at >= v_since and star_rating is not null),
      'google_n', (select count(*) from google_reviews where reviewed_at >= v_since and star_rating is not null),
      'all_avg', (select round(avg(x), 2) from (select rating::numeric x from reviews where created_at >= v_since
                                                  union all select star_rating from google_reviews where reviewed_at >= v_since and star_rating is not null) q)),
    'held', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter', r.legal_name,
                        'vehicle', app.vehicle_name(b.vehicle_id), 'returned_at', app.review_returned_at(b.id), 'held_since', rr.held_since,
                        'reasons', to_jsonb(rr.hold_reasons), 'items', app.review_hold_items(b.id)) order by rr.held_since)
                        from review_requests rr join bookings b on b.id = rr.booking_id join renters r on r.id = b.renter_id where rr.status = 'held'), '[]'::jsonb),
    'google', jsonb_build_object('status', g.status, 'account_email', g.account_email, 'location_title', g.location_title,
                                 'last_sync_at', g.last_sync_at, 'last_ok_at', g.last_ok_at, 'last_error', g.last_error),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', gr.id, 'reviewer', gr.reviewer_name, 'rating', gr.star_rating, 'comment', left(gr.comment, 400),
                           'reviewed_at', gr.reviewed_at, 'status', gr.match_status, 'score', gr.match_score, 'booking_id', gr.booking_id,
                           'booking_number', b.booking_number, 'renter', r.legal_name) order by gr.reviewed_at desc)
                           from (select * from google_reviews order by reviewed_at desc limit 50) gr
                           left join bookings b on b.id = gr.booking_id left join renters r on r.id = b.renter_id), '[]'::jsonb));
end $$;

-- Staff confirm a suggested match, reject it, or assign the review to a booking (by its number).
create or replace function app.review_google_match(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g google_reviews;
  v_booking uuid;
  v_act text := p ->> 'act';
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Customer service or an Admin matches reviews' using errcode = '42501'; end if;
  select * into g from google_reviews where id = p ->> 'id' for update;
  if g.id is null then raise exception 'That Google review is not here' using errcode = 'P0002'; end if;
  if v_act = 'confirm' then
    if g.booking_id is null then raise exception 'No booking to confirm: assign one' using errcode = '23514'; end if;
    update google_reviews set match_status = 'confirmed', match_by = p_user, match_at = now() where id = g.id;
    perform app.review_stop(g.booking_id, 'google_review', p_user);
  elsif v_act = 'reject' then
    update google_reviews set match_status = 'rejected', booking_id = null, match_by = p_user, match_at = now() where id = g.id;
  elsif v_act = 'assign' then
    v_booking := app.review_booking_id(btrim(coalesce(p ->> 'booking', '')));
    if v_booking is null then raise exception 'No booking with that number' using errcode = 'P0002'; end if;
    update google_reviews set match_status = 'confirmed', booking_id = v_booking, match_by = p_user, match_at = now() where id = g.id;
    perform app.review_stop(v_booking, 'google_review', p_user);
  else
    raise exception 'Confirm, reject or assign' using errcode = '22023';
  end if;
  return (select to_jsonb(x) - 'comment' from google_reviews x where x.id = g.id);
end $$;

-- ================================================================ 7. the renter's review page (no sign-in, the token)
create or replace function app.review_helper(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  rr review_requests;
  b bookings;
  r renters;
begin
  select * into rr from review_requests where token = p_token;
  if rr.booking_id is null then return jsonb_build_object('ok', false); end if;
  select * into b from bookings where id = rr.booking_id;
  select * into r from renters where id = b.renter_id;
  return jsonb_build_object('ok', true,
    'first_name', split_part(btrim(coalesce(r.legal_name, '')), ' ', 1),
    'booking_number', b.booking_number, 'status', b.status,
    'vehicle', app.vehicle_name(b.vehicle_id), 'days', b.billable_days,
    'delivered', b.pickup_method = 'delivered', 'picked_up', b.return_method = 'picked_up',
    'staff', coalesce((select jsonb_agg(distinct split_part(btrim(u.full_name), ' ', 1)) from field_jobs j join users u on u.id = j.assigned_to
                        where j.booking_id = b.id and j.status = 'done' and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')
                          and nullif(btrim(coalesce(u.full_name, '')), '') is not null), '[]'::jsonb),
    'google_url', app.google_review_url(),
    'reviewed', coalesce(rr.stop_reason in ('renter_said_reviewed', 'staff_marked_reviewed', 'onsite_review', 'google_review'), false),
    'returned', b.status in ('returned', 'closed'));
end $$;

-- What the renter did on the page: opened it, copied the draft, opened Google, said they already reviewed, or said
-- something was not right. "I already left a review" stops the sequence.
create or replace function app.review_helper_act(p_token uuid, p_act text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  rr review_requests;
begin
  select * into rr from review_requests where token = p_token for update;
  if rr.booking_id is null then raise exception 'This review link is not valid' using errcode = 'P0002'; end if;
  case p_act
  when 'opened' then update review_requests set helper_opened_at = coalesce(helper_opened_at, now()) where booking_id = rr.booking_id;
  when 'copied' then update review_requests set copied_at = now() where booking_id = rr.booking_id;
  when 'google' then update review_requests set google_opened_at = now() where booking_id = rr.booking_id;
  when 'unhappy' then update review_requests set unhappy_at = now() where booking_id = rr.booking_id;
  when 'reviewed' then
    update review_requests set status = 'stopped', stop_reason = 'renter_said_reviewed', stopped_at = now(), stopped_by = null, manual_pending = false
     where booking_id = rr.booking_id and coalesce(stop_reason, '') not in ('onsite_review', 'google_review', 'staff_marked_reviewed');
  else raise exception 'Unknown action' using errcode = '22023';
  end case;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_review_helper(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.review_helper(p_token) $$;
create or replace function public.server_review_helper_act(p_token uuid, p_act text) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.review_helper_act(p_token, p_act) $$;

-- The signed-in review page: the renter's own booking's token (the row is made when missing).
create or replace function app.renter_review_token(p_booking uuid, p_by uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  if not exists (select 1 from bookings b where b.id = p_booking and b.status in ('on_rent', 'returned', 'closed') and b.booking_type <> 'owner') then return null; end if;
  return (app.review_request_row(p_booking)).token;
end $$;
create or replace function public.renter_review_token(p_booking uuid, p_by uuid) returns uuid
language sql volatile security definer set search_path = public, app as $$ select app.renter_review_token(p_booking, p_by) $$;

-- ================================================================ 8. Google: the connection and the sync
-- The refresh token lives in the vault (Supabase Vault); nothing else stores it.
create or replace function app.review_google_token_set(p_token text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if to_regnamespace('vault') is null then raise exception 'The vault is not available on this database' using errcode = '55000'; end if;
  execute 'select id from vault.secrets where name = $1' into v_id using 'google_reviews_refresh_token';
  if p_token is null then
    if v_id is not null then execute 'delete from vault.secrets where id = $1' using v_id; end if;
  elsif v_id is null then
    execute 'select vault.create_secret($1, $2, $3)' using p_token, 'google_reviews_refresh_token', 'Google Business Profile reviews sync (rent@carmacars.ca), 0146';
  else
    execute 'select vault.update_secret($1, $2)' using v_id, p_token;
  end if;
end $$;

create or replace function app.review_google_token() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text;
begin
  if to_regnamespace('vault') is null then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v using 'google_reviews_refresh_token';
  return v;
end $$;

-- The server's OAuth callback (an Admin connected the account): the token into the vault, the account on record.
create or replace function app.review_google_connect(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  if nullif(p ->> 'refresh_token', '') is null then raise exception 'Google sent no refresh token: connect again and allow offline access' using errcode = '22023'; end if;
  perform app.review_google_token_set(p ->> 'refresh_token');
  update review_google_link set status = 'connected', account_email = nullif(btrim(coalesce(p ->> 'email', '')), ''), connected_at = now(), connected_by = p_admin,
         last_error = null, account_name = null, location_name = null, location_title = null;
  return jsonb_build_object('connected', true);
end $$;

create or replace function app.review_google_disconnect(p_admin uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  if to_regnamespace('vault') is not null then perform app.review_google_token_set(null); end if;
  update review_google_link set status = 'not_connected', account_email = null, account_name = null, location_name = null, location_title = null,
         connected_at = null, connected_by = null, last_error = null;
  return jsonb_build_object('connected', false);
end $$;

-- Admin > Settings > Reviews.
create or replace function app.review_settings_read(p_admin uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g review_google_link;
  si site_settings;
begin
  perform app.assert_admin(p_admin);
  select * into g from review_google_link;
  select * into si from site_settings limit 1;
  return jsonb_build_object(
    'google', jsonb_build_object('status', g.status, 'account_email', g.account_email, 'account_name', g.account_name, 'location_name', g.location_name,
                                 'location_title', g.location_title, 'connected_at', g.connected_at, 'last_sync_at', g.last_sync_at, 'last_ok_at', g.last_ok_at,
                                 'last_error', g.last_error, 'reviews_seen', g.reviews_seen, 'vault', to_regnamespace('vault') is not null),
    'place_id', si.google_place_id, 'review_link', si.google_review_link, 'google_url', app.google_review_url(),
    'counts', jsonb_build_object('held', (select count(*) from review_requests where status = 'held'),
                                 'google_reviews', (select count(*) from google_reviews),
                                 'suggested', (select count(*) from google_reviews where match_status = 'suggested')));
end $$;

-- The Worker's job, first call: is it connected, the token and the place, and the renters a review may belong to
-- (returned in the matching window before the oldest review that could still be new).
create or replace function app.review_google_sync_begin(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  g review_google_link;
  v_token text;
  v_since timestamptz;
begin
  select * into g from review_google_link;
  if g.status = 'not_connected' then return jsonb_build_object('connected', false); end if;
  v_token := app.review_google_token();
  if v_token is null then
    update review_google_link set status = 'error', last_error = 'The refresh token is not in the vault: connect again', last_sync_at = p_now;
    return jsonb_build_object('connected', false);
  end if;
  v_since := p_now - make_interval(days => 2 * s.review_google_match_days + 30);
  return jsonb_build_object('connected', true, 'refresh_token', v_token, 'account_name', g.account_name, 'location_name', g.location_name,
    'place_id', (select google_place_id from site_settings limit 1), 'match_days', s.review_google_match_days, 'auto_match', s.review_google_auto_match,
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'renter_name', r.legal_name, 'returned_at', app.review_returned_at(b.id)))
                              from bookings b join renters r on r.id = b.renter_id
                             where b.booking_type <> 'owner' and b.status in ('returned', 'closed') and coalesce(b.checked_in_at, b.return_at) >= v_since), '[]'::jsonb),
    'known', coalesce((select jsonb_agg(id) from google_reviews where match_status in ('confirmed', 'rejected')), '[]'::jsonb));
end $$;

-- The second call: the reviews read and the matches the job worked out (a review staff already confirmed or rejected
-- keeps their decision), or the error (api_not_approved when Google refused the API to this project).
create or replace function app.review_google_sync_finish(p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb;
  m jsonb;
  v_status text := coalesce(p ->> 'status', 'connected');
  v_n integer := 0;
  v_matched integer := 0;
  v_booking uuid;
begin
  if v_status not in ('connected', 'api_not_approved', 'error') then raise exception 'Unknown status' using errcode = '22023'; end if;
  update review_google_link set status = case when status = 'not_connected' then status else v_status end, last_sync_at = p_now,
         last_ok_at = case when v_status = 'connected' then p_now else last_ok_at end,
         last_error = case when v_status = 'connected' then null else left(coalesce(p ->> 'error', v_status), 500) end,
         account_name = coalesce(nullif(p ->> 'account_name', ''), account_name), location_name = coalesce(nullif(p ->> 'location_name', ''), location_name),
         location_title = coalesce(nullif(p ->> 'location_title', ''), location_title);
  if v_status <> 'connected' then return jsonb_build_object('status', v_status); end if;
  for x in select * from jsonb_array_elements(coalesce(p -> 'reviews', '[]'::jsonb)) loop
    continue when nullif(x ->> 'id', '') is null or nullif(x ->> 'reviewed_at', '') is null;
    insert into google_reviews (id, reviewer_name, star_rating, comment, reply, reviewed_at, updated_at_google, synced_at)
    values (x ->> 'id', left(x ->> 'reviewer_name', 200), nullif(x ->> 'star_rating', '')::smallint, left(x ->> 'comment', 4000), left(x ->> 'reply', 4000),
            (x ->> 'reviewed_at')::timestamptz, nullif(x ->> 'updated_at', '')::timestamptz, p_now)
    on conflict (id) do update set reviewer_name = excluded.reviewer_name, star_rating = excluded.star_rating, comment = excluded.comment,
           reply = excluded.reply, updated_at_google = excluded.updated_at_google, synced_at = p_now;
    v_n := v_n + 1;
  end loop;
  for m in select * from jsonb_array_elements(coalesce(p -> 'matches', '[]'::jsonb)) loop
    v_booking := nullif(m ->> 'booking_id', '')::uuid;
    continue when m ->> 'status' not in ('matched', 'suggested', 'unmatched');
    update google_reviews set booking_id = case when m ->> 'status' = 'unmatched' then null else v_booking end, match_status = m ->> 'status',
           match_score = nullif(m ->> 'score', '')::numeric, match_at = p_now, match_by = null
     where id = m ->> 'id' and match_status in ('unmatched', 'suggested', 'matched') and match_by is null
       and (m ->> 'status' = 'unmatched' or exists (select 1 from bookings b where b.id = v_booking));
    if found and m ->> 'status' = 'matched' then
      perform app.review_stop(v_booking, 'google_review');
      v_matched := v_matched + 1;
    end if;
  end loop;
  update review_google_link set reviews_seen = (select count(*) from google_reviews);
  return jsonb_build_object('status', 'connected', 'reviews', v_n, 'matched', v_matched);
end $$;

create or replace function public.server_review_google_sync_begin() returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.review_google_sync_begin(now()) $$;
create or replace function public.server_review_google_sync_finish(p jsonb) returns jsonb
language sql volatile security definer set search_path = public, app as $$ select app.review_google_sync_finish(p, now()) $$;

-- The cron gate: the sync is due every 6 hours while connected (an error is tried again after 6 hours too).
alter function app.server_jobs_due() rename to server_jobs_due_pre0146;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0146();
begin
  return v || jsonb_build_object('reviews', coalesce((select g.status <> 'not_connected' and (g.last_sync_at is null or g.last_sync_at < now() - interval '6 hours')
                                                        from review_google_link g), false));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0146()'::regprocedure);

-- ================================================================ 9. the notifications' values
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0146;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0146(p_code, p_event, p_to);
  v_base text;
  v_token uuid;
  v_number text;
begin
  if p_code in ('renter_trip_checkin', 'renter_review_ask', 'renter_review_reminder', 'renter_review_final') and p_event.entity = 'booking' then
    v_base := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
    select token into v_token from review_requests where booking_id = p_event.entity_id;
    select booking_number into v_number from bookings where id = p_event.entity_id;
    if p_code = 'renter_trip_checkin' then
      x := x || jsonb_build_object('_url', v_base || '/account/bookings/' || v_number);
    else
      x := x || jsonb_build_object('review_url', v_base || '/review/' || v_token, 'review_done_url', v_base || '/review/' || v_token || '?done=1',
                                   'google_review_url', coalesce(app.google_review_url(), v_base || '/review/' || v_token),
                                   '_url', v_base || '/review/' || v_token);
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0146(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0146;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_b uuid;
begin
  if (p_call = 'ops_read' and p_name in ('review_request', 'review_overview'))
     or (p_call = 'ops_do' and p_name in ('review_ask_now', 'review_send_anyway', 'review_mark_reviewed', 'review_google_match')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    v_b := case when p_ ? 'booking' then coalesce(app.review_booking_id(p_ ->> 'booking'), '00000000-0000-0000-0000-000000000000'::uuid) end;
    case p_name
    when 'review_request' then return app.review_request_panel(p_user, v_b);
    when 'review_overview' then return app.review_overview(p_user, coalesce((p_ ->> 'days')::integer, 30));
    when 'review_ask_now' then return app.review_ask_now(p_user, v_b);
    when 'review_send_anyway' then return app.review_send_anyway(p_user, v_b);
    when 'review_mark_reviewed' then return app.review_mark_reviewed(p_user, v_b);
    else return app.review_google_match(p_user, p_);
    end case;
  end if;
  if (p_call = 'admin_read' and p_name = 'review_settings') or (p_call = 'admin_do' and p_name in ('review_google_connect', 'review_google_disconnect')) then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return case p_name when 'review_settings' then app.review_settings_read(p_user)
                       when 'review_google_connect' then app.review_google_connect(p_user, p_)
                       else app.review_google_disconnect(p_user) end;
  end if;
  return app.door_pre0146(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 11. the bookings already there
-- A booking back more than the request's window ago, or one that already had 0023's or 0061's review email: nothing more.
insert into review_requests (booking_id, status, ask_sent_at, stop_reason, stopped_at)
select b.id,
       case when exists (select 1 from reviews r where r.booking_id = b.id) then 'stopped'
            when ms.at is not null then 'finished'
            when coalesce(b.checked_in_at, b.return_at) < now() - interval '7 days' then 'stopped' else 'waiting' end,
       ms.at,
       case when exists (select 1 from reviews r where r.booking_id = b.id) then 'onsite_review'
            when ms.at is not null then null
            when coalesce(b.checked_in_at, b.return_at) < now() - interval '7 days' then 'too_late' end,
       case when exists (select 1 from reviews r where r.booking_id = b.id) or (ms.at is null and coalesce(b.checked_in_at, b.return_at) < now() - interval '7 days') then now() end
  from bookings b
  left join lateral (select min(m.decided_at) at from marketing_sends m where m.booking_id = b.id and m.code in ('renter_review_request', 'renter_google_review_request')) ms on true
 where b.booking_type <> 'owner' and b.status in ('returned', 'closed')
on conflict (booking_id) do nothing;

-- ================================================================ 12. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['door', 'door_pre0146', 'review_charge_reason', 'review_hold_items', 'review_hold_reasons',
       'review_returned_at', 'review_in_window', 'review_next_window', 'review_may_ask', 'review_found', 'review_request_row', 'review_stop', 'review_emit',
       'review_step', 'job_review_requests', 'review_requests_on_review', 'review_program_guard', 'review_may_staff', 'review_booking_id',
       'review_request_panel', 'review_ask_now', 'review_send_anyway', 'review_mark_reviewed', 'review_overview', 'review_google_match',
       'review_helper', 'review_helper_act', 'renter_review_token', 'review_google_token_set', 'review_google_token', 'review_google_connect',
       'review_google_disconnect', 'review_settings_read', 'review_google_sync_begin', 'review_google_sync_finish'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.server_review_helper(uuid), public.server_review_helper_act(uuid, text), public.renter_review_token(uuid, uuid),
  public.server_review_google_sync_begin(), public.server_review_google_sync_finish(jsonb) from public, anon, authenticated;
grant execute on function public.server_review_helper(uuid), public.server_review_helper_act(uuid, text), public.renter_review_token(uuid, uuid),
  public.server_review_google_sync_begin(), public.server_review_google_sync_finish(jsonb) to service_role;
-- the review link's function is read by the outbox (as service_role) and by staff screens
revoke all on function app.google_review_url() from public, anon;
grant execute on function app.google_review_url() to authenticated, service_role;

-- ================================================================ 13. the email catalogue
-- CATALOGUE 0146 START (generated by supabase/seed/0146_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_trip_checkin', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'How is the {{vehicle_name}} going?', 'If anything is off, reply or call. We fix it.', '24 hours after the pickup, rentals of 2 days or more', 'Review requests (migration 0138, app.job_review_requests every 10 minutes): booking status is on_rent, the rental is at least review_checkin_min_days long (2 by default) and review_checkin_after_hours (24 by default) have passed since the pickup, never in the last 6 hours before the return. Only from review_send_from_hour to review_send_until_hour Toronto time (9 am to 9 pm by default). A service message about the rental in progress: it asks for no review. Once per booking.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_trip_checkin.html', 'templates/renter_trip_checkin.txt'),
  ('renter_review_ask', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'How was the {{vehicle_name}}?', 'A quick review takes a minute. We help you write it.', '1 hour after the check-in, 9 am to 9 pm', 'Review requests (migration 0138, app.job_review_requests every 10 minutes): review_ask_after_minutes (60 by default) after the car is checked in (booking status returned or closed). Only from 9 am to 9 pm Toronto time (Program settings). Never while a return or later charge (late, kilometres, fuel, cleaning, smoking, damage, tolls) is not settled or waived, nor with an open incident or dispute: the booking waits on the hold list and is released by itself, or by staff with Send anyway. Not sent when the renter already reviewed (on the site, on Google matched by name, "I already left a review", or marked by staff) or unsubscribed. Staff can also send it from the booking (Ask for a review). Never depends on a rating and offers nothing for a review. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"review_done_url","type":"url"},{"name":"review_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_review_ask.html', 'templates/renter_review_ask.txt'),
  ('renter_review_reminder', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'A minute for a review of the {{vehicle_name}}?', 'Tap what you liked, add a sentence, done.', '24 hours after the review request', 'Review requests (migration 0138): review_reminder_hours (24 by default) after renter_review_ask, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"review_done_url","type":"url"},{"name":"review_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_review_reminder.html', 'templates/renter_review_reminder.txt'),
  ('renter_review_final', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Our last note about your {{vehicle_name}} trip', 'If you have a minute for a review, it helps a lot.', '7 days after the review request', 'Review requests (migration 0138): review_final_days (7 by default) after renter_review_ask, the last message of the sequence, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"review_done_url","type":"url"},{"name":"review_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_review_final.html', 'templates/renter_review_final.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0146 END
update notification_catalogue set emitted_by = 'app.job_review_requests through app.review_step (0146)'
 where code in ('renter_trip_checkin', 'renter_review_ask', 'renter_review_reminder', 'renter_review_final');
update notification_catalogue
   set trigger_text = trigger_text || ' Not sent while the review request program of 0146 is on (Program settings review_program_enabled): renter_review_ask and its follow-ups ask instead.'
 where code in ('renter_review_request', 'renter_google_review_request') and trigger_text not like '%review_program_enabled%';

-- ================================================================ 14. texts
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_trip_checkin', 'Mid-trip check-in', 'CarmaCars: how is the {{vehicle_name}} going, {{first_name}}? If anything is off, reply to this text or call {{support_phone}}. Your booking: {{link}}', false, 88),
  ('renter_review_ask', 'Review request', 'CarmaCars: thanks for renting the {{vehicle_name}}, {{first_name}}. Would you leave a quick review? It takes a minute: {{link}}', false, 89),
  ('renter_review_reminder', 'Review reminder', 'CarmaCars: a short review of the {{vehicle_name}} helps other renters choose. Takes a minute: {{link}}', false, 90),
  ('renter_review_final', 'Review, last follow-up', 'CarmaCars: our last note about your {{vehicle_name}} trip. If you have a minute for a review: {{link}}', false, 92)
on conflict (code) do nothing;

-- ================================================================ 15. the guides
-- GUIDES 0146 START (generated by supabase/seed/0146_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'during-your-trip', 'chapter', 'before-pickup', 'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Choose the new return date and time, then press **See the price**.
3. Press **Request extension**. Once we approve it, press **Pay for the extension** before your current return time.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Watch out: Ask before your current return time. One rental can be at most 30 days.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10057/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Ask to extend before your return time, or call us at 289-312-5991.
', 'During your trip', 'Extend, change dates, answer a change we suggest, or cancel.',
  'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Choose the new return date and time, then press **See the price**.
3. Press **Request extension**. Once we approve it, press **Pay for the extension** before your current return time.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Watch out: Ask before your current return time. One rental can be at most 30 days.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10057/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- On a rental of 2 days or more we check in after the first day: "How is the car?" If anything is off, reply to the email or text, or call us.
- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Ask to extend before your return time, or call us at 289-312-5991.
',
  '<p class="gd-p">Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.</p><section class="gd-task" id="during-your-trip-extend-your-rental" data-gd-task><h2 class="gd-h2">Extend your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Extend</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the new return date and time, then press <b class="gd-ui">See the price</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Request extension</b>. Once we approve it, press <b class="gd-ui">Pay for the extension</b> before your current return time.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/extend</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-11-extend-desktop-957274cc.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:34.4%;top:62.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:15.1%;top:77.2%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Ask before your current return time. One rental can be at most 30 days.</div></aside></section><section class="gd-task" id="during-your-trip-ask-to-change-dates" data-gd-task><h2 class="gd-h2">Ask to change dates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Ask to change dates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the new pickup and return, then press <b class="gd-ui">See the difference</b> to see what you would pay or get back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Ask to change dates</b> to send it. Nothing changes until you agree to our answer.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/change</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-12-change-desktop-09f6b563.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:15.1%;top:91.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="during-your-trip-a-change-we-suggest" data-gd-task><h2 class="gd-h2">A change we suggest</h2><p class="gd-p">Sometimes we need to change your booking, for example another car of the same class. You decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and your booking says &quot;We suggest a change to your booking&quot;. Press <b class="gd-ui">Review and answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read what changes (before and after), the reason, the money and the time left to answer.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To agree, press <b class="gd-ui">Accept and sign the amendment</b>, sign, then press <b class="gd-ui">Accept and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Anything more to pay is charged to your Card on File. If the card is declined, press <b class="gd-ui">Pay and apply the change</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">To say no, press <b class="gd-ui">Decline this change</b>. Your booking stays as it was.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.</div></aside></section><section class="gd-task" id="during-your-trip-cancel-a-booking" data-gd-task><h2 class="gd-h2">Cancel a booking</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Cancel booking</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read What you get back. It shows the rule that applies and your refund.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the booking number to confirm (for example CC-10021), then press <b class="gd-ui">Cancel booking</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/cancel</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/692"><img src="/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg" alt="" loading="lazy" decoding="async" width="1440" height="692"><span class="gd-pin" style="left:36.1%;top:67.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:95.8%;top:45.1%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Standard booking: when you cancel</th><th scope="col">Refund of what you paid</th></tr></thead><tbody><tr><td>Within 24 hours of booking, and 48 hours or more before pickup</td><td>95% back</td></tr><tr><td>48 hours or more before pickup</td><td>75% back</td></tr><tr><td>24 to 48 hours before pickup</td><td>50% back</td></tr><tr><td>Less than 24 hours before pickup</td><td>No refund</td></tr></tbody></table></div><p class="gd-p">A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.</p></section><section class="gd-task" id="during-your-trip-messages-tolls-and-tickets" data-gd-task><h2 class="gd-h2">Messages, tolls and tickets</h2><ul class="gd-ul"><li>On a rental of 2 days or more we check in after the first day: &quot;How is the car?&quot; If anything is off, reply to the email or text, or call us.</li><li>Write to us about a booking at the bottom of its page: type in Your message and press Send.</li><li>Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.</li><li>Running late? Ask to extend before your return time, or call us at 289-312-5991.</li></ul></section>');
select app.guide_release_section('renter', 'after-your-trip', 'chapter', 'during-your-trip', 'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- The photo report of the pickup and the return is in your email, in Documents and on your booking (**Photo report**): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past trips, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.

## Sign in with your phone number

No password needed: we text you a 6-digit code from the CarmaCars number.

1. On `carmacars.ca/sign-in`, press **Use my phone number instead**.
2. Enter your mobile number and press **Text me a code**. Codes go to Canadian mobile numbers.
3. Type the 6-digit code from the text (on most phones it fills itself in), or press **Sign in**. The code works for 5 minutes; **Send a new code** after a minute if it did not arrive.
4. To sign in by phone every time, open **Profile**, press **Add and verify my phone number**, enter the code we text you, then choose **My phone number (a code by text)** under Sign in with. The sign-in page then opens on your phone number.

> Tip: New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.

## Texts or email: how we reach you

Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.

1. Open **Profile**. Under **Messages**, choose **Email**, **Text** or **Both**. It is saved at once.
2. Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.
3. Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.
4. No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.

> Tip: You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.
', 'After your trip', 'The return, your deposit, reviews, documents and your profile.',
  'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- The photo report of the pickup and the return is in your email, in Documents and on your booking (**Photo report**): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your trip

After the return we send you a link by email or text. It takes about a minute, and we help you write it.

1. Open the link. Tap what you liked: the car, the pickup or delivery, communication, the price, cleanliness, how easy booking was, or the name of the person who helped you.
2. If you like, tap the stars for how it felt, and write one sentence in your own words.
3. Your review appears, made only from what you picked and wrote and the facts of your booking. Change anything you like.
4. Press **Post on Google**: it copies your review and opens Google. Choose your stars and paste it. **Copy** only copies it.

Already left a review? Press "I already left a review" and we stop asking. Something wasn''t right? The page offers to tell us directly. We never offer anything for a review, and every renter gets the same link.

## Review your rental on our site

1. Open the trip under Past trips, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.

## Sign in with your phone number

No password needed: we text you a 6-digit code from the CarmaCars number.

1. On `carmacars.ca/sign-in`, press **Use my phone number instead**.
2. Enter your mobile number and press **Text me a code**. Codes go to Canadian mobile numbers.
3. Type the 6-digit code from the text (on most phones it fills itself in), or press **Sign in**. The code works for 5 minutes; **Send a new code** after a minute if it did not arrive.
4. To sign in by phone every time, open **Profile**, press **Add and verify my phone number**, enter the code we text you, then choose **My phone number (a code by text)** under Sign in with. The sign-in page then opens on your phone number.

> Tip: New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.

## Texts or email: how we reach you

Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.

1. Open **Profile**. Under **Messages**, choose **Email**, **Text** or **Both**. It is saved at once.
2. Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.
3. Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.
4. No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.

> Tip: You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.
',
  '<p class="gd-p">We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.</p><section class="gd-task" id="after-your-trip-the-return-and-your-deposit" data-gd-task><h2 class="gd-h2">The return and your deposit</h2><ul class="gd-ul"><li>At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.</li><li>The photo report of the pickup and the return is in your email, in Documents and on your booking (<b class="gd-ui">Photo report</b>): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.</li><li>We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.</li><li>Your statement appears under Documents.</li></ul></section><section class="gd-task" id="after-your-trip-review-your-trip" data-gd-task><h2 class="gd-h2">Review your trip</h2><p class="gd-p">After the return we send you a link by email or text. It takes about a minute, and we help you write it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the link. Tap what you liked: the car, the pickup or delivery, communication, the price, cleanliness, how easy booking was, or the name of the person who helped you.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If you like, tap the stars for how it felt, and write one sentence in your own words.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your review appears, made only from what you picked and wrote and the facts of your booking. Change anything you like.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Post on Google</b>: it copies your review and opens Google. Choose your stars and paste it. <b class="gd-ui">Copy</b> only copies it.</div></li></ol></div><p class="gd-p">Already left a review? Press &quot;I already left a review&quot; and we stop asking. Something wasn&#39;t right? The page offers to tell us directly. We never offer anything for a review, and every renter gets the same link.</p></section><section class="gd-task" id="after-your-trip-review-your-rental-on-our-site" data-gd-task><h2 class="gd-h2">Review your rental on our site</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the trip under Past trips, then press <b class="gd-ui">Review your rental</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap the stars. Add a title and a few words if you like. Both are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick <b class="gd-ui">Show my review on the site with my first name</b> only if you agree to it being shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Send my review</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10058/review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/672"><img src="/guides/img/renter-14-review-desktop-c6c61830.jpg" alt="" loading="lazy" decoding="async" width="1440" height="672"><span class="gd-pin" style="left:25%;top:33.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:3.5%;top:84.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:18.1%;top:92.4%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="after-your-trip-documents-notifications-and-profile" data-gd-task><h2 class="gd-h2">Documents, notifications and profile</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Documents</b>: your agreements, receipts, statements and uploads. Press <b class="gd-ui">View</b> or <b class="gd-ui">Download</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Notifications</b>: notices from us. Use <b class="gd-ui">Mark as read</b> or <b class="gd-ui">Mark all as read</b>, and choose which optional emails you get.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Profile</b>: your contact details (<b class="gd-ui">Save</b>), drivers, your Card on File and your marketing choice.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/renter-15-documents-desktop-fd428a63.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:91.8%;top:35.7%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your legal name is locked once you are verified. To change it or your email, call or message us.</div></aside></section><section class="gd-task" id="after-your-trip-sign-in-with-your-phone-number" data-gd-task><h2 class="gd-h2">Sign in with your phone number</h2><p class="gd-p">No password needed: we text you a 6-digit code from the CarmaCars number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <span class="gd-url">carmacars.ca/sign-in</span>, press <b class="gd-ui">Use my phone number instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter your mobile number and press <b class="gd-ui">Text me a code</b>. Codes go to Canadian mobile numbers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the 6-digit code from the text (on most phones it fills itself in), or press <b class="gd-ui">Sign in</b>. The code works for 5 minutes; <b class="gd-ui">Send a new code</b> after a minute if it did not arrive.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To sign in by phone every time, open <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b>, enter the code we text you, then choose <b class="gd-ui">My phone number (a code by text)</b> under Sign in with. The sign-in page then opens on your phone number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.</div></aside></section><section class="gd-task" id="after-your-trip-texts-or-email-how-we-reach-you" data-gd-task><h2 class="gd-h2">Texts or email: how we reach you</h2><p class="gd-p">Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Profile</b>. Under <b class="gd-ui">Messages</b>, choose <b class="gd-ui">Email</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Both</b>. It is saved at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.</div></aside></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick the checks, then <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
5. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
5. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day&#39;s opening and closing checks close at the end of that day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (**Record a payment**, For: the rental and fees).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (**Record a payment**, For: the rental and fees).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (<b class="gd-ui">Record a payment</b>, For: the rental and fees).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Renters are asked for a review by email and text after each trip. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Review requests</b> shows the ones on hold and the Google reviews to match.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter should be asked now anyway? Press <b class="gd-ui">Send anyway</b>. Should never be asked? Press <b class="gd-ui">Do not ask</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google reviews: a possible match to a renter shows &quot;possible match&quot;. Press <b class="gd-ui">Confirm</b> if it is them, <b class="gd-ui">Not this renter</b> if not, or <b class="gd-ui">Match to a booking</b> with the booking number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On a booking, the card Review requests has <b class="gd-ui">Ask for a review</b> (for example after a call that went well) and <b class="gd-ui">Mark reviewed</b> when the renter says they already left one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
-- GUIDES 0146 END
