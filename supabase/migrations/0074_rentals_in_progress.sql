-- 0074_rentals_in_progress.sql
-- A rental already underway, added by hand (the owner's request of October 21, 2026): "Staff must be able to enter a
-- rental that is already in progress, easily, with no confusing errors." Before this, Add a rental took an upcoming
-- rental (pickup no more than an hour ago) or, ticked by an Admin, a past one (return in the past): a car picked up
-- yesterday and due back next week could not be entered at all. docs/changes/2026-10-21-rentals-in-progress.md.
--
--   1. Three cases, from the dates alone (app.manual_rental_phase): upcoming (the pickup is ahead), in progress (the
--      pickup has passed, the return is ahead) and past (the return has passed, kept as completed). No tick to set:
--      the form says which case it is; "past": true sent by an older screen is still checked against the dates.
--   2. In progress: the booking is written on trip (on_rent), handed over at the pickup entered by the staff member
--      who adds it. The handover gates (identity verified, coverage confirmed, deposit, condition report, agreement
--      signed, the car on the fleet policy) do not stop a car that is already out: each one missing becomes a task
--      (app.manual_rental_went_out), and the car's status, the tracker controls and the calendar follow as at a
--      handover. Return reminders, the return and check-in, tolls, payment (other way, link, saved card, unpaid),
--      commissions and the owner's revenue run as for any rental. Every staff role that adds rentals may add one, on
--      any active car (listing not finished, bookings closed to the public); a retired or exited car is refused.
--   3. The clash check of a rental in progress (app.manual_rental_live_clashes): before now, the rentals that really
--      happened (as they were checked in, no turnaround); from now on, the bookings, calendar blocks and turnaround
--      that hold the car.
--   4. Past: unchanged limits (an Admin; no payment link or saved card; at most manual_rental_past_max_days back), with
--      the wording "For a past rental, the return must already have happened".
--   5. Every message of Add a rental says what to do.
--   6. Paying a rental in progress online: the payment link is the renter's portal (sign, then Pay now); the payment
--      is recorded on the booking without changing its status (app.finalize_booking).

-- ================================================================ 1. the booking's record of how it was added
alter table bookings drop constraint if exists bookings_added_mode_check;
alter table bookings add constraint bookings_added_mode_check check (added_mode in ('future', 'in_progress', 'past'));
comment on column bookings.added_mode is
  'A rental added by hand (0046, 0074): future (upcoming when added), in_progress (already underway: written on trip at the pickup entered) or past (completed).';

-- ================================================================ 2. the three cases, the car, the clashes, the car going out
-- Which case the dates make: upcoming (the pickup is ahead), in_progress (the pickup has passed and the return is
-- ahead) or past (the return has passed). Null when a date is missing.
create or replace function app.manual_rental_phase(p_from timestamptz, p_to timestamptz, p_now timestamptz default now()) returns text
language sql stable set search_path = public, app as $$
  select case when p_from is null or p_to is null then null
              when p_to <= p_now then 'past'
              when p_from <= p_now then 'in_progress'
              else 'upcoming' end
$$;

-- A rental added by hand that is live: confirmed (0046), or on trip since it was added while underway (0074). The
-- renter signs it in the portal with no payment step, and CarmaCars countersigns at once.
create or replace function app.booking_added_live(b bookings) returns boolean
language sql stable set search_path = public, app as $$
  select coalesce(b.added_by_staff and (b.status = 'confirmed' or (b.status = 'on_rent' and b.added_mode = 'in_progress')), false)
$$;

-- Licence photos, the selfie and the coverage proof are sent and reviewed between the approved offer and pickup, and
-- on a rental added while already underway (until its return).
create or replace function app.booking_docs_open(b bookings) returns boolean
language sql stable set search_path = public, app as $$
  select coalesce(b.status in ('pending_payment', 'confirmed') or (b.status = 'on_rent' and b.added_mode = 'in_progress'), false)
$$;

-- Why this car cannot take a rental added by hand in this case, as a sentence that says what to do; null when it can.
-- Past: any car it happened on (0046). In progress: any active car, listed or not, open to the public or not. Upcoming:
-- a car open for bookings (app.vehicle_bookable, as the booking itself requires).
create or replace function app.manual_rental_car_problem(p_vehicle uuid, p_phase text, p_return timestamptz default null) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_name text;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return 'Choose the car'; end if;
  if p_phase = 'past' then return null; end if;
  v_name := app.vehicle_name(v.id);
  if v.retired_at is not null then
    return format('%s is retired and takes no rentals. Choose another car, or ask an Admin to restore it (Vehicles, the car)', v_name);
  end if;
  if v.status::text in ('exited', 'total_loss', 'declined') then
    return format('%s has left the fleet (%s) and takes no rentals. Choose another car', v_name, replace(v.status::text, '_', ' '));
  end if;
  if coalesce(v.is_sample, false) then
    return format('%s is a sample car for the website and takes no rentals. Choose a real car', v_name);
  end if;
  if v.owner_id is null then
    return format('%s has no owner on file. An Admin sets it (Vehicles, the car) before a rental is added', v_name);
  end if;
  if v.supply_type = 'partner' and not exists (select 1 from partners pr where pr.id = v.partner_id and pr.status <> 'ended') then
    return format('%s belongs to a partner whose agreement has ended. Choose another car', v_name);
  end if;
  if v.exit_date is not null and p_return is not null and app.local_date(p_return) > v.exit_date then
    return format('%s leaves the fleet on %s. Set the return on or before that day, or choose another car', v_name, app.fmt_day(v.exit_date));
  end if;
  if p_phase = 'in_progress' then return null; end if;
  if not coalesce(app.vehicle_bookable(v.id), false) then
    return format('%s is not open for new bookings (%s). Choose another car, or ask an Admin to open it for bookings (Vehicles, the car). If the car is already out with this renter, enter the pickup as when it left: a rental already underway can be added on this car',
      v_name, case when not v.bookings_enabled then 'bookings are turned off for this car'
                   when v.management_mode = 'turo_only' then 'it is rented on Turo only'
                   when v.management_mode = 'self_managed' and v.in_arrears then 'its owner is behind on payments'
                   else 'it is ' || replace(v.status::text, '_', ' ') end);
  end if;
  return null;
end $$;

-- What is in the way of a rental already underway on this car: before now, the rentals that really happened (on trip,
-- returned, closed, or confirmed and holding the calendar), as they were checked in and with no turnaround; from now
-- on, the trips to come with their turnaround and the calendar blocks (the cleaning time of a trip already checked in
-- is history: the car is out). Same shape as the quote's list (0046).
create or replace function app.manual_rental_live_clashes(p_vehicle uuid, p_from timestamptz, p_to timestamptz, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public, app as $$
  with t as (select make_interval(mins => coalesce(app.turnaround_minutes(p_vehicle), 0)) as buf)
  select coalesce(jsonb_agg(x order by x ->> 'starts_at'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'booking', 'booking_number', b.booking_number, 'status', b.status, 'starts_at', b.pickup_at,
                              'ends_at', coalesce(b.checked_in_at, b.return_at),
                              'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                              'overlaps', b.pickup_at < p_to
                                          and coalesce(b.checked_in_at, case when b.status = 'on_rent' then 'infinity'::timestamptz else b.return_at end) > p_from) as x
      from bookings b cross join t
     where b.vehicle_id = p_vehicle and not app.booking_is_placeholder(b.id)
       and (b.status in ('on_rent', 'returned', 'closed') or (b.status = 'confirmed' and b.blocks_calendar))
       and b.pickup_at - case when b.pickup_at > p_now then t.buf else interval '0' end < p_to
       and coalesce(b.checked_in_at, case when b.status = 'on_rent' then 'infinity'::timestamptz else b.return_at end) > p_from
    union all
    select jsonb_build_object('kind', 'block', 'reason', k.reason, 'starts_at', k.starts_at, 'ends_at', k.ends_at, 'overlaps', true)
      from vehicle_calendar_blocks k
     where k.vehicle_id = p_vehicle and k.removed_at is null and k.source is distinct from 'turnaround'
       and k.starts_at < p_to and coalesce(k.ends_at, 'infinity'::timestamptz) > greatest(p_from, p_now)) q
$$;

-- A rental added while already underway is out now, as after a handover: the car's status (by the moves the status
-- rules allow), the owner's tracker controls of a managed car, and a task for each thing a handover checks that is
-- still missing. None of them stops the rental: the car is already out.
create or replace function app.manual_rental_went_out(p_booking uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  v_car text;
begin
  select * into b from bookings where id = p_booking;
  select * into v from vehicles where id = b.vehicle_id for no key update;
  v_car := app.vehicle_name(v.id);
  if v.status <> 'on_rent' then
    if v.status = 'cleaning' and exists (select 1 from status_transitions t where t.entity = 'vehicle' and t.from_status = 'cleaning' and t.to_status = 'available') then
      update vehicles set status = 'available' where id = v.id;
      v.status := 'available';
    end if;
    if exists (select 1 from status_transitions t where t.entity = 'vehicle' and t.from_status = v.status::text and t.to_status = 'on_rent') then
      update vehicles set status = 'on_rent' where id = v.id;
    else
      perform app.raise_task(p_type => 'live_rental_car_status', p_queue => 'fleet', p_priority => 'high',
        p_title => format('%s is out on rental %s: set its status to On rent', v_car, b.booking_number),
        p_detail => format('The car was %s when the rental already underway was added. Change its status to On rent (Vehicles, the car, Change status) so the return and the cleaning follow.',
                           replace(v.status::text, '_', ' ')),
        p_booking => b.id, p_vehicle => v.id, p_created_by => p_by, p_dedupe => 'live_rental_car_status:' || b.id);
    end if;
  end if;
  if b.booking_type <> 'owner' and b.management_mode = 'managed' then
    insert into tracker_access_blocks (vehicle_id, booking_id, reason, starts_at)
    values (v.id, b.id, 'managed_rental', coalesce(b.handed_over_at, b.pickup_at))
    on conflict do nothing;
  end if;

  if exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null) then
    perform app.raise_task(p_type => 'live_rental_identity', p_queue => 'cs', p_priority => 'high',
      p_title => format('Verify the drivers of %s: the rental is already underway', b.booking_number),
      p_detail => 'The car left before the drivers'' licences were checked. Ask the renter to upload the licence photos and a selfie from their booking, or have an Admin verify the licence in person.',
      p_booking => b.id, p_vehicle => v.id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'live_rental_identity:' || b.id);
  end if;
  if b.booking_type <> 'owner' and (b.coverage_confirmed_at is null
       or not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'confirmed')) then
    perform app.raise_task(p_type => 'live_rental_coverage', p_queue => 'cs', p_priority => 'high',
      p_title => format('Coverage proof missing for an active rental: %s', b.booking_number),
      p_detail => format('The renter chose %s. Get the proof from the renter (they can upload it from their booking) and review it, or sell the Protection Plan.',
                         coalesce(app.coverage_option_label(b.coverage_option), 'a coverage option')),
      p_booking => b.id, p_vehicle => v.id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'live_rental_coverage:' || b.id);
  end if;
  if b.booking_type <> 'owner' and b.deposit_cents > 0 and b.deposit_waived_at is null
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')) then
    perform app.raise_task(p_type => 'live_rental_deposit', p_queue => 'finance',
      p_title => format('Deposit not taken for an active rental: %s (%s)', b.booking_number, app.fmt_money(b.deposit_cents)),
      p_detail => 'Take the deposit on the renter''s card, or an Admin waives it with a reason.',
      p_booking => b.id, p_vehicle => v.id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'live_rental_deposit:' || b.id);
  end if;
  if not exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup') then
    perform app.raise_task(p_type => 'live_rental_condition', p_queue => 'fleet',
      p_title => format('No pickup condition report for an active rental: %s', b.booking_number),
      p_detail => 'Ask the renter for photos of the car as it is now (all sides, the dashboard with the odometer and fuel), and check it closely at the return.',
      p_booking => b.id, p_vehicle => v.id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'live_rental_condition:' || b.id);
  end if;
  if b.booking_type <> 'owner' and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed') then
    perform app.raise_task(p_type => 'live_rental_agreement', p_queue => 'cs', p_priority => 'high',
      p_title => format('Rental agreement not signed for an active rental: %s', b.booking_number),
      p_detail => case when b.do_not_email then 'The renter was not emailed. Ask them to sign in their portal (Bookings, the booking, Sign the agreement), or have an Admin record a paper signature.'
                       else 'The renter has the email to sign in their portal. Follow up, or have an Admin record a paper signature.' end,
      p_booking => b.id, p_vehicle => v.id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'live_rental_agreement:' || b.id);
  end if;
  if not app.vehicle_on_policy(v.id) then
    perform app.raise_task(p_type => 'live_rental_insurance', p_queue => 'admin', p_priority => 'urgent',
      p_title => format('Insurance not confirmed for an active rental: %s on %s', b.booking_number, v_car),
      p_detail => 'This car is not on the fleet insurance policy yet. Confirm the insurer''s written confirmation in the car''s onboarding now, or bring the car back.',
      p_booking => b.id, p_vehicle => v.id, p_created_by => p_by, p_dedupe => 'live_rental_insurance:' || b.id,
      p_escalation_reason => 'a car out on rental without confirmed insurance');
  end if;
end $$;

-- CarmaCars' countersignature closes the "agreement not signed" task of a rental in progress.
alter function app.manual_agreement_complete(uuid) rename to manual_agreement_complete_pre0074;
create or replace function app.manual_agreement_complete(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid := app.manual_agreement_complete_pre0074(p_booking);
begin
  if v is not null then perform app.resolve_tasks(array['live_rental_agreement'], p_booking, null, 'The renter signed'); end if;
  return v;
end $$;

-- ================================================================ 3. the rental: 0058's, with the three cases
-- The same function and checks as 0058, with the case from the dates (app.manual_rental_phase), the rental in progress
-- written as on trip, the car checks per case (app.manual_rental_car_problem) and every message saying what to do.
create or replace function app.manual_rental_create_0058(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  s program_settings := app.settings();
  v vehicles;
  rc rate_cards;
  u users;
  rn renters;
  dr drivers;
  b bookings;
  pm payment_methods;
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  pay jsonb := coalesce(p -> 'payment', '{}'::jsonb);
  v_mode text := coalesce(nullif(p #>> '{payment,mode}', ''), 'unpaid');
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  -- 0074: upcoming, in progress or past, from the dates (the outer wrapper sets it; derived here when called alone)
  v_phase text := coalesce(nullif(p ->> 'phase', ''), app.manual_rental_phase((p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz));
  v_past boolean := v_phase = 'past';
  v_live boolean := v_phase = 'in_progress';
  v_problem text;
  v_type text := coalesce(nullif(p ->> 'booking_type', ''), 'standard');
  v_source text := coalesce(nullif(p ->> 'source', ''), 'phone');
  v_clash_reason text := nullif(btrim(coalesce(p ->> 'clash_reason', '')), '');
  v_price_reason text := nullif(btrim(coalesce(p ->> 'price_reason', '')), '');
  v_override bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_deposit bigint := nullif(p ->> 'deposit_cents', '')::bigint;
  v_cover integer := coalesce(nullif(p ->> 'coverage_option', '')::integer, 1);
  v_seats integer := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);
  v_adds jsonb := case when jsonb_typeof(p -> 'additional_drivers') = 'array' then p -> 'additional_drivers' else '[]'::jsonb end;
  v_free boolean;
  v_overlap boolean;
  v_days integer;
  v_rate record;
  v_rental bigint;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_name text := nullif(btrim(coalesce(r ->> 'full_name', '')), '');
  v_dob date := nullif(r ->> 'date_of_birth', '')::date;
  v_age integer;
  a jsonb;
  v_a_age integer;
  v_driver uuid;
  v_status booking_status;
  v_pay uuid;
  v_amount bigint;
  v_method text;
  v_ref text := nullif(btrim(coalesce(pay ->> 'reference', '')), '');
  v_on date := coalesce(nullif(pay ->> 'received_on', '')::date, app.today());
  v_limit bigint;
  v_version integer;
  v_charge jsonb;
  v_promo_problem text;
begin
  if v_role is null then raise exception 'Only CarmaCars staff can add a rental. Sign in with your staff account' using errcode = '42501'; end if;
  -- what an assistant or field staff may not do (0058: they may type a price, with its reason)
  if v_role in ('va', 'field') then
    if v_past then raise exception 'Only an Admin can record a rental that has already ended. Check the return date and time, or ask an Admin to add it' using errcode = '42501'; end if;
    if v_deposit is not null then raise exception 'The deposit comes from the rate sheet. Leave it empty, or ask an Admin to change it' using errcode = '42501'; end if;
    if v_clash_reason is not null then raise exception 'The car is not free for these dates. Choose other dates or another car, or ask an Admin to add it over the clash' using errcode = '42501'; end if;
    -- field staff take no payment themselves (Field Staff Agreement 6.1): a payment link or the saved card only
    if not v_mode = any (case when v_role = 'field' then array['link', 'card'] else s.manual_rental_va_payment_modes end) then
      raise exception 'You cannot take payment that way (only an Admin can). Choose one of the ways shown under Payment' using errcode = '42501';
    end if;
    if nullif(p ->> 'promo_code', '') is not null and not s.manual_rental_va_promo then
      raise exception 'Only an Admin can apply a promo code to a rental added by hand. Clear the promo code, or ask an Admin' using errcode = '42501';
    end if;
  end if;
  if v_mode not in ('other_way', 'link', 'card', 'unpaid') then raise exception 'Choose how the rental is paid' using errcode = '22023'; end if;
  if v_past and v_mode in ('link', 'card') then
    raise exception 'This rental has already ended, so it cannot be paid by payment link or saved card. Choose Paid another way or Unpaid' using errcode = '22023';
  end if;
  if v_mode = 'link' and coalesce((p ->> 'do_not_email')::boolean, false) then
    raise exception 'A payment link is sent by email: untick "Do not email the renter", or record the payment another way' using errcode = '22023';
  end if;
  if v_source not in ('phone', 'walk_in', 'turo', 'partner', 'insurer', 'email', 'other') then raise exception 'Choose where the rental came from' using errcode = '22023'; end if;
  if v_source = 'other' and nullif(btrim(coalesce(p ->> 'source_note', '')), '') is null then raise exception 'Say where the rental came from' using errcode = '22023'; end if;
  if v_type not in ('standard', 'non_refundable') then raise exception 'Choose Standard or Non-refundable for the booking' using errcode = '22023'; end if;
  if v_cover not in (1, 2, 3) then raise exception 'Choose how damage to the car is covered (option 1, 2 or 3)' using errcode = '22023'; end if;
  if v_override is not null and v_override < 0 then raise exception 'The rental charge cannot be below zero' using errcode = '22023'; end if;
  if v_override is not null and v_price_reason is null then raise exception 'A price typed by hand needs its reason: type it under Reason for the price' using errcode = '22023'; end if;

  -- the dates
  if v_from is null or v_to is null then raise exception 'Enter the pickup and the return, each with a date and a time' using errcode = '22023'; end if;
  if v_to <= v_from then raise exception 'The return must be after the pickup: check both dates and times' using errcode = '22023'; end if;
  v_days := public.calc_billable_days(v_from, v_to);
  if v_days > s.max_rental_days then
    raise exception 'A rental is 1 to % days; these dates make %. Shorten it, and add the rest later as a new booking.', s.max_rental_days, v_days using errcode = '22023';
  end if;
  -- 0074: upcoming (pickup ahead), in progress (picked up, return ahead) or past (returned): the dates decide
  if v_past then
    if v_to > now() then raise exception 'For a past rental, the return must already have happened. Check the return date and time' using errcode = '22023'; end if;
    if v_from < now() - make_interval(days => s.manual_rental_past_max_days) then
      raise exception 'A past rental can go back at most % days, and this pickup is earlier. Check the pickup date', s.manual_rental_past_max_days using errcode = '22023';
    end if;
  end if;

  -- the car
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for no key update;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  v_problem := app.manual_rental_car_problem(v.id, v_phase, v_to);
  if v_problem is not null then raise exception '%', v_problem using errcode = '23514'; end if;
  select * into rc from rate_cards x where x.vehicle_id = v.id and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is null and v_override is null then raise exception 'This car has no rates yet: type the rental charge for the whole rental and the reason' using errcode = '23514'; end if;

  -- free for the dates, the turnaround included (a past rental: no other real rental at the same time)
  if v_past then
    v_free := not exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('on_rent', 'returned', 'closed', 'confirmed')
                             and not app.booking_is_placeholder(x.id) and x.pickup_at < v_to and coalesce(x.checked_in_at, x.return_at) > v_from);
    v_overlap := false;
  elsif v_live then
    -- in progress: what really happened before now (rentals, no turnaround) and what holds the car from now on
    v_free := jsonb_array_length(app.manual_rental_live_clashes(v.id, v_from, v_to)) = 0;
    v_overlap := exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
                            and x.rental_window && tstzrange(v_from, v_to, '[)'));
  else
    v_free := app.vehicle_is_available(v.id, v_from, v_to);
    v_overlap := exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
                            and x.rental_window && tstzrange(v_from, v_to, '[)'));
  end if;
  if not v_free and v_clash_reason is null then
    raise exception 'The car is not free for these dates: another rental, a calendar block or the cleaning time between trips is in the way. Press Check the calendar and the price to see what, then choose other dates or another car%',
      case when v_role = 'admin' then ', or give the reason to add it over the clash' else '' end using errcode = '23P01';
  end if;

  -- the renter: found, or made from what staff typed
  if nullif(p ->> 'renter_id', '') is not null then
    select * into rn from renters where id = (p ->> 'renter_id')::uuid;
    if rn.id is null then raise exception 'That renter is no longer on file. Search again, or add them as a new renter' using errcode = 'P0002'; end if;
    select * into u from users where id = rn.user_id;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  else
    if v_name is null or v_dob is null then raise exception 'Enter the renter''s full legal name and date of birth' using errcode = '22023'; end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the renter''s email address (like name@example.com)' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(r ->> 'mobile', '')), '') is null then raise exception 'Enter the renter''s phone number' using errcode = '22023'; end if;
    select * into u from users where lower(email) = v_email;
    if u.id is null then
      insert into users (email, phone, full_name) values (v_email, btrim(r ->> 'mobile'), v_name) returning * into u;
    end if;
    insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
    select * into rn from renters where user_id = u.id;
    if rn.id is null then
      insert into renters (user_id, legal_name, date_of_birth, mobile, email, address_line1, city, province, postal_code)
      values (u.id, v_name, v_dob, btrim(r ->> 'mobile'), v_email, nullif(btrim(r ->> 'address_line1'), ''), nullif(btrim(r ->> 'city'), ''),
              nullif(btrim(r ->> 'province'), ''), upper(nullif(btrim(r ->> 'postal_code'), '')))
      returning * into rn;
    end if;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  end if;
  if rn.is_blocked then raise exception '% is blocked from renting. An Admin must lift the block (Renters, the renter) before you add the rental', rn.legal_name using errcode = '23514'; end if;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, mobile, email)
    values (rn.id, true, rn.user_id, rn.legal_name, coalesce(rn.date_of_birth, v_dob), nullif(btrim(r ->> 'licence_number'), ''),
            upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), 'G')), coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), 'ON'),
            nullif(r ->> 'licence_expiry', '')::date, rn.mobile, rn.email)
    returning * into dr;
  elsif nullif(btrim(r ->> 'licence_number'), '') is not null and dr.licence_number is null then
    update drivers set licence_number = btrim(r ->> 'licence_number'), licence_class = upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), licence_class, 'G')),
           licence_issuer = coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), licence_issuer, 'ON'),
           licence_expiry = coalesce(nullif(r ->> 'licence_expiry', '')::date, licence_expiry)
     where id = dr.id returning * into dr;
  end if;
  v_age := app.age_on(coalesce(dr.date_of_birth, rn.date_of_birth), app.local_date(v_from));
  if v_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup: check the renter''s date of birth', s.min_renter_age using errcode = '23514'; end if;
  if app.age_band(v_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over: choose another car for this renter', s.standard_min_age using errcode = '23514'; end if;
  if jsonb_array_length(v_adds) > s.max_additional_drivers then
    raise exception 'A booking may name up to % additional drivers', s.max_additional_drivers using errcode = '22023';
  end if;

  -- the booking, with the rate sheet (or the Admin's price) and the source
  if v_clash_reason is not null and v_role = 'admin' and not v_past then
    perform set_config('app.manual_rental_override', 'on', true);
  end if;
  select * into v_rate from public.calc_rental_charge(v_from, v_days, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0),
                                                       coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));
  v_rental := coalesce(v_override, v_rate.rental_charge_cents);
  v_number := 'CC-' || nextval('booking_number_seq');
  -- in progress: out on trip from the pickup entered, handed over by the staff member who adds it (0074)
  v_status := case when v_past then 'closed' when v_live then 'on_rent' when v_mode = 'link' then 'requested' else 'confirmed' end;
  insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, source, booked_at, requested_at, request_note,
      pickup_at, return_at, original_return_at, pickup_method, return_method, pickup_place, return_place, billable_days,
      rate_card_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
      rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, deductible_cents, hst_bps, created_by, coverage_option,
      blocks_calendar, blocks_calendar_reason, blocks_calendar_changed_by, blocks_calendar_changed_at,
      confirmed_at, handed_over_at, checked_in_at,
      added_by_staff, added_mode, payment_mode, do_not_email, clash_override_reason, notes, request_details)
  values (v_id, v_number, v_type::booking_type, v_status, v.id, rn.id,
      case when v_source in ('walk_in', 'turo', 'partner', 'insurer', 'phone', 'email', 'other') then v_source else 'staff' end,
      now(), now(), nullif(btrim(coalesce(p ->> 'note', '')), ''),
      v_from, v_to, v_to, coalesce(nullif(p ->> 'pickup_method', ''), 'collected'), coalesce(nullif(p ->> 'return_method', ''), 'returned'),
      nullif(btrim(coalesce(p ->> 'pickup_place', '')), ''), nullif(btrim(coalesce(p ->> 'return_place', '')), ''), v_days,
      rc.id, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0), coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0),
      v_rate.rate_applied, v_rate.daily_days, v_rate.weekend_days,
      v_rental, case when v_type = 'non_refundable' then public.calc_bps(v_rental, s.non_refundable_discount_bps) else 0 end,
      coalesce(rc.km_allowance_per_day, 0), coalesce(rc.km_allowance_per_day, 0) * v_days, coalesce(rc.overage_cents_per_km, 0),
      coalesce(v_deposit, rc.deposit_cents, 0), s.deductible_cents, s.hst_bps, p_by, v_cover,
      not (v_overlap and v_clash_reason is not null),
      case when v_overlap and v_clash_reason is not null then 'Added over a clash: ' || v_clash_reason end,
      case when v_overlap and v_clash_reason is not null then p_by end,
      case when v_overlap and v_clash_reason is not null then now() end,
      case when v_status in ('confirmed', 'closed', 'on_rent') then now() end,
      case when v_past or v_live then v_from end, case when v_past then v_to end,
      true, case when v_past then 'past' when v_live then 'in_progress' else 'future' end, v_mode, coalesce((p ->> 'do_not_email')::boolean, false), v_clash_reason,
      concat_ws(E'\n', case when v_price_reason is not null then 'Price set by hand: ' || v_price_reason end,
                       case when nullif(btrim(coalesce(p ->> 'source_note', '')), '') is not null then 'Source: ' || btrim(p ->> 'source_note') end),
      jsonb_build_object('added_by_staff', true, 'source', v_source, 'source_note', nullif(btrim(coalesce(p ->> 'source_note', '')), ''),
                         'extras', jsonb_build_object('winter_tire', coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false), 'baby_seats', v_seats),
                         'coverage_option', v_cover, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason, 'past', v_past, 'phase', v_phase))
  returning * into b;

  -- drivers, as the agreement will print them
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
  values (b.id, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer, dr.licence_expiry, v_age, app.age_band(v_age));
  for a in select value from jsonb_array_elements(v_adds) loop
    if nullif(btrim(coalesce(a ->> 'full_name', '')), '') is null or nullif(a ->> 'date_of_birth', '') is null then
      raise exception 'Each additional driver needs a full name and a date of birth' using errcode = '22023';
    end if;
    v_a_age := app.age_on((a ->> 'date_of_birth')::date, app.local_date(v_from));
    if v_a_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
    if app.age_band(v_a_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', s.standard_min_age using errcode = '23514'; end if;
    select d.id into v_driver from drivers d where d.renter_id = rn.id and not d.is_account_holder and d.date_of_birth = (a ->> 'date_of_birth')::date
       and lower(regexp_replace(d.full_name, '\s+', ' ', 'g')) = lower(regexp_replace(btrim(a ->> 'full_name'), '\s+', ' ', 'g')) limit 1;
    if v_driver is null then
      insert into drivers (renter_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, email)
      values (rn.id, btrim(a ->> 'full_name'), (a ->> 'date_of_birth')::date, nullif(btrim(a ->> 'licence_number'), ''), 'G', 'ON',
              lower(nullif(btrim(a ->> 'email'), '')))
      returning id into v_driver;
    end if;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
    select b.id, d.id, 'additional', d.full_name, d.date_of_birth, d.licence_number, d.licence_class, d.licence_issuer, d.licence_expiry, v_a_age, app.age_band(v_a_age)
      from drivers d where d.id = v_driver;
    v_driver := null;
  end loop;

  -- the fee terms of today, the places, the price lines
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select b.id, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v.id, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;
  perform app.apply_booking_places(b.id, p);
  if nullif(btrim(coalesce(p ->> 'promo_code', '')), '') is not null then
    v_promo_problem := app.promo_code_problem(p ->> 'promo_code', rn.id, b.id);
    if v_promo_problem is not null then raise exception 'Promo code: %', v_promo_problem using errcode = '23514'; end if;
    perform app.apply_promo_code(b.id, p ->> 'promo_code', p_by);
  end if;
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  perform app.log_booking_event(b.id, 'added_by_staff', null, b.status::text, null, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by, 'staff',
    jsonb_build_object('source', v_source, 'payment_mode', v_mode, 'past', v_past, 'phase', v_phase, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                       'total_cents', b.total_due_at_booking_cents));

  -- payment
  if v_mode = 'other_way' then
    v_method := coalesce(nullif(pay ->> 'method', ''), 'e_transfer');
    v_amount := coalesce(nullif(pay ->> 'amount_cents', '')::bigint, b.renter_due_at_booking_cents);
    if v_method not in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other') then
      raise exception 'Choose how it was paid: e-Transfer, cheque, cash, bank transfer or another way' using errcode = '22023';
    end if;
    if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
      raise exception 'Enter the reference of the payment (the e-Transfer, cheque or transfer number)' using errcode = '22023';
    end if;
    if v_method = 'other' and nullif(btrim(coalesce(pay ->> 'note', '')), '') is null then raise exception 'Say how it was paid' using errcode = '22023'; end if;
    if v_on > app.today() then raise exception 'The date received cannot be in the future: enter the day the money came in' using errcode = '22023'; end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    if v_role in ('va', 'field') then
      v_limit := coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0);
      if v_amount > v_limit then
        raise exception '% is above your single limit of %. Record it as Unpaid and ask an Admin to record the payment, or ask an Admin to add the rental', app.fmt_money(v_amount), app.fmt_money(v_limit) using errcode = '42501';
      end if;
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
    values (b.id, rn.id, 'booking_total', 'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
    values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on,
            'note', nullif(btrim(coalesce(pay ->> 'note', '')), ''), 'recorded_by', p_by, 'manual_rental', true)));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by)
    values (v_pay, 'booking', b.id, rn.id, v_method, v_amount, v_on, v_ref, nullif(btrim(coalesce(pay ->> 'note', '')), ''), p_by);
    -- the booking's charges are paid by it (in full: every line; a part payment leaves them to collect)
    if v_amount >= b.renter_due_at_booking_cents then
      update booking_line_items set payment_id = v_pay where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
    end if;
  elsif v_mode = 'card' then
    select x.* into pm from payment_methods x join payment_method_secrets sc on sc.payment_method_id = x.id
     where x.renter_id = rn.id and x.status = 'active' and sc.processor_method_id is not null order by x.created_at desc limit 1;
    if pm.id is null then raise exception '% has no saved card. Choose Send a payment link instead', rn.legal_name using errcode = '23514'; end if;
    update bookings set card_on_file_id = pm.id where id = b.id;
    if b.renter_due_at_booking_cents > 0 then
      v_charge := (select jsonb_build_object('customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id, 'amount_cents', b.renter_due_at_booking_cents,
                                             'brand', pm.card_brand, 'last4', pm.card_last4)
                     from payment_method_secrets sc where sc.payment_method_id = pm.id);
    end if;
  elsif v_mode = 'link' and not v_live then
    -- the standard flow from here: the offer (the email with the link), the renter signs and pays online
    v_version := app.send_offer(b.id, p_by, nullif(btrim(coalesce(p ->> 'message', '')), ''),
                                now() + make_interval(hours => least(s.offer_expiry_hours, 72)));
    perform app.approve_offer(b.id, v_version, p_by);
  end if;

  -- a past rental: its split, so the owner's or partner's statement and the company statement include it
  if v_past then
    perform app.compute_booking_split(b.id);
    if b.booking_type <> 'owner' then
      update renters set first_completed_booking_id = coalesce(first_completed_booking_id, b.id) where id = rn.id;
    end if;
  end if;
  -- in progress (0074): the car is out now, as after a handover; what a handover checks and is missing becomes a task
  if v_live then
    perform app.manual_rental_went_out(b.id, p_by);
  end if;
  -- a confirmed rental: requests and offers that wanted the same dates go back to customer service with a task
  if b.status in ('confirmed', 'on_rent') and b.blocks_calendar then
    perform app.raise_task(p_type => 'reoffer_booking', p_title => format('Offer another car or dates for %s: %s was booked by staff', x.booking_number, app.vehicle_name(v.id)),
        p_booking => x.id, p_vehicle => v.id, p_queue => 'cs', p_created_by => p_by, p_dedupe => 'manual_rental_clash:' || x.id)
      from bookings x where x.vehicle_id = v.id and x.id <> b.id and x.status in ('requested', 'offered', 'pending_payment')
       and x.pickup_at < b.return_at and x.return_at > b.pickup_at;
  end if;

  -- the renter's email and the owner's or partner's notice
  if b.status in ('confirmed', 'on_rent') and not b.do_not_email then
    perform app.ntf_emit('renter_rental_added', 'booking', b.id, 'added', jsonb_build_object('booking_id', b.id, 'renter_id', rn.id));
  end if;
  if b.status in ('confirmed', 'on_rent') and v.supply_type <> 'company' and b.booking_type <> 'owner' then
    perform app.ntf_emit('owner_new_booking', 'booking', b.id, 'confirmed', jsonb_build_object('booking_id', b.id, 'owner_id', b.owner_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_create', 'bookings', b.id::text,
          jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle_id', v.id, 'supply_type', v.supply_type, 'renter_id', rn.id,
                             'source', v_source, 'payment_mode', v_mode, 'past', v_past, 'phase', v_phase, 'total_cents', b.total_due_at_booking_cents,
                             'rental_charge_cents', b.rental_charge_cents, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                             'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'do_not_email', b.do_not_email, 'role', v_role));
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'phase', v_phase, 'total_cents', b.total_due_at_booking_cents,
                            'due_cents', b.renter_due_at_booking_cents, 'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'charge', v_charge,
                            'renter_id', rn.id, 'renter_has_account', exists (select 1 from users au where au.id = rn.user_id and au.email_verified_at is not null));
end $$;

-- The quote: 0058's, with the case, the clashes of a rental in progress and no link or card for a past one.
create or replace function app.manual_rental_quote_0058(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  v vehicles;
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  v_buffer interval := make_interval(mins => coalesce(app.turnaround_minutes(nullif(p ->> 'vehicle_id', '')::uuid), 0));
  v_quote jsonb;
  v_clash jsonb;
  s program_settings := app.settings();
  v_phase text := coalesce(nullif(p ->> 'phase', ''), app.manual_rental_phase(v_from, v_to));
  v_past boolean := v_phase = 'past';
begin
  if v_role is null then raise exception 'Only CarmaCars staff can add a rental. Sign in with your staff account' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_from is null or v_to is null then raise exception 'Enter the pickup and the return, each with a date and a time' using errcode = '22023'; end if;
  if v_to <= v_from then raise exception 'The return must be after the pickup: check both dates and times' using errcode = '22023'; end if;
  v_quote := app.price_quote(v.id, v_from, v_to, jsonb_build_object('booking_type', coalesce(p ->> 'booking_type', 'standard'),
               'pickup_method', coalesce(p ->> 'pickup_method', 'collected'), 'return_method', coalesce(p ->> 'return_method', 'returned'),
               'drivers', coalesce(p -> 'drivers', '[]'::jsonb), 'extras', coalesce(p -> 'extras', '{}'::jsonb),
               'coverage_option', coalesce(nullif(p ->> 'coverage_option', '')::integer, 1),
               'promo_code', case when v_role = 'admin' or s.manual_rental_va_promo then nullif(p ->> 'promo_code', '') end));
  -- what is in the way: blocking bookings and calendar blocks, with the turnaround either side; real rentals for a past one;
  -- for one in progress, what really happened before now and what holds the car from now on (0074)
  if v_phase = 'in_progress' then
    v_clash := app.manual_rental_live_clashes(v.id, v_from, v_to);
  else
  select coalesce(jsonb_agg(x order by x ->> 'starts_at'), '[]'::jsonb) into v_clash from (
    select jsonb_build_object('kind', 'booking', 'booking_number', b.booking_number, 'status', b.status, 'starts_at', b.pickup_at, 'ends_at', b.return_at,
                              'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                              'overlaps', b.pickup_at < v_to and b.return_at > v_from) as x
      from bookings b
     where b.vehicle_id = v.id and not app.booking_is_placeholder(b.id)
       and ((not v_past and b.status in ('confirmed', 'on_rent') and b.blocks_calendar) or (v_past and b.status in ('confirmed', 'on_rent', 'returned', 'closed')))
       and b.pickup_at < v_to + v_buffer and coalesce(b.checked_in_at, b.return_at) > v_from - v_buffer
    union all
    select jsonb_build_object('kind', 'block', 'reason', k.reason, 'starts_at', k.starts_at, 'ends_at', k.ends_at, 'overlaps', true)
      from vehicle_calendar_blocks k
     where not v_past and k.vehicle_id = v.id and k.removed_at is null and k.starts_at < v_to and coalesce(k.ends_at, 'infinity'::timestamptz) > v_from) q;
  end if;
  return jsonb_build_object(
    'role', v_role, 'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'supply_type', v.supply_type, 'retired', v.retired_at is not null,
                                                  'bookable', app.vehicle_bookable(v.id)),
    'free', jsonb_array_length(v_clash) = 0, 'clashes', v_clash, 'turnaround_minutes', extract(epoch from v_buffer) / 60,
    'quote', v_quote,
    'payment_modes', (select coalesce(jsonb_agg(m), '[]'::jsonb) from unnest(case when v_role = 'admin' then array['other_way', 'link', 'card', 'unpaid']
                                                                         when v_role = 'field' then array['link', 'card'] else s.manual_rental_va_payment_modes end) m
                       where not v_past or m in ('other_way', 'unpaid')),
    'phase', v_phase,
    'may_override_price', true, 'rate_sheet_cents', (v_quote ->> 'rental_charge_cents')::bigint, 'billable_days', (v_quote ->> 'billable_days')::integer,
    'price_floor_daily_cents', s.custom_price_floor_daily_cents, 'price_max_discount_bps', s.custom_price_max_discount_bps,
    'choice_required', v_role <> 'admin', 'may_search_renters', v_role <> 'field', 'may_override_clash', v_role = 'admin', 'may_record_past', v_role = 'admin',
    'may_promo', v_role = 'admin' or s.manual_rental_va_promo,
    'single_limit_cents', (select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by),
    'card', case when nullif(p ->> 'renter_id', '') is not null then
              (select jsonb_build_object('id', pm.id, 'brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm
                 join payment_method_secrets sc on sc.payment_method_id = pm.id
                where pm.renter_id = (p ->> 'renter_id')::uuid and pm.status = 'active' and sc.processor_method_id is not null
                order by pm.created_at desc limit 1) end);
end $$;

-- ================================================================ 4. the doors of Add a rental: the cars, the insurance check, the case
-- The cars of Add a rental (0064's list): every active car for every role, with whether it is open for bookings, so a
-- rental already underway can be added on a car whose listing is not finished or that is closed to the public. An
-- upcoming rental still needs a car open for bookings (said when the dates are checked).
create or replace function app.manual_rental_vehicles(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'supply_type', v.supply_type,
           'bookable', app.vehicle_bookable(v.id), 'retired', v.retired_at is not null, 'status', v.status::text,
           'daily_rate_cents', rc.daily_rate_cents, 'has_rates', rc.id is not null,
           'listing_status', coalesce(l.status, 'none'), 'listing_finished', coalesce(l.status = 'published', false),
           'needs_policy_confirm', app.vehicle_needs_policy_confirm(v.id), 'needs_terms', app.vehicle_needs_terms(v.id))
           order by app.vehicle_bookable(v.id) desc, coalesce(l.status = 'published', false) desc, v.make, v.model, v.year), '[]'::jsonb)
    from vehicles v
    left join vehicle_listings l on l.vehicle_id = v.id
    left join lateral (select r.* from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) limit 1) rc on true
   where v.status not in ('declined', 'exited', 'total_loss')
     and (app.user_is_admin(p_by) or (v.retired_at is null and not coalesce(v.is_sample, false)))
$$;

-- 0064's door with the case: the fleet-policy confirmation and the Revenue Share are asked for an upcoming rental; a
-- rental already underway is never stopped by the insurance check (an Admin gets an urgent task instead, 0074).
create or replace function app.manual_rental_create_pre0066(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  rc rate_cards;
  d jsonb;
  out jsonb;
  b bookings;
  v_phase text := coalesce(nullif(p ->> 'phase', ''), app.manual_rental_phase(nullif(p ->> 'pickup_at', '')::timestamptz, nullif(p ->> 'return_at', '')::timestamptz));
  v_past boolean := v_phase = 'past';
  v_policy boolean;
  v_unlisted boolean;
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then return app.manual_rental_create_pre0064(p_by, p - 'fleet_policy_confirmed'); end if;
  select * into rc from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  v_policy := coalesce(v_phase, 'upcoming') = 'upcoming' and app.vehicle_needs_policy_confirm(v.id);
  v_unlisted := not app.vehicle_listing_finished(v.id);
  if not v_past and app.vehicle_needs_terms(v.id) then
    raise exception 'This owner''s car has no Revenue Share yet: set its terms (Owners, the owner, the car) before adding a rental' using errcode = '23514';
  end if;
  if v_policy then
    if not app.user_is_admin(p_by) then
      raise exception 'This car is not on the fleet insurance policy yet: only an Admin can add its rentals, after checking it is insured' using errcode = '42501';
    end if;
    if not coalesce((p ->> 'fleet_policy_confirmed')::boolean, false) then
      raise exception 'This car is not on the fleet insurance policy yet. Tick "I checked that this car is insured for this rental" to add it' using errcode = '23514';
    end if;
  end if;
  if rc.id is null and nullif(p ->> 'rental_charge_cents', '') is null then
    raise exception 'This car has no rates yet: type the rental charge for the whole rental and the reason, then press Check again' using errcode = '22023';
  end if;
  if rc.id is null then
    -- the kilometres and the deposit of the defaults, set as the booking is written (0046 left them at 0 when the car
    -- had no rates; a confirmed booking's terms cannot change afterwards)
    d := app.rate_card_defaults(v.id);
    perform set_config('app.rental_defaults', jsonb_build_object('vehicle_id', v.id, 'km_per_day', d -> 'km_per_day', 'overage_cents', d -> 'overage_cents',
      'deposit_cents', case when nullif(p ->> 'deposit_cents', '') is null then d -> 'deposit_cents' end)::text, true);
  end if;
  out := app.manual_rental_create_pre0064(p_by, p - 'fleet_policy_confirmed');
  perform set_config('app.rental_defaults', '', true);
  select * into b from bookings where id = (out ->> 'booking_id')::uuid;
  if b.id is not null and (v_unlisted or v_policy) then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'manual_rental_unlisted_car', 'bookings', b.id::text,
            jsonb_build_object('booking_number', b.booking_number, 'vehicle_id', v.id, 'listing_finished', not v_unlisted, 'had_rates', rc.id is not null,
                               'vehicle_status', v.status, 'fleet_policy_confirmed', v_policy));
  end if;
  return out || jsonb_build_object('listing_finished', not v_unlisted, 'fleet_policy_confirmed', v_policy, 'had_rates', rc.id is not null);
end $$;

-- Add a rental (0074): the case from the dates, passed to every layer below as "phase" (and "past" for the layers that
-- read it). An older screen's "past": true with a return still ahead is refused with the reason.
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0074;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_phase text;
  v_out jsonb;
begin
  begin
    v_from := nullif(p ->> 'pickup_at', '')::timestamptz;
    v_to := nullif(p ->> 'return_at', '')::timestamptz;
  exception when others then
    raise exception 'Enter the pickup and the return, each with a date and a time' using errcode = '22023';
  end;
  v_phase := app.manual_rental_phase(v_from, v_to);
  if lower(coalesce(p ->> 'past', '')) = 'true' and v_phase is distinct from 'past' and v_to > v_from then
    raise exception 'For a past rental, the return must already have happened. Check the return date and time' using errcode = '22023';
  end if;
  if v_phase = 'past' and app.manual_rental_role(p_by) in ('va', 'field') then
    raise exception 'Only an Admin can record a rental that has already ended. Check the return date and time, or ask an Admin to add it' using errcode = '42501';
  end if;
  v_out := app.manual_rental_create_pre0074(p_by, (p - 'past' - 'phase') || jsonb_build_object('past', coalesce(v_phase = 'past', false), 'phase', v_phase));
  return v_out || jsonb_build_object('phase', v_phase, 'payment_mode', (select x.payment_mode from bookings x where x.id = (v_out ->> 'booking_id')::uuid));
end $$;

-- The check before adding (0074): the case and what it means, the car refused with the reason, and for a rental
-- already underway no insurance confirmation to tick (an urgent task for an Admin instead).
alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre0074;
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_phase text;
  v_vehicle uuid;
  v_problem text;
  out jsonb;
  v_notes jsonb;
begin
  begin
    v_from := nullif(p ->> 'pickup_at', '')::timestamptz;
    v_to := nullif(p ->> 'return_at', '')::timestamptz;
    v_vehicle := nullif(p ->> 'vehicle_id', '')::uuid;
  exception when others then
    raise exception 'Enter the pickup and the return, each with a date and a time' using errcode = '22023';
  end;
  v_phase := app.manual_rental_phase(v_from, v_to);
  if v_phase = 'past' and app.manual_rental_role(p_by) in ('va', 'field') then
    raise exception 'Only an Admin can record a rental that has already ended. Check the return date and time, or ask an Admin to add it' using errcode = '42501';
  end if;
  if v_vehicle is not null and v_phase is not null and v_to > v_from and app.manual_rental_role(p_by) is not null then
    v_problem := app.manual_rental_car_problem(v_vehicle, v_phase, v_to);
    if v_problem is not null then raise exception '%', v_problem using errcode = '23514'; end if;
  end if;
  out := app.manual_rental_quote_pre0074(p_by, (p - 'past' - 'phase') || jsonb_build_object('past', coalesce(v_phase = 'past', false), 'phase', v_phase));
  if v_phase = 'in_progress' then
    select coalesce(jsonb_agg(n), '[]'::jsonb) into v_notes from jsonb_array_elements_text(coalesce(out -> 'notes', '[]'::jsonb)) n
     where n not like 'Before the handover%' and n not like 'This car is not on the fleet insurance policy yet%';
    if coalesce((out ->> 'needs_policy_confirm')::boolean, false) then
      v_notes := v_notes || to_jsonb('This car is not on the fleet insurance policy yet. The rental is still added, and an Admin gets an urgent task to confirm the insurance.'::text);
    end if;
    out := out || jsonb_build_object('notes', v_notes, 'needs_policy_confirm', false);
  end if;
  return out || jsonb_build_object('phase', v_phase, 'phase_note', case v_phase
    when 'upcoming' then 'This rental starts in the future: it is confirmed now and the car is handed over at pickup as usual.'
    when 'in_progress' then 'This rental is already underway: it will be recorded as on trip, picked up at the time you entered. Anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report) becomes a task.'
    when 'past' then 'This rental has already ended: it will be recorded as completed, for the history and the statements.' end);
end $$;

-- ================================================================ 5. after it is added: the agreement, the card, the documents
-- A rental in progress is signed by the renter as a confirmed rental added by hand is (0046, 0053): its agreement opens
-- on the booking, the renter signs in the portal (or an Admin records paper), CarmaCars countersigns at once, the saved
-- card is charged on "Accept and sign". The licence photos, the selfie and the coverage proof can still be sent and
-- reviewed while the car is out, and an Admin can verify a driver in person, so the tasks it raised can be closed.

create or replace function app.open_rental_agreement(p_booking uuid, p_by uuid, p_template_version text, p_document_sha256 text,
                                                     p_storage_path text, p_storage_bucket text default 'agreements')
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  rn renters;
  v_set program_settings := app.settings();
  v_sha text := lower(btrim(coalesce(p_document_sha256, '')));
  v_reissue boolean;
  v_number text;
  v_cs_name text;
  v_doc uuid;
  v_req uuid;
  v_id uuid := gen_random_uuid();
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not app.booking_added_live(b) then
    return app.open_rental_agreement_0019(p_booking, p_by, p_template_version, p_document_sha256, p_storage_path, p_storage_bucket);
  end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, opens its agreement' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_template_version, '')), '') is null or nullif(btrim(coalesce(p_storage_path, '')), '') is null or v_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'An agreement needs its text version, its file and the SHA-256 of the rendered document' using errcode = '22023';
  end if;
  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed', 'completed');
  if a.id is not null then
    if a.status in ('completed', 'signed') then return a.id; end if;
    if a.document_sha256 = v_sha and a.template_version = p_template_version then return a.id; end if;
    perform app.void_rental_agreements(p_booking, 'A new version of the agreement was issued');
  end if;
  v_reissue := exists (select 1 from rental_agreements x where x.booking_id = p_booking);
  select * into rn from renters where id = b.renter_id;
  v_number := coalesce(b.agreement_number, 'RA-' || nextval('rental_agreement_number_seq'));
  v_cs_name := coalesce((select u.full_name from users u where u.id = b.created_by), v_set.company_trade_name);
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, renter_id, booking_id)
  values ('rental_agreement', format('Rental agreement %s', v_number), p_storage_bucket, p_storage_path, 'application/pdf', v_sha,
          p_template_version, 'records_7y', p_by, b.renter_id, p_booking)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, provider_envelope, status, sent_at, created_by)
  values (v_doc, 'builtin', v_id::text, 'sent', now(), p_by) returning id into v_req;
  insert into rental_agreements (id, booking_id, offer_version, agreement_number, template_version, document_id, document_sha256,
                                 signature_request_id, countersigner_user_id, countersigner_name, opened_by)
  values (v_id, p_booking, null, v_number, p_template_version, v_doc, v_sha, v_req, b.created_by, v_cs_name, p_by);
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email, required_before_payment)
  select v_id, 'renter', d.id, d.driver_id, rn.user_id, coalesce(d.full_name, rn.legal_name), coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)), true
    from (select 1) one left join booking_drivers d on d.booking_id = p_booking and d.role = 'renter';
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email)
  select v_id, 'additional_driver', d.id, d.driver_id, dv.user_id, d.full_name, dv.email
    from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = p_booking and d.role = 'additional';
  insert into rental_agreement_signers (agreement_id, signer_role, user_id, signer_name, signer_email)
  values (v_id, 'carmacars', b.created_by, v_cs_name, v_set.company_email);
  update bookings set agreement_number = v_number, agreement_document_id = v_doc, signature_request_id = v_req where id = p_booking;
  perform app.log_booking_event(p_booking, 'agreement_opened', b.status::text, b.status::text, null, null, p_by, null,
    jsonb_build_object('agreement_id', v_id, 'agreement_number', v_number, 'template_version', p_template_version, 'document_sha256', v_sha,
                       'reissued', v_reissue, 'added_by_staff', true));
  return v_id;
end $$;

create or replace function app.record_signature(p_request uuid, p_signer uuid, p_typed_name text, p_drawn_signature text,
                                                p_ip inet, p_user_agent text, p_consent_text text,
                                                p_document_sha256 text default null, p_consents jsonb default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  g rental_agreement_signers;
  b bookings;
  v_typed text := nullif(btrim(coalesce(p_typed_name, '')), '');
  v_drawn text := nullif(btrim(coalesce(p_drawn_signature, '')), '');
  v_rec uuid;
  k jsonb;
begin
  select * into a from rental_agreements where signature_request_id = p_request;
  select * into b from bookings where id = a.booking_id;
  select * into g from rental_agreement_signers where id = p_signer and agreement_id = a.id;
  if not (app.booking_added_live(b) and g.signer_role = 'renter') then
    v_rec := app.record_signature_0019(p_request, p_signer, p_typed_name, p_drawn_signature, p_ip, p_user_agent, p_consent_text, p_document_sha256, p_consents);
    if app.booking_added_live(b) then perform app.manual_agreement_complete(b.id); end if;
    return v_rec;
  end if;
  perform 1 from rental_agreements where id = a.id for update;
  if a.status <> 'open' then raise exception 'This agreement is not open for the renter''s signature' using errcode = '23514'; end if;
  if g.signed_at is not null then raise exception '% has already signed this agreement', g.signer_name using errcode = '23514'; end if;
  if p_document_sha256 is not null and lower(btrim(p_document_sha256)) <> a.document_sha256 then
    raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  if v_typed is null and v_drawn is null then raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023'; end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(g.signer_name, '\s+', '', 'g')) then
    raise exception 'The typed name must be the signer''s full legal name (%)', g.signer_name using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_consent_text, '')), '') is null then
    raise exception 'The statement the signer agreed to is recorded with the signature' using errcode = '22023';
  end if;
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 ip_address, user_agent, provider_signature, typed_name, consent_text, document_sha256)
  values (p_request, 'renter', g.user_id, g.signer_name, g.signer_email, 'signed', now(), case when v_drawn is not null then 'drawn' else 'typed' end,
          p_ip, p_user_agent, v_drawn, v_typed, p_consent_text, a.document_sha256)
  returning id into v_rec;
  update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where id = g.id;
  if jsonb_typeof(p_consents) = 'array' then
    for k in select value from jsonb_array_elements(p_consents) loop
      insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
      values (g.user_id, g.driver_id, a.booking_id, k ->> 'code', k ->> 'version', k ->> 'text', p_ip, p_user_agent);
    end loop;
  end if;
  update rental_agreements set status = 'signed', renter_signed_at = now() where id = a.id;
  update signature_requests set status = 'partially_signed' where id = p_request;
  perform app.log_booking_event(a.booking_id, 'agreement_signed', b.status::text, b.status::text, null, null, g.user_id, 'renter',
    jsonb_build_object('agreement_id', a.id, 'signer_id', g.id, 'signer_role', 'renter', 'signer_name', g.signer_name, 'signature_record_id', v_rec));
  perform app.manual_agreement_complete(b.id);
  return v_rec;
end $$;

create or replace function app.manual_rental_sign_charge(p_booking uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.booking_added_live(b) and b.payment_mode = 'card' and b.renter_due_at_booking_cents > 0
                   and not exists (select 1 from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.status = 'succeeded')
              then jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', b.renter_due_at_booking_cents,
                                      'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id, 'brand', pm.card_brand, 'last4', pm.card_last4) end
    from bookings b join renters r on r.id = b.renter_id
    left join payment_methods pm on pm.id = b.card_on_file_id
    left join payment_method_secrets sc on sc.payment_method_id = pm.id
   where b.id = p_booking and (r.user_id = p_by or p_by is null)
$$;

create or replace function app.booking_awaiting_signature(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.booking_added_live(b) and b.booking_type <> 'owner'
                          and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed')
                     from bookings b where b.id = p_booking), false)
$$;

create or replace function app.verify_driver_in_person(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d booking_drivers;
  b bookings;
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say what was checked (the licence seen, its number)' using errcode = '22023'; end if;
  select * into d from booking_drivers where id = (p ->> 'booking_driver_id')::uuid for update;
  if d.id is null then raise exception 'Driver not found' using errcode = 'P0002'; end if;
  select * into b from bookings where id = d.booking_id;
  if not app.booking_docs_open(b) then
    raise exception 'Booking % is %: drivers are verified between the approved offer and the return', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  update booking_drivers set identity_method = 'in_person', identity_verified_on = app.today() where id = d.id;
  update drivers set identity_status = 'verified' where id = d.driver_id;
  if d.role = 'renter' then update renters set identity_status = 'verified' where id = b.renter_id; end if;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, btrim(p ->> 'note'), p_by, 'staff',
    jsonb_build_object('booking_driver_id', d.id, 'decision', 'verified_in_person'));
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Verified in person'
   where booking_id = b.id and task_type in ('verify_identity', 'verification_due', 'identity_review', 'live_rental_identity') and status in ('open', 'in_progress', 'waiting')
     and not exists (select 1 from booking_drivers x where x.booking_id = b.id and x.identity_verified_on is null);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'verify_driver_in_person', 'booking_drivers', d.id::text, jsonb_build_object('booking_id', b.id, 'note', btrim(p ->> 'note')));
  return jsonb_build_object('booking_driver_id', d.id, 'verified', true);
end $$;

create or replace function app.coverage_assert_open(b bookings) returns void
language plpgsql stable as $$
begin
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514'; end if;
  if not app.booking_docs_open(b) then
    raise exception 'Booking % is %: coverage is sent between the approved offer and pickup', b.booking_number, b.status using errcode = '23514';
  end if;
end $$;

create or replace function app.register_verification_upload(p_booking uuid, p_by uuid, p_kind text, p_driver uuid, p_storage_path text,
                                                            p_sha256 text default null, p_mime_type text default null,
                                                            p_details jsonb default null, p_storage_bucket text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_set program_settings := app.settings();
  v_id_kind boolean := p_kind in ('licence_front', 'licence_back', 'selfie');
  d jsonb := coalesce(p_details, '{}'::jsonb);
  v_doc uuid;
  v_iv uuid;
  cp coverage_proofs;
  v_option integer;
  v_purge timestamptz;
  v_id uuid;
  v_name text;
  v_insurer text;
  v_policy text;
  v_expiry date;
  v_check jsonb;
  v_pages integer;
  v_first boolean := false;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_kind is null or p_kind not in ('licence_front', 'licence_back', 'selfie', 'coverage_proof') then
    raise exception 'Unknown kind of upload "%"', p_kind using errcode = '22023';
  end if;
  if p_by is not null and not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)
       or exists (select 1 from drivers x where x.id = p_driver and x.user_id = p_by)
       or exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id
                   where sp.user_id = p_by and sp.staff_type = 'field' and sp.is_active and u.status = 'active')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not app.booking_docs_open(b) then
    raise exception 'Booking % is %: documents are uploaded once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_storage_path, '')), '') is null then
    raise exception 'An upload needs the key of its file in private storage' using errcode = '22023';
  end if;
  if v_id_kind then
    select x.full_name into v_name from booking_drivers x where x.booking_id = p_booking and x.driver_id = p_driver;
    if v_name is null then raise exception 'That driver is not on this booking' using errcode = '23514'; end if;
    v_purge := greatest(b.return_at, now()) + make_interval(days => v_set.retention_id_face_days);
  else
    if p_driver is not null then
      raise exception 'The proof of coverage belongs to the booking, not to one driver' using errcode = '22023';
    elsif b.booking_type = 'owner' then
      raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514';
    end if;
    v_option := coalesce(nullif(d ->> 'coverage_option', '')::integer, b.coverage_option);
    if v_option is null or v_option not in (1, 2) then
      raise exception 'Proof is uploaded for coverage option 1 (OPCF 27 on your own auto policy) or 2 (credit card coverage)' using errcode = '22023';
    end if;
    if b.coverage_option is distinct from v_option then
      raise exception 'Your booking is set to coverage option %. Change the option first.', coalesce(b.coverage_option::text, 'none') using errcode = '23514';
    end if;
    -- the current proof (a declined one is kept as it is and a new one starts)
    select * into cp from coverage_proofs where booking_id = p_booking and coverage_option = v_option and status in ('submitted', 'confirmed')
     order by created_at desc limit 1;
    if cp.status = 'confirmed' then
      raise exception 'Your coverage is already confirmed. To change it, message us.' using errcode = '23514';
    end if;
    if v_option = 1 then
      v_insurer := coalesce(nullif(left(btrim(d ->> 'insurer_name'), 120), ''), cp.insurer_name);
      v_policy := coalesce(nullif(left(btrim(d ->> 'policy_number'), 60), ''), cp.policy_number);
      v_expiry := coalesce(nullif(d ->> 'policy_expiry', '')::date, cp.policy_expiry);
      if v_insurer is null or v_policy is null or v_expiry is null then
        raise exception 'Add the insurer, the policy number and the policy expiry date first' using errcode = '22023';
      end if;
      if v_expiry <= app.local_date(b.return_at) then
        raise exception 'The policy must still be active after your return date (%). Its expiry date is %.', app.fmt_day(app.local_date(b.return_at)), app.fmt_day(v_expiry)
          using errcode = '23514';
      end if;
    else
      v_check := app.card_coverage_check(p_booking);
      if not (v_check ->> 'eligible')::boolean then raise exception '%', v_check ->> 'message' using errcode = '23514'; end if;
      if cp.id is null or cp.renter_confirmed_at is null then
        raise exception 'Confirm that your card includes rental car coverage first, then add its benefit document' using errcode = '23514';
      end if;
    end if;
    if cp.id is not null then
      select count(*) into v_pages from verification_uploads u where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved');
      if v_pages >= v_set.coverage_proof_max_pages then
        raise exception 'A proof can have up to % pages. Combine them into one PDF, or message us.', v_set.coverage_proof_max_pages using errcode = '23514';
      end if;
    end if;
    -- a rental record (privacy policy section 6): 7 years after the return
    v_purge := greatest(b.return_at, now()) + interval '7 years';
  end if;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, purge_after, uploaded_by, renter_id, booking_id)
  values (case p_kind when 'licence_front' then 'id_front' when 'licence_back' then 'id_back' when 'selfie' then 'face_photo' else 'coverage_proof' end::document_kind,
          case p_kind when 'licence_front' then 'Licence, front: ' || v_name when 'licence_back' then 'Licence, back: ' || v_name
                      when 'selfie' then 'Face photo: ' || v_name
                      else case v_option when 1 then 'OPCF 27 policy, booking ' else 'Card benefit document, booking ' end || b.booking_number end,
          coalesce(p_storage_bucket, case when v_id_kind then 'identity' else 'documents' end), p_storage_path, p_mime_type,
          lower(nullif(btrim(coalesce(p_sha256, '')), '')), case when v_id_kind then 'id_face_90d' else 'records_7y' end::retention_class,
          v_purge, p_by, b.renter_id, p_booking)
  returning id into v_doc;

  if v_id_kind then
    update verification_uploads set status = 'replaced'
     where booking_id = p_booking and driver_id is not distinct from p_driver and kind = p_kind and status in ('submitted', 'approved');
    -- one staff review per driver and booking, reopened by a new upload
    select iv.id into v_iv from identity_verifications iv
     where iv.driver_id = p_driver and iv.booking_id = p_booking and iv.method = 'staff_review' and iv.purged_at is null
     order by iv.created_at desc limit 1;
    if v_iv is null then
      insert into identity_verifications (driver_id, booking_id, method, status, purge_after)
      values (p_driver, p_booking, 'staff_review', 'pending', v_purge) returning id into v_iv;
    end if;
    update identity_verifications
       set status = 'pending', failure_reason = null, verified_by = null, verified_at = null, purge_after = v_purge,
           id_front_document_id = case when p_kind = 'licence_front' then v_doc else id_front_document_id end,
           id_back_document_id = case when p_kind = 'licence_back' then v_doc else id_back_document_id end,
           face_document_id = case when p_kind = 'selfie' then v_doc else face_document_id end
     where id = v_iv;
    update booking_drivers set identity_verified_on = null, identity_method = null where booking_id = p_booking and driver_id = p_driver;
    update drivers set identity_status = 'pending' where id = p_driver and identity_status <> 'verified';
  else
    if cp.id is null then
      v_first := true;
      insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, proof_document_id, submitted_by, submitted_at)
      values (p_booking, v_option, 'submitted', v_insurer, v_policy, v_expiry, v_doc, p_by, now())
      returning * into cp;
    elsif v_option = 1 then
      update coverage_proofs set insurer_name = v_insurer, policy_number = v_policy, policy_expiry = v_expiry,
             proof_document_id = coalesce(proof_document_id, v_doc), submitted_at = now()
       where id = cp.id;
    else
      v_first := not exists (select 1 from verification_uploads u where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved'));
      update coverage_proofs set proof_document_id = coalesce(proof_document_id, v_doc) where id = cp.id;
    end if;
  end if;

  insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by)
  values (p_booking, p_driver, p_kind, v_doc, v_iv, cp.id, p_by)
  returning id into v_id;

  -- ready for review: a proof at its first page; a driver's identity once all three images are in
  if (not v_id_kind and v_first) or (v_id_kind and (select count(distinct u.kind) from verification_uploads u
                        where u.booking_id = p_booking and u.driver_id = p_driver and u.status in ('submitted', 'approved')) = 3) then
    perform app.emit_event('staff_identity_review', 'booking', p_booking,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'kind', case when v_id_kind then 'identity' else 'coverage' end,
                         'driver_id', p_driver, 'driver_name', coalesce(v_name, (select r.legal_name from renters r where r.id = b.renter_id)),
                         'pickup_at', b.pickup_at),
      'staff_identity_review:' || p_booking || ':' || case when v_id_kind then v_id::text else 'cp:' || cp.id end);
  end if;
  return v_id;
end $$;

-- ================================================================ 6. paying a rental in progress online (the payment link)
-- A rental already underway sent with a payment link is on trip from the start (the car is out): the renter signs in
-- the portal, then pays the amount due at booking on the Pay page, with the same checks as any online payment (the
-- amount, the name on the card, a credit card). The payment is recorded and tied to the charges; the status stays on
-- trip. Every other payment goes through 0019's app.finalize_booking unchanged.
create or replace function app.booking_link_due(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.added_by_staff and b.added_mode = 'in_progress' and b.status = 'on_rent' and b.payment_mode = 'link'
                  and b.renter_due_at_booking_cents > 0
                  and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge'
                                    and p.status = 'succeeded'), false)
$$;

create or replace function app.finalize_live_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_card jsonb, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_proc text := coalesce(nullif(p_processor ->> 'processor', ''), 'stripe');
  v_pp text := nullif(p_processor ->> 'payment_id', '');
  v_pm uuid;
  v_pay uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if v_pp is null then raise exception 'The processor''s payment id is needed' using errcode = '22023'; end if;
  if p_amount_cents is distinct from b.renter_due_at_booking_cents then
    return app.refuse_confirmation(p_booking, 'payment', 'amount_mismatch',
      format('The amount does not equal what the renter owes at booking on %s.', b.booking_number),
      jsonb_build_object('expected_cents', b.renter_due_at_booking_cents, 'received_cents', p_amount_cents));
  end if;
  if not exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('signed', 'completed') and a.renter_signed_at is not null) then
    return app.refuse_confirmation(p_booking, 'payment', 'agreement_not_signed', format('The rental agreement of %s is not signed yet.', b.booking_number));
  end if;
  if p_card is not null and (p_card ->> 'is_credit') = 'false' then
    return app.refuse_confirmation(p_booking, 'payment', 'card_not_credit', 'The Card on File must be a credit card in the renter''s name.');
  end if;
  v_pm := coalesce(app.save_card_on_file(b.renter_id, p_card, p_processor), b.card_on_file_id,
                   (select pm.id from payment_methods pm where pm.renter_id = b.renter_id and pm.status = 'active' order by pm.created_at desc, pm.id limit 1));
  if v_pm is distinct from b.card_on_file_id then update bookings set card_on_file_id = v_pm where id = b.id; end if;
  select p.id into v_pay from payments p join payment_processor_details d on d.payment_id = p.id
   where p.booking_id = p_booking and p.purpose = 'booking_total' and d.processor = v_proc and d.processor_payment_id = v_pp
     and p.status in ('pending', 'requires_action', 'authorized')
   order by p.created_at limit 1;
  if v_pay is null then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at, created_by)
    values (p_booking, b.renter_id, 'booking_total', 'charge', 'card', p_amount_cents, 'succeeded', v_pm,
            (select pm.card_brand from payment_methods pm where pm.id = v_pm), (select pm.card_last4 from payment_methods pm where pm.id = v_pm), now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, receipt_url, raw)
    values (v_pay, v_proc, v_pp, p_processor ->> 'charge_id', p_processor ->> 'receipt_url', jsonb_build_object('manual_rental', true, 'in_progress', true));
  else
    update payments set status = 'succeeded', amount_cents = p_amount_cents, payment_method_id = v_pm, processed_at = now(),
           card_brand = (select pm.card_brand from payment_methods pm where pm.id = v_pm), card_last4 = (select pm.card_last4 from payment_methods pm where pm.id = v_pm)
     where id = v_pay;
  end if;
  update booking_line_items set payment_id = v_pay
   where booking_id = p_booking and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null
     and not (b.bill_to = 'insurer' and revenue_class = 'owner_revenue');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_paid_online', 'bookings', b.id::text, jsonb_build_object('payment_id', v_pay, 'amount_cents', p_amount_cents, 'status', b.status));
  return jsonb_build_object('ok', true, 'booking_id', p_booking, 'booking_number', b.booking_number, 'status', b.status, 'payment_id', v_pay,
                            'amount_cents', p_amount_cents, 'card_on_file_id', v_pm, 'action', 'capture');
end $$;

alter function app.finalize_booking(uuid, text, jsonb, bigint, integer, jsonb, uuid) rename to finalize_booking_pre0074;
create or replace function app.finalize_booking(p_booking uuid, p_mode text, p_processor jsonb, p_amount_cents bigint,
                                                p_offer_version integer, p_card jsonb, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if p_mode = 'payment' and app.booking_link_due(b) then
    -- the same lock on the vehicle as every confirmation (0019), so payments on one car are recorded one at a time
    perform 1 from vehicles where id = b.vehicle_id for no key update;
    return app.finalize_live_payment(p_booking, p_processor, p_amount_cents, p_card, p_by);
  end if;
  return app.finalize_booking_pre0074(p_booking, p_mode, p_processor, p_amount_cents, p_offer_version, p_card, p_by);
end $$;

-- What the server checks before and after the card is authorized (0028), with a rental in progress waiting for its
-- online payment ("link_due"; the car is out, so no free-car check) and a live rental added by hand ("added_live").
create or replace function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'booking_type', b.booking_type,
           'renter_due_at_booking_cents', b.renter_due_at_booking_cents, 'offer_approved_version', b.offer_approved_version,
           'current_offer_version', b.current_offer_version, 'vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
           'renter_id', b.renter_id, 'renter_user_id', r.user_id, 'legal_name', r.legal_name,
           'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id)),
           'agreement_signed', exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('signed', 'completed')
                                         and a.offer_version is not distinct from b.offer_approved_version),
           'vehicle_free', app.booking_link_due(b) or app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id),
           'link_due', app.booking_link_due(b), 'added_live', app.booking_added_live(b),
           'customer_id', (select s.processor_customer_id from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
                            where pm.renter_id = b.renter_id and s.processor_customer_id is not null order by pm.created_at desc limit 1),
           'card_on_file', (select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id,
                                                      'brand', pm.card_brand, 'last4', pm.card_last4)
                              from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id where pm.id = b.card_on_file_id))
    from bookings b join renters r on r.id = b.renter_id
   where b.id = p_booking
$$;

-- The renter's email for a rental added while already underway: it has started; sign now (and pay online after
-- signing, with a payment link).
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0074;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0074(p_code, p_event, p_to);
  b bookings;
begin
  if p_code = 'renter_rental_added' then
    select * into b from bookings where id = p_event.entity_id;
    if b.added_mode = 'in_progress' then
      x := x || jsonb_build_object(
        'sign_line', case when app.booking_link_due(b) then 'Your rental has already started. Read and sign your rental agreement now, then pay online from your booking.'
                          when b.payment_mode = 'card' and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.status = 'succeeded')
                            then 'Your rental has already started. Read and sign your rental agreement now; your card is charged when you sign.'
                          else 'Your rental has already started. Please read and sign your rental agreement now.' end,
        'payment_line', case when app.booking_link_due(b) then 'Pay online after you sign: the Pay now button is on your booking.' else x ->> 'payment_line' end,
        'verify_by', app.fmt_at(now() + interval '24 hours'));
    end if;
  end if;
  return x;
end $$;

-- The renter's booking page (0046's my_booking): a live rental added by hand ("added_live": sign with no payment step
-- before it) and one waiting for its online payment ("link_due": Pay now after signing).
create or replace function app.booking_portal_flags(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('added_live', app.booking_added_live(b), 'link_due', app.booking_link_due(b), 'added_mode', b.added_mode)
    from bookings b where b.id = p_booking and app.is_booking_renter(b.id, app.uid())
$$;
create or replace function public.my_booking(p_number text) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select case when x is null then null
              else x || jsonb_build_object('added_by_staff', coalesce(app.booking_added_flag((x ->> 'id')::uuid), false))
                     || coalesce(app.booking_portal_flags((x ->> 'id')::uuid), '{}'::jsonb) end
    from (select app.my_booking_0028(p_number) as x) q
$$;
revoke all on function app.booking_portal_flags(uuid) from public, anon;
grant execute on function app.booking_portal_flags(uuid) to authenticated, service_role;


-- ================================================================ 7. privileges
-- New functions: the server only. Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['manual_rental_phase', 'booking_added_live', 'booking_docs_open', 'manual_rental_car_problem',
             'manual_rental_live_clashes', 'manual_rental_went_out', 'booking_link_due', 'finalize_live_payment'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('manual_rental_create_pre0074', 'manual_rental_create'), ('manual_rental_quote_pre0074', 'manual_rental_quote'),
                          ('manual_agreement_complete_pre0074', 'manual_agreement_complete'), ('finalize_booking_pre0074', 'finalize_booking'),
                          ('ntf_payload_pre0074', 'notification_payload')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g);
      else execute format('revoke all on function %s from %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
