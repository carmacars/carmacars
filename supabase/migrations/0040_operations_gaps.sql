-- 0040_operations_gaps.sql
-- The operations gaps of the launch audit (docs/changes/2026-10-14-operations-gaps.md):
--   1. a change to a confirmed booking proposed by staff: the renter gets an email and a page to accept or
--      decline by a deadline (with a reminder), the price difference is paid (an off-session PaymentIntent) or
--      refunded, the owner hears when their car or income changes, and the calendar moves only on acceptance
--   2. the booking amendment: a PDF addendum to the rental agreement, signed by the renter with the built-in
--      signature, stored with the booking and linked in the emails and portals
--   3. the automatic cleaning block after each trip (Program settings, a per-vehicle override), shown on the
--      calendars, blocking availability, removable by staff
--   4. the listing similarity check: a new vehicle, its photos and its drafted copy are compared with the cars
--      on file; a likely duplicate waits for staff before it is published
--   5. earlier requests attached to a sign-in once its email address is verified
--   6. the additional driver's signing link: versioned, expiring, renewed and resent by the renter or staff
--   7. Forms C and D (witnessed, on paper): what each owner needs, the signed scan uploaded, reviewed by staff
--   8. the photo shoot capture on a field job: each photo's fingerprint (for 4) and the job's progress
-- No earlier migration is edited. Functions it changes are wrapped (renamed _00NN and called from a new function
-- of the same name) or replaced with the same signature, as 0029 to 0039 did. Function bodies are checked when called.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column booking_change_accept_hours smallint not null default 48 check (booking_change_accept_hours between 1 and 336),
  add column booking_change_reminder_hours smallint not null default 12 check (booking_change_reminder_hours between 1 and 168),
  add column booking_change_lead_hours smallint not null default 2 check (booking_change_lead_hours between 0 and 72),
  add column booking_driver_link_hours smallint not null default 72 check (booking_driver_link_hours between 1 and 720),
  add column turnaround_block_enabled boolean not null default true,
  add column turnaround_block_minutes smallint not null default 120 check (turnaround_block_minutes between 0 and 2880),
  add column listing_similarity_enabled boolean not null default true,
  add column listing_similarity_copy_bps smallint not null default 6000 check (listing_similarity_copy_bps between 1000 and 10000);
comment on column program_settings.booking_change_accept_hours is 'Hours a renter has to accept a change staff proposed to a confirmed booking (never later than the pickup less booking_change_lead_hours)';
comment on column program_settings.booking_change_reminder_hours is 'Hours before the acceptance deadline that the renter is reminded once';
comment on column program_settings.booking_change_lead_hours is 'A proposed change must be accepted at least this many hours before the pickup';
comment on column program_settings.booking_driver_link_hours is 'Hours an additional driver''s signing link stays valid; the renter or staff send a new one after that';
comment on column program_settings.turnaround_block_enabled is 'A cleaning block is put on the calendar after every confirmed trip';
comment on column program_settings.turnaround_block_minutes is 'Length of the cleaning block after a trip, in minutes (a vehicle may have its own)';
comment on column program_settings.listing_similarity_enabled is 'New vehicles, listing photos and drafted copy are compared with the cars on file; a likely duplicate waits for staff before publishing';
comment on column program_settings.listing_similarity_copy_bps is 'How alike two listings'' copy must be (word overlap, in basis points) to be flagged';

alter table vehicles add column turnaround_block_minutes smallint check (turnaround_block_minutes between 0 and 2880);
comment on column vehicles.turnaround_block_minutes is 'This car''s cleaning block after a trip, in minutes; empty uses Program settings';

-- the amendment is a document of its own kind (used in function bodies only: a new enum value cannot be used in
-- the transaction that adds it)
alter type document_kind add value if not exists 'rental_amendment';

-- ================================================================ 2. a change staff propose to a confirmed booking
-- 0019's change requests carry the flow (proposed by staff, agreed by the renter, applied with the money). This
-- adds: a deadline and one reminder, the renter's own "no", expiry, a new price as part of a proposal, the emails
-- to the renter, the owner and customer service, and the amendment the renter signs before it is applied.
alter table booking_change_requests
  add column accept_by timestamptz,
  add column reminded_at timestamptz,
  add column expired_at timestamptz,
  add column renter_declined_at timestamptz;
comment on column booking_change_requests.accept_by is 'The renter accepts (signs the amendment and pays any difference) by this time, or the change expires';
alter table booking_change_requests drop constraint booking_change_requests_status_check;
alter table booking_change_requests add constraint booking_change_requests_status_check check (status in (
  'requested', 'proposed', 'approved', 'declined', 'cancelled', 'applied', 'expired'));

-- 0025's preview, with one more change staff may propose: the rental charge before discounts and tax
-- (rental_charge_cents). Everything else is 0025's, word for word.
create or replace function app.preview_booking_change(p_booking uuid, p_changes jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v2 vehicles;
  v_set program_settings := app.settings();
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  k text;
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz;
  v_problems jsonb := '[]'::jsonb;
  v_days integer;
  o record; n record;
  v_rental bigint;
  v_override bigint;
  v_new jsonb;
  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];
  v_other bigint; v_other_hst bigint;
  v_sub bigint; v_hst bigint;
  v_available boolean := true;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if jsonb_typeof(ch) <> 'object' then raise exception 'Give the changes as a JSON object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(ch) loop
    if k not in ('pickup_at', 'return_at', 'vehicle_id', 'rental_charge_cents') then
      raise exception 'Unknown change "%": a confirmed booking may change its dates, its car or its rental charge', k using errcode = '22023';
    end if;
  end loop;
  if ch ? 'rental_charge_cents' then
    v_override := (ch ->> 'rental_charge_cents')::bigint;
    if v_override is null or v_override < 0 then raise exception 'The rental charge is an amount of $0.00 or more' using errcode = '22023'; end if;
  end if;
  v_vehicle := coalesce((ch ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((ch ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((ch ->> 'return_at')::timestamptz, b.return_at);
  if v_return <= v_pickup then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if (v_vehicle, v_pickup, v_return) is not distinct from (b.vehicle_id, b.pickup_at, b.return_at)
     and (v_override is null or v_override = b.rental_charge_cents) then
    v_problems := v_problems || jsonb_build_object('code', 'nothing_changes', 'message', 'These are the dates, the car and the price the booking already has.');
  end if;
  if v_override is not null and b.booking_type = 'owner' then
    v_problems := v_problems || jsonb_build_object('code', 'owner_booking_price', 'message', 'An Owner Booking has no rental charge to change.');
  end if;
  if b.status <> 'confirmed' then
    v_problems := v_problems || jsonb_build_object('code', 'not_confirmed',
      'message', format('Booking %s is %s. A change request is for a confirmed booking that has not started.', b.booking_number, b.status));
  end if;
  if b.dates_provisional or b.bill_to <> 'renter' then
    v_problems := v_problems || jsonb_build_object('code', 'insurer_booking', 'message', 'A booking billed to an insurer is changed by staff.');
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status in ('requested', 'approved', 'confirmed')) then
    v_problems := v_problems || jsonb_build_object('code', 'has_extension', 'message', 'A booking with an extension is changed by staff.');
  end if;
  if v_pickup <> b.pickup_at and v_pickup < now() then
    v_problems := v_problems || jsonb_build_object('code', 'pickup_in_past', 'message', 'The new pickup time has already passed.');
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_days > least(v_set.max_rental_days, 30) then
    v_problems := v_problems || jsonb_build_object('code', 'over_maximum_length',
      'message', format('A rental is %s days or less. A longer stay is a renewal.', least(v_set.max_rental_days, 30)));
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id);
  end if;
  if v_vehicle <> b.vehicle_id then
    select * into v2 from vehicles where id = v_vehicle;
    if v2.id is null then raise exception 'Vehicle not found' using errcode = '22023'; end if;
    if b.booking_type <> 'owner' and not coalesce(app.vehicle_bookable(v_vehicle), false) then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_bookable', 'message', 'That car is not open for bookings.');
    end if;
    if b.booking_type = 'owner' and v2.owner_id <> b.owner_id then
      v_problems := v_problems || jsonb_build_object('code', 'other_owner_vehicle',
        'message', 'An Owner Booking moves only to another car of the same Owner.');
    end if;
    if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                  and app.age_band(app.age_on(d.date_of_birth, app.local_date(v_pickup))) = '18_to_20') and not v2.allows_18_to_20 then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_for_young_drivers',
        'message', format('That car is for drivers %s and over.', v_set.standard_min_age));
    end if;
  else
    select * into v2 from vehicles where id = b.vehicle_id;
  end if;
  if v2.exit_date is not null and app.local_date(v_return) > v2.exit_date then
    v_problems := v_problems || jsonb_build_object('code', 'vehicle_leaving', 'message', 'The car is not offered for the whole of these dates.');
  end if;
  if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                and app.age_on(d.date_of_birth, app.local_date(v_pickup)) < v_set.min_renter_age) then
    v_problems := v_problems || jsonb_build_object('code', 'driver_under_minimum_age',
      'message', format('Every driver must be %s or older at pickup.', v_set.min_renter_age));
  end if;
  if b.blocks_calendar then
    v_available := app.vehicle_is_available(v_vehicle, v_pickup, v_return, b.id);
    if not v_available then
      v_problems := v_problems || jsonb_build_object('code', 'not_available', 'message', 'The car is not free for the whole of these dates.');
    end if;
  end if;

  -- the price after the change
  if b.booking_type = 'owner' then
    v_rental := 0;
  elsif v_override is not null then
    v_rental := v_override;
  else
    select * into o from public.calc_rental_charge(b.pickup_at, b.billable_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    select * into n from public.calc_rental_charge(v_pickup, v_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    v_rental := greatest(0, b.rental_charge_cents + n.rental_charge_cents - o.rental_charge_cents);
  end if;
  v_new := app.price_lines(app.booking_price_spec(p_booking, (ch - 'rental_charge_cents') || jsonb_build_object('rental_charge_cents', v_rental)));
  if b.request_details is not null then
    v_owned := v_owned || array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold'];
  end if;
  select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_other, v_other_hst
    from booking_line_items li
   where li.booking_id = p_booking and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null
     and not li.charge_type = any (v_owned);
  v_sub := (v_new ->> 'subtotal_cents')::bigint + v_other;
  v_hst := (v_new ->> 'hst_cents')::bigint + v_other_hst;
  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'problems', v_problems, 'booking_id', b.id, 'changes', ch,
    'before', jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
                                 'rental_charge_cents', b.rental_charge_cents, 'subtotal_cents', b.subtotal_at_booking_cents,
                                 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents),
    'after', jsonb_build_object('vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return, 'billable_days', v_days,
                                'rental_charge_cents', v_rental, 'rate_applied', v_new ->> 'rate_applied',
                                'subtotal_cents', v_sub, 'hst_cents', v_hst, 'total_cents', v_sub + v_hst),
    'lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                from jsonb_array_elements(v_new -> 'lines') with ordinality x(value, ord)),
    'difference_cents', v_sub - b.subtotal_at_booking_cents, 'hst_cents', v_hst - b.hst_at_booking_cents,
    'total_difference_cents', (v_sub + v_hst) - b.total_due_at_booking_cents, 'available', v_available);
end $$;

-- A new price is staff's to propose; a renter asks for dates only.
alter function app.request_booking_change(uuid, uuid, jsonb, text) rename to request_booking_change_0019;
create or replace function app.request_booking_change(p_booking uuid, p_by uuid, p_changes jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p_changes, '{}'::jsonb) ? 'rental_charge_cents' and not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only customer service, fleet or an Admin proposes a new rental charge' using errcode = '42501';
  end if;
  return app.request_booking_change_0019(p_booking, p_by, p_changes, p_note);
end $$;

create or replace function public.my_booking_change_preview(p_booking uuid, p_changes jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.preview_booking_change(p_booking, coalesce(p_changes, '{}'::jsonb) - 'rental_charge_cents');
end $$;

-- The deadline: set when a change waits for the renter (proposed by staff, or a renter's request approved).
create or replace function app.booking_change_deadline() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  v timestamptz;
begin
  if new.status in ('proposed', 'approved') and new.accept_by is null
     and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    select * into b from bookings where id = new.booking_id;
    v := least(now() + make_interval(hours => s.booking_change_accept_hours),
               least(b.pickup_at, coalesce((new.after ->> 'pickup_at')::timestamptz, b.pickup_at)) - make_interval(hours => s.booking_change_lead_hours));
    new.accept_by := least(greatest(v, now() + interval '1 hour'), greatest(b.pickup_at, now() + interval '5 minutes'));
  end if;
  return new;
end $$;
create trigger booking_change_requests_deadline before insert or update of status on booking_change_requests
  for each row execute function app.booking_change_deadline();

-- A proposal is emailed once the transaction that made it commits and only if it is still waiting (the
-- calendar's "agreed by phone" path proposes and applies in one go: no proposal email then).
create or replace function app.booking_change_proposed_notify() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
begin
  select * into c from booking_change_requests where id = new.id;
  if c.id is null or c.status <> 'proposed' then return null; end if;
  select * into b from bookings where id = c.booking_id;
  perform app.ntf_emit('renter_change_proposed', 'booking_change_request', c.id, 'proposed',
    jsonb_build_object('booking_id', c.booking_id, 'renter_id', b.renter_id, 'owner_id', b.owner_id));
  return null;
end $$;
create constraint trigger booking_change_requests_proposed after insert on booking_change_requests
  deferrable initially deferred for each row execute function app.booking_change_proposed_notify();

-- How the change ended: the renter, the owner(s) whose car or income changes, and customer service hear.
create or replace function app.booking_change_outcome_notify() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o1 uuid;
  o2 uuid;
  pl jsonb;
begin
  if new.status is not distinct from old.status then return null; end if;
  select * into b from bookings where id = new.booking_id;
  pl := jsonb_build_object('booking_id', new.booking_id, 'renter_id', b.renter_id, 'owner_id', b.owner_id);
  if new.status = 'applied' then
    perform app.ntf_emit('renter_change_applied', 'booking_change_request', new.id, 'applied', pl);
    if b.booking_type <> 'owner' then
      o1 := (select v.owner_id from vehicles v where v.id = (new.before ->> 'vehicle_id')::uuid);
      o2 := (select v.owner_id from vehicles v where v.id = coalesce((new.after ->> 'vehicle_id')::uuid, (new.before ->> 'vehicle_id')::uuid));
      if o1 is not null then
        perform app.ntf_emit('owner_booking_changed', 'booking_change_request', new.id, 'owner:' || o1,
          pl || jsonb_build_object('owner_id', o1, 'owner_side', case when o1 is distinct from o2 then 'out' else 'same' end));
      end if;
      if o2 is not null and o2 is distinct from o1 then
        perform app.ntf_emit('owner_booking_changed', 'booking_change_request', new.id, 'owner:' || o2,
          pl || jsonb_build_object('owner_id', o2, 'owner_side', 'in'));
      end if;
    end if;
    if new.requested_by_role = 'staff' and not new.agreed_by_phone then
      perform app.ntf_emit('staff_change_proposal_answered', 'booking_change_request', new.id, 'accepted', pl || jsonb_build_object('outcome', 'accepted'));
    end if;
  elsif new.status = 'declined' and new.renter_declined_at is not null then
    perform app.ntf_emit('staff_change_proposal_answered', 'booking_change_request', new.id, 'declined', pl || jsonb_build_object('outcome', 'declined'));
  elsif new.status = 'expired' then
    perform app.ntf_emit('renter_change_proposal_expired', 'booking_change_request', new.id, 'expired', pl);
    perform app.ntf_emit('staff_change_proposal_answered', 'booking_change_request', new.id, 'expired', pl || jsonb_build_object('outcome', 'expired'));
    perform app.resolve_tasks(array['booking_change_approval'], new.booking_id, null, 'The change expired', true);
  end if;
  if new.status in ('declined', 'cancelled', 'expired') then
    update booking_amendments set status = 'voided', voided_at = now(), void_reason = 'The change was ' || new.status
     where change_request_id = new.id and status = 'open';
  end if;
  return null;
end $$;
create trigger booking_change_requests_outcome after update of status on booking_change_requests
  for each row execute function app.booking_change_outcome_notify();

-- Staff propose a change: new pickup or return, another car, or a new rental charge, with the reason the renter
-- reads. p: booking, pickup_at, return_at, vehicle_id, rental_charge_cents, note. An earlier proposal of staff is
-- replaced; a request of the renter is decided first.
create or replace function app.propose_booking_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  c booking_change_requests;
  v_ch jsonb;
  v_id uuid;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only customer service, fleet or an Admin proposes a change to a booking' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_ch := jsonb_strip_nulls(jsonb_build_object(
    'pickup_at', case when nullif(p_ ->> 'pickup_at', '') is not null and (p_ ->> 'pickup_at')::timestamptz <> b.pickup_at then p_ -> 'pickup_at' end,
    'return_at', case when nullif(p_ ->> 'return_at', '') is not null and (p_ ->> 'return_at')::timestamptz <> b.return_at then p_ -> 'return_at' end,
    'vehicle_id', case when nullif(p_ ->> 'vehicle_id', '') is not null and (p_ ->> 'vehicle_id')::uuid <> b.vehicle_id then p_ -> 'vehicle_id' end,
    'rental_charge_cents', case when nullif(p_ ->> 'rental_charge_cents', '') is not null and (p_ ->> 'rental_charge_cents')::bigint <> b.rental_charge_cents
                                then to_jsonb((p_ ->> 'rental_charge_cents')::bigint) end));
  if v_ch = '{}'::jsonb then
    raise exception 'Nothing would change: give new dates, another car or a new rental charge' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_ ->> 'note', '')), '') is null then
    raise exception 'Write the reason for the renter: it is in their email' using errcode = '22023';
  end if;
  select * into c from booking_change_requests where booking_id = b.id and status in ('requested', 'proposed', 'approved') for update;
  if c.id is not null then
    if c.requested_by_role = 'staff' and c.status = 'proposed' then
      perform app.withdraw_booking_change(c.id, p_by);
    else
      raise exception 'Booking % has a change the renter asked for: approve or decline it first', b.booking_number using errcode = '23514';
    end if;
  end if;
  v_id := app.request_booking_change(b.id, p_by, v_ch, left(btrim(p_ ->> 'note'), 1000));
  select * into c from booking_change_requests where id = v_id;
  perform app.raise_task(p_type => 'booking_change_approval',
      p_title => format('Booking %s: waiting for the renter to accept a change', b.booking_number),
      p_detail => left(btrim(p_ ->> 'note'), 1000), p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
      p_related_table => 'booking_change_requests', p_related_id => v_id, p_due_at => c.accept_by,
      p_dedupe => 'booking_change_approval:' || b.id || ':' || v_id, p_created_by => p_by);
  return to_jsonb(c) || jsonb_build_object('booking_number', b.booking_number);
end $$;

-- What a proposal would do, for the staff form (no change is written).
create or replace function app.propose_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_ch jsonb;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_ch := jsonb_strip_nulls(jsonb_build_object(
    'pickup_at', case when nullif(p_ ->> 'pickup_at', '') is not null and (p_ ->> 'pickup_at')::timestamptz <> b.pickup_at then p_ -> 'pickup_at' end,
    'return_at', case when nullif(p_ ->> 'return_at', '') is not null and (p_ ->> 'return_at')::timestamptz <> b.return_at then p_ -> 'return_at' end,
    'vehicle_id', case when nullif(p_ ->> 'vehicle_id', '') is not null and (p_ ->> 'vehicle_id')::uuid <> b.vehicle_id then p_ -> 'vehicle_id' end,
    'rental_charge_cents', case when nullif(p_ ->> 'rental_charge_cents', '') is not null and (p_ ->> 'rental_charge_cents')::bigint <> b.rental_charge_cents
                                then to_jsonb((p_ ->> 'rental_charge_cents')::bigint) end));
  return app.preview_booking_change(b.id, v_ch) || jsonb_build_object('rows', app.change_rows(b.id, app.preview_booking_change(b.id, v_ch)));
end $$;

-- The change as rows of label, before and after (dates, car, days, rental charge, total), for emails and pages.
-- p_c: a change request row as JSON, or a preview (both carry before and after).
create or replace function app.change_rows(p_booking uuid, p_c jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with x as (select coalesce(p_c -> 'before', '{}'::jsonb) as bf, coalesce(p_c -> 'after', '{}'::jsonb) as af)
  select coalesce(jsonb_agg(r.row order by r.ord), '[]'::jsonb)
    from x, lateral (values
      (1, case when (x.af ->> 'pickup_at') is distinct from (x.bf ->> 'pickup_at') and x.af ? 'pickup_at' then
         jsonb_build_object('label', 'Pickup', 'before', app.fmt_at((x.bf ->> 'pickup_at')::timestamptz), 'after', app.fmt_at((x.af ->> 'pickup_at')::timestamptz)) end),
      (2, case when (x.af ->> 'return_at') is distinct from (x.bf ->> 'return_at') and x.af ? 'return_at' then
         jsonb_build_object('label', 'Return', 'before', app.fmt_at((x.bf ->> 'return_at')::timestamptz), 'after', app.fmt_at((x.af ->> 'return_at')::timestamptz)) end),
      (3, case when (x.af ->> 'vehicle_id') is distinct from (x.bf ->> 'vehicle_id') and x.af ? 'vehicle_id' then
         jsonb_build_object('label', 'Car', 'before', app.vehicle_name((x.bf ->> 'vehicle_id')::uuid), 'after', app.vehicle_name((x.af ->> 'vehicle_id')::uuid)) end),
      (4, case when (x.af ->> 'billable_days') is distinct from (x.bf ->> 'billable_days') and x.af ? 'billable_days' then
         jsonb_build_object('label', 'Days', 'before', x.bf ->> 'billable_days', 'after', x.af ->> 'billable_days') end),
      (5, case when (x.af ->> 'rental_charge_cents') is distinct from (x.bf ->> 'rental_charge_cents') and x.af ? 'rental_charge_cents' then
         jsonb_build_object('label', 'Rental charge', 'before', app.fmt_money((x.bf ->> 'rental_charge_cents')::bigint), 'after', app.fmt_money((x.af ->> 'rental_charge_cents')::bigint)) end),
      (6, case when x.af ? 'total_cents' then
         jsonb_build_object('label', 'Total with HST', 'before', app.fmt_money((x.bf ->> 'total_cents')::bigint), 'after', app.fmt_money((x.af ->> 'total_cents')::bigint)) end)
    ) r(ord, row)
   where r.row is not null
$$;

-- The renter says no to a change staff proposed (or to the price of one they asked for).
create or replace function app.renter_decline_booking_change(p_request uuid, p_by uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change not found' using errcode = 'P0002'; end if;
  if p_by is null or not app.is_booking_renter(c.booking_id, p_by) then
    raise exception 'Only the renter of this booking answers this change' using errcode = '42501';
  end if;
  if c.status not in ('proposed', 'approved') then
    raise exception 'This change is % and is no longer waiting for an answer', c.status using errcode = '23514';
  end if;
  select * into b from bookings where id = c.booking_id;
  update booking_change_requests
     set status = 'declined', renter_declined_at = now(), decided_at = coalesce(decided_at, now()),
         decline_reason = 'Declined by the renter' || coalesce(': ' || left(v_reason, 500), '')
   where id = c.id;
  perform app.log_booking_event(c.booking_id, 'booking_change', b.status::text, b.status::text, null, v_reason, p_by, 'renter',
    jsonb_build_object('change_request_id', c.id, 'step', 'declined_by_renter'));
end $$;

-- Every 15 minutes: a change past its deadline expires (the booking stays as it was); one reminder before it.
create or replace function app.booking_change_sweep(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  c booking_change_requests;
  v_exp integer := 0;
  v_rem integer := 0;
begin
  for c in select * from booking_change_requests x
            where x.status in ('proposed', 'approved') and x.accept_by is not null and x.accept_by <= p_now
            order by x.accept_by for update skip locked loop
    update booking_change_requests set status = 'expired', expired_at = p_now where id = c.id;
    perform app.log_booking_event(c.booking_id, 'booking_change', null, null, null, 'Not accepted in time', null, 'system',
      jsonb_build_object('change_request_id', c.id, 'step', 'expired'));
    v_exp := v_exp + 1;
  end loop;
  for c in select * from booking_change_requests x
            where x.status in ('proposed', 'approved') and x.reminded_at is null and x.accept_by > p_now
              and x.accept_by - make_interval(hours => s.booking_change_reminder_hours) <= p_now
              and x.created_at < x.accept_by - make_interval(hours => s.booking_change_reminder_hours)
              and not exists (select 1 from booking_amendments a where a.change_request_id = x.id and a.status = 'signed')
            order by x.accept_by for update skip locked loop
    update booking_change_requests set reminded_at = p_now where id = c.id;
    perform app.ntf_emit('renter_change_proposal_reminder', 'booking_change_request', c.id, 'reminder',
      jsonb_build_object('booking_id', c.booking_id, 'renter_id', (select b.renter_id from bookings b where b.id = c.booking_id),
                         'owner_id', (select b.owner_id from bookings b where b.id = c.booking_id)));
    v_rem := v_rem + 1;
  end loop;
  return jsonb_build_object('expired', v_exp, 'reminded', v_rem);
end $$;

create or replace function app.job_booking_changes(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_run uuid;
  v jsonb;
begin
  if not exists (select 1 from booking_change_requests where status in ('proposed', 'approved') and accept_by is not null) then return 'not_due'; end if;
  v_run := app.job_claim('booking-changes', app.job_slot(p_now, 15));
  if v_run is null then return 'already_run'; end if;
  begin
    v := app.booking_change_sweep(p_now);
    perform app.job_succeed(v_run, v);
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- open changes from before this migration get their deadline
update booking_change_requests c
   set accept_by = greatest(now() + interval '1 hour', least(now() + make_interval(hours => (app.settings()).booking_change_accept_hours),
                                                             (select b.pickup_at from bookings b where b.id = c.booking_id)))
 where c.status in ('proposed', 'approved') and c.accept_by is null;

-- ================================================================ 3. the booking amendment, signed by the renter
-- An addendum to the rental agreement for one accepted change: what changes, the money, "everything else stays".
-- The server renders the PDF (pdf-lib) and stores it; it is opened for signature here with its SHA-256, the renter
-- signs it with the built-in signature (typed or drawn), and after the change is applied the signed copy (the
-- signature and its record) is attached. A change agreed by phone is recorded without a signature.
create table booking_amendments (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references bookings (id) on delete cascade,
  change_request_id     uuid not null references booking_change_requests (id) on delete cascade,
  amendment_number      text not null unique,
  agreement_id          uuid references rental_agreements (id),
  document_id           uuid references documents (id),
  document_sha256       text check (document_sha256 ~ '^[0-9a-f]{64}$'),
  template_version      text,
  signature_request_id  uuid unique references signature_requests (id),
  status                text not null default 'open' check (status in ('open', 'signed', 'voided', 'recorded')),
  signer_user_id        uuid references users (id),
  signature_record_id   uuid references signature_records (id),
  signed_at             timestamptz,
  signed_document_id    uuid references documents (id),
  voided_at             timestamptz,
  void_reason           text,
  created_by            uuid references users (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check (status <> 'signed' or (signed_at is not null and signature_record_id is not null)),
  check (status <> 'voided' or (voided_at is not null and void_reason is not null)),
  check (status = 'recorded' or (document_id is not null and signature_request_id is not null))
);
create unique index booking_amendments_one_live on booking_amendments (change_request_id) where status in ('open', 'signed', 'recorded');
create index booking_amendments_booking_idx on booking_amendments (booking_id, created_at);
create trigger booking_amendments_updated before update on booking_amendments for each row execute function app.set_updated_at();
comment on table booking_amendments is 'One addendum to a booking''s rental agreement per accepted change: the PDF the renter signs and the signed copy.';

-- What the amendment PDF and the renter's page show: the change in rows, the money, the parties, the agreement it
-- amends. p_by is the renter (or staff, who read it in the portals).
create or replace function app.booking_change_facts(p_request uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  r renters;
  a rental_agreements;
  am booking_amendments;
begin
  select * into c from booking_change_requests where id = p_request;
  if c.id is null then raise exception 'Change not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.is_booking_renter(c.booking_id, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into b from bookings where id = c.booking_id;
  select * into r from renters where id = b.renter_id;
  select * into a from rental_agreements where booking_id = b.id and status <> 'voided' order by opened_at desc limit 1;
  select * into am from booking_amendments where change_request_id = c.id and status in ('open', 'signed', 'recorded') order by created_at desc limit 1;
  return jsonb_build_object(
    'change', jsonb_build_object('id', c.id, 'status', c.status, 'requested_by_role', c.requested_by_role, 'note', c.note,
                                 'changes', c.changes, 'before', c.before, 'after', c.after, 'lines', c.lines,
                                 'difference_cents', c.difference_cents, 'hst_cents', c.hst_cents, 'total_difference_cents', c.total_difference_cents,
                                 'accept_by', c.accept_by, 'renter_agreed_at', c.renter_agreed_at, 'created_at', c.created_at,
                                 'decline_reason', c.decline_reason, 'applied_at', c.applied_at, 'expired_at', c.expired_at,
                                 'payment_id', c.payment_id, 'refund_id', c.refund_id),
    'rows', app.change_rows(b.id, to_jsonb(c)),
    'open', c.status in ('proposed', 'approved') and coalesce(c.accept_by, 'infinity') > now(),
    'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                                  'vehicle_id', b.vehicle_id, 'vehicle_name', app.vehicle_name(b.vehicle_id), 'renter_user_id', r.user_id,
                                  'total_due_at_booking_cents', b.total_due_at_booking_cents, 'hst_bps', b.hst_bps),
    'renter', jsonb_build_object('legal_name', r.legal_name, 'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id)),
                                 'address', concat_ws(', ', nullif(r.address_line1, ''), nullif(r.city, ''), nullif(r.province, ''), nullif(r.postal_code, ''))),
    'agreement', case when a.id is null then null else jsonb_build_object('id', a.id, 'agreement_number', a.agreement_number, 'status', a.status,
                                                                         'completed_at', a.completed_at, 'template_version', a.template_version) end,
    'amendment', case when am.id is null then null else to_jsonb(am) end,
    'amendment_number_next', coalesce(a.agreement_number, b.booking_number) || '-A' || (1 + (select count(*) from booking_amendments x where x.booking_id = b.id)),
    'card_on_file', (select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id,
                                               'brand', pm.card_brand, 'last4', pm.card_last4)
                       from payment_methods pm left join payment_method_secrets s on s.payment_method_id = pm.id where pm.id = b.card_on_file_id),
    'company', app.doc_company_brand());
end $$;

-- The server stored the rendered amendment: open it for the renter's signature. The same document again returns
-- the open amendment; a different one (the change was priced again) replaces it.
create or replace function app.open_booking_amendment(p_request uuid, p_by uuid, p_sha256 text, p_storage_path text, p_template_version text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  am booking_amendments;
  v_doc uuid;
  v_req uuid;
  v_agreement uuid;
  v_number text;
begin
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change not found' using errcode = 'P0002'; end if;
  if p_by is null or not app.is_booking_renter(c.booking_id, p_by) then
    raise exception 'The amendment is opened for the renter of the booking' using errcode = '42501';
  end if;
  if c.status not in ('proposed', 'approved') or coalesce(c.accept_by, 'infinity') <= now() then
    raise exception 'This change is no longer waiting for your answer' using errcode = '23514';
  end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or nullif(btrim(coalesce(p_storage_path, '')), '') is null then
    raise exception 'The amendment document is missing' using errcode = '22023';
  end if;
  select * into b from bookings where id = c.booking_id;
  select * into am from booking_amendments where change_request_id = c.id and status = 'open' for update;
  if am.id is not null and am.document_sha256 = lower(p_sha256) then
    return to_jsonb(am);
  elsif am.id is not null then
    update booking_amendments set status = 'voided', voided_at = now(), void_reason = 'The amendment was made again' where id = am.id;
    update signature_requests set status = 'voided' where id = am.signature_request_id;
  end if;
  if exists (select 1 from booking_amendments x where x.change_request_id = c.id and x.status in ('signed', 'recorded')) then
    raise exception 'This change is already signed' using errcode = '23514';
  end if;
  select id, coalesce(agreement_number, b.booking_number) into v_agreement, v_number
    from rental_agreements where booking_id = b.id and status <> 'voided' order by opened_at desc limit 1;
  v_number := coalesce(v_number, b.booking_number) || '-A' || (1 + (select count(*) from booking_amendments x where x.booking_id = b.id));
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, booking_id, renter_id, uploaded_by)
  values ('rental_amendment'::text::document_kind, 'Booking amendment ' || v_number, 'agreements', btrim(p_storage_path), 'application/pdf',
          lower(p_sha256), p_template_version, b.id, b.renter_id, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by)
  returning id into v_req;
  insert into booking_amendments (booking_id, change_request_id, amendment_number, agreement_id, document_id, document_sha256, template_version,
                                  signature_request_id, created_by)
  values (b.id, c.id, v_number, v_agreement, v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into am;
  return to_jsonb(am);
end $$;

-- The renter signs the amendment: the signature record (typed name or drawn image, the statement, IP address and
-- browser, the document's SHA-256), and the renter's agreement to the change is recorded on it.
create or replace function app.sign_booking_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  am booking_amendments;
  c booking_change_requests;
  r renters;
  v_typed text := nullif(btrim(coalesce(p_typed_name, '')), '');
  v_drawn text := nullif(btrim(coalesce(p_drawn_signature, '')), '');
  v_rec uuid;
begin
  select * into am from booking_amendments where id = p_amendment for update;
  if am.id is null then raise exception 'Amendment not found' using errcode = 'P0002'; end if;
  if p_by is null or not app.is_booking_renter(am.booking_id, p_by) then
    raise exception 'The renter of the booking signs the amendment' using errcode = '42501';
  end if;
  select * into c from booking_change_requests where id = am.change_request_id for update;
  if am.status <> 'open' then raise exception 'This amendment is % and is not open for signature', am.status using errcode = '23514'; end if;
  if c.status not in ('proposed', 'approved') or coalesce(c.accept_by, 'infinity') <= now() then
    raise exception 'This change is no longer waiting for your answer' using errcode = '23514';
  end if;
  if lower(coalesce(p_document_sha256, '')) <> am.document_sha256 then
    raise exception 'The amendment changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  if v_typed is null and v_drawn is null then
    raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023';
  end if;
  select r2.* into r from renters r2 join bookings b on b.renter_id = r2.id where b.id = am.booking_id;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(r.legal_name, '\s+', '', 'g')) then
    raise exception 'The typed name must be your full legal name (%)', r.legal_name using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_consent_text, '')), '') is null then
    raise exception 'The statement you agree to is recorded with the signature' using errcode = '22023';
  end if;
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 ip_address, user_agent, provider_signature, typed_name, consent_text, document_sha256)
  values (am.signature_request_id, 'renter', p_by, r.legal_name, coalesce(r.email, (select u.email from users u where u.id = p_by)), 'signed', now(),
          case when v_drawn is not null then 'drawn' else 'typed' end, p_ip, p_user_agent, v_drawn, v_typed, p_consent_text, am.document_sha256)
  returning id into v_rec;
  update booking_amendments set status = 'signed', signed_at = now(), signer_user_id = p_by, signature_record_id = v_rec where id = am.id;
  update signature_requests set status = 'partially_signed' where id = am.signature_request_id;
  perform app.agree_booking_change(c.id, p_by, p_ip, p_user_agent);
  return (select to_jsonb(x) from booking_amendments x where x.id = am.id);
end $$;

-- After the change is applied: the signed copy (rendered by the server with the signature and its record).
create or replace function app.attach_signed_amendment(p_amendment uuid, p_storage_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  am booking_amendments;
  v_doc uuid;
begin
  select * into am from booking_amendments where id = p_amendment for update;
  if am.id is null then raise exception 'Amendment not found' using errcode = 'P0002'; end if;
  if am.status <> 'signed' then raise exception 'Only a signed amendment gets its signed copy' using errcode = '23514'; end if;
  if am.signed_document_id is not null then return am.signed_document_id; end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or nullif(btrim(coalesce(p_storage_path, '')), '') is null then
    raise exception 'The signed copy is missing' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, booking_id, renter_id)
  select 'rental_amendment'::text::document_kind, 'Signed booking amendment ' || am.amendment_number, 'agreements', btrim(p_storage_path),
         'application/pdf', lower(p_sha256), am.template_version, am.booking_id, b.renter_id
    from bookings b where b.id = am.booking_id
  returning id into v_doc;
  update booking_amendments set signed_document_id = v_doc where id = am.id;
  update signature_requests set status = 'completed', completed_at = now(), signed_document_id = v_doc where id = am.signature_request_id;
  return v_doc;
end $$;

-- A change applied without the renter's signature online (an Admin's record of a phone agreement): the
-- amendment is recorded, with no document to sign.
create or replace function app.booking_change_record_amendment() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_number text;
begin
  if new.status = 'applied' and old.status is distinct from 'applied'
     and not exists (select 1 from booking_amendments a where a.change_request_id = new.id and a.status in ('signed', 'recorded')) then
    update booking_amendments set status = 'voided', voided_at = now(), void_reason = 'Agreed another way'
     where change_request_id = new.id and status = 'open';
    select coalesce((select a.agreement_number from rental_agreements a where a.booking_id = new.booking_id and a.status <> 'voided' order by a.opened_at desc limit 1),
                    (select b.booking_number from bookings b where b.id = new.booking_id))
           || '-A' || (1 + (select count(*) from booking_amendments x where x.booking_id = new.booking_id)) into v_number;
    insert into booking_amendments (booking_id, change_request_id, amendment_number, status, created_by)
    values (new.booking_id, new.id, v_number, 'recorded', coalesce(new.applied_by, new.agreed_by));
  end if;
  return null;
end $$;
create trigger booking_change_requests_amendment after update of status on booking_change_requests
  for each row execute function app.booking_change_record_amendment();

-- The renter (or staff) apply an agreed change: under 0019's lock the price is checked again and the money is
-- recorded (a payment of exactly the difference when more is owed; a refund for approval when less). A change
-- the renter accepts online must carry their signed amendment first.
create or replace function app.accept_booking_change_apply(p_request uuid, p_by uuid, p_processor jsonb default null, p_amount_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
begin
  select * into c from booking_change_requests where id = p_request;
  if c.id is null then raise exception 'Change not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from booking_amendments a where a.change_request_id = c.id and a.status = 'signed') and not c.agreed_by_phone then
    raise exception 'Sign the amendment first' using errcode = '23514';
  end if;
  if coalesce(c.accept_by, 'infinity') <= now() then
    raise exception 'The time to accept this change has passed' using errcode = '23514';
  end if;
  return app.apply_booking_change(p_request, p_by, p_processor, p_amount_cents);
end $$;

-- ================================================================ 4. the cleaning block after each trip
-- A confirmed booking that blocks the calendar gets a "cleaning" block from its return for the vehicle's minutes
-- (Program settings, or the vehicle's own). It follows the booking (new return, another car, the actual return
-- when the car came back late) and goes when the booking is cancelled. It never covers another confirmed booking
-- (it stops at the next pickup). Staff may remove it; a removed block is not put back.
alter table vehicle_calendar_blocks
  add column booking_id uuid references bookings (id) on delete cascade,
  add column source text not null default 'staff' check (source in ('staff', 'turnaround'));
create unique index vehicle_calendar_blocks_one_turnaround on vehicle_calendar_blocks (booking_id) where source = 'turnaround';
comment on column vehicle_calendar_blocks.source is 'staff: added by a person; turnaround: the cleaning block after a trip, kept in step with its booking';

create or replace function app.turnaround_minutes(p_vehicle uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when (app.settings()).turnaround_block_enabled
              then coalesce((select v.turnaround_block_minutes from vehicles v where v.id = p_vehicle), (app.settings()).turnaround_block_minutes)
              else 0 end
$$;

create or replace function app.sync_turnaround_block(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  k vehicle_calendar_blocks;
  v_min integer;
  v_start timestamptz;
  v_end timestamptz;
  v_next timestamptz;
begin
  select * into b from bookings where id = p_booking;
  select * into k from vehicle_calendar_blocks where booking_id = p_booking and source = 'turnaround';
  if b.id is null then return null; end if;
  -- removed by staff: left as it is
  if k.id is not null and k.removed_at is not null then return k.id; end if;
  -- a trip that is over keeps its block as it was
  if b.status = 'closed' or (b.status = 'returned' and k.id is not null and k.ends_at <= now()) then return k.id; end if;
  v_min := app.turnaround_minutes(b.vehicle_id);
  if b.status not in ('confirmed', 'on_rent', 'returned') or not b.blocks_calendar or v_min <= 0 then
    if k.id is not null then delete from vehicle_calendar_blocks where id = k.id; end if;
    return null;
  end if;
  v_start := case when b.status = 'returned' then coalesce(b.checked_in_at, b.return_at) else greatest(b.return_at, coalesce(b.checked_in_at, b.return_at)) end;
  v_end := v_start + make_interval(mins => v_min);
  select min(x.pickup_at) into v_next from bookings x
   where x.vehicle_id = b.vehicle_id and x.id <> b.id and x.blocks_calendar and x.status in ('confirmed', 'on_rent')
     and x.pickup_at >= b.pickup_at and x.pickup_at < v_end;
  if v_next is not null then v_end := least(v_end, v_next); end if;
  if v_end <= v_start then
    if k.id is not null then delete from vehicle_calendar_blocks where id = k.id; end if;
    return null;
  end if;
  if k.id is null then
    insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, booking_id, source)
    values (b.vehicle_id, 'cleaning', v_start, v_end, 'Cleaning after booking ' || b.booking_number, b.id, 'turnaround')
    returning id into k.id;
  elsif (k.vehicle_id, k.starts_at, k.ends_at) is distinct from (b.vehicle_id, v_start, v_end) then
    update vehicle_calendar_blocks set vehicle_id = b.vehicle_id, starts_at = v_start, ends_at = v_end,
           note = 'Cleaning after booking ' || b.booking_number where id = k.id;
  end if;
  return k.id;
end $$;

create or replace function app.bookings_turnaround_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' and new.status not in ('confirmed', 'on_rent', 'returned') then return null; end if;
  if tg_op = 'UPDATE' and (new.status, new.vehicle_id, new.return_at, new.checked_in_at, new.blocks_calendar)
                          is not distinct from (old.status, old.vehicle_id, old.return_at, old.checked_in_at, old.blocks_calendar) then
    return null;
  end if;
  perform app.sync_turnaround_block(new.id);
  return null;
end $$;
create trigger bookings_turnaround after insert or update of status, vehicle_id, return_at, checked_in_at, blocks_calendar on bookings
  for each row execute function app.bookings_turnaround_after();

-- A booking's own cleaning block never stands in its way (a later return, another car, a change).
create or replace function app.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz,
                                                    p_ignore_booking uuid default null)
returns boolean language plpgsql stable security definer set search_path = public, app as $$
declare
  v_buffer interval := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
begin
  if p_vehicle is null or p_from is null or p_to is null or p_to <= p_from then
    return false;
  end if;
  return not exists (
           select 1 from bookings b
            where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
              and (p_ignore_booking is null or b.id <> p_ignore_booking)
              and b.pickup_at - v_buffer < p_to and b.return_at + v_buffer > p_from)
     and not exists (
           select 1 from vehicle_calendar_blocks c
            where c.vehicle_id = p_vehicle and c.removed_at is null
              and (p_ignore_booking is null or c.booking_id is distinct from p_ignore_booking)
              and c.starts_at < p_to and (c.ends_at is null or c.ends_at > p_from));
end $$;

-- Staff remove a cleaning block (Admin, Fleet or customer service), with a reason.
create or replace function app.remove_turnaround_block(p_by uuid, p_block uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  k vehicle_calendar_blocks;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Only Fleet, customer service or an Admin removes a cleaning block' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for removing the block' using errcode = '22023'; end if;
  select * into k from vehicle_calendar_blocks where id = p_block for update;
  if k.id is null or k.removed_at is not null then raise exception 'That block is not there any more' using errcode = 'P0002'; end if;
  if k.source <> 'turnaround' then raise exception 'Only a cleaning block after a trip is removed here' using errcode = '22023'; end if;
  update vehicle_calendar_blocks set removed_at = now(), removed_by = p_by, removed_reason = btrim(p_reason) where id = k.id;
  return jsonb_build_object('id', k.id, 'removed', true);
end $$;

-- A vehicle's own cleaning time (empty: Program settings). Admin or Fleet. Its future blocks follow.
create or replace function app.set_vehicle_turnaround(p_by uuid, p_vehicle uuid, p_minutes integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'Only Fleet or an Admin sets a car''s cleaning time' using errcode = '42501';
  end if;
  if p_minutes is not null and (p_minutes < 0 or p_minutes > 2880) then
    raise exception 'Cleaning time is 0 to 2,880 minutes' using errcode = '22023';
  end if;
  update vehicles set turnaround_block_minutes = p_minutes where id = p_vehicle;
  if not found then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  for r in select id from bookings where vehicle_id = p_vehicle and status in ('confirmed', 'on_rent', 'returned') and return_at > now() - interval '2 days' loop
    perform app.sync_turnaround_block(r.id);
  end loop;
  return jsonb_build_object('vehicle_id', p_vehicle, 'turnaround_block_minutes', p_minutes, 'in_force', app.turnaround_minutes(p_vehicle));
end $$;

-- the blocks of the bookings already on the calendar
do $$
declare r record;
begin
  for r in select id from bookings where status in ('confirmed', 'on_rent') and blocks_calendar and return_at > now() - interval '1 day' order by pickup_at loop
    perform app.sync_turnaround_block(r.id);
  end loop;
end $$;

-- ================================================================ 5. the listing similarity check
-- A vehicle is compared with the other cars on file when it is added (VIN one character apart, the same plate,
-- the same year, make, model and colour), when a listing photo is uploaded (the same image, by SHA-256, on a car
-- that is listed) and when its copy is drafted or edited (word overlap with a listed car above the setting). A
-- likely duplicate is a flag: VIN, plate, photo and copy flags stop publishing until staff clear them; the same year,
-- make, model and colour (a fleet may hold twins) is shown to the reviewer and in Similar cars without stopping it.
create table listing_similarity_flags (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null references vehicles (id) on delete cascade,
  other_vehicle_id uuid not null references vehicles (id) on delete cascade,
  kind             text not null check (kind in ('vin', 'plate', 'photo', 'copy', 'specs')),
  score_bps        integer check (score_bps between 0 and 10000),
  blocking         boolean not null,
  detail           text not null,
  status           text not null default 'open' check (status in ('open', 'cleared', 'confirmed')),
  decided_by       uuid references users (id),
  decided_at       timestamptz,
  decision_note    text,
  first_seen_at    timestamptz not null default now(),
  last_seen_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (vehicle_id <> other_vehicle_id),
  check (status = 'open' or (decided_by is not null and decided_at is not null)),
  unique (vehicle_id, other_vehicle_id, kind)
);
create index listing_similarity_flags_open_idx on listing_similarity_flags (vehicle_id) where status = 'open';
create trigger listing_similarity_flags_updated before update on listing_similarity_flags for each row execute function app.set_updated_at();
comment on table listing_similarity_flags is 'A vehicle that looks like another car on file (VIN, plate, photo, copy or details), for staff to clear or confirm before it is published.';

alter table vehicle_photos add column content_sha256 text check (content_sha256 ~ '^[0-9a-f]{64}$');
create index vehicle_photos_sha_idx on vehicle_photos (content_sha256) where content_sha256 is not null;
comment on column vehicle_photos.content_sha256 is 'SHA-256 of the photo as uploaded: the same image on two cars is flagged (0040)';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('listing_similarity', 'fleet', 'A new car looks like one on file', 'high', 'business_days', 1, 17, 'flags_decided',
   'Compare the two cars and clear the flag (not a duplicate) or confirm it (the same car); a confirmed or open flag stops publishing'),
  ('owner_form_review', 'cs', 'Review a witnessed form', 'normal', 'business_days', 1, null, 'form_reviewed',
   'Check the signed and witnessed Form C or D: every part filled, signed, witnessed; approve it or send it back with a reason')
on conflict (task_type) do nothing;

create or replace function app.norm_plate(p text) returns text
language sql immutable as $$ select nullif(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

create or replace function app.vin_distance(a text, b text) returns integer
language sql immutable as $$
  select case when length(coalesce(a, '')) <> 17 or length(coalesce(b, '')) <> 17 then 99
              else (select count(*)::int from generate_series(1, 17) i where substr(upper(a), i, 1) <> substr(upper(b), i, 1)) end
$$;

-- A VIN whose check digit (position 9, as North American VINs carry) is right. Two VINs one character apart are
-- compared only when at least one of them is a real VIN: a typing slip of a real VIN is flagged, while placeholder
-- numbers on sample or imported records (SAMPLE01XXXXXXXXX, SAMPLE02XXXXXXXXX) are not. The same VIN always is.
create or replace function app.vin_check_ok(p text) returns boolean
language sql immutable as $$
  with v as (select upper(coalesce(p, '')) as s)
  select case when s !~ '^[A-HJ-NPR-Z0-9]{17}$' then false else
    (select case when m = 10 then 'X' else m::text end = substr(s, 9, 1)
       from (select (sum(case when c ~ '[0-9]' then c::int
                              else (array[1,2,3,4,5,6,7,8,0,1,2,3,4,5,0,7,0,9,2,3,4,5,6,7,8,9])[ascii(c) - 64] end
                         * (array[8,7,6,5,4,3,2,10,0,9,8,7,6,5,4,3,2])[i])) % 11 as m
               from generate_series(1, 17) i, lateral (select substr(s, i, 1) as c) x) t) end
  from v
$$;

create or replace function app.vin_near(a text, b text) returns boolean
language sql immutable as $$
  select case app.vin_distance(a, b) when 0 then true when 1 then app.vin_check_ok(a) or app.vin_check_ok(b) else false end
$$;

-- Three-word runs of a text (lower case, letters and digits), the unit copy is compared in.
create or replace function app.copy_shingles(p text) returns text[]
language sql immutable as $$
  with w as (
    select array_agg(t order by n) as a
      from regexp_split_to_table(btrim(lower(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]+', ' ', 'g'))), '\s+') with ordinality x(t, n)
     where t <> '')
  select coalesce((select array_agg(distinct w.a[i] || ' ' || w.a[i + 1] || ' ' || w.a[i + 2])
                     from generate_series(1, greatest(coalesce(array_length(w.a, 1), 0) - 2, 0)) i), '{}')
    from w
$$;

create or replace function app.jaccard_bps(a text[], b text[]) returns integer
language sql immutable as $$
  select case when cardinality(coalesce(a, '{}')) = 0 or cardinality(coalesce(b, '{}')) = 0 then 0
              else (10000 * (select count(*) from (select unnest(a) intersect select unnest(b)) i)
                    / (select count(*) from (select unnest(a) union select unnest(b)) u))::integer end
$$;

-- The copy a vehicle shows or will show: its listing text, or the latest draft while it has none.
create or replace function app.listing_copy(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select nullif(btrim(concat_ws(' ', coalesce(nullif(l.headline, ''), d.headline), coalesce(nullif(l.description, ''), d.description))), '')
    from (select 1) one
    left join vehicle_listings l on l.vehicle_id = p_vehicle
    left join lateral (select x.headline, x.description from listing_drafts x where x.vehicle_id = p_vehicle order by x.created_at desc limit 1) d on true
$$;

create or replace function app.similarity_flag(p_vehicle uuid, p_other uuid, p_kind text, p_score integer, p_blocking boolean, p_detail text)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  f listing_similarity_flags;
begin
  insert into listing_similarity_flags (vehicle_id, other_vehicle_id, kind, score_bps, blocking, detail)
  values (p_vehicle, p_other, p_kind, p_score, p_blocking, p_detail)
  on conflict (vehicle_id, other_vehicle_id, kind) do update
     set score_bps = excluded.score_bps, blocking = excluded.blocking, detail = excluded.detail, last_seen_at = now()
  returning * into f;
  if f.status = 'open' and f.blocking and f.first_seen_at = f.last_seen_at
     and coalesce(current_setting('app.similarity_quiet', true), '') <> 'on' then
    perform app.raise_task(p_type => 'listing_similarity', p_title => format('Possible duplicate: %s and %s', app.vehicle_name(p_vehicle), app.vehicle_name(p_other)),
        p_detail => p_detail, p_vehicle => p_vehicle, p_related_table => 'listing_similarity_flags', p_related_id => f.id,
        p_dedupe => 'listing_similarity:' || p_vehicle);
    perform app.ntf_emit('staff_listing_similarity', 'listing_similarity_flag', f.id, 'open',
      jsonb_build_object('vehicle_id', p_vehicle, 'owner_id', (select v.owner_id from vehicles v where v.id = p_vehicle)));
  end if;
  return f.id;
end $$;

-- Compare one vehicle with the cars on file. p_what: vehicle (VIN, plate, details), photo, copy, or all. Returns
-- the open flags that stop publishing.
create or replace function app.check_listing_similarity(p_vehicle uuid, p_what text default 'all') returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  o record;
  s program_settings := app.settings();
  v_mine text[];
  v_bps integer;
  n integer;
begin
  if not s.listing_similarity_enabled then return 0; end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or v.status in ('exited', 'total_loss', 'declined') then return 0; end if;
  if p_what in ('vehicle', 'all') then
    for o in select x.* from vehicles x
              where x.id <> v.id and x.status not in ('exited', 'total_loss', 'declined')
                and (app.vin_near(x.vin, v.vin)
                     or app.norm_plate(x.plate) = app.norm_plate(v.plate)
                     or (x.year = v.year and lower(x.make) = lower(v.make) and lower(x.model) = lower(v.model)
                         and lower(coalesce(x.colour, '')) = lower(coalesce(v.colour, '')) and coalesce(v.colour, '') <> '')) loop
      if app.vin_near(o.vin, v.vin) then
        perform app.similarity_flag(v.id, o.id, 'vin', 10000, true,
          case when app.vin_distance(o.vin, v.vin) = 0 then format('Same VIN %s as %s', v.vin, app.vehicle_name(o.id))
               else format('VIN %s is one character from %s (%s)', v.vin, o.vin, app.vehicle_name(o.id)) end);
      end if;
      if app.norm_plate(o.plate) = app.norm_plate(v.plate) then
        perform app.similarity_flag(v.id, o.id, 'plate', 10000, true, format('Same plate %s as %s', app.norm_plate(v.plate), app.vehicle_name(o.id)));
      end if;
      if o.year = v.year and lower(o.make) = lower(v.make) and lower(o.model) = lower(v.model)
         and lower(coalesce(o.colour, '')) = lower(coalesce(v.colour, '')) and coalesce(v.colour, '') <> '' then
        perform app.similarity_flag(v.id, o.id, 'specs', 8000, false,
          format('Same year, make, model and colour as %s, %s', app.vehicle_name(o.id),
                 case when o.owner_id = v.owner_id then 'the same owner' else 'another owner' end));
      end if;
    end loop;
  end if;
  if p_what in ('photo', 'all') then
    for o in select distinct x.vehicle_id as id
               from vehicle_photos mine join vehicle_photos x on x.content_sha256 = mine.content_sha256 and x.vehicle_id <> mine.vehicle_id
               join vehicle_listings l on l.vehicle_id = x.vehicle_id and l.status in ('published', 'paused')
              where mine.vehicle_id = v.id and mine.replaced_at is null and mine.status <> 'rejected' and mine.content_sha256 is not null
                and x.replaced_at is null and x.status <> 'rejected' loop
      perform app.similarity_flag(v.id, o.id, 'photo', 10000, true, format('A listing photo is the same image as one of %s', app.vehicle_name(o.id)));
    end loop;
  end if;
  if p_what in ('copy', 'all') then
    v_mine := app.copy_shingles(app.listing_copy(v.id));
    if cardinality(v_mine) >= 5 then
      -- twins (the same year, make and model) may share their copy: the canonical twin rule of 0022 handles them
      for o in select l.vehicle_id as id, app.copy_shingles(concat_ws(' ', l.headline, l.description)) as sh
                 from vehicle_listings l join vehicles x on x.id = l.vehicle_id
                where l.vehicle_id <> v.id and l.status in ('published', 'paused')
                  and (x.year, lower(x.make), lower(x.model)) is distinct from (v.year, lower(v.make), lower(v.model)) loop
        v_bps := app.jaccard_bps(v_mine, o.sh);
        if v_bps >= s.listing_similarity_copy_bps then
          perform app.similarity_flag(v.id, o.id, 'copy', v_bps, true,
            format('The copy is %s%% the same as the listing of %s', round(v_bps / 100.0), app.vehicle_name(o.id)));
        end if;
      end loop;
    end if;
  end if;
  select count(*) into n from listing_similarity_flags f where f.vehicle_id = v.id and f.status = 'open' and f.blocking;
  return n;
end $$;

create or replace function app.vehicles_similarity_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and (new.vin, new.plate, new.year, new.make, new.model, new.colour, new.owner_id)
                          is not distinct from (old.vin, old.plate, old.year, old.make, old.model, old.colour, old.owner_id) then
    return null;
  end if;
  perform app.check_listing_similarity(new.id, 'vehicle');
  return null;
end $$;
create trigger vehicles_similarity after insert or update of vin, plate, year, make, model, colour, owner_id on vehicles
  for each row execute function app.vehicles_similarity_after();

create or replace function app.photos_similarity_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.content_sha256 is not null and (tg_op = 'INSERT' or new.content_sha256 is distinct from old.content_sha256) then
    perform app.check_listing_similarity(new.vehicle_id, 'photo');
  end if;
  return null;
end $$;
create trigger vehicle_photos_similarity after insert or update of content_sha256 on vehicle_photos
  for each row execute function app.photos_similarity_after();

create or replace function app.drafts_similarity_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.check_listing_similarity(new.vehicle_id, 'copy');
  return null;
end $$;
create trigger listing_drafts_similarity after insert on listing_drafts for each row execute function app.drafts_similarity_after();

-- Staff decide a flag: cleared (not a duplicate) or confirmed (the same car: it stays blocked).
create or replace function app.decide_similarity(p_by uuid, p_flag uuid, p_decision text, p_note text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f listing_similarity_flags;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Only Fleet, customer service or an Admin decides a possible duplicate' using errcode = '42501';
  end if;
  if p_decision not in ('cleared', 'confirmed') then raise exception 'Clear the flag or confirm it' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say what you checked' using errcode = '22023'; end if;
  update listing_similarity_flags set status = p_decision, decided_by = p_by, decided_at = now(), decision_note = btrim(p_note)
   where id = p_flag returning * into f;
  if f.id is null then raise exception 'Flag not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from listing_similarity_flags x where x.vehicle_id = f.vehicle_id and x.status = 'open' and x.blocking) then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Possible duplicates decided'
     where task_type = 'listing_similarity' and vehicle_id = f.vehicle_id and status in ('open', 'in_progress', 'waiting');
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'similarity_' || p_decision, 'listing_similarity_flags', f.id::text, jsonb_build_object('kind', f.kind, 'note', f.decision_note));
  return to_jsonb(f);
end $$;

create or replace function app.vehicle_similarity(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object('vehicle_name', app.vehicle_name(f.vehicle_id), 'other_vehicle_name', app.vehicle_name(f.other_vehicle_id),
                    'other_plate', (select v.plate from vehicles v where v.id = f.other_vehicle_id),
                    'other_listing_status', (select l.status from vehicle_listings l where l.vehicle_id = f.other_vehicle_id),
                    'other_owner_name', (select o.legal_name from vehicles v join owners o on o.id = v.owner_id where v.id = f.other_vehicle_id),
                    'decided_by_name', (select u.full_name from users u where u.id = f.decided_by))
                  order by (f.status = 'open') desc, f.blocking desc, f.created_at desc), '[]'::jsonb)
    from listing_similarity_flags f where f.vehicle_id = p_vehicle
$$;

-- Publishing checks first: a listing with an open flag that stops publishing waits for staff. The copy is
-- compared again as it stands (the reviewer may have edited it).
alter function app.publish_listing(uuid, uuid) rename to publish_listing_0022;
create or replace function app.publish_listing(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f listing_similarity_flags;
begin
  if (app.settings()).listing_similarity_enabled then
    perform app.check_listing_similarity(p_vehicle, 'copy');
    select * into f from listing_similarity_flags x where x.vehicle_id = p_vehicle and x.status = 'open' and x.blocking order by x.created_at limit 1;
    if f.id is not null then
      raise exception 'Possible duplicate: %. Clear or confirm it under Similar cars first', f.detail using errcode = '23514';
    end if;
    if exists (select 1 from listing_similarity_flags x where x.vehicle_id = p_vehicle and x.status = 'confirmed' and x.blocking) then
      raise exception 'Staff confirmed this car is a duplicate of another listing: it is not published' using errcode = '23514';
    end if;
  end if;
  return app.publish_listing_0022(p_vehicle, p_by);
end $$;

-- The fingerprint of an uploaded listing photo, recorded with the upload.
alter function app.record_listing_upload(uuid, uuid, jsonb) rename to record_listing_upload_0022;
create or replace function app.record_listing_upload(p_by uuid, p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.record_listing_upload_0022(p_by, p_intake, p);
begin
  if lower(coalesce(p ->> 'sha256', '')) ~ '^[0-9a-f]{64}$' then
    update vehicle_photos set content_sha256 = lower(p ->> 'sha256') where id = (v_out ->> 'photo_id')::uuid;
    v_out := v_out || jsonb_build_object('similar', (select count(*) from listing_similarity_flags f
                                                       where f.vehicle_id = (select vehicle_id from vehicle_photos where id = (v_out ->> 'photo_id')::uuid)
                                                         and f.status = 'open' and f.blocking));
  end if;
  return v_out;
end $$;

-- the cars already on file are compared once (flags only; nothing is unpublished)
do $$
declare r record;
begin
  perform set_config('app.similarity_quiet', 'on', true);
  for r in select id from vehicles where status not in ('exited', 'total_loss', 'declined') order by created_at loop
    perform app.check_listing_similarity(r.id, 'vehicle');
  end loop;
  perform set_config('app.similarity_quiet', '', true);
end $$;

-- ================================================================ 6. earlier requests on a new sign-in, once its email is verified
-- A booking request made without an account keeps its records under the email address (0019). When a sign-in for
-- that address proves the address (the confirmation link, an invitation or password link, or a sign-in the
-- service allows only to confirmed addresses), what was made with it is attached: the renter record and its
-- requests and bookings, and the person's place as an additional driver on someone else's booking. Nothing is
-- attached to an address that is not verified. The renter portal lists what was added.
alter table users add column email_verified_at timestamptz;
comment on column users.email_verified_at is 'When the sign-in service confirmed the person controls this address; earlier records are attached only after it';

create table account_links (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  kind       text not null check (kind in ('renter_record', 'booking', 'driver', 'needs_staff')),
  entity_id  uuid not null,
  detail     text,
  linked_at  timestamptz not null default now(),
  seen_at    timestamptz,
  unique (user_id, kind, entity_id)
);
create index account_links_user_idx on account_links (user_id, linked_at desc);
alter table account_links enable row level security;
create policy admin_all on account_links for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on account_links for select to authenticated using (user_id = app.uid());
comment on table account_links is 'What was attached to a sign-in when its email address was verified (earlier requests, bookings, additional driver places).';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('account_link_review', 'cs', 'Two renter records for one email address', 'normal', 'business_days', 1, 1, 'records_merged',
   'A verified sign-in has its own renter record and an older one with the same email: check they are the same person and move the bookings by hand')
on conflict (task_type) do nothing;

create or replace function app.account_link_earlier(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
  r renters;
  x renters;
  d record;
  bk record;
  v_new integer := 0;
  v_bookings integer := 0;
  v_drivers integer := 0;
  v_staff integer := 0;
begin
  select * into u from users where id = p_user for update;
  if u.id is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  if u.email_verified_at is null then
    raise exception 'Confirm your email address first: earlier requests are added once it is confirmed' using errcode = '42501';
  end if;
  select * into r from renters where user_id = u.id;
  -- renter records under this address with no sign-in
  for x in select * from renters where user_id is null and lower(btrim(email)) = lower(btrim(u.email)) order by created_at loop
    if r.id is null then
      update renters set user_id = u.id where id = x.id returning * into r;
      insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'renter_record', x.id, x.legal_name) on conflict do nothing;
      update drivers set user_id = u.id where renter_id = x.id and is_account_holder and user_id is null;
      v_new := v_new + 1;
    else
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'needs_staff', x.id, x.legal_name) on conflict do nothing;
      if found then
        perform app.raise_task(p_type => 'account_link_review', p_title => format('Two renter records for %s', u.email),
            p_detail => format('The sign-in %s (renter %s) and an earlier record %s (%s) share the address. Move the bookings by hand if they are the same person.',
                               u.email, r.legal_name, x.legal_name, x.id),
            p_renter => x.id, p_related_table => 'renters', p_related_id => x.id, p_dedupe => 'account_link_review:' || x.id);
        v_staff := v_staff + 1;
      end if;
    end if;
  end loop;
  -- the requests and bookings of this person's renter record made before the address was verified
  if r.id is not null then
    for bk in select b.id, b.booking_number from bookings b where b.renter_id = r.id and b.created_at <= u.email_verified_at loop
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'booking', bk.id, bk.booking_number) on conflict do nothing;
      if found then v_bookings := v_bookings + 1; end if;
    end loop;
  end if;
  -- an additional driver's place on someone else's booking
  for d in select dr.id, dr.full_name from drivers dr
            where dr.user_id is null and not dr.is_account_holder and lower(btrim(dr.email)) = lower(btrim(u.email)) loop
    update drivers set user_id = u.id where id = d.id;
    update rental_agreement_signers set user_id = u.id where driver_id = d.id and user_id is null and signer_role = 'additional_driver';
    insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'driver', d.id, d.full_name) on conflict do nothing;
    v_drivers := v_drivers + 1;
  end loop;
  return jsonb_build_object('user_id', u.id, 'renter_records', v_new, 'bookings', v_bookings, 'drivers', v_drivers, 'needs_staff', v_staff);
end $$;

-- The sign-in service confirmed the address (p_email is the address it confirmed). Anything else is ignored.
create or replace function app.account_email_verified(p_user uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', false, 'reason', 'no_record'); end if;
  if lower(btrim(coalesce(p_email, ''))) <> lower(btrim(u.email)) then return jsonb_build_object('ok', false, 'reason', 'email_mismatch'); end if;
  update users set email_verified_at = coalesce(email_verified_at, now()) where id = u.id;
  return jsonb_build_object('ok', true) || app.account_link_earlier(u.id);
end $$;

-- The renter portal: what was added and not yet acknowledged.
create or replace function app.my_account_links(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'verified', (select u.email_verified_at is not null from users u where u.id = p_user),
    'new', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'detail', l.detail, 'linked_at', l.linked_at,
                                                         'booking_number', case when l.kind = 'booking' then l.detail end) order by l.linked_at, l.detail)
                       from account_links l where l.user_id = p_user and l.seen_at is null and l.kind in ('booking', 'driver')), '[]'::jsonb),
    'driver_trips', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
                                                                  'return_at', b.return_at, 'vehicle_name', app.vehicle_name(b.vehicle_id),
                                                                  'accepted', bd.accepted_at is not null) order by b.pickup_at desc)
                                from drivers dr join booking_drivers bd on bd.driver_id = dr.id join bookings b on b.id = bd.booking_id
                               where dr.user_id = p_user and not dr.is_account_holder and b.status not in ('declined', 'expired')), '[]'::jsonb))
$$;

create or replace function app.seen_account_links(p_user uuid) returns integer
language sql security definer set search_path = public, app as $$
  with u as (update account_links set seen_at = now() where user_id = p_user and seen_at is null returning 1) select count(*)::integer from u
$$;

-- ================================================================ 7. the additional driver's signing link
-- The link names the driver's signer row and a version; it is valid until link_expires_at. Making a new link (the
-- renter or staff, "Send a new link") raises the version, so every earlier link stops working. The server signs the
-- token (LINK_SIGNING_KEY) and hands the URL to app.driver_link_send, which emails it to the driver.
alter table rental_agreement_signers
  add column link_version integer not null default 1 check (link_version >= 1),
  add column link_expires_at timestamptz,
  add column link_sent_at timestamptz,
  add column link_sent_count integer not null default 0,
  add column link_sent_by uuid references users (id);

create or replace function app.driver_signer_link_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.signer_role = 'additional_driver' and new.link_expires_at is null then
    new.link_expires_at := now() + make_interval(hours => (app.settings()).booking_driver_link_hours);
  end if;
  return new;
end $$;
create trigger rental_agreement_signers_link before insert on rental_agreement_signers
  for each row execute function app.driver_signer_link_default();
update rental_agreement_signers set link_expires_at = now() + make_interval(hours => (app.settings()).booking_driver_link_hours)
 where signer_role = 'additional_driver' and signed_at is null and link_expires_at is null;

-- Who may make a new link: the renter of the booking, customer service or an Admin.
create or replace function app.driver_link_check(p_signer uuid, p_by uuid) returns rental_agreement_signers
language plpgsql stable security definer set search_path = public, app as $$
declare
  g rental_agreement_signers;
  a rental_agreements;
  b bookings;
begin
  select * into g from rental_agreement_signers where id = p_signer;
  if g.id is null or g.signer_role <> 'additional_driver' then raise exception 'Driver not found' using errcode = 'P0002'; end if;
  select * into a from rental_agreements where id = g.agreement_id;
  select * into b from bookings where id = a.booking_id;
  if p_by is null or not (app.is_booking_renter(b.id, p_by) or app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only the renter, customer service or an Admin sends the driver''s link' using errcode = '42501';
  end if;
  if g.signed_at is not null then raise exception '% has already accepted the agreement', g.signer_name using errcode = '23514'; end if;
  if a.status = 'voided' or b.status not in ('pending_payment', 'confirmed') then
    raise exception 'This agreement is not open for signing' using errcode = '23514';
  end if;
  return g;
end $$;

-- A new link: the version goes up (earlier links stop working) and it is valid for the set hours.
create or replace function app.driver_link_renew(p_signer uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g rental_agreement_signers := app.driver_link_check(p_signer, p_by);
begin
  update rental_agreement_signers
     set link_version = link_version + 1, link_expires_at = now() + make_interval(hours => (app.settings()).booking_driver_link_hours)
   where id = g.id returning * into g;
  return jsonb_build_object('signer_id', g.id, 'version', g.link_version, 'expires_at', g.link_expires_at, 'email', g.signer_email, 'name', g.signer_name);
end $$;

-- Email the link the server signed for this version.
create or replace function app.driver_link_send(p_signer uuid, p_by uuid, p_version integer, p_url text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g rental_agreement_signers := app.driver_link_check(p_signer, p_by);
  b bookings;
begin
  if p_version is distinct from g.link_version then raise exception 'A newer link was made: send that one' using errcode = '23514'; end if;
  if g.link_expires_at <= now() then raise exception 'This link has expired: make a new one' using errcode = '23514'; end if;
  if nullif(btrim(coalesce(g.signer_email, '')), '') is null then
    raise exception 'We have no email address for %. Copy the link and send it yourself', g.signer_name using errcode = '22023';
  end if;
  if coalesce(p_url, '') !~ '^https?://[^ ]+/sign/driver/[A-Za-z0-9_.-]+$' then raise exception 'The link is not a signing link' using errcode = '22023'; end if;
  select b2.* into b from bookings b2 join rental_agreements a on a.booking_id = b2.id where a.id = g.agreement_id;
  update rental_agreement_signers set link_sent_at = now(), link_sent_count = link_sent_count + 1, link_sent_by = p_by where id = g.id;
  perform app.ntf_emit('renter_driver_link', 'rental_agreement_signer', g.id, 'v' || g.link_version,
    jsonb_build_object('booking_id', b.id, 'signer_email', g.signer_email, 'signer_name', g.signer_name, 'signer_user_id', g.user_id,
                       'sign_url', p_url, 'link_expires', app.fmt_at(g.link_expires_at), 'owner_id', b.owner_id));
  return jsonb_build_object('signer_id', g.id, 'sent_to', g.signer_email, 'version', g.link_version, 'expires_at', g.link_expires_at);
end $$;

-- What the signing page needs to accept a token: its version is the current one and it has not expired. A token
-- made before versions (no v) counts as version 1.
create or replace function app.driver_link_valid(p_signer uuid, p_version integer) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from rental_agreement_signers g
                  where g.id = p_signer and g.signer_role = 'additional_driver'
                    and g.link_version = coalesce(p_version, 1) and coalesce(g.link_expires_at, 'infinity') > now())
$$;

-- The links of a booking's drivers, for the renter's page and the staff booking screen.
create or replace function app.booking_driver_links(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('signer_id', g.id, 'name', g.signer_name, 'email', g.signer_email, 'booking_driver_id', g.booking_driver_id,
                    'signed_at', g.signed_at, 'version', g.link_version, 'expires_at', g.link_expires_at,
                    'expired', coalesce(g.link_expires_at, 'infinity') <= now(), 'sent_at', g.link_sent_at, 'sent_count', g.link_sent_count)
                  order by g.created_at), '[]'::jsonb)
    from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
   where a.booking_id = p_booking and a.status <> 'voided' and g.signer_role = 'additional_driver'
$$;

-- ================================================================ 8. Forms C and D: signed on paper, uploaded, reviewed
-- Form C (lender or lessor permission acknowledgment) is needed for each financed or leased vehicle; Form D Part 1
-- (limited power of attorney, two witnesses) once per owner with a vehicle under the Title Agreement (anything but
-- Turo-Only). The owner downloads the pre-filled form, signs it with the witnesses and uploads a photo or scan;
-- staff approve it or send it back with a reason. 0002's owner_agreement_forms keeps each upload.
alter table owner_agreement_forms alter column owner_agreement_id drop not null;
alter table owner_agreement_forms
  add column owner_id     uuid references owners (id),
  add column status       text not null default 'uploaded' check (status in ('uploaded', 'approved', 'rejected', 'replaced')),
  add column uploaded_by  uuid references users (id),
  add column uploaded_at  timestamptz not null default now(),
  add column reviewed_by  uuid references users (id),
  add column reviewed_at  timestamptz,
  add column reject_reason text,
  add column updated_at   timestamptz not null default now(),
  add constraint owner_agreement_forms_rejected_reason check (status <> 'rejected' or nullif(btrim(reject_reason), '') is not null),
  add constraint owner_agreement_forms_reviewed check (status not in ('approved', 'rejected') or (reviewed_by is not null and reviewed_at is not null));
update owner_agreement_forms f set owner_id = a.owner_id from owner_agreements a where a.id = f.owner_agreement_id and f.owner_id is null;
create index owner_agreement_forms_owner_idx on owner_agreement_forms (owner_id, form_code, status);
create unique index owner_agreement_forms_one_live on owner_agreement_forms (owner_id, form_code, coalesce(vehicle_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('uploaded', 'approved') and form_code in ('C', 'D1');
create trigger owner_agreement_forms_updated before update on owner_agreement_forms for each row execute function app.set_updated_at();
do $$ begin perform app.attach_audit(); end $$;

-- What an owner needs, with the status of each: one Form D, and one Form C per financed or leased vehicle.
create or replace function app.owner_witnessed_forms(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with need as (
    select 'D1'::text as code, null::uuid as vehicle_id, 0 as ord
     where exists (select 1 from vehicles v where v.owner_id = p_owner and v.management_mode <> 'turo_only'
                      and v.status not in ('exited', 'declined', 'total_loss'))
    union all
    select 'C', v.id, 1 from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
     where v.owner_id = p_owner and s.title_status in ('financed', 'leased') and v.status not in ('exited', 'declined', 'total_loss')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'code', n.code, 'vehicle_id', n.vehicle_id, 'vehicle_name', case when n.vehicle_id is not null then app.vehicle_name(n.vehicle_id) end,
      'title', case n.code when 'C' then 'Form C, lender or lessor permission acknowledgment' else 'Form D, limited power of attorney' end,
      'witnesses', case n.code when 'C' then 1 else 2 end,
      'status', coalesce(f.status, case when r.id is not null then 'rejected' else 'needed' end),
      'form_id', coalesce(f.id, r.id), 'document_id', coalesce(f.document_id, r.document_id), 'uploaded_at', coalesce(f.uploaded_at, r.uploaded_at),
      'reviewed_at', coalesce(f.reviewed_at, r.reviewed_at), 'reject_reason', case when f.id is null then r.reject_reason end,
      'witness_1_name', coalesce(f.witness_1_name, r.witness_1_name), 'witness_2_name', coalesce(f.witness_2_name, r.witness_2_name))
      order by n.ord, app.vehicle_name(n.vehicle_id)), '[]'::jsonb)
    from need n
    left join lateral (select * from owner_agreement_forms x where x.owner_id = p_owner and x.form_code = n.code
                          and x.vehicle_id is not distinct from n.vehicle_id and x.status in ('uploaded', 'approved')
                        order by x.uploaded_at desc limit 1) f on true
    left join lateral (select * from owner_agreement_forms x where x.owner_id = p_owner and x.form_code = n.code
                          and x.vehicle_id is not distinct from n.vehicle_id and x.status = 'rejected'
                        order by x.reviewed_at desc limit 1) r on true
$$;

-- The owner uploads a signed form (the file is already stored and checked by the server).
create or replace function app.owner_upload_witnessed_form(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_owner uuid := app.portal_owner_id(p_by);
  v_code text := p_ ->> 'code';
  v_vehicle uuid := nullif(p_ ->> 'vehicle_id', '')::uuid;
  v_doc uuid;
  v_id uuid;
  v_agreement uuid;
  v_w1 text := nullif(btrim(coalesce(p_ ->> 'witness_1_name', '')), '');
  v_w2 text := nullif(btrim(coalesce(p_ ->> 'witness_2_name', '')), '');
begin
  if v_owner is null then raise exception 'This account is not an owner account' using errcode = '42501'; end if;
  if v_code not in ('C', 'D1') then raise exception 'Choose Form C or Form D' using errcode = '22023'; end if;
  if not exists (select 1 from jsonb_array_elements(app.owner_witnessed_forms(v_owner)) x
                  where x ->> 'code' = v_code and (x ->> 'vehicle_id')::uuid is not distinct from v_vehicle) then
    raise exception 'That form is not needed for your account' using errcode = '22023';
  end if;
  if v_w1 is null or (v_code = 'D1' and v_w2 is null) then
    raise exception '%', case when v_code = 'D1' then 'Give the names of both witnesses' else 'Give the name of the witness' end using errcode = '22023';
  end if;
  if lower(coalesce(p_ ->> 'sha256', '')) !~ '^[0-9a-f]{64}$' or nullif(btrim(coalesce(p_ ->> 'path', '')), '') is null then
    raise exception 'The file is missing' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id, vehicle_id, uploaded_by)
  values (case when v_code = 'C' then 'form_c_finance_permission_ack' else 'form_d_power_of_attorney' end::document_kind,
          case when v_code = 'C' then 'Form C, signed' || coalesce(', ' || app.vehicle_name(v_vehicle), '') else 'Form D, signed' end,
          'documents', btrim(p_ ->> 'path'), p_ ->> 'mime', lower(p_ ->> 'sha256'), v_owner, v_vehicle, p_by)
  returning id into v_doc;
  update owner_agreement_forms set status = 'replaced'
   where owner_id = v_owner and form_code = v_code and vehicle_id is not distinct from v_vehicle and status = 'uploaded';
  if exists (select 1 from owner_agreement_forms where owner_id = v_owner and form_code = v_code and vehicle_id is not distinct from v_vehicle and status = 'approved') then
    raise exception 'This form is already approved' using errcode = '23514';
  end if;
  select id into v_agreement from owner_agreements where owner_id = v_owner and kind = 'title_holding' and status <> 'void' order by created_at desc limit 1;
  insert into owner_agreement_forms (owner_agreement_id, owner_id, form_code, vehicle_id, document_id, witness_1_name, witness_2_name, status, uploaded_by,
                                     finance_permission, ack_read_warning_at, ack_no_advice_at, ack_bears_consequences_at, signed_at)
  values (v_agreement, v_owner, v_code, v_vehicle, v_doc, v_w1, v_w2, 'uploaded', p_by,
          case when v_code = 'C' then (select s.finance_permission from vehicle_schedules s where s.vehicle_id = v_vehicle and s.superseded_by is null) end,
          case when v_code = 'C' then now() end, case when v_code = 'C' then now() end, case when v_code = 'C' then now() end, now())
  returning id into v_id;
  perform app.raise_task(p_type => 'owner_form_review',
      p_title => format('Review %s from %s', case when v_code = 'C' then 'Form C' else 'Form D' end, (select legal_name from owners where id = v_owner)),
      p_owner => v_owner, p_vehicle => v_vehicle, p_related_table => 'owner_agreement_forms', p_related_id => v_id,
      p_dedupe => 'owner_form_review:' || v_id);
  perform app.ntf_emit('staff_owner_form_uploaded', 'owner_agreement_form', v_id, 'uploaded',
    jsonb_build_object('owner_id', v_owner, 'vehicle_id', v_vehicle));
  return jsonb_build_object('id', v_id, 'document_id', v_doc, 'status', 'uploaded');
end $$;

-- Staff approve a form or send it back with the reason the owner reads. Customer service or an Admin.
create or replace function app.review_witnessed_form(p_by uuid, p_form uuid, p_approve boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f owner_agreement_forms;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only customer service or an Admin reviews a witnessed form' using errcode = '42501';
  end if;
  select * into f from owner_agreement_forms where id = p_form for update;
  if f.id is null or f.form_code not in ('C', 'D1') then raise exception 'Form not found' using errcode = 'P0002'; end if;
  if f.status <> 'uploaded' then raise exception 'This form is % and is not waiting for review', f.status using errcode = '23514'; end if;
  if not p_approve and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Tell the owner what to fix' using errcode = '22023';
  end if;
  update owner_agreement_forms
     set status = case when p_approve then 'approved' else 'rejected' end, reviewed_by = p_by, reviewed_at = now(),
         reject_reason = case when p_approve then null else left(btrim(p_reason), 1000) end
   where id = f.id returning * into f;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = case when p_approve then 'Approved' else 'Sent back' end
   where task_type = 'owner_form_review' and related_id = f.id and status in ('open', 'in_progress', 'waiting');
  perform app.ntf_emit(case when p_approve then 'owner_form_approved' else 'owner_form_rejected' end, 'owner_agreement_form', f.id, f.status,
    jsonb_build_object('owner_id', f.owner_id, 'vehicle_id', f.vehicle_id));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'witnessed_form_' || f.status, 'owner_agreement_forms', f.id::text, jsonb_build_object('form_code', f.form_code, 'reason', f.reject_reason));
  return to_jsonb(f);
end $$;

-- The review queue: forms waiting, and the latest decided.
create or replace function app.witnessed_forms_queue() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'code', f.form_code, 'status', f.status, 'owner_id', f.owner_id, 'owner_name', o.legal_name,
                    'vehicle_id', f.vehicle_id, 'vehicle_name', case when f.vehicle_id is not null then app.vehicle_name(f.vehicle_id) end,
                    'document_id', f.document_id, 'witness_1_name', f.witness_1_name, 'witness_2_name', f.witness_2_name,
                    'uploaded_at', f.uploaded_at, 'reviewed_at', f.reviewed_at, 'reject_reason', f.reject_reason,
                    'reviewed_by_name', (select u.full_name from users u where u.id = f.reviewed_by))
                  order by (f.status = 'uploaded') desc, f.uploaded_at desc), '[]'::jsonb)
    from (select * from owner_agreement_forms x where x.form_code in ('C', 'D1') and x.status in ('uploaded', 'approved', 'rejected')
           order by (x.status = 'uploaded') desc, x.uploaded_at desc limit 200) f
    join owners o on o.id = f.owner_id
$$;

-- The pre-filled form's facts (the server renders the PDF): the owner, the vehicles it covers, the company.
create or replace function app.witnessed_form_facts(p_owner uuid, p_code text, p_vehicle uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'code', p_code,
    'owner', jsonb_build_object('legal_name', o.legal_name, 'owner_type', o.owner_type, 'address', concat_ws(', ', nullif(o.address_line1, ''), nullif(o.city, ''), nullif(o.province, ''), nullif(o.postal_code, ''))),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate,
                                  'finance_party', s.finance_party_name, 'finance_account', s.finance_party_account,
                                  'permission', s.finance_permission, 'title_status', s.title_status) order by v.created_at, v.created_seq)
                            from vehicles v left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
                           where v.owner_id = o.id and v.status not in ('exited', 'declined', 'total_loss') and v.management_mode <> 'turo_only'
                             and (p_code <> 'C' or (v.id = p_vehicle and s.title_status in ('financed', 'leased')))), '[]'::jsonb),
    'title_agreement', (select a.agreement_number from owner_agreements a where a.owner_id = o.id and a.kind = 'title_holding' and a.status <> 'void' order by a.created_at desc limit 1),
    'company', app.doc_company_brand())
    from owners o where o.id = p_owner
$$;

-- The owner's onboarding checklist gains "Witnessed forms" (0022's list, one more item at the end of the paperwork).
alter table onboarding_checklist_items drop constraint onboarding_checklist_items_code_check;
alter table onboarding_checklist_items add constraint onboarding_checklist_items_code_check check (code in ('owner_details', 'documents', 'government_forms',
  'signatures', 'witnessed_forms', 'upfront_payment', 'tracker_install', 'registry_visit', 'insurer_confirmation', 'photos', 'listing'));
update onboarding_checklist_items set sort_order = sort_order + 1
 where sort_order > (select sort_order from onboarding_checklist_items where code = 'signatures')
   and not exists (select 1 from onboarding_checklist_items where code = 'witnessed_forms');
insert into onboarding_checklist_items (code, label, sort_order, waits_on, owner_action, staff_action, is_active)
select 'witnessed_forms', 'Forms C and D signed with witnesses', coalesce((select sort_order from onboarding_checklist_items where code = 'signatures'), 4) + 1,
       'owner', 'Download Forms C and D, sign them with your witnesses, and upload them', 'Review the uploaded forms', true
 where not exists (select 1 from onboarding_checklist_items where code = 'witnessed_forms');

alter function app.onboarding_checklist(uuid) rename to onboarding_checklist_0022;
create or replace function app.onboarding_checklist(p_vehicle uuid)
returns table (code text, label text, sort_order integer, status text, waits_on text, next_action text, owner_action text, staff_action text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  f jsonb;
  v_mine jsonb;
  v_status text;
  v_wait text;
  v_next text;
begin
  select * into v from vehicles where id = p_vehicle;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  for code, label, sort_order, status, waits_on, next_action, owner_action, staff_action in
    select * from app.onboarding_checklist_0022(p_vehicle) c loop
    if code = 'witnessed_forms' then
      select coalesce(jsonb_agg(x), '[]'::jsonb) into v_mine from jsonb_array_elements(app.owner_witnessed_forms(v.owner_id)) x
       where x ->> 'code' = 'D1' or (x ->> 'vehicle_id')::uuid = v.id;
      if v.management_mode = 'turo_only' or jsonb_array_length(v_mine) = 0 then
        v_status := 'not_applicable'; v_wait := null; v_next := null;
      elsif not exists (select 1 from jsonb_array_elements(v_mine) x where x ->> 'status' <> 'approved') then
        v_status := 'done'; v_wait := null; v_next := null;
      else
        v_status := 'open';
        if exists (select 1 from jsonb_array_elements(v_mine) x where x ->> 'status' in ('needed', 'rejected')) then
          v_wait := 'owner';
          v_next := 'Upload ' || (select string_agg(case x ->> 'code' when 'C' then 'Form C' else 'Form D' end || case when x ->> 'status' = 'rejected' then ' again' else '' end, ' and ')
                                    from jsonb_array_elements(v_mine) x where x ->> 'status' in ('needed', 'rejected'));
        else
          v_wait := 'carmacars'; v_next := 'Review the uploaded forms';
        end if;
      end if;
      if ob.checklist_marks ? 'witnessed_forms' then v_status := ob.checklist_marks -> 'witnessed_forms' ->> 'status'; end if;
      if ob.status in ('declined', 'withdrawn') and v_status = 'open' then v_status := 'not_applicable'; end if;
      status := v_status; waits_on := case when v_status = 'open' then v_wait end; next_action := case when v_status = 'open' then v_next end;
    end if;
    return next;
  end loop;
end $$;

-- ================================================================ 9. emails: who, what
-- An additional driver signs through their own link (section 7), which the driver link email carries; the
-- "agreement ready" email and its reminders, whose button opens the renter portal, now go to the renter only.
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_0037;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  e app_events := p_event;
begin
  if p_c.code = 'renter_agreement_ready' then
    if coalesce(e.payload ->> 'signer_role', '') = 'additional_driver' then return; end if;
    if jsonb_typeof(e.payload -> 'signers') = 'array' then
      e.payload := jsonb_set(e.payload, '{signers}', coalesce((select jsonb_agg(g) from jsonb_array_elements(e.payload -> 'signers') g
                                                               where coalesce(g ->> 'signer_role', '') <> 'additional_driver'), '[]'::jsonb));
    end if;
  end if;
  return query select * from app.notification_recipients_0037(e, p_c);
end $$;

-- The merge values of the new emails.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0037;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0037(p_code, p_event, p_to);
  c booking_change_requests;
  b bookings;
  am booking_amendments;
  f listing_similarity_flags;
  fm owner_agreement_forms;
  pm payment_methods;
  rf refunds;
  v_share integer;
  v_owner uuid;
  v_before bigint;
  v_after bigint;
  v_rows jsonb;
begin
  if p_code in ('renter_change_proposed', 'renter_change_proposal_reminder', 'renter_change_proposal_expired', 'renter_change_applied',
                'owner_booking_changed', 'staff_change_proposal_answered') then
    select * into c from booking_change_requests where id = p_event.entity_id;
    select * into b from bookings where id = c.booking_id;
    v_rows := app.change_rows(b.id, to_jsonb(c));
    x := x || jsonb_build_object(
      'booking_number', b.booking_number,
      'change_rows', v_rows,
      'change_reason', coalesce(nullif(btrim(c.note), ''), 'We need to change your booking.'),
      'accept_by', coalesce(app.fmt_at(c.accept_by), 'before your pickup'),
      'has_difference', coalesce(c.total_difference_cents, 0) <> 0,
      'difference_label', case when coalesce(c.total_difference_cents, 0) > 0 then 'Extra to pay' when coalesce(c.total_difference_cents, 0) < 0 then 'Back to you' else 'No change to the price' end,
      'difference_amount', app.fmt_money(abs(coalesce(c.total_difference_cents, 0))),
      'total_amount', app.fmt_money(coalesce((c.after ->> 'total_cents')::bigint, b.total_due_at_booking_cents)),
      'renter_name', (select r.legal_name from renters r where r.id = b.renter_id),
      '_url', app.ntf_link(case when p_code like 'owner_%' then 'owner_booking' when p_code like 'staff_%' then 'va_cs_booking'
                               when p_code = 'renter_change_applied' then 'booking' else 'booking_change' end,
                          jsonb_build_object('booking_number', b.booking_number)));
    if p_code = 'renter_change_applied' then
      select * into am from booking_amendments where change_request_id = c.id and status in ('signed', 'recorded') order by created_at desc limit 1;
      select * into pm from payment_methods where id = b.card_on_file_id;
      select * into rf from refunds where id = c.refund_id;
      x := x || jsonb_build_object(
        'amendment_number', coalesce(am.amendment_number, b.booking_number),
        'has_amendment_pdf', coalesce(am.status = 'signed', false),
        'money_text', case when coalesce(c.total_difference_cents, 0) > 0
                           then format('We charged %s to your card ending %s.', app.fmt_money(c.total_difference_cents), coalesce(pm.card_last4, '----'))
                           when coalesce(c.total_difference_cents, 0) < 0
                           then format('%s goes back to your card. Refunds reach your account 5 to 10 business days after we send them.', app.fmt_money(-c.total_difference_cents))
                           else 'The price of your booking stays the same.' end);
    elsif p_code = 'owner_booking_changed' then
      v_owner := (p_event.payload ->> 'owner_id')::uuid;
      v_share := coalesce(b.company_share_bps, 0);
      v_before := case when (select v.owner_id from vehicles v where v.id = (c.before ->> 'vehicle_id')::uuid) = v_owner
                       then (c.before ->> 'rental_charge_cents')::bigint * (10000 - v_share) / 10000 else 0 end;
      v_after := case when (select v.owner_id from vehicles v where v.id = coalesce((c.after ->> 'vehicle_id')::uuid, (c.before ->> 'vehicle_id')::uuid)) = v_owner
                      then (c.after ->> 'rental_charge_cents')::bigint * (10000 - v_share) / 10000 else 0 end;
      x := x || jsonb_build_object(
        'owner_change_text', case p_event.payload ->> 'owner_side'
                               when 'out' then format('Booking %s moved from your %s to another car. It no longer earns for your car.', b.booking_number, app.vehicle_name((c.before ->> 'vehicle_id')::uuid))
                               when 'in' then format('Booking %s moved to your %s.', b.booking_number, app.vehicle_name((c.after ->> 'vehicle_id')::uuid))
                               else format('The renter of booking %s accepted new details for your %s.', b.booking_number, app.vehicle_name(b.vehicle_id)) end,
        'income_before', app.fmt_money(v_before), 'income_after', app.fmt_money(v_after),
        'income_changed', v_before <> v_after,
        'renter_name', '');
    elsif p_code = 'staff_change_proposal_answered' then
      x := x || jsonb_build_object(
        'outcome_title', case p_event.payload ->> 'outcome' when 'accepted' then 'accepted' when 'declined' then 'declined' else 'did not answer' end,
        'outcome_detail', case p_event.payload ->> 'outcome'
                            when 'accepted' then 'The renter signed the amendment and the booking now has the new details.'
                            when 'declined' then coalesce(c.decline_reason, 'Declined by the renter') || '. The booking stays as it was.'
                            else 'The time to accept passed. The booking stays as it was: call the renter if the change is still needed.' end);
    end if;
  elsif p_code = 'renter_driver_link' then
    x := x || jsonb_build_object('sign_url', p_event.payload ->> 'sign_url', 'link_expires', p_event.payload ->> 'link_expires',
                                 'first_name', split_part(btrim(coalesce(p_event.payload ->> 'signer_name', p_to ->> 'name', 'there')), ' ', 1));
  elsif p_code = 'staff_listing_similarity' then
    select * into f from listing_similarity_flags where id = p_event.entity_id;
    x := x || jsonb_build_object('vehicle_name', app.vehicle_name(f.vehicle_id), 'other_vehicle_name', app.vehicle_name(f.other_vehicle_id),
                                 'flag_detail', f.detail,
                                 'flag_kind', case f.kind when 'vin' then 'Almost the same VIN' when 'plate' then 'Same plate' when 'photo' then 'Same photo'
                                                          when 'copy' then 'Very similar listing text' else 'Same year, make, model and colour' end);
  elsif p_code in ('staff_owner_form_uploaded', 'owner_form_approved', 'owner_form_rejected') then
    select * into fm from owner_agreement_forms where id = p_event.entity_id;
    x := x || jsonb_build_object(
      'form_title', case fm.form_code when 'C' then 'Form C, lender or lessor permission acknowledgment' else 'Form D, limited power of attorney' end,
      'vehicle_line', case when fm.vehicle_id is not null then 'For your ' || app.vehicle_name(fm.vehicle_id) else 'Covers every car you have with us' end,
      'witness_names', concat_ws(' and ', fm.witness_1_name, fm.witness_2_name),
      'reject_reason', coalesce(fm.reject_reason, ''),
      'owner_name', (select o.legal_name from owners o where o.id = fm.owner_id));
  end if;
  return x;
end $$;

-- The files the new emails link to: the amendment (signed copy, or the document signed).
alter function app.outbox_file_refs(uuid) rename to outbox_file_refs_0037;
create or replace function app.outbox_file_refs(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v_doc uuid;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.code = 'renter_change_applied' and o.entity = 'booking_change_request' then
    select coalesce(a.signed_document_id, a.document_id) into v_doc from booking_amendments a
     where a.change_request_id = o.entity_id and a.status = 'signed' order by a.created_at desc limit 1;
    if v_doc is not null then return jsonb_build_object('signed_agreement_url', jsonb_build_object('k', 'document', 'key', v_doc::text)); end if;
    return '{}'::jsonb;
  end if;
  return app.outbox_file_refs_0037(p_outbox);
end $$;

insert into notification_link_paths (key, path) values
  ('va_similar_cars', '/va/similar-cars'), ('va_owner_forms', '/va/owner-forms')
on conflict (key) do update set path = excluded.path;

-- CATALOGUE 0040 START (generated by supabase/seed/0040_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_change_proposed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We suggest a change to booking {{booking_number}}', 'Review it and answer by {{accept_by}}. Your booking stays as it is until you accept.', 'Immediate', 'Staff (customer service, Fleet or an Admin) propose a change to a confirmed booking: new pickup or return times, another car, or a new rental charge. Sent once the proposal is saved, unless the change was agreed by phone and applied at once. The booking stays as it is until the renter accepts by the deadline (Program settings: booking_change_accept_hours, never later than the pickup less booking_change_lead_hours).', null, '/account/bookings/{{booking_number}}/change', '[{"name":"accept_by","type":"string"},{"name":"booking_number","type":"string"},{"name":"change_reason","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"difference_amount","type":"string"},{"name":"difference_label","type":"string"},{"name":"has_difference","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"}]'::jsonb, 'templates/renter_change_proposed.html', 'templates/renter_change_proposed.txt'),
  ('renter_change_proposal_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Reminder: answer the change to booking {{booking_number}} by {{accept_by}}', 'If you do nothing, your booking stays as it is.', 'Once, the reminder hours before the deadline', 'Booking change job (every 15 minutes): a change staff proposed (or a change the renter asked for and staff approved) has not been accepted, and its deadline is within booking_change_reminder_hours (Program settings, 12 by default). Sent once per change, and not when the change was made inside that window.', null, '/account/bookings/{{booking_number}}/change', '[{"name":"accept_by","type":"string"},{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"difference_amount","type":"string"},{"name":"difference_label","type":"string"},{"name":"first_name","type":"string"},{"name":"has_difference","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_change_proposal_reminder.html', 'templates/renter_change_proposal_reminder.txt'),
  ('renter_change_proposal_expired', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booking {{booking_number}} stays as it was', 'The suggested change was not accepted in time, so nothing changed.', 'At the deadline', 'Booking change job: a change waiting for the renter passed its deadline without being accepted. The change is closed as expired; the booking keeps its dates, car and price. Customer service is told at the same time.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_change_proposal_expired.html', 'templates/renter_change_proposal_expired.txt'),
  ('renter_change_applied', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booking {{booking_number}} is updated', 'Here are your new booking details. Amendment {{amendment_number}}.', 'Immediate', 'A change to a confirmed booking is applied: the renter accepted online (signed the amendment and any difference was charged), or an Admin recorded the renter''s agreement by phone. Carries what changed, the money, and the signed amendment when there is one.', null, '/account/bookings/{{booking_number}}', '[{"name":"amendment_number","type":"string"},{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_amendment_pdf","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"money_text","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"signed_agreement_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_change_applied.html', 'templates/renter_change_applied.txt'),
  ('owner_booking_changed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Booking {{booking_number}} changed', 'Your estimated share: {{income_before}} before, {{income_after}} now.', 'Immediate', 'A change to a confirmed booking on the owner''s car is applied (new dates, another car, or a new rental charge). One email to each owner whose car or income the change touches: the owner of the car it left and, if different, the owner of the car it moved to. Not sent for Owner Bookings.', null, '/owner/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"income_after","type":"string"},{"name":"income_before","type":"string"},{"name":"income_changed","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"owner_change_text","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_booking_changed.html', 'templates/owner_booking_changed.txt'),
  ('staff_change_proposal_answered', 'staff_va_cs', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', '{{booking_number}}: the renter {{outcome_title}} the change', '{{renter_name}}, {{vehicle_name}}.', 'Next digest', 'A change staff proposed to a confirmed booking ends: the renter accepted it online (amendment signed, difference settled, booking updated), declined it, or did not answer by the deadline. Queued for the next customer service digest. Staff notices about a test owner''s car go only to the verification accounts.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"outcome_detail","type":"string"},{"name":"outcome_title","type":"string"},{"name":"renter_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_change_proposal_answered.html', 'templates/staff_change_proposal_answered.txt'),
  ('renter_driver_link', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', '{{renter_name}} added you as a driver on booking {{booking_number}}', 'Read and accept the rental agreement before pickup. The link works until {{link_expires}}.', 'Immediate', 'The signing link of an additional driver is sent: when the renter''s agreement is opened, or when the renter or customer service sends a new link from the booking. Sent to the additional driver''s own email address. The link is valid for booking_driver_link_hours (Program settings, 72 by default); a newer link replaces it.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expires","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"renter_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"sign_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_driver_link.html', 'templates/renter_driver_link.txt'),
  ('staff_listing_similarity', 'staff_va_fleet', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Possible duplicate: {{vehicle_name}}', '{{flag_kind}}. Clear it or confirm it before the car is published.', 'Next digest', 'The listing similarity check finds a likely duplicate that stops publishing: a VIN one character from another car, the same plate, the same listing photo as a listed car, listing text very like a listed car (listing_similarity_copy_bps in Program settings), Queued for the next Fleet digest; a Fleet task is raised with it.', null, '/va/similar-cars', '[{"name":"company_address","type":"string","global":true},{"name":"flag_detail","type":"string"},{"name":"flag_kind","type":"string"},{"name":"other_vehicle_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_listing_similarity.html', 'templates/staff_listing_similarity.txt'),
  ('staff_owner_form_uploaded', 'staff_va_cs', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', 'Review {{form_title}} from {{owner_name}}', 'Signed with witnesses {{witness_names}}.', 'Next digest', 'An owner uploads a signed and witnessed Form C (lender or lessor permission acknowledgment, per financed or leased car) or Form D (limited power of attorney). Queued for the next customer service digest; a review task is raised with it.', null, '/va/owner-forms', '[{"name":"company_address","type":"string","global":true},{"name":"form_title","type":"string"},{"name":"owner_name","type":"string"},{"name":"vehicle_line","type":"string"},{"name":"witness_names","type":"string"}]'::jsonb, 'templates/staff_owner_form_uploaded.html', 'templates/staff_owner_form_uploaded.txt'),
  ('owner_form_approved', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', '{{form_title}} approved', 'Thanks. Nothing more to do for this form.', 'Immediate', 'Customer service or an Admin approves a Form C or Form D the owner uploaded.', null, '/owner/documents', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"form_title","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_line","type":"string"}]'::jsonb, 'templates/owner_form_approved.html', 'templates/owner_form_approved.txt'),
  ('owner_form_rejected', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Please upload {{form_title}} again', '{{reject_reason}}', 'Immediate', 'Customer service or an Admin sends back a Form C or Form D the owner uploaded, with the reason. The owner uploads it again from the owner portal.', null, '/owner/documents', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"form_title","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reject_reason","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_line","type":"string"}]'::jsonb, 'templates/owner_form_rejected.html', 'templates/owner_form_rejected.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0040 END

update notification_catalogue set emitted_by = 'booking_change_requests_proposed (0040)' where code = 'renter_change_proposed';
update notification_catalogue set emitted_by = 'app.booking_change_sweep (0040)' where code = 'renter_change_proposal_reminder';
update notification_catalogue set emitted_by = 'booking_change_requests_outcome (0040)'
 where code in ('renter_change_proposal_expired', 'renter_change_applied', 'owner_booking_changed', 'staff_change_proposal_answered');
update notification_catalogue set emitted_by = 'app.driver_link_send (0040)' where code = 'renter_driver_link';
update notification_catalogue set emitted_by = 'app.similarity_flag (0040)' where code = 'staff_listing_similarity';
update notification_catalogue set emitted_by = 'app.owner_upload_witnessed_form (0040)' where code = 'staff_owner_form_uploaded';
update notification_catalogue set emitted_by = 'app.review_witnessed_form (0040)' where code in ('owner_form_approved', 'owner_form_rejected');

-- ================================================================ 10. the doors: staff, the server
-- Staff actions and reads of this migration, through 0031's door for an Admin and an assistant alike. Each
-- function checks the person's role itself (customer service, Fleet or an Admin, as each says).
create or replace function app.ops40(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
begin
  if not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  case p_name
  when 'change_preview' then return app.propose_preview(p_user, p_);
  when 'change_vehicles' then
    -- the cars a booking may move to: open for bookings (0024's rule), with the booking's own car first
    return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'owner', o.legal_name)
                                      order by (v.id = b.vehicle_id) desc, app.vehicle_name(v.id))
                       from vehicles v join owners o on o.id = v.owner_id
                       left join bookings b on b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking'
                      where v.status in ('available', 'on_rent', 'cleaning') and coalesce(app.vehicle_bookable(v.id), false)), '[]'::jsonb);
  when 'change_propose' then return app.propose_booking_change(p_user, p_);
  when 'change_withdraw' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.withdraw_booking_change((p_ ->> 'request')::uuid, p_user);
    return jsonb_build_object('request', p_ ->> 'request', 'status', 'cancelled');
  when 'turnaround_block_remove' then return app.remove_turnaround_block(p_user, (p_ ->> 'block')::uuid, p_ ->> 'reason');
  when 'vehicle_turnaround' then return app.set_vehicle_turnaround(p_user, (p_ ->> 'vehicle')::uuid, nullif(p_ ->> 'minutes', '')::integer);
  when 'similarity_decide' then return app.decide_similarity(p_user, (p_ ->> 'flag')::uuid, p_ ->> 'decision', p_ ->> 'note');
  when 'similarity_check' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object('blocking', app.check_listing_similarity((p_ ->> 'vehicle')::uuid, 'all'), 'flags', app.vehicle_similarity((p_ ->> 'vehicle')::uuid));
  when 'vehicle_similarity' then return app.vehicle_similarity((p_ ->> 'vehicle')::uuid);
  when 'similar_cars' then
    return coalesce((select jsonb_agg(x order by (x ->> 'status' = 'open') desc, (x ->> 'created_at') desc)
                       from (select to_jsonb(f) || jsonb_build_object('vehicle_name', app.vehicle_name(f.vehicle_id), 'other_vehicle_name', app.vehicle_name(f.other_vehicle_id),
                                       'plate', (select v.plate from vehicles v where v.id = f.vehicle_id),
                                       'other_plate', (select v.plate from vehicles v where v.id = f.other_vehicle_id),
                                       'listing_status', (select l.status from vehicle_listings l where l.vehicle_id = f.vehicle_id),
                                       'decided_by_name', (select u.full_name from users u where u.id = f.decided_by)) as x
                               from listing_similarity_flags f
                              where f.status = 'open' or f.decided_at > now() - interval '30 days'
                              order by f.created_at desc limit 300) q), '[]'::jsonb);
  when 'owner_forms_queue' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.witnessed_forms_queue();
  when 'form_document' then
    -- the scan of a witnessed form, for the reviewer (customer service or an Admin)
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return (select app.document_file(d.id) from documents d
             where d.id = (p_ ->> 'document')::uuid and d.kind in ('form_c_finance_permission_ack', 'form_d_power_of_attorney')
               and exists (select 1 from owner_agreement_forms f where f.document_id = d.id));
  when 'owner_form_review' then return app.review_witnessed_form(p_user, (p_ ->> 'form')::uuid, coalesce((p_ ->> 'approve')::boolean, false), p_ ->> 'reason');
  when 'owner_witnessed_forms' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.owner_witnessed_forms((p_ ->> 'owner')::uuid);
  when 'driver_links' then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    return app.booking_driver_links(b.id);
  when 'driver_link_renew' then return app.driver_link_renew((p_ ->> 'signer')::uuid, p_user);
  when 'driver_link_send' then return app.driver_link_send((p_ ->> 'signer')::uuid, p_user, (p_ ->> 'version')::integer, p_ ->> 'url');
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0033;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'admin_do', 'va_read', 'va_do')
     and p_name in ('change_preview', 'change_vehicles', 'change_propose', 'change_withdraw', 'turnaround_block_remove', 'vehicle_turnaround', 'similarity_decide',
                    'similarity_check', 'vehicle_similarity', 'similar_cars', 'owner_forms_queue', 'owner_form_review', 'owner_witnessed_forms', 'form_document',
                    'driver_links', 'driver_link_renew', 'driver_link_send') then
    perform app.door_begin(p_user, p_aal);
    if p_call like 'admin_%' then perform app.assert_admin(p_user); end if;
    if p_call like 'va_%' and not app.user_va_has(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.ops40(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0033(p_user, p_aal, p_call, p_name, p);
end $$;

-- the server's calls (service role only): the renter's change page, the amendment, the driver links, the
-- verified address, the owner's witnessed forms
create or replace function public.server_change_facts(p_request uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.booking_change_facts(p_request, p_by) $$;
create or replace function public.server_open_amendment(p_request uuid, p_by uuid, p_sha256 text, p_storage_path text, p_template_version text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.open_booking_amendment(p_request, p_by, p_sha256, p_storage_path, p_template_version) $$;
create or replace function public.renter_sign_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$
  select app.sign_booking_amendment(p_amendment, p_by, p_consent_text, p_document_sha256, p_typed_name, p_drawn_signature, p_ip, p_user_agent) $$;
create or replace function public.server_apply_booking_change(p_request uuid, p_by uuid, p_processor jsonb default null, p_amount_cents bigint default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.accept_booking_change_apply(p_request, p_by, p_processor, p_amount_cents) $$;
create or replace function public.server_attach_signed_amendment(p_amendment uuid, p_storage_path text, p_sha256 text) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.attach_signed_amendment(p_amendment, p_storage_path, p_sha256) $$;
create or replace function public.server_amendment_record(p_amendment uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('amendment', to_jsonb(a),
           'record', (select jsonb_build_object('signer_name', r.signer_name, 'method', r.method, 'signed_at', r.signed_at, 'ip_address', host(r.ip_address),
                                                'user_agent', r.user_agent, 'provider_signature', r.provider_signature, 'typed_name', r.typed_name,
                                                'consent_text', r.consent_text, 'document_sha256', r.document_sha256)
                        from signature_records r where r.id = a.signature_record_id),
           'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = a.document_id))
    from booking_amendments a where a.id = p_amendment $$;
create or replace function public.renter_decline_booking_change(p_request uuid, p_by uuid, p_reason text default null) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.renter_decline_booking_change(p_request, p_by, p_reason) $$;
create or replace function public.server_account_email_verified(p_user uuid, p_email text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_email_verified(p_user, p_email) $$;
create or replace function public.server_my_account_links(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_account_links(p_user) $$;
create or replace function public.server_seen_account_links(p_user uuid) returns integer
language sql volatile security invoker set search_path = public, app as $$ select app.seen_account_links(p_user) $$;
create or replace function public.server_booking_driver_links(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
begin
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return app.booking_driver_links(p_booking);
end $$;
create or replace function public.server_driver_link_renew(p_signer uuid, p_by uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.driver_link_renew(p_signer, p_by) $$;
create or replace function public.server_driver_link_send(p_signer uuid, p_by uuid, p_version integer, p_url text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.driver_link_send(p_signer, p_by, p_version, p_url) $$;
create or replace function public.server_driver_link_valid(p_signer uuid, p_version integer) returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.driver_link_valid(p_signer, p_version) $$;
create or replace function public.owner_witnessed_forms(p_by uuid) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
begin
  if app.portal_owner_id(p_by) is null then raise exception 'This account is not an owner account' using errcode = '42501'; end if;
  return app.owner_witnessed_forms(app.portal_owner_id(p_by));
end $$;
create or replace function public.owner_upload_witnessed_form(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_upload_witnessed_form(p_by, p) $$;
create or replace function public.server_witnessed_form_facts(p_by uuid, p_code text, p_vehicle uuid default null) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
begin
  if v_owner is null then raise exception 'This account is not an owner account' using errcode = '42501'; end if;
  if p_code not in ('C', 'D1') or not exists (select 1 from jsonb_array_elements(app.owner_witnessed_forms(v_owner)) x
                                               where x ->> 'code' = p_code and (x ->> 'vehicle_id')::uuid is not distinct from p_vehicle) then
    raise exception 'That form is not needed for your account' using errcode = 'P0002';
  end if;
  return app.witnessed_form_facts(v_owner, p_code, p_vehicle);
end $$;

-- ================================================================ 11. row-level security, privileges and the schedule
-- the renter reads the amendments of their booking, as they read the rental agreement (0012's list, with the new kind;
-- compared as text because the kind is added in this same migration)
drop policy renter_read on public.documents;
create policy renter_read on public.documents for select to authenticated using (
  (renter_id = app.my_renter_id() or app.is_my_booking(booking_id))
  and kind::text in ('rental_agreement', 'rental_amendment', 'condition_report', 'renter_statement', 'coverage_proof', 'coverage_terms',
                     'coverage_activation', 'id_front', 'id_back', 'face_photo', 'toll_ticket_notice', 'receipt',
                     'repair_estimate', 'repair_invoice', 'notice'));
alter table booking_amendments enable row level security;
create policy admin_all on booking_amendments for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy renter_read on booking_amendments for select to authenticated using (app.is_my_booking(booking_id));
create policy staff_read on booking_amendments for select to authenticated using (app.va_has('cs', 'finance', 'fleet'));
alter table listing_similarity_flags enable row level security;
create policy admin_all on listing_similarity_flags for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy staff_read on listing_similarity_flags for select to authenticated using (app.va_has('fleet', 'cs'));
revoke all on booking_amendments, listing_similarity_flags, account_links from anon, authenticated;
grant select on booking_amendments, listing_similarity_flags, account_links to authenticated;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'booking_change_deadline', 'booking_change_proposed_notify',
              'booking_change_outcome_notify', 'propose_booking_change', 'propose_preview', 'change_rows', 'renter_decline_booking_change',
              'booking_change_sweep', 'job_booking_changes', 'booking_change_facts', 'open_booking_amendment', 'sign_booking_amendment',
              'attach_signed_amendment', 'booking_change_record_amendment', 'accept_booking_change_apply',
              'turnaround_minutes', 'sync_turnaround_block', 'bookings_turnaround_after', 'remove_turnaround_block', 'set_vehicle_turnaround',
              'similarity_flag', 'check_listing_similarity', 'vehicles_similarity_after', 'photos_similarity_after', 'drafts_similarity_after',
              'decide_similarity', 'vehicle_similarity', 'listing_copy', 
              'account_link_earlier', 'account_email_verified', 'my_account_links', 'seen_account_links',
              'driver_signer_link_default', 'driver_link_check', 'driver_link_renew', 'driver_link_send', 'driver_link_valid', 'booking_driver_links',
              'owner_witnessed_forms', 'owner_upload_witnessed_form', 'review_witnessed_form', 'witnessed_forms_queue', 'witnessed_form_facts',
              'ops40']))
        or (n.nspname = 'public' and p.proname = any (array[
              'server_change_facts', 'server_open_amendment', 'renter_sign_amendment', 'server_apply_booking_change', 'server_attach_signed_amendment',
              'server_amendment_record', 'renter_decline_booking_change', 'server_account_email_verified', 'server_my_account_links',
              'server_seen_account_links', 'server_booking_driver_links', 'server_driver_link_renew', 'server_driver_link_send', 'server_driver_link_valid',
              'owner_witnessed_forms', 'owner_upload_witnessed_form', 'server_witnessed_form_facts']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- pure helpers stay usable by the database's own roles
grant execute on function app.norm_plate(text), app.vin_distance(text, text), app.vin_check_ok(text), app.vin_near(text, text), app.copy_shingles(text), app.jaccard_bps(text[], text[]) to service_role, authenticated;
-- Each wrapper keeps the privileges of the function it wraps (a new function would otherwise be open to everyone).
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('request_booking_change_0019', 'request_booking_change'), ('publish_listing_0022', 'publish_listing'),
                          ('record_listing_upload_0022', 'record_listing_upload'), ('onboarding_checklist_0022', 'onboarding_checklist'),
                          ('notification_recipients_0037', 'notification_recipients'), ('ntf_payload_0037', 'notification_payload'),
                          ('outbox_file_refs_0037', 'outbox_file_refs'), ('door_0033', 'door')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke execute on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not available here: the booking change job is not scheduled';
    return;
  end if;
  perform cron.schedule('carmacars-booking-changes', '9-59/15 * * * *', 'select app.job_booking_changes()');
end $$;

select app.attach_audit();
