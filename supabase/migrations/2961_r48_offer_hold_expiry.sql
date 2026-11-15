-- 2961 (release 48): offers and accepted-but-unpaid bookings expire on time and stop holding the car.
--
-- The owner approved these defaults (Nov 14):
--   * an offer is open 12 hours (Program settings, offer_expiry_hours, was 24) and never past 1 hour before the pickup
--     (offer_cutoff_before_pickup_minutes, 60);
--   * an accepted offer not paid yet (pending_payment) holds the car 2 hours (offer_unpaid_hold_minutes, 120). Then the
--     hold ends: the car is free again, and while it is still free for those dates the renter gets a fresh offer (same
--     price, a new version) and a text with the link to pay; when the car is taken, the booking expires;
--   * only confirmed and paid bookings (and cars out) block solidly; an accepted unpaid booking blocks only until its hold
--     ends, an offer never blocked (the first to pay gets the car) and both are drawn as a light hatched hold on the fleet
--     calendar until they expire; an expired one never blocks.
-- Before: pending_payment held the car with no end (a renter who accepted and never paid kept the car off the site), and
-- stale offers and holds stayed in the database. The hold applies to card payments the renter makes online; an Owner
-- Booking, a placeholder, an insurer or platform payout, an offline payment (e-transfer, cash, ...) and a booking with a
-- payment in are not touched. A one-time sweep below expires what is already stale (logged in each booking's history).
-- No applied migration is edited: functions are patched in place (the patch refuses when the text is not found) or new.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2961: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the settings
alter table program_settings
  add column offer_cutoff_before_pickup_minutes integer not null default 60 check (offer_cutoff_before_pickup_minutes between 0 and 1440),
  add column offer_unpaid_hold_minutes integer not null default 120 check (offer_unpaid_hold_minutes between 0 and 1440);
comment on column program_settings.offer_cutoff_before_pickup_minutes is 'An offer never stays open past this many minutes before the pickup (2961).';
comment on column program_settings.offer_unpaid_hold_minutes is 'An accepted offer not paid yet holds the car this many minutes, then the hold ends (2961). 0: no limit.';
alter table program_settings alter column offer_expiry_hours set default 12;
update program_settings set offer_expiry_hours = 12 where offer_expiry_hours = 24;

-- ================================================================ 2. how long a booking holds the car
-- An accepted offer the renter pays online by card, with nothing paid yet: held until the approval plus the setting.
-- null: not such a booking (it blocks as it always did, or it does not block at all).
create or replace function app.unpaid_hold_until(b bookings) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case
    when b.status = 'pending_payment' and b.booking_type::text <> 'owner' and not coalesce(b.is_placeholder, false)
     and coalesce(b.rental_pay_method, 'card') = 'card' and b.offer_approved_at is not null
     and coalesce((app.settings()).offer_unpaid_hold_minutes, 120) > 0
     and not exists (select 1 from payments p where p.booking_id = b.id and p.kind in ('charge', 'hold')
                       and (p.status in ('succeeded', 'authorized')
                            or (p.status in ('pending', 'requires_action') and p.created_at > now() - interval '30 minutes')))
    then b.offer_approved_at + make_interval(mins => coalesce((app.settings()).offer_unpaid_hold_minutes, 120)) end
$$;

-- true while an accepted unpaid booking's hold has run out (it no longer blocks)
create or replace function app.unpaid_hold_over(b bookings, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.unpaid_hold_until(b) <= p_now, false)
$$;

-- the time a soft hold on the calendar ends: an open offer at its expiry, an accepted unpaid booking at its hold
create or replace function app.booking_hold_until(b bookings) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when b.status = 'offered' then b.offer_expires_at when b.status = 'pending_payment' then app.unpaid_hold_until(b) end
$$;

revoke all on function app.unpaid_hold_until(bookings) from public, anon, authenticated;
revoke all on function app.unpaid_hold_over(bookings, timestamptz) from public, anon, authenticated;
revoke all on function app.booking_hold_until(bookings) from public, anon, authenticated;
grant execute on function app.unpaid_hold_until(bookings) to service_role;
grant execute on function app.unpaid_hold_over(bookings, timestamptz) to service_role;
grant execute on function app.booking_hold_until(bookings) to service_role;

-- ================================================================ 3. availability: a lapsed hold does not block
select pg_temp.patch_fn('app.vehicle_is_available(uuid, timestamptz, timestamptz, uuid)'::regprocedure,
  $o$b.status in ('pending_payment', 'confirmed', 'on_rent')$o$,
  $n$b.status in ('pending_payment', 'confirmed', 'on_rent') and not app.unpaid_hold_over(b)$n$);
select pg_temp.patch_fn('app.vehicle_free_until(uuid, timestamptz, uuid)'::regprocedure,
  $o$b.status in ('pending_payment', 'confirmed', 'on_rent')$o$,
  $n$b.status in ('pending_payment', 'confirmed', 'on_rent') and not app.unpaid_hold_over(b)$n$);
select pg_temp.patch_fn('app.public_vehicle_calendar(uuid, date, date)'::regprocedure,
  $o$b.status in ('pending_payment', 'confirmed', 'on_rent')$o$,
  $n$b.status in ('pending_payment', 'confirmed', 'on_rent') and not app.unpaid_hold_over(b)$n$);
select pg_temp.patch_fn('app.partner_crm_availability(uuid, integer)'::regprocedure,
  $o$b.status in ('pending_payment', 'confirmed', 'on_rent')$o$,
  $n$b.status in ('pending_payment', 'confirmed', 'on_rent') and not app.unpaid_hold_over(b)$n$);

-- ================================================================ 4. an offer's expiry: never past the cut-off before pickup
select pg_temp.patch_fn('app.issue_offer(uuid, uuid, text, timestamptz)'::regprocedure,
  $o$  v_expires := coalesce(p_expires_at, now() + make_interval(hours => (app.settings()).offer_expiry_hours));$o$,
  $n$  v_expires := coalesce(p_expires_at, now() + make_interval(hours => (app.settings()).offer_expiry_hours));
  -- 2961: never past the cut-off before the pickup; with the pickup closer than that, no later than the pickup
  if b.pickup_at is not null then
    if b.pickup_at - make_interval(mins => coalesce((app.settings()).offer_cutoff_before_pickup_minutes, 60)) > now() then
      v_expires := least(v_expires, b.pickup_at - make_interval(mins => coalesce((app.settings()).offer_cutoff_before_pickup_minutes, 60)));
    elsif b.pickup_at > now() then
      v_expires := least(v_expires, b.pickup_at);
    end if;
  end if;$n$);

-- ================================================================ 5. the hold ends
-- p_sweep (the one-time sweep): also an accepted booking of any payment kind whose rental is over with nothing paid.
create or replace function app.expire_unpaid(p_now timestamptz default now(), p_sweep boolean default false) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r bookings;
  rn renters;
  v_until timestamptz;
  v_by uuid;
  v_version integer;
  v_free boolean;
  v_body text;
  n integer := 0;
begin
  for r in select b.* from bookings b
            where b.status = 'pending_payment'
              and (app.unpaid_hold_until(b) <= p_now
                   or (p_sweep and b.booking_type::text <> 'owner' and not coalesce(b.is_placeholder, false) and b.return_at < p_now
                       and not exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'charge' and p.status in ('succeeded', 'authorized'))))
            order by b.offer_approved_at nulls first, b.id
            for update skip locked
  loop
    v_until := app.unpaid_hold_until(r);
    v_free := r.pickup_at > p_now + make_interval(mins => coalesce(s.offer_cutoff_before_pickup_minutes, 60))
              and app.vehicle_is_available(r.vehicle_id, r.pickup_at, r.return_at, r.id)
              and coalesce(app.vehicle_bookable(r.vehicle_id), false);
    -- the agreement opened for the accepted offer is for an offer that is no longer accepted
    perform app.void_rental_agreements(r.id, 'The booking was not paid in time: the hold on the car ended');
    if v_free then
      -- a fresh offer at the same price (a new version), and a text with the link to pay
      select o.sent_by into v_by from booking_offers o where o.booking_id = r.id and o.version = r.current_offer_version;
      -- back to staff for a moment (pending_payment never goes straight back to offered): the approval is cleared and the
      -- accepted version withdrawn, then the fresh version goes out in the same step
      update bookings set status = 'requested' where id = r.id;
      perform set_config('app.offer_quiet', 'on', true);
      v_version := app.issue_offer(r.id, v_by, 'The hold on the car ended because payment did not come in time. The car is still free: pay to book it.', null);
      perform set_config('app.offer_quiet', '', true);
      perform app.log_booking_event(r.id, 'reopened', 'pending_payment', 'offered', v_version,
        format('Not paid within %s minutes of accepting (by %s, Toronto): the hold on the car ended. The car was still free, so a fresh offer (version %s) went to the renter with a text to pay.',
               coalesce(s.offer_unpaid_hold_minutes, 120), to_char(coalesce(v_until, p_now) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), v_version), null, 'system');
      select * into rn from renters where id = r.renter_id;
      if app.phone_e164(rn.mobile) is not null then
        v_body := format('Hi %s, the hold on the %s ended because payment did not come in time. It is still free: pay here to book it: %s',
                         coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.vehicle_name(r.vehicle_id),
                         app.ntf_link('booking_offer', jsonb_build_object('booking_number', r.booking_number)));
        perform app.phone_outbox_put(rn.mobile, v_body, 'booking', r.id, rn.id, 'offer_sent', null, 'unpaid_reopen:' || r.id || ':v' || v_version, now(), 'queued', null);
      end if;
    else
      update booking_offers set status = 'expired', responded_at = p_now where booking_id = r.id and status in ('sent', 'approved');
      update bookings set status = 'expired', offer_expires_at = null where id = r.id;
      -- the renter hears about it while the pickup is still ahead; a rental long past is closed quietly
      perform app.log_booking_event(r.id, case when r.pickup_at > p_now then 'offer_expired' else 'adjusted' end, 'pending_payment', 'expired', r.current_offer_version,
        case when v_until is not null
             then format('Not paid within %s minutes of accepting (by %s, Toronto): the hold on the car ended and the booking expired%s.',
                         coalesce(s.offer_unpaid_hold_minutes, 120), to_char(v_until at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                         case when r.pickup_at > p_now then ' (the car is taken for those dates, or the pickup is too close)' else '' end)
             else 'Accepted and never paid, and the rental dates are past: the booking expired (release 48 clean-up).' end, null, 'system');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.expire_unpaid(timestamptz, boolean) from public, anon, authenticated;
grant execute on function app.expire_unpaid(timestamptz, boolean) to service_role;

-- the offers job (every 5 minutes) ends the holds too
select pg_temp.patch_fn('app.job_offers_expire(timestamptz)'::regprocedure,
  $o$     and not (coalesce((app.settings()).stale_request_expire, true) and exists (select 1 from bookings b where b.status = 'requested' and b.pickup_at <= p_now)) then$o$,
  $n$     and not (coalesce((app.settings()).stale_request_expire, true) and exists (select 1 from bookings b where b.status = 'requested' and b.pickup_at <= p_now))
     and not exists (select 1 from bookings b where b.status = 'pending_payment' and app.unpaid_hold_until(b) <= p_now) then$n$);
select pg_temp.patch_fn('app.job_offers_expire(timestamptz)'::regprocedure,
  $o$    v_r := app.expire_stale_requests(p_now);
    perform app.job_succeed(v_run, jsonb_build_object('offers_expired', v_n, 'requests_expired', v_r));$o$,
  $n$    v_r := app.expire_stale_requests(p_now);
    perform app.job_succeed(v_run, jsonb_build_object('offers_expired', v_n, 'requests_expired', v_r, 'holds_ended', app.expire_unpaid(p_now)));$n$);

-- ================================================================ 6. the fleet calendar: each soft hold says when it ends
select pg_temp.patch_fn('app.admin_calendar(timestamptz, timestamptz, uuid)'::regprocedure,
  $o$jsonb_build_object('placeholder', e.ph, $o$,
  $n$jsonb_build_object('hold_until', case when e.x ->> 'type' = 'booking' and e.x ->> 'status' in ('offered', 'pending_payment')
                                          then (select app.booking_hold_until(bb) from bookings bb where bb.id = (e.x ->> 'booking_id')::uuid) end,
                                     'placeholder', e.ph, $n$);

-- ================================================================ 7. the one-time sweep: what is already stale
select app.expire_offers(now());
select app.expire_unpaid(now(), true);

comment on function app.expire_unpaid(timestamptz, boolean) is
  'An accepted offer not paid within offer_unpaid_hold_minutes (2961): a fresh offer and a text while the car is still free, else expired. Logged in the booking history.';
