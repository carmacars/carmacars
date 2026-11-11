-- 1300_r35a_request_history.sql
-- Release 35, part A (helper A), tasks 1 and 2 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: staff (Sales,
-- customer service, Fleet, Admin) see the renter's ORIGINAL request as submitted (car, dates, coverage choice, add-ons,
-- notes, the price shown at the time) and the full offer history on that request (every version with its price breakdown,
-- who sent it, when, its status), with "Revert to this offer" that makes a new offer from an old version (still to send);
-- and the request page shows prominently which coverage the renter chose, with its proof status.
--   1. booking_request_snapshots: the request as the renter sent it, taken once at the end of the transaction that made the
--      request (a deferred constraint trigger, so the add-ons, the coverage choice, the promo and the price the request
--      function sets after the insert are all in it) and never changed after. Requests made before this release get one
--      rebuilt from what the booking kept (source 'backfill': the dates, choices and note of the request; the car and the
--      price only when no offer was ever sent, else left out rather than shown wrong).
--   2. app.request_history (ops_read request_history): the original request, every offer version (booking_offers, with
--      the sender's name and the price lines) and the coverage card, for an Admin, customer service, Sales and Fleet.
--   3. app.offer_revert_prepare (ops_read offer_revert): the changes that bring the review screen back to an old version
--      (car, dates, rate type, rates, rental charge, deposit, km, discount, fees, Protection Plan price, promo code). Nothing
--      changes until staff send it: the screen loads them as a new offer to review and send. Only who sends offers asks
--      (customer service, Sales, an Admin), on a request or an offer still being arranged.
--   4. app.booking_coverage_card: the coverage the renter chose (OPCF 27 on their own policy, credit card, Protection Plan,
--      included with the car) and its proof status (missing, waiting for review, confirmed, rejected, not needed).
-- No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. the request as sent
create table booking_request_snapshots (
  booking_id      uuid primary key references bookings(id) on delete cascade,
  source          text not null default 'request' check (source in ('request', 'backfill')),
  captured_at     timestamptz not null default now(),
  vehicle_id      uuid references vehicles(id) on delete set null,
  vehicle_name    text,
  pickup_at       timestamptz,
  return_at       timestamptz,
  billable_days   integer,
  pickup_place    text,
  return_place    text,
  booking_type    text,
  coverage_option smallint,
  note            text,
  details         jsonb not null default '{}'::jsonb,
  addons          jsonb not null default '[]'::jsonb,
  price           jsonb
);
comment on table booking_request_snapshots is 'The booking request exactly as the renter sent it (1300): car, dates, places, coverage choice, add-ons, note, the request details and the price shown at the time. Taken once when the request is made and never changed; source backfill marks a request made before r35, rebuilt without the car and price when an offer had already changed them.';
alter table booking_request_snapshots enable row level security;
create policy admin_all on booking_request_snapshots for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_booking_request_snapshots after insert or update or delete on booking_request_snapshots for each row execute function app.audit_row();
revoke all on booking_request_snapshots from anon, authenticated;
grant select on booking_request_snapshots to authenticated;

-- the price the booking holds now, with its lines
create function app.request_price_now(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'rental_charge_cents', b.rental_charge_cents, 'rate_applied', b.rate_applied,
    'discount_cents', coalesce(b.discount_cents, 0) + coalesce(b.staff_discount_cents, 0) + coalesce(b.promo_discount_cents, 0),
    'promo_code', (select pc.code from promo_codes pc where pc.id = b.promo_code_id),
    'subtotal_cents', b.subtotal_at_booking_cents, 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents,
    'renter_due_cents', coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents), 'deposit_cents', b.deposit_cents,
    'km_allowance_per_day', b.km_allowance_per_day,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('charge_type', li.charge_type, 'description', li.description,
                                                         'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents) order by li.created_at, li.id)
                         from booking_line_items li
                        where li.booking_id = b.id and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null), '[]'::jsonb))
    from bookings b where b.id = p_booking
$$;

create function app.request_snapshot_take(p_booking uuid, p_source text default 'request') returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_exact boolean;
  v_pickup timestamptz;
  v_return timestamptz;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.requested_at is null then return; end if;
  -- a request made before r35: what the booking kept of it. The car and the price are the request's only while no offer
  -- or edit by staff changed them (no offer ever sent and still a request).
  v_exact := p_source = 'request' or (b.status = 'requested' and b.current_offer_version is null
             and not exists (select 1 from booking_events e where e.booking_id = b.id and e.kind in ('adjusted', 'car_changed', 'custom_price')));
  v_pickup := coalesce((select (e.details ->> 'pickup_at')::timestamptz from booking_events e where e.booking_id = b.id and e.kind = 'requested' and e.details ? 'pickup_at' order by e.created_at limit 1),
                       case when v_exact then b.pickup_at end, (b.request_details ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((select (e.details ->> 'return_at')::timestamptz from booking_events e where e.booking_id = b.id and e.kind = 'requested' and e.details ? 'return_at' order by e.created_at limit 1),
                       case when v_exact then b.return_at end, (b.request_details ->> 'return_at')::timestamptz, b.original_return_at, b.return_at);
  insert into booking_request_snapshots (booking_id, source, captured_at, vehicle_id, vehicle_name, pickup_at, return_at, billable_days,
      pickup_place, return_place, booking_type, coverage_option, note, details, addons, price)
  values (b.id, p_source, case when p_source = 'request' then now() else b.requested_at end,
      case when v_exact then b.vehicle_id end, case when v_exact then app.vehicle_name(b.vehicle_id) end,
      v_pickup, v_return, case when v_exact then b.billable_days end,
      case when v_exact then b.pickup_place end, case when v_exact then b.return_place end,
      b.booking_type::text, coalesce((b.request_details ->> 'coverage_option')::smallint, b.coverage_option), b.request_note,
      coalesce(b.request_details, '{}'::jsonb),
      case when v_exact then coalesce((select jsonb_agg(jsonb_build_object('name', a.name, 'quantity', a.quantity, 'hours', a.hours,
                                                                   'unit_price_cents', a.unit_price_cents, 'pricing_unit', a.pricing_unit, 'status', a.status) order by a.added_at)
                                         from booking_addons a where a.booking_id = b.id and not a.after_booking and a.cancelled_at is null), '[]'::jsonb)
           else coalesce((select jsonb_agg(jsonb_build_object('name', a.name, 'quantity', a.quantity, 'hours', a.hours, 'status', a.status) order by a.added_at)
                            from booking_addons a where a.booking_id = b.id and a.added_via = 'request' and not a.after_booking), '[]'::jsonb) end,
      case when v_exact then app.request_price_now(b.id) end)
  on conflict (booking_id) do nothing;
end $$;

create function app.request_snapshot_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.request_snapshot_take(new.id, 'request');
  return null;
end $$;
-- at the end of the transaction that made the request: the request function prices it, adds the add-ons, the coverage
-- choice and the promo after the insert
create constraint trigger bookings_request_snapshot after insert on bookings deferrable initially deferred
  for each row when (new.status = 'requested' and new.requested_at is not null) execute function app.request_snapshot_after();

-- the requests already there
select app.request_snapshot_take(b.id, 'backfill') from bookings b where b.requested_at is not null
   and not exists (select 1 from booking_request_snapshots s where s.booking_id = b.id);

-- ================================================================ 2. the coverage the renter chose, and its proof
create function app.booking_coverage_card(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when b.id is null then null else jsonb_build_object(
    'option', b.coverage_option,
    'short', case when b.booking_type = 'owner' then 'Not needed: the owner''s own trip'
                  else case b.coverage_option when 1 then 'Own insurance (OPCF 27)' when 2 then 'Credit card coverage'
                                              when 3 then 'Protection Plan' when 4 then 'Insurance included with the car' end end,
    'label', app.coverage_option_label(b.coverage_option),
    'requested_option', coalesce((select s.coverage_option from booking_request_snapshots s where s.booking_id = b.id), b.coverage_option),
    'confirmed_at', b.coverage_confirmed_at,
    'proof', case
      when b.booking_type = 'owner' or b.coverage_option in (3, 4) then 'not_needed'
      when b.coverage_option is null then 'no_choice'
      when cp.id is null then 'missing'
      when cp.status = 'confirmed' or b.coverage_confirmed_at is not null then 'confirmed'
      else cp.status end,
    'proof_words', case
      when b.booking_type = 'owner' then 'No coverage needed for the owner''s own trip'
      when b.coverage_option = 3 then case when b.coverage_confirmed_at is not null then 'Protection Plan confirmed' else 'Bought with the rental: no proof to send' end
      when b.coverage_option = 4 then 'Included with the car: no proof to send'
      when b.coverage_option is null then 'No coverage chosen yet'
      when cp.id is null then 'Proof not sent yet'
      when cp.status = 'confirmed' or b.coverage_confirmed_at is not null then 'Proof confirmed' || coalesce(' ' || app.fmt_at(coalesce(cp.confirmed_at, b.coverage_confirmed_at)), '')
      when cp.status = 'rejected' then 'Proof rejected' || coalesce(': ' || cp.rejection_reason, '')
      else 'Proof sent, waiting for review' end,
    'detail', case b.coverage_option
      when 1 then concat_ws(', ', cp.insurer_name, case when cp.policy_expiry is not null then 'valid to ' || app.fmt_day(cp.policy_expiry) end)
      when 2 then concat_ws(' ', initcap(cp.card_brand), case when cp.card_last4 is not null then 'ending ' || cp.card_last4 end) end,
    'rejection_reason', cp.rejection_reason) end
    from bookings b left join lateral (select * from app.current_coverage_proof(b.id)) cp on true
   where b.id = p_booking
$$;

-- ================================================================ 3. the request, the offers and the coverage, for staff
create function app.request_history_viewer(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales', 'fleet')
$$;

-- p {booking: id or number}
create function app.request_history(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_request_snapshots;
  v_offers jsonb;
begin
  if not app.request_history_viewer(p_by) then raise exception 'An Admin, customer service, Sales or Fleet sees the request and its offers' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', p ->> 'number', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into s from booking_request_snapshots where booking_id = b.id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'version', o.version, 'status', o.status, 'current', o.version = b.current_offer_version,
      'sent_at', o.sent_at, 'sent_by', o.sent_by, 'sent_by_name', coalesce((select u.full_name from users u where u.id = o.sent_by), case when o.sent_by is null then 'Automatic' else 'Staff' end),
      'expires_at', o.expires_at, 'responded_at', o.responded_at, 'response_note', o.response_note, 'message', o.message,
      'vehicle_id', o.vehicle_id, 'vehicle_name', app.vehicle_name(o.vehicle_id), 'pickup_at', o.pickup_at, 'return_at', o.return_at, 'billable_days', o.billable_days,
      'rental_charge_cents', o.rental_charge_cents, 'discount_cents', o.discount_cents, 'deposit_cents', o.deposit_cents,
      'subtotal_cents', o.subtotal_cents, 'hst_cents', o.hst_cents, 'total_cents', o.total_cents,
      'insurer_share_cents', o.insurer_share_cents, 'renter_due_cents', o.renter_due_cents,
      'rate_applied', o.terms ->> 'rate_applied', 'km_allowance_per_day', (o.terms ->> 'km_allowance_per_day')::integer,
      'promo_code', o.terms ->> 'promo_code', 'lines', coalesce(o.line_items, '[]'::jsonb)) order by o.version desc), '[]'::jsonb)
    into v_offers from booking_offers o where o.booking_id = b.id;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'booking_type', b.booking_type,
    'owner_trip', b.booking_type = 'owner', 'instant_book', coalesce((to_jsonb(b) ->> 'instant_book')::boolean, false), 'current_offer_version', b.current_offer_version,
    'made_by_staff', s.booking_id is null and coalesce(b.added_by_staff, false),
    'original', case when s.booking_id is null then null else jsonb_build_object(
      'source', s.source, 'captured_at', s.captured_at, 'requested_at', b.requested_at,
      'vehicle_id', s.vehicle_id, 'vehicle_name', s.vehicle_name, 'pickup_at', s.pickup_at, 'return_at', s.return_at,
      'billable_days', s.billable_days, 'pickup_place', s.pickup_place, 'return_place', s.return_place, 'booking_type', s.booking_type,
      'coverage_option', s.coverage_option, 'coverage_label', case when s.coverage_option is null then null else app.coverage_option_label(s.coverage_option) end,
      'note', s.note, 'addons', s.addons, 'price', s.price,
      'drivers', coalesce(jsonb_array_length(case when jsonb_typeof(s.details -> 'drivers') = 'array' then s.details -> 'drivers' end), 0),
      'extras', coalesce(s.details -> 'extras', '{}'::jsonb), 'promo_code', s.details ->> 'promo_code',
      'heard_about', s.details ->> 'heard_about') end,
    'offers', v_offers,
    'coverage', app.booking_coverage_card(b.id),
    'may_revert', app.offer_role(p_by) is not null and b.status in ('requested', 'offered', 'pending_payment'));
end $$;

-- ================================================================ 4. back to an old offer: the changes, to review and send
-- p {booking, version}: the review screen's changes that bring the booking back to that version. Nothing changes here.
create function app.offer_revert_prepare(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  o booking_offers;
  t jsonb;
  v_lines jsonb;
begin
  if app.offer_role(p_by) is null then raise exception 'Customer service, Sales or an Admin sends offers' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('requested', 'offered', 'pending_payment') then
    raise exception 'Booking % is %: an old offer comes back only while the offer is being arranged', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  select * into o from booking_offers where booking_id = b.id and version = nullif(p ->> 'version', '')::integer;
  if o.id is null then raise exception 'There is no offer version % on %', coalesce(p ->> 'version', '?'), b.booking_number using errcode = 'P0002'; end if;
  if o.version = b.current_offer_version and b.status in ('offered', 'pending_payment') then
    raise exception 'Version % is the offer out now: nothing to go back to', o.version using errcode = '23514';
  end if;
  t := coalesce(o.terms, '{}'::jsonb);
  -- each fee line of that version for the trip (the rental charge, the discounts and HST are worked out again)
  select coalesce(jsonb_object_agg(x ->> 'charge_type', (x ->> 'amount_cents')::bigint), '{}'::jsonb) into v_lines
    from jsonb_array_elements(coalesce(o.line_items, '[]'::jsonb)) x
   where x ->> 'charge_type' not in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount')
     and (x ->> 'charge_type') not like 'insurer\_%';
  return jsonb_build_object('version', o.version, 'sent_at', o.sent_at, 'total_cents', o.total_cents,
    'changes', jsonb_strip_nulls(jsonb_build_object(
      'vehicle_id', o.vehicle_id, 'pickup_at', o.pickup_at, 'return_at', o.return_at, 'booking_type', t ->> 'booking_type',
      'daily_rate_cents', (t ->> 'daily_rate_cents')::bigint, 'weekend_rate_cents', (t ->> 'weekend_rate_cents')::bigint,
      'weekly_rate_cents', (t ->> 'weekly_rate_cents')::bigint, 'monthly_rate_cents', (t ->> 'monthly_rate_cents')::bigint,
      'rental_charge_cents', o.rental_charge_cents, 'deposit_cents', o.deposit_cents,
      'km_allowance_per_day', (t ->> 'km_allowance_per_day')::integer, 'overage_cents_per_km', (t ->> 'overage_cents_per_km')::bigint,
      'staff_discount_cents', coalesce((t ->> 'staff_discount_cents')::bigint, 0),
      'staff_discount_reason', case when coalesce((t ->> 'staff_discount_cents')::bigint, 0) > 0 then format('Back to offer version %s', o.version) end)),
    'lines', v_lines, 'promo_code', coalesce(t ->> 'promo_code', ''),
    'message', format('Back to the offer of %s (version %s).', app.fmt_at(o.sent_at), o.version));
end $$;

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['request_price_now', 'request_snapshot_take', 'request_snapshot_after', 'booking_coverage_card',
             'request_history_viewer', 'request_history', 'offer_revert_prepare'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
