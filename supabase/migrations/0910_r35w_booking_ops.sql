-- 0910_r35w_booking_ops.sql
-- Release 35 part W (docs/changes/2026-11-08-r35-car-change.md, -accident-card.md, -past-trips.md, -odometer-fuel.md).
-- SCHEMA_MARKER 0910. The owner, November 8:
--   1. Change the car on an offer or a confirmed booking before pickup (app.swap_vehicle of 0020 only works on rent and
--      said "change the booking instead", which did not exist for the car). Admin, customer service, Fleet (and Sales on a
--      request or an offer) pick a car free for the dates; the price comes from the new car's rate sheet; the difference
--      is an open amount (the renter's Pay the balance, the existing pay link and saved card charge) or a refund waiting
--      for approval; the open field jobs move to the new car; the coverage stays; the history and the audit log record it;
--      the renter gets one email. An offer is sent again (its email is the one); a confirmed booking gets a change request
--      applied at once (source staff_car_change: the "Booking updated" email, owners told as for any change) and its
--      agreement a new version to sign, made by the agreement job (0154); that version's email is folded into the change
--      email when its signing link also goes by text.
--   2. The accident card of a booking (app.accident_card): the steps after an accident (the r34 card's) and the coverage
--      this booking uses: OPCF 27 (the renter's own policy: insurer and policy number from their proof), credit card
--      coverage (the card and its coverage provider from their proof), or the Protection Plan (the provider, policy number
--      and claims phone from Program settings, new here, with the activation reference). Never the fleet policy.
--   3. Past trips never left open: Admin and Fleet list the bookings confirmed or on rent whose return time has passed and
--      close them at the booked times (or the times they enter) with the past-trip override of 0770 (a confirmed booking)
--      or a return override (on rent); no renter email or text for a back-dated close; the deposit then settles as today.
--      A Fleet To do when one is still open 2 hours after its return time, and a line in the morning digest.
--   4. Odometer and fuel at every check-out and check-in: the dashboard photo is read by the vision model (purpose
--      dash_read, within the AI allowance) and confirmed or typed by the person; each reading is kept (handover_readings)
--      with the dashboard photo and the selfie's capture details (taken live; a selfie without fresh capture details is
--      noted for staff, never a block). The return charges of 0130 price the km over the allowance (the booking's rate per
--      km) and the fuel by the eighth (Program settings refill price); an eighth is now counted to the nearest eighth.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '0910: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 0. shared
alter table booking_change_requests drop constraint if exists booking_change_requests_source_check;
alter table booking_change_requests add constraint booking_change_requests_source_check
  check (source in ('booking_app', 'staff_calendar', 'staff_car_change'));
comment on column booking_change_requests.source is 'booking_app: asked or proposed through the 0019 functions; staff_calendar: a drag or resize on the calendar (app.calendar_apply_change); staff_car_change: staff changed the car before pickup (0910, app.car_change), applied at once.';

do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds from unnest(v_kinds || array['car_changed', 'past_trip_closed']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('past_trip_open', 'fleet', 'A trip is still open after its return time', 'high', 'none', null, null, null,
   'A booking is still confirmed or on rent 2 hours after its return time (0910). Close it on Close past trips: at the booked times, or the actual times if it was late or early.')
on conflict (task_type) do nothing;

-- ================================================================ 1. change the car before pickup
-- who changes the car: an Admin, customer service, Fleet; Sales on a request or an offer
create or replace function app.car_change_allowed(p_by uuid, p_status text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')
      or (app.user_va_has(p_by, 'fleet') and p_status = 'confirmed')
      or (app.user_va_has(p_by, 'sales') and p_status in ('requested', 'offered'))
$$;

-- what stops moving booking b to car v now; null when nothing does
create or replace function app.car_change_refusal(b bookings, p_vehicle uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  if b.status::text not in ('requested', 'offered', 'pending_payment', 'confirmed') then
    return format('Booking %s is %s: the car is changed on a request, an offer or a confirmed booking before pickup (on rent: Swap vehicle)', b.booking_number, replace(b.status::text, '_', ' '));
  end if;
  if b.handed_over_at is not null or exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' and c.completed_at is not null) then
    return 'The car was already picked up: use Swap vehicle';
  end if;
  if coalesce(b.is_placeholder, false) then return 'A placeholder booking has no car to change'; end if;
  if b.status::text = 'confirmed' and (b.bill_to <> 'renter' or b.dates_provisional) then
    return 'A booking billed to an insurer, or with dates still provisional, changes its car on the calendar';
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = b.id and e.status in ('requested', 'approved', 'confirmed')) then
    return 'The booking has an extension open: decide it first';
  end if;
  if p_vehicle is null then return 'Choose the car'; end if;
  if p_vehicle = b.vehicle_id then return 'That is the car the booking already has'; end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return 'That car does not exist'; end if;
  if v.retired_at is not null or coalesce(v.is_sample, false) then return 'That car is not in the fleet'; end if;
  if b.booking_type <> 'owner' and not coalesce(app.vehicle_bookable(p_vehicle), false) then return 'That car is not open for bookings'; end if;
  if b.booking_type = 'owner' and v.owner_id is distinct from b.owner_id then return 'An Owner Booking moves only to another car of the same Owner'; end if;
  if v.exit_date is not null and app.local_date(b.return_at) > v.exit_date then return 'That car leaves the fleet before the return'; end if;
  if exists (select 1 from booking_drivers d where d.booking_id = b.id and app.age_band(app.age_on(d.date_of_birth, app.local_date(b.pickup_at))) = '18_to_20')
     and not coalesce(v.allows_18_to_20, false) then
    return 'A driver is 18 to 20: that car is not for young drivers';
  end if;
  if not app.vehicle_is_available(p_vehicle, b.pickup_at, b.return_at, b.id) then return 'That car is not free for the whole of these dates'; end if;
  if b.booking_type <> 'owner' and not exists (select 1 from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())) then
    return 'That car has no rates set';
  end if;
  return null;
end $$;

-- the new car's rental charge for the booking's dates, from its rate sheet (the booking's own type and days)
create or replace function app.car_change_rental(b bookings, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  rc rate_cards;
  r record;
begin
  if b.booking_type = 'owner' then return jsonb_build_object('rental_charge_cents', 0, 'rate_applied', 'none', 'daily_days', 0, 'weekend_days', 0); end if;
  select * into rc from rate_cards x where x.vehicle_id = p_vehicle and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is null then return null; end if;
  select * into r from public.calc_rental_charge(b.pickup_at, b.billable_days, rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents,
                                                 rc.monthly_rate_cents, 'America/Toronto', rc.multi_day_rate_cents);
  return jsonb_build_object('rental_charge_cents', r.rental_charge_cents, 'rate_applied', r.rate_applied, 'daily_days', r.daily_days, 'weekend_days', r.weekend_days,
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents, 'weekly_rate_cents', rc.weekly_rate_cents,
    'monthly_rate_cents', rc.monthly_rate_cents, 'multi_day_rate_cents', rc.multi_day_rate_cents,
    'km_allowance_per_day', rc.km_allowance_per_day, 'overage_cents_per_km', rc.overage_cents_per_km);
end $$;

-- the booking's total if it moved to car v (the price lines a quote uses, with the lines staff typed kept)
create or replace function app.car_change_total(b bookings, p_vehicle uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.car_change_rental(b, p_vehicle);
  v_new jsonb;
  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];
  v_other bigint; v_other_hst bigint;
begin
  if r is null then return null; end if;
  v_new := app.price_lines(app.booking_price_spec(b.id, jsonb_build_object('vehicle_id', p_vehicle, 'rental_charge_cents', (r ->> 'rental_charge_cents')::bigint)));
  if b.request_details is not null then
    v_owned := v_owned || array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold'];
  end if;
  select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_other, v_other_hst
    from booking_line_items li
   where li.booking_id = b.id and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null and not li.charge_type = any (v_owned);
  return (v_new ->> 'subtotal_cents')::bigint + v_other + (v_new ->> 'hst_cents')::bigint + v_other_hst;
end $$;

-- p {booking}: the cars the booking may move to now, each with its new total and the difference
create or replace function app.car_change_options(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not app.car_change_allowed(p_by, b.status::text) then raise exception 'An Admin, customer service or Fleet changes the car (Sales on a request or an offer)' using errcode = '42501'; end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'total_cents', b.total_due_at_booking_cents,
    'refusal', nullif(app.car_change_refusal(b, b.vehicle_id), 'That is the car the booking already has'),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', q.id, 'name', q.name, 'plate', q.plate, 'class', q.class,
                       'total_cents', q.total, 'difference_cents', q.total - b.total_due_at_booking_cents) order by q.total, q.name)
                     from (select v.id, app.vehicle_name(v.id) as name, v.plate, v.class::text as class, app.car_change_total(b, v.id) as total
                             from vehicles v
                            where v.id <> b.vehicle_id and v.retired_at is null and not coalesce(v.is_sample, false)
                              and app.car_change_refusal(b, v.id) is null) q
                    where q.total is not null), '[]'::jsonb));
end $$;

-- p {booking, vehicle, reason}: move the booking to the car
create or replace function app.car_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  b2 bookings;
  v_to uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_refusal text;
  r jsonb;
  v_old_total bigint;
  v_diff bigint;
  v_before jsonb;
  v_after jsonb;
  v_req uuid;
  v_refund uuid;
  v_version integer;
  v_pay uuid;
  v_who text := coalesce((select full_name from users where id = p_by), 'Staff');
  v_from_name text;
  v_to_name text;
begin
  perform 1 from vehicles where id in ((select x.vehicle_id from bookings x where x.id::text = p ->> 'booking' or x.booking_number = upper(btrim(coalesce(p ->> 'booking', '')))), v_to)
   order by id for no key update;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not app.car_change_allowed(p_by, b.status::text) then raise exception 'An Admin, customer service or Fleet changes the car (Sales on a request or an offer)' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Say why the car changes (the history keeps it)' using errcode = '22023'; end if;
  v_refusal := app.car_change_refusal(b, v_to);
  if v_refusal is not null then raise exception '%', v_refusal using errcode = '23514'; end if;
  if b.status::text in ('pending_payment', 'confirmed')
     and exists (select 1 from booking_change_requests c where c.booking_id = b.id and c.status in ('requested', 'proposed', 'approved')) then
    raise exception 'A change request is open on booking %: decide it first', b.booking_number using errcode = '23514';
  end if;
  r := app.car_change_rental(b, v_to);
  v_old_total := b.total_due_at_booking_cents;
  v_from_name := app.vehicle_name(b.vehicle_id);
  v_to_name := app.vehicle_name(v_to);
  v_before := jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
                                 'rental_charge_cents', b.rental_charge_cents, 'subtotal_cents', b.subtotal_at_booking_cents,
                                 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents);

  -- an offer out is closed first (the renter gets the new one: that is their one email)
  if b.status::text in ('offered', 'pending_payment') then
    perform app.withdraw_offer(b.id, p_by, 'The car changes: ' || v_reason);
    -- the new offer is the renter's one email: the "offer withdrawn" one is not sent
    update app_events set processed_at = now(), process_note = 'Car changed: the new offer is the one email (0910)'
     where code = 'renter_offer_withdrawn' and entity_id = b.id and processed_at is null and created_at >= now();
  end if;

  -- the new car and its rate sheet (the coverage choice, the drivers and the add-ons stay); the rates of a confirmed
  -- booking change only here (app.booking_before_write lets this booking's update through)
  perform set_config('app.car_change', b.id::text, true);
  update bookings set
      vehicle_id = v_to,
      daily_rate_cents = coalesce((r ->> 'daily_rate_cents')::bigint, daily_rate_cents),
      weekend_rate_cents = coalesce((r ->> 'weekend_rate_cents')::bigint, weekend_rate_cents),
      weekly_rate_cents = coalesce((r ->> 'weekly_rate_cents')::bigint, weekly_rate_cents),
      monthly_rate_cents = coalesce((r ->> 'monthly_rate_cents')::bigint, monthly_rate_cents),
      multi_day_rate_cents = case when r ? 'daily_rate_cents' then (r ->> 'multi_day_rate_cents')::bigint else multi_day_rate_cents end,
      km_allowance_per_day = coalesce((r ->> 'km_allowance_per_day')::integer, km_allowance_per_day),
      km_allowance_total = coalesce((r ->> 'km_allowance_per_day')::integer, km_allowance_per_day) * billable_days,
      overage_cents_per_km = coalesce((r ->> 'overage_cents_per_km')::integer, overage_cents_per_km),
      rental_charge_cents = (r ->> 'rental_charge_cents')::bigint,
      rate_applied = coalesce(r ->> 'rate_applied', rate_applied),
      daily_days = coalesce((r ->> 'daily_days')::integer, daily_days), weekend_days = coalesce((r ->> 'weekend_days')::integer, weekend_days),
      discount_cents = case when booking_type = 'non_refundable' then public.calc_bps((r ->> 'rental_charge_cents')::bigint, (app.settings(app.local_date(booked_at))).non_refundable_discount_bps) else discount_cents end
   where id = b.id;
  perform set_config('app.car_change', '', true);
  perform app.sync_booking_price(b.id);
  select * into b2 from bookings where id = b.id;
  v_diff := b2.total_due_at_booking_cents - v_old_total;
  v_after := jsonb_build_object('vehicle_id', v_to, 'pickup_at', b2.pickup_at, 'return_at', b2.return_at, 'billable_days', b2.billable_days,
                                'rental_charge_cents', b2.rental_charge_cents, 'subtotal_cents', b2.subtotal_at_booking_cents,
                                'hst_cents', b2.hst_at_booking_cents, 'total_cents', b2.total_due_at_booking_cents);
  insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason, approved_by)
  values (b.id, b.vehicle_id, v_to, now(), 'Car changed before pickup: ' || v_reason, p_by);
  -- the open handover, delivery, return and collection jobs go to the new car
  update field_jobs set vehicle_id = v_to where booking_id = b.id and status in ('scheduled', 'acknowledged') and vehicle_id = b.vehicle_id;

  if b.status::text in ('offered', 'pending_payment') then
    v_version := app.send_offer(b.id, p_by, format('We changed the car to the %s. %s', v_to_name, v_reason));
  elsif b.status::text = 'confirmed' then
    -- the money: more is an open amount the renter pays (Pay the balance, the pay link or the saved card); less is a
    -- refund that waits for approval
    if v_diff < 0 then
      v_pay := (select x.id from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.kind = 'charge' and x.status = 'succeeded'
                 order by x.processed_at desc nulls last limit 1);
      if v_pay is not null then
        insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
        values (b.id, v_pay, 'other', -v_diff, 'pending_approval', p_by, format('Car changed to the %s before pickup: the new car costs less. %s', v_to_name, v_reason))
        returning id into v_refund;
        perform app.raise_task(p_type => 'change_refund', p_queue => 'finance', p_title => format('Booking %s: refund after a change of car', b.booking_number),
          p_detail => format('The car changed from the %s to the %s: %s back to the renter. The refund waits for approval.', v_from_name, v_to_name, app.fmt_money(-v_diff)),
          p_booking => b.id, p_vehicle => v_to, p_renter => b.renter_id, p_related_table => 'refunds', p_related_id => v_refund,
          p_dedupe => 'change_refund:' || v_refund, p_created_by => p_by);
      end if;
    end if;
    -- recorded as a change applied at once: the renter's "Booking updated" email, the owners' notices, the jobs follow
    insert into booking_change_requests (booking_id, requested_by_role, requested_by, status, note, changes, before, after, lines,
        difference_cents, hst_cents, total_difference_cents, priced_at, decided_by, decided_at, source, refund_id)
    values (b.id, 'staff', p_by, 'approved', v_reason, jsonb_build_object('vehicle_id', v_to), v_before, v_after,
        (select coalesce(jsonb_agg(jsonb_build_object('charge_type', li.charge_type, 'description', li.description, 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents) order by li.created_at), '[]'::jsonb)
           from booking_line_items li where li.booking_id = b.id and li.stage = 'booking' and li.voided_at is null and li.charged_to_renter),
        b2.subtotal_at_booking_cents - b.subtotal_at_booking_cents, b2.hst_at_booking_cents - b.hst_at_booking_cents, v_diff, now(), p_by, now(),
        'staff_car_change', v_refund)
    returning id into v_req;
    update booking_change_requests set status = 'applied', applied_by = p_by, applied_at = now() where id = v_req;
  end if;
  perform app.booking_jobs_follow(b.id);

  perform app.log_booking_event(b.id, 'car_changed', b.status::text, (select status::text from bookings where id = b.id), v_version,
    format('Car changed by %s from the %s to the %s: %s. %s', v_who, v_from_name, v_to_name, v_reason,
           case when v_diff > 0 then format('%s more is open for the renter to pay.', app.fmt_money(v_diff))
                when v_diff < 0 and v_refund is not null then format('%s back to the renter, waiting for approval.', app.fmt_money(-v_diff))
                when v_diff < 0 then format('The price is %s lower.', app.fmt_money(-v_diff))
                else 'The price stays the same.' end),
    p_by, 'staff', jsonb_build_object('from_vehicle_id', b.vehicle_id, 'to_vehicle_id', v_to, 'difference_cents', v_diff, 'refund_id', v_refund,
                                      'change_request_id', v_req, 'offer_version', v_version));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_car_changed', 'bookings', b.id::text, v_before, v_after || jsonb_build_object('reason', v_reason, 'refund_id', v_refund));
  return jsonb_build_object('ok', true, 'booking_id', b.id, 'booking_number', b.booking_number, 'status', (select status from bookings where id = b.id),
    'vehicle_id', v_to, 'vehicle', v_to_name, 'old_total_cents', v_old_total, 'total_cents', b2.total_due_at_booking_cents, 'difference_cents', v_diff,
    'open_cents', case when b.status::text = 'confirmed' then app.booking_part_open(b.id, 'balance') end, 'refund_id', v_refund,
    'change_request_id', v_req, 'offer_version', v_version);
end $$;

select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$  -- a booking always uses the rates stored on it
  if not (old.status::text = any (v_arranging))$o$,
  $n$  -- a booking always uses the rates stored on it (0910: but a change of car before pickup takes the new car's)
  if not (old.status::text = any (v_arranging)) and coalesce(current_setting('app.car_change', true), '') is distinct from new.id::text$n$);

-- the email of a change of car: the money in the words of this change, and the agreement to sign by text
alter function app.notification_payload(text, app_events, jsonb) rename to notification_payload_pre0910;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.notification_payload_pre0910(p_code, p_event, p_to);
  c booking_change_requests;
  v_signed boolean;
  v_mobile boolean;
begin
  if p_code = 'renter_change_applied' and p_event.entity = 'booking_change_request' then
    select * into c from booking_change_requests where id = p_event.entity_id;
    if c.source = 'staff_car_change' then
      v_signed := exists (select 1 from rental_agreements a where a.booking_id = c.booking_id and a.status = 'completed');
      v_mobile := exists (select 1 from bookings b join renters r on r.id = b.renter_id where b.id = c.booking_id and coalesce(r.mobile, '') <> '');
      x := x || jsonb_build_object('money_text',
        case when coalesce(c.total_difference_cents, 0) > 0
             then format('The new car costs %s more. Pay it from your booking page (Pay the balance), or pay our team by e-Transfer or cash.', app.fmt_money(c.total_difference_cents))
             when coalesce(c.total_difference_cents, 0) < 0 and c.refund_id is not null
             then format('The new car costs %s less: it goes back to your card. Refunds reach your account 5 to 10 business days after we send them.', app.fmt_money(-c.total_difference_cents))
             when coalesce(c.total_difference_cents, 0) < 0 then format('The new car costs %s less.', app.fmt_money(-c.total_difference_cents))
             else 'The price of your booking stays the same.' end
        || case when v_signed then case when v_mobile then ' Your rental agreement is updated for the new car: sign it with the link we text you.'
                                       else ' Your rental agreement is updated for the new car: we email you the link to sign it.' end
                else '' end);
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.notification_payload_pre0910(text, app_events, jsonb)'::regprocedure);

-- one renter email: the agreement version of a change of car is announced by the change email (its link by text);
-- the version's own email is sent only to a signer with no mobile number (or for any other change)
alter function app.agreement_version_notify(uuid, boolean) rename to agreement_version_notify_pre0910;
create function app.agreement_version_notify(p_version uuid, p_resend boolean default false) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v agreement_versions;
  n integer;
begin
  select * into v from agreement_versions where id = p_version;
  n := app.agreement_version_notify_pre0910(p_version, p_resend);
  if not p_resend and v.status = 'awaiting_signature'
     and exists (select 1 from jsonb_array_elements(coalesce(v.changes, '[]'::jsonb)) x where x ->> 'key' = 'vehicle.id')
     and exists (select 1 from booking_change_requests c where c.booking_id = v.booking_id and c.source = 'staff_car_change' and c.status = 'applied'
                    and c.applied_at > now() - interval '3 days') then
    update app_events e set processed_at = now(), process_note = 'Change of car: announced by the change email, the signing link goes by text (0910)'
     where e.code = 'renter_agreement_version' and e.entity_id = v.id and e.processed_at is null
       and exists (select 1 from agreement_version_signers g where g.version_id = v.id and g.id::text = e.payload ->> 'signer_id' and coalesce(g.mobile, '') <> '');
  end if;
  return n;
end $$;
select pg_temp.copy_grants('app.agreement_version_notify(uuid, boolean)'::regprocedure, 'app.agreement_version_notify_pre0910(uuid, boolean)'::regprocedure);

-- ================================================================ 2. the accident card of a booking
alter table program_settings
  add column if not exists accident_plan_provider_name text default 'RentalCover',
  add column if not exists accident_plan_policy_number text,
  add column if not exists accident_plan_claims_phone text;
comment on column program_settings.accident_plan_provider_name is 'Protection Plan provider printed on a renter''s accident card when the booking has the Protection Plan (0910).';
comment on column program_settings.accident_plan_policy_number is 'Protection Plan master policy number printed on the accident card (0910); empty: the card shows the activation reference.';
comment on column program_settings.accident_plan_claims_phone is 'Protection Plan claims phone printed on the accident card (0910).';

create or replace function app.accident_card(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  ss site_settings;
  cp coverage_proofs;
  pm payment_methods;
  v vehicles;
  v_kind text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into ss from site_settings limit 1;
  select * into v from vehicles where id = b.vehicle_id;
  select * into cp from coverage_proofs x where x.booking_id = b.id and x.coverage_option = b.coverage_option and x.status in ('confirmed', 'submitted')
   order by (x.status = 'confirmed') desc, x.created_at desc limit 1;
  if cp.payment_method_id is not null then select * into pm from payment_methods where id = cp.payment_method_id; end if;
  if pm.id is null and b.coverage_option = 2 then select * into pm from payment_methods where id = b.card_on_file_id; end if;
  v_kind := case b.coverage_option when 1 then 'own_policy' when 2 then 'card' when 3 then 'plan' else 'none' end;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
    'company', jsonb_build_object('trade_name', s.company_trade_name, 'support_phone', coalesce(ss.phone_display, s.company_phone),
                'roadside_phone', coalesce(ss.roadside_phone_display, s.incident_line_phone), 'incident_line', coalesce(ss.roadside_phone_display, s.incident_line_phone)),
    'car', jsonb_build_object('vehicle_id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'plate', v.plate, 'vin', v.vin),
    'renter', (select r.legal_name from renters r where r.id = b.renter_id),
    'coverage', jsonb_build_object('kind', v_kind, 'option', b.coverage_option, 'confirmed', b.coverage_confirmed_at is not null and cp.status = 'confirmed',
      'insurer_name', case when v_kind = 'own_policy' then cp.insurer_name end,
      'policy_number', case when v_kind = 'own_policy' then cp.policy_number end,
      'policy_expiry', case when v_kind = 'own_policy' then cp.policy_expiry end,
      'card_issuer', case when v_kind = 'card' then coalesce(cp.card_issuer, pm.card_brand) end,
      'card_brand', case when v_kind = 'card' then coalesce(cp.card_brand, pm.card_brand) end,
      'card_last4', case when v_kind = 'card' then coalesce(cp.card_last4, pm.card_last4) end,
      'card_coverage_provider', case when v_kind = 'card' then nullif(btrim(coalesce(cp.coverage_provider, '')), '') end,
      'cardholder_name', case when v_kind = 'card' then cp.cardholder_name end,
      'plan_provider', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_provider_name, '')), '') end,
      'plan_policy_number', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_policy_number, '')), '') end,
      'plan_claims_phone', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_claims_phone, '')), '') end,
      'plan_reference', case when v_kind = 'plan' then cp.activation_ref end,
      'proof_document_id', cp.proof_document_id));
end $$;

-- the renter of the booking, or staff
create or replace function public.server_accident_card(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return app.accident_card(p_booking);
end $$;

-- ================================================================ 3. past trips never left open
create or replace function app.past_trips_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet') $$;

-- the trips still open after their return time, oldest first
create or replace function app.past_trips_open(p_now timestamptz default now()) returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from bookings b
   where b.status::text in ('confirmed', 'on_rent') and b.return_at < p_now and not coalesce(b.is_placeholder, false)
   order by b.return_at, b.booking_number
$$;

create or replace function app.past_trips_view(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.past_trips_allowed(p_by) then raise exception 'An Admin or Fleet closes past trips' using errcode = '42501'; end if;
  return jsonb_build_object('admin', app.user_is_admin(p_by), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
      'handed_over_at', b.handed_over_at, 'vehicle', app.vehicle_name(b.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = b.vehicle_id),
      'renter', (select r.legal_name from renters r where r.id = b.renter_id),
      'hours_past', round(extract(epoch from now() - b.return_at) / 3600.0, 1),
      'odometer_out_km', b.odometer_out_km) order by b.return_at)
    from app.past_trips_open(now()) b), '[]'::jsonb));
end $$;

-- p {booking, pickup_at?, return_at?, odometer_out_km?, odometer_in_km?, reason?}: closed at the booked times unless times are given
create or replace function app.past_trip_close(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o booking_overrides;
  v_kind text;
  v_payload jsonb;
  v_checks text[];
  v_res jsonb;
  v_pick timestamptz;
  v_ret timestamptz;
  v_on_time boolean;
  v_reason text;
begin
  if not app.past_trips_allowed(p_by) then raise exception 'An Admin or Fleet closes past trips' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text not in ('confirmed', 'on_rent') then raise exception 'Booking % is %: nothing to close', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514'; end if;
  if coalesce(b.is_placeholder, false) then raise exception 'Booking % is a placeholder: it is never handed over', b.booking_number using errcode = '23514'; end if;
  v_pick := coalesce(nullif(p ->> 'pickup_at', '')::timestamptz, b.handed_over_at, b.pickup_at);
  v_ret := coalesce(nullif(p ->> 'return_at', '')::timestamptz, b.return_at);
  if v_ret > now() then raise exception 'The return time has not passed yet: record the return when the car is back' using errcode = '22023'; end if;
  v_on_time := v_ret = b.return_at and (b.status::text = 'on_rent' or v_pick = b.pickup_at);
  v_reason := coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''),
                       case when v_on_time then 'Closed on time from Close past trips' else 'Closed from Close past trips at the actual times' end);
  v_kind := case when b.status::text = 'on_rent' then 'return' else 'past_trip' end;
  if v_kind = 'return' then
    v_payload := jsonb_strip_nulls(jsonb_build_object('at', v_ret, 'odometer_km', nullif(p ->> 'odometer_in_km', '')::numeric::integer, 'fuel_pct', nullif(p ->> 'fuel_in_pct', '')::numeric::integer));
  else
    v_payload := app.override_payload(b, 'past_trip', jsonb_build_object('pickup_at', v_pick, 'return_at', v_ret, 'odometer_out_km', p ->> 'odometer_out_km',
                                      'odometer_in_km', p ->> 'odometer_in_km', 'fuel_out_pct', p ->> 'fuel_out_pct', 'fuel_in_pct', p ->> 'fuel_in_pct'));
  end if;
  select array_agg(x ->> 'code') into v_checks from jsonb_array_elements(app.handover_blockers(p_by, b.id, v_kind, v_payload)) x;
  update booking_overrides set status = 'cancelled', decision_note = 'Replaced: closed from Close past trips', decided_by = p_by, decided_at = now()
   where booking_id = b.id and action = v_kind and status = 'requested';
  insert into booking_overrides (booking_id, action, checks, reason, payload, requested_by, decided_by, decided_at)
  values (b.id, v_kind, coalesce(v_checks, '{}'), v_reason, v_payload, p_by, p_by, now()) returning * into o;
  v_res := app.override_apply(o.id, p_by);
  -- a back-dated close sends the renter nothing (no "rental started", no return receipt, no text)
  update app_events set processed_at = now(), process_note = 'Past trip closed later (0910): no renter email for a back-dated close'
   where code like 'renter\_%' and processed_at is null and created_at >= now()
     and (entity_id = b.id or payload ->> 'booking_id' = b.id::text);
  update notification_outbox set status = 'skipped', status_reason = 'Past trip closed later (0910): no renter email for a back-dated close'
   where booking_id = b.id and audience = 'renter' and status in ('queued', 'delayed') and created_at >= now();
  update phone_outbox set status = 'skipped', status_reason = 'Past trip closed later (0910)'
   where booking_id = b.id and renter_id is not null and status in ('queued', 'delayed') and created_at >= now();
  perform app.resolve_tasks(array['past_trip_open'], b.id, p_by, 'Closed from Close past trips');
  perform app.log_booking_event(b.id, 'past_trip_closed', b.status::text, (select status::text from bookings where id = b.id), null,
    format('Past trip closed by %s %s: picked up %s, returned %s', coalesce((select full_name from users where id = p_by), 'staff'),
           case when v_on_time then 'on time' else 'at the actual times' end, app.fmt_at(coalesce(b.handed_over_at, v_pick)), app.fmt_at(v_ret)),
    p_by, 'staff', jsonb_build_object('override_id', o.id, 'on_time', v_on_time, 'kind', v_kind));
  return v_res || jsonb_build_object('on_time', v_on_time, 'kind', v_kind);
end $$;

-- p {bookings?}: every open past trip, or only those listed (the page sends none)
create or replace function app.past_trips_close_all(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  n integer := 0;
  v_failed jsonb := '[]'::jsonb;
  v_only text[] := case when jsonb_typeof(p -> 'bookings') = 'array' then array(select jsonb_array_elements_text(p -> 'bookings')) end;
begin
  if not app.past_trips_allowed(p_by) then raise exception 'An Admin or Fleet closes past trips' using errcode = '42501'; end if;
  for b in select * from app.past_trips_open(now()) x where v_only is null or x.id::text = any (v_only) loop
    begin
      perform app.past_trip_close(p_by, jsonb_build_object('booking', b.id));
      n := n + 1;
    exception when others then
      v_failed := v_failed || jsonb_build_object('booking_number', b.booking_number, 'problem', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('closed', n, 'failed', v_failed);
end $$;

-- every quarter-hour: a Fleet To do per trip open 2 hours after its return; once a day a digest line
create or replace function app.past_trips_sweep(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  n integer := 0;
  v_count integer;
  v_day text := to_char(app.local_date(p_now), 'YYYY-MM-DD');
begin
  for b in select * from app.past_trips_open(p_now - interval '2 hours') loop
    perform app.raise_task(p_type => 'past_trip_open', p_queue => 'fleet',
      p_title => left(format('%s: still %s %s after its return time. Close it', b.booking_number, replace(b.status::text, '_', ' '),
                             case when p_now - b.return_at < interval '1 day' then round(extract(epoch from p_now - b.return_at) / 3600.0) || ' hours'
                                  else floor(extract(epoch from p_now - b.return_at) / 86400.0) || ' days' end), 200),
      p_detail => format('Returned at %s on the booking. Close past trips records the pickup and the return at the booked times (edit them if it was late or early).', app.fmt_at(b.return_at)),
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'past_trip_open:' || b.id);
    n := n + 1;
  end loop;
  -- closed another way: the To do is done
  update tasks t set status = 'done', completed_at = p_now, completion_note = 'The trip is closed'
   where t.task_type = 'past_trip_open' and t.status in ('open', 'in_progress', 'waiting')
     and not exists (select 1 from bookings x where x.id = t.booking_id and x.status::text in ('confirmed', 'on_rent'));
  select count(*) into v_count from app.past_trips_open(p_now);
  if v_count > 0 and extract(hour from p_now at time zone 'America/Toronto') >= 5 then
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
    select x.role, 'staff_expiry_watch', 'morning',
           format('%s past %s still open after the return time: close them on Close past trips', v_count, case when v_count = 1 then 'trip' else 'trips' end),
           'Bookings confirmed or on rent whose return time has passed',
           rtrim((app.settings()).notify_base_url, '/') || x.path, 'past_trips_open:' || x.role || ':' || v_day
      from (values ('admin', '/admin/bookings/past-trips'), ('va_fleet', '/staff/past-trips')) x(role, path)
    on conflict (dedupe_key) do nothing;
  end if;
  return n;
end $$;

alter function app.server_jobs_due() rename to server_jobs_due_pre0910;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0910();
begin
  if extract(minute from now())::integer % 15 < 5 then
    begin
      perform app.past_trips_sweep(now());
    exception when others then
      raise warning 'past trips sweep: %', sqlerrm;
    end;
  end if;
  return j;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0910()'::regprocedure);

-- ================================================================ 4. odometer and fuel at every check-out and check-in
create table handover_readings (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references bookings (id) on delete cascade,
  kind             text not null check (kind in ('pickup', 'return')),
  who              text not null check (who in ('renter', 'staff')),
  recorded_by      uuid references users (id),
  odometer_km      integer check (odometer_km is null or odometer_km between 0 and 2000000),
  fuel_pct         smallint check (fuel_pct is null or fuel_pct between 0 and 100),
  source           text not null check (source in ('read_confirmed', 'typed')),
  ai_odometer_km   integer,
  ai_fuel_eighths  smallint check (ai_fuel_eighths is null or ai_fuel_eighths between 0 and 8),
  ai_model         text,
  dash_photo_path  text,
  selfie_path      text,
  selfie_taken_at  timestamptz,
  selfie_latitude  numeric(9, 6),
  selfie_longitude numeric(9, 6),
  selfie_live      boolean,
  staff_note       text,
  created_at       timestamptz not null default now()
);
comment on table handover_readings is 'Each odometer and fuel reading given at a check-out or check-in (0910): read from the dashboard photo and confirmed, or typed; with the dashboard photo, the selfie taken live in front of the car (its capture time and place when the device gave them) and a note to staff when the selfie had no fresh capture details.';
create index handover_readings_booking on handover_readings (booking_id, kind, created_at desc);
alter table handover_readings enable row level security;
create policy admin_all on handover_readings for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on handover_readings from anon, authenticated;
grant select on handover_readings to authenticated;
grant all on handover_readings to service_role;
create trigger audit_handover_readings after insert or update or delete on handover_readings for each row execute function app.audit_row();

-- the dashboard and selfie photos: their own angles (any photo may come from the camera roll; the selfie is taken live)
alter function app.angle_shot(text) rename to angle_shot_pre0910;
create function app.angle_shot(p_angle text) returns text
language sql immutable as $$
  select case p_angle when 'dashboard' then 'instrument_cluster' when 'selfie' then 'other' else app.angle_shot_pre0910(p_angle) end
$$;
select pg_temp.copy_grants('app.angle_shot(text)'::regprocedure, 'app.angle_shot_pre0910(text)'::regprocedure);

-- p.reading {source, ai_odometer_km, ai_fuel_eighths, ai_model, selfie {taken_at, latitude, longitude, live}}, beside the photos
create or replace function app.handover_reading_record(p_booking uuid, p_kind text, p_who text, p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  rd jsonb := coalesce(p -> 'reading', '{}'::jsonb);
  sf jsonb := coalesce(rd -> 'selfie', '{}'::jsonb);
  v_dash text;
  v_selfie text;
  v_taken timestamptz;
  v_live boolean;
  v_note text;
  v_id uuid;
begin
  if jsonb_typeof(p -> 'reading') is distinct from 'object' then return null; end if;
  select x ->> 'path' into v_dash from jsonb_array_elements(coalesce(p -> 'photos', '[]'::jsonb)) x where x ->> 'angle' in ('dashboard', 'odometer') limit 1;
  select x ->> 'path' into v_selfie from jsonb_array_elements(coalesce(p -> 'photos', '[]'::jsonb)) x where x ->> 'angle' = 'selfie' limit 1;
  v_taken := nullif(sf ->> 'taken_at', '')::timestamptz;
  -- live: the camera took it now (the device's capture time within 10 minutes of the submission)
  v_live := coalesce((sf ->> 'live')::boolean, false) and v_taken is not null and abs(extract(epoch from now() - v_taken)) <= 600;
  if v_selfie is null then v_note := 'No selfie in front of the car with this reading';
  elsif not v_live then v_note := 'The selfie has no fresh capture time from the camera: check it is the person at the car';
  end if;
  insert into handover_readings (booking_id, kind, who, recorded_by, odometer_km, fuel_pct, source, ai_odometer_km, ai_fuel_eighths, ai_model,
                                 dash_photo_path, selfie_path, selfie_taken_at, selfie_latitude, selfie_longitude, selfie_live, staff_note)
  values (p_booking, p_kind, p_who, p_by, nullif(p ->> 'odometer_km', '')::numeric::integer, nullif(p ->> 'fuel_pct', '')::numeric::smallint,
          case when rd ->> 'source' = 'read_confirmed' then 'read_confirmed' else 'typed' end,
          nullif(rd ->> 'ai_odometer_km', '')::numeric::integer, nullif(rd ->> 'ai_fuel_eighths', '')::numeric::smallint, left(rd ->> 'ai_model', 120),
          v_dash, v_selfie, v_taken, nullif(sf ->> 'latitude', '')::numeric, nullif(sf ->> 'longitude', '')::numeric, v_live, v_note)
  returning id into v_id;
  return v_id;
end $$;

alter function app.handover_one_screen(uuid, jsonb) rename to handover_one_screen_pre0910;
create function app.handover_one_screen(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.handover_one_screen_pre0910(p_by, p - 'reading');
  v_b uuid := (select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1);
  v_id uuid;
begin
  v_id := app.handover_reading_record(v_b, p ->> 'kind', 'staff', p_by, p);
  if v_id is not null and (select staff_note from handover_readings where id = v_id) is not null and (r ->> 'report_id') is not null then
    update condition_reports set notes = left(concat_ws(' ', notes, '[' || (select staff_note from handover_readings where id = v_id) || ']'), 4000) where id = (r ->> 'report_id')::uuid;
  end if;
  return r || jsonb_build_object('reading_id', v_id);
end $$;
select pg_temp.copy_grants('app.handover_one_screen(uuid, jsonb)'::regprocedure, 'app.handover_one_screen_pre0910(uuid, jsonb)'::regprocedure);

alter function app.self_handover_submit(uuid, jsonb) rename to self_handover_submit_pre0910;
create function app.self_handover_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.self_handover_submit_pre0910(p_user, p - 'reading');
  v_b uuid := (select id from bookings where id::text = p ->> 'booking' limit 1);
begin
  perform app.handover_reading_record(v_b, coalesce(p ->> 'kind', 'pickup'), 'renter', p_user, p);
  return r;
end $$;
select pg_temp.copy_grants('app.self_handover_submit(uuid, jsonb)'::regprocedure, 'app.self_handover_submit_pre0910(uuid, jsonb)'::regprocedure);

alter function public.server_return_claim_submit(uuid, jsonb, uuid) rename to server_return_claim_submit_pre0910;
create function public.server_return_claim_submit(p_token uuid, p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := public.server_return_claim_submit_pre0910(p_token, p - 'reading', p_user);
  v_b uuid := coalesce(nullif(r ->> 'booking_id', '')::uuid, (select booking_id from return_claims where id = nullif(r ->> 'claim_id', '')::uuid));
begin
  if v_b is not null then perform app.handover_reading_record(v_b, 'return', 'renter', p_user, p); end if;
  return r;
end $$;
select pg_temp.copy_grants('public.server_return_claim_submit(uuid, jsonb, uuid)'::regprocedure, 'public.server_return_claim_submit_pre0910(uuid, jsonb, uuid)'::regprocedure);

-- the pickup and the return readings side by side, with the km and fuel charges written at the return
create or replace function app.handover_readings_view(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'readings', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'who', h.who, 'odometer_km', h.odometer_km, 'fuel_pct', h.fuel_pct, 'source', h.source,
                   'ai_odometer_km', h.ai_odometer_km, 'ai_fuel_eighths', h.ai_fuel_eighths, 'dash_photo_path', h.dash_photo_path, 'selfie_path', h.selfie_path,
                   'selfie_taken_at', h.selfie_taken_at, 'selfie_live', h.selfie_live, 'staff_note', h.staff_note, 'at', h.created_at,
                   'by', (select u.full_name from users u where u.id = h.recorded_by)) order by h.created_at)
                 from handover_readings h where h.booking_id = p_booking), '[]'::jsonb),
    'km_out', b.odometer_out_km, 'km_in', b.odometer_in_km, 'km_driven', case when b.odometer_in_km is not null and b.odometer_out_km is not null then b.odometer_in_km - b.odometer_out_km end,
    'km_allowance', b.km_allowance_total, 'overage_cents_per_km', b.overage_cents_per_km,
    'km_over', greatest(coalesce(b.odometer_in_km - b.odometer_out_km, 0) - coalesce(b.km_allowance_total, 0), 0),
    'fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct,
    'fuel_eighths_short', case when b.fuel_out_pct is not null and b.fuel_in_pct is not null and b.fuel_out_pct > b.fuel_in_pct
                               then greatest(1, round((b.fuel_out_pct - b.fuel_in_pct) / 12.5))::integer else 0 end,
    'charges', coalesce((select jsonb_agg(jsonb_build_object('key', li.assessment_key, 'label', coalesce(li.description, li.charge_type), 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents) order by li.created_at)
                 from booking_line_items li where li.booking_id = p_booking and li.voided_at is null and li.amount_cents <> 0
                  and li.assessment_key in ('mileage_overage', 'fuel', 'recharging', 'fuel_service_fee')), '[]'::jsonb))
    from bookings b where b.id = p_booking
$$;

-- a gas car short at the return: counted to the nearest eighth (12% or 13% short is one eighth, 25% two), at least one
select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  'v_pump := ceil(v_short / 12.5)::integer * (app.settings()).statement_fuel_cents_per_eighth;',
  'v_pump := greatest(1, round(v_short / 12.5))::integer * (app.settings()).statement_fuel_cents_per_eighth;');

-- the vision model reads the dashboard photo (purpose dash_read, the live tier of the AI allowance)
create or replace function app.ai_tier(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose = 'staff_assistant' then 'assistant'
              when p_purpose in ('chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review', 'permit_read',
                                 'interview_transcribe', 'interview_followup', 'vin_read', 'photo_sort', 'licence_read', 'dash_read') then 'live'
              else 'background' end
$$;
alter function app.ai_feature_label(text) rename to ai_feature_label_pre0910;
create function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$
  select case p_purpose when 'dash_read' then 'Odometer and fuel reader' else app.ai_feature_label_pre0910(p_purpose) end
$$;
select pg_temp.copy_grants('app.ai_feature_label(text)'::regprocedure, 'app.ai_feature_label_pre0910(text)'::regprocedure);

-- may this person have a dashboard photo read now: the renter of the booking, staff who record handovers, or the holder of
-- the booking's return link (the renter's "I've returned the car" page, signed in or not). p_booking or p_token names it.
create or replace function public.server_dash_read_gate(p_booking uuid, p_by uuid, p_token uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb;
  v_b uuid := coalesce(p_booking, (select b.id from bookings b where p_token is not null and b.return_link_token = p_token));
begin
  if v_b is null or not ((p_token is not null and exists (select 1 from bookings b where b.id = v_b and b.return_link_token = p_token))
                         or (p_by is not null and (app.is_booking_renter(v_b, p_by) or app.user_may_handover(p_by)))) then
    return jsonb_build_object('allowed', false, 'reason', 'not_permitted');
  end if;
  if not coalesce((app.ai_vision_budget(now()) ->> 'enabled')::boolean, false) then return jsonb_build_object('allowed', false, 'reason', 'off', 'booking_id', v_b); end if;
  a := app.ai_allow('dash_read', 150, now());
  return jsonb_build_object('allowed', coalesce((a ->> 'ok')::boolean, false), 'reason', case when not coalesce((a ->> 'ok')::boolean, false) then 'allowance' end,
                            'booking_id', v_b, 'model', (app.settings()).ai_vision_model, 'fallback_model', (app.settings()).ai_vision_fallback_model);
end $$;

-- the call, recorded with its model and neurons (never the reading or the photo)
create or replace function public.server_dash_read_record(p jsonb) returns void
language sql security definer set search_path = public, app as $$
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'dash_read', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons')
$$;

-- ================================================================ 5. the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0910;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_b uuid;
begin
  if (p_call = 'ops_do' and p_name in ('car_change', 'past_trip_close', 'past_trips_close_all'))
     or (p_call = 'ops_read' and p_name in ('car_change_options', 'past_trips', 'accident_card', 'handover_readings')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    if p_name = 'car_change' then return app.car_change(p_user, p_); end if;
    if p_name = 'car_change_options' then return app.car_change_options(p_user, p_); end if;
    if p_name = 'past_trips' then return app.past_trips_view(p_user, p_); end if;
    if p_name = 'past_trip_close' then return app.past_trip_close(p_user, p_); end if;
    if p_name = 'past_trips_close_all' then return app.past_trips_close_all(p_user, p_); end if;
    v_b := (select id from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', ''))) limit 1);
    if v_b is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if not (app.user_is_staff(p_user) or app.user_is_field(p_user)) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_name = 'accident_card' then return app.accident_card(v_b); end if;
    return app.handover_readings_view(v_b);
  end if;
  return app.door_pre0910(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0910(uuid, text, text, text, jsonb)'::regprocedure);

-- the renter's own page reads the readings of their booking (the return receipt)
create or replace function public.server_renter_readings(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.handover_readings_view(p_booking) - 'readings';
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['car_change_allowed', 'car_change_refusal', 'car_change_rental', 'car_change_total', 'car_change_options',
                     'car_change', 'notification_payload_pre0910', 'agreement_version_notify_pre0910', 'accident_card', 'past_trips_allowed', 'past_trips_open',
                     'past_trips_view', 'past_trip_close', 'past_trips_close_all', 'past_trips_sweep', 'server_jobs_due_pre0910', 'handover_reading_record',
                     'handover_one_screen_pre0910', 'self_handover_submit_pre0910', 'handover_readings_view', 'door_pre0910']))
               or (n.nspname = 'public' and p.proname = any (array['server_accident_card', 'server_dash_read_gate', 'server_dash_read_record', 'server_renter_readings',
                     'server_return_claim_submit_pre0910']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
