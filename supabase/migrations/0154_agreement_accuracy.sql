-- 0154: the rental agreements, accurate and dynamic (docs/changes/2026-10-24-agreement-accuracy.md).
--
-- The owner: "the rental agreements for Blind Spot and CarmaCars need to be fully accurate, with the kms upon pickup and
-- everything", "the agreements should be dynamic. If shit changes then the agreement changes. The agreements need to be
-- 100% on point with every field filled out so that we don't have issues with claims", and "Need to be able to e-sign
-- properly, not just putting in a name. Like the way that works for chargebacks."
--
--   1. The facts the two agreements were missing (app.agreement_extra): the deposit and how it is held, how the rental
--      was paid, every price line of every stage, the late terms, the car's fleet number, colour and VIN, each driver's
--      address, the insurance replacement's policy and insured vehicle, the car swaps, and the pickup and return records
--      (time, odometer, fuel, damage, return charges, final totals).
--   2. Versions (agreement_versions): after the agreement is signed, any change to what it prints makes a new version of
--      both documents. A material change (dates, price, car, drivers added or removed, the coverage option) waits for the
--      renter's (and the affected drivers') signature, sent by email and text; a correction is filed without signing. The
--      check-out makes the "as picked up" copy (time out, km out, fuel out, countersigned by the staff member), the
--      check-in the closing copy. Each version says what changed; the history stays.
--   3. The completeness check (app.agreement_missing): what an agreement still prints blank for want of data; check-out
--      refuses a booking missing a field a claim needs unless an Admin overrides with a reason.
--   4. Electronic signatures that hold up (esign_sessions, esign_events): a one-time code to the renter's phone or email,
--      the documents viewed, initials on the key terms, three explicit consents, a drawn signature (typed only when an
--      Admin turns on the accessibility fallback), the time, IP address, device and place of each step; a certificate of
--      completion on every signed PDF; any signed file checked against its recorded SHA-256 on /verify.
--   5. The dispute evidence pack (dispute_packs): built for a booking on demand and when a card payment is disputed.
--
-- The site does the PDFs (web/src/server/agreements/*); the database decides what changed, who signs, and keeps the
-- record. SCHEMA_MARKER 0154.

-- ================================================================ 1. schema
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table bookings
  add column if not exists insured_vehicle text,
  add column if not exists insurer_policy_number text,
  add column if not exists insurer_policy_province text,
  add column if not exists insurer_policy_expiry date;
comment on column bookings.insured_vehicle is 'An insurance replacement rental (0154): the insured''s own vehicle (year, make, model, plate), Blind Spot''s "Insured vehicle information".';
comment on column bookings.insurer_policy_number is 'An insurance replacement rental (0154): the insured''s policy number (Blind Spot box 13).';

alter table drivers
  add column if not exists address_line1 text,
  add column if not exists address_line2 text,
  add column if not exists city text,
  add column if not exists province text,
  add column if not exists postal_code text;
comment on column drivers.address_line1 is 'An additional driver''s home address (0154): printed on the rental agreement.';

alter table rental_agreements
  add column if not exists rendered_pickup jsonb,
  add column if not exists rendered_snapshot jsonb,
  add column if not exists signed_snapshot jsonb;
comment on column rental_agreements.rendered_pickup is 'The pickup readings printed in this agreement''s document when it was rendered (0154): signed at pickup after the check-out readings.';
comment on column rental_agreements.signed_snapshot is 'What the agreement printed when the renter signed (app.agreement_snapshot, 0154): version 1 of the booking''s agreement history.';

alter table program_settings
  add column if not exists agreement_claim_check boolean not null default true,
  add column if not exists esign_strict boolean not null default true,
  add column if not exists esign_typed_fallback boolean not null default false,
  add column if not exists esign_code_minutes integer not null default 10;
comment on column program_settings.agreement_claim_check is 'Check-out refuses a booking whose agreement is missing a field a claim needs (0154), unless an Admin overrides with a reason.';
comment on column program_settings.esign_strict is 'Rental agreements, amendments and new versions are signed only after the one-time code, the initials, the consents and a drawn signature (0154).';
comment on column program_settings.esign_typed_fallback is 'Accessibility fallback (0154): a signer who cannot draw may type their name and initials. Off by default; an Admin turns it on.';

-- booking history kinds
do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds
    from unnest(v_kinds || array['agreement_version', 'agreement_version_signed', 'agreement_fields_filled', 'agreement_override', 'dispute_pack']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- ================================================================ 2. the facts the agreements were missing
-- A person's or place's address on one line.
create or replace function app.agreement_address(p_line1 text, p_line2 text, p_city text, p_province text, p_postal text) returns text
language sql immutable as $$
  select nullif(concat_ws(', ', nullif(btrim(p_line1), ''), nullif(btrim(p_line2), ''), nullif(btrim(p_city), ''),
                          nullif(btrim(concat_ws(' ', nullif(btrim(p_province), ''), nullif(btrim(p_postal), ''))), '')), '')
$$;

-- A car as the agreements print it.
create or replace function app.agreement_vehicle(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'fuel', v.fuel,
                            'plate', v.plate, 'vin', v.vin, 'fleet_number', nullif(btrim(v.fleet_number), ''))
    from vehicles v where v.id = p_vehicle
$$;

-- The pickup record: the pickup condition report once its odometer and fuel are in (completed, or in progress for an
-- agreement signed at pickup after the readings), with the car it was for.
create or replace function app.agreement_pickup(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('report_id', c.id, 'completed', c.completed_at is not null,
           'at', case when c.completed_at is not null then c.performed_at else c.created_at end,
           'odometer_km', c.odometer_km, 'fuel_pct', c.fuel_pct, 'keys', c.keys_count,
           'staff_user_id', coalesce(c.completed_by, c.performed_by),
           'staff_name', (select u.full_name from users u where u.id = coalesce(c.completed_by, c.performed_by)),
           'damages', coalesce((select jsonb_agg(jsonb_build_object('label', d.label, 'location', d.location, 'description', d.description) order by d.label)
                                  from condition_report_damages d where d.condition_report_id = c.id), '[]'::jsonb),
           'photos', (select count(*) from condition_report_photos ph where ph.condition_report_id = c.id),
           'vehicle', app.agreement_vehicle(c.vehicle_id))
    from condition_reports c
   where c.booking_id = p_booking and c.kind = 'pickup' and c.odometer_km is not null and c.fuel_pct is not null
$$;

-- The return record: the completed return condition report, the kilometres, the fuel, the lateness, the new damage.
create or replace function app.agreement_return(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('report_id', c.id, 'at', coalesce(b.checked_in_at, c.performed_at),
           'odometer_km', c.odometer_km, 'odometer_out_km', b.odometer_out_km, 'km_driven', app.booking_km_driven(b.id),
           'km_allowed', b.km_allowance_total, 'km_charged', greatest(coalesce(app.booking_km_driven(b.id), 0) - coalesce(b.km_allowance_total, 0), 0),
           'fuel_out_pct', b.fuel_out_pct, 'fuel_pct', c.fuel_pct, 'minutes_late', coalesce(b.minutes_late, 0),
           'late_hours', ceil(coalesce(b.minutes_late, 0) / 60.0)::integer, 'extra_days', coalesce(b.extra_days, 0),
           'keys', c.keys_count, 'cleanliness', c.cleanliness,
           'staff_user_id', c.completed_by, 'staff_name', (select u.full_name from users u where u.id = c.completed_by),
           'new_damages', coalesce((select jsonb_agg(jsonb_build_object('label', d.label, 'location', d.location, 'description', d.description) order by d.label)
                                      from condition_report_damages d where d.condition_report_id = c.id and d.is_new), '[]'::jsonb),
           'photos', (select count(*) from condition_report_photos ph where ph.condition_report_id = c.id),
           'vehicle', app.agreement_vehicle(c.vehicle_id))
    from condition_reports c join bookings b on b.id = c.booking_id
   where c.booking_id = p_booking and c.kind = 'return' and c.completed_at is not null
$$;

-- Everything the agreements print beyond public.server_agreement_facts (0028) and app.blindspot_extra (0127).
create or replace function app.agreement_extra(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  dep deposits;
  t record;
  v_first uuid;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking using errcode = 'P0002'; end if;
  select * into dep from deposits where booking_id = b.id;
  select * into t from app.booking_fee_term(b.id, 'late_return_fee');
  select s.from_vehicle_id into v_first from booking_vehicle_swaps s where s.booking_id = b.id order by s.swapped_at limit 1;
  return jsonb_build_object(
    'booking', jsonb_build_object('status', b.status, 'bill_to', b.bill_to, 'payment_mode', b.payment_mode, 'rental_pay_method', b.rental_pay_method,
                                  'deposit_pay_method', b.deposit_pay_method, 'agreement_on_paper', b.agreement_on_paper,
                                  'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at),
    'vehicle', app.agreement_vehicle(b.vehicle_id),
    -- the car the rental started with, when it was swapped since (the original vehicle on Blind Spot's form)
    'original_vehicle', case when v_first is not null then app.agreement_vehicle(v_first) end,
    'swaps', coalesce((select jsonb_agg(jsonb_build_object('at', s.swapped_at, 'reason', s.reason,
                         'from', app.agreement_vehicle(s.from_vehicle_id), 'to', app.agreement_vehicle(s.to_vehicle_id),
                         'from_km_in', (select c.odometer_km from condition_reports c where c.booking_id = b.id and c.kind = 'swap_out' and c.vehicle_id = s.from_vehicle_id order by c.performed_at desc limit 1),
                         'from_fuel_in', (select c.fuel_pct from condition_reports c where c.booking_id = b.id and c.kind = 'swap_out' and c.vehicle_id = s.from_vehicle_id order by c.performed_at desc limit 1),
                         'to_km_out', (select c.odometer_km from condition_reports c where c.booking_id = b.id and c.kind = 'swap_in' and c.vehicle_id = s.to_vehicle_id order by c.performed_at desc limit 1),
                         'to_fuel_out', (select c.fuel_pct from condition_reports c where c.booking_id = b.id and c.kind = 'swap_in' and c.vehicle_id = s.to_vehicle_id order by c.performed_at desc limit 1))
                         order by s.swapped_at) from booking_vehicle_swaps s where s.booking_id = b.id), '[]'::jsonb),
    -- each driver's address and contact (the facts' drivers carry the licence)
    'drivers', coalesce((select jsonb_object_agg(d.id::text, jsonb_build_object(
                           'address', case when d.role = 'renter' then (select app.agreement_address(r.address_line1, r.address_line2, r.city, r.province, r.postal_code) from renters r where r.id = b.renter_id)
                                           else app.agreement_address(dv.address_line1, dv.address_line2, dv.city, dv.province, dv.postal_code) end,
                           'mobile', dv.mobile, 'email', dv.email))
                           from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = b.id), '{}'::jsonb),
    'deposit', jsonb_build_object('amount_cents', b.deposit_cents, 'pay_method', b.deposit_pay_method, 'method', dep.method, 'paid_method', dep.paid_method,
                                  'status', dep.status, 'taken_at', dep.taken_at, 'applied_cents', coalesce(dep.applied_cents, 0),
                                  'released_cents', coalesce(dep.released_cents, 0), 'held_back_cents', coalesce(dep.held_back_cents, 0),
                                  'card_hold_days', (app.settings()).deposit_hold_max_days),
    -- every payment received for the booking (card, cash, e-Transfer...), the refunds as negatives
    'payments', coalesce((select jsonb_agg(jsonb_build_object('purpose', p.purpose, 'kind', p.kind, 'method', coalesce(m.method, p.method),
                           'amount_cents', case when p.kind in ('refund', 'release') then -p.amount_cents else p.amount_cents end,
                           'card_brand', p.card_brand, 'card_last4', p.card_last4, 'reference', m.reference,
                           'at', coalesce(p.processed_at, m.recorded_at, p.created_at)) order by coalesce(p.processed_at, p.created_at))
                           from payments p left join manual_payments m on m.payment_id = p.id and m.voided_at is null
                          where p.booking_id = b.id and p.status = 'succeeded' and p.kind in ('charge', 'capture', 'refund')), '[]'::jsonb),
    -- every price line of every stage (the facts carry the booking stage only)
    'lines', coalesce((select jsonb_agg(jsonb_build_object('charge_type', li.charge_type, 'description', coalesce(li.description, li.charge_type),
                         'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents, 'stage', li.stage, 'quantity', li.quantity,
                         'unit_amount_cents', li.unit_amount_cents) order by li.created_at, li.charge_type)
                         from booking_line_items li where li.booking_id = b.id and li.charged_to_renter and li.voided_at is null), '[]'::jsonb),
    'late', jsonb_build_object('fee_cents', t.amount_cents, 'cap_bps', t.percent_bps, 'grace_minutes', t.grace_minutes),
    'card_expiry', (select case when pm.exp_month is not null and pm.exp_year is not null then lpad(pm.exp_month::text, 2, '0') || '/' || pm.exp_year end
                      from payment_methods pm where pm.id = b.card_on_file_id),
    'multi_day_rate_cents', b.multi_day_rate_cents,
    'insurer_policy', case when b.bill_to <> 'renter' and b.insurer_id is not null then jsonb_build_object(
                        'policy_number', nullif(btrim(b.insurer_policy_number), ''), 'province', nullif(btrim(b.insurer_policy_province), ''),
                        'expiry', b.insurer_policy_expiry, 'insured_vehicle', nullif(btrim(b.insured_vehicle), '')) end,
    'pickup', app.agreement_pickup(b.id),
    'return', app.agreement_return(b.id));
end $$;

create or replace function public.server_agreement_extra(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not (coalesce(app.is_booking_renter(p_booking, p_by), false) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, reads its agreement' using errcode = '42501';
  end if;
  return app.agreement_extra(p_booking);
end $$;



-- ================================================================ 3. what the agreements print, compared
-- One canonical object per booking: every value the two agreements print, grouped. Two snapshots are compared key by
-- key (app.agreement_changes); the pickup and return records are compared on their own (a version of their own kind).
create or replace function app.agreement_snapshot(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  cp coverage_proofs;
  pm payment_methods;
  dep deposits;
  pk jsonb := app.agreement_pickup(p_booking);
  rt jsonb := app.agreement_return(p_booking);
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select * into r from renters where id = b.renter_id;
  select * into cp from coverage_proofs c where c.booking_id = b.id order by c.created_at desc limit 1;
  select * into pm from payment_methods where id = b.card_on_file_id;
  select * into dep from deposits where booking_id = b.id;
  return jsonb_build_object(
    'dates', jsonb_build_object('pickup_at', b.pickup_at, 'return_at', b.return_at),
    'places', jsonb_build_object('pickup_place', b.pickup_place, 'return_place', b.return_place, 'pickup_method', b.pickup_method, 'return_method', b.return_method),
    'renter', jsonb_build_object('legal_name', r.legal_name, 'date_of_birth', r.date_of_birth, 'mobile', r.mobile,
                                 'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id)),
                                 'address', app.agreement_address(r.address_line1, r.address_line2, r.city, r.province, r.postal_code)),
    'drivers', coalesce((select jsonb_object_agg(d.driver_id::text, jsonb_build_object('present', 'yes', 'role', d.role,
                           'full_name', d.full_name, 'date_of_birth', d.date_of_birth,
                           'licence_number', coalesce(d.licence_number, dv.licence_number), 'licence_class', coalesce(d.licence_class, dv.licence_class),
                           'licence_issuer', coalesce(d.licence_issuer, dv.licence_issuer), 'licence_expiry', coalesce(d.licence_expiry, dv.licence_expiry),
                           'address', case when d.role = 'additional' then app.agreement_address(dv.address_line1, dv.address_line2, dv.city, dv.province, dv.postal_code) end))
                           from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = b.id), '{}'::jsonb),
    'vehicle', app.agreement_vehicle(b.vehicle_id),
    'price', jsonb_build_object('rate_applied', b.rate_applied, 'billable_days', b.billable_days, 'daily_rate_cents', b.daily_rate_cents,
                                'weekend_rate_cents', b.weekend_rate_cents, 'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents,
                                'rental_charge_cents', b.rental_charge_cents, 'km_allowance_per_day', b.km_allowance_per_day,
                                'km_allowance_total', b.km_allowance_total, 'overage_cents_per_km', b.overage_cents_per_km,
                                'deposit_cents', b.deposit_cents, 'subtotal_cents', b.subtotal_at_booking_cents, 'hst_cents', b.hst_at_booking_cents,
                                'total_cents', b.total_due_at_booking_cents,
                                'lines', (select string_agg(coalesce(li.description, li.charge_type) || ' ' || app.fmt_money(li.amount_cents), '; ' order by li.created_at, li.charge_type)
                                            from booking_line_items li where li.booking_id = b.id and li.charged_to_renter and li.voided_at is null
                                             and li.stage in ('booking', 'extension'))),
    'coverage', jsonb_build_object('option', b.coverage_option, 'insurer_name', cp.insurer_name, 'policy_number', cp.policy_number,
                                   'policy_expiry', cp.policy_expiry, 'card_issuer', cp.card_issuer, 'card_last4', cp.card_last4),
    'insurer', case when b.bill_to <> 'renter' and b.insurer_id is not null then jsonb_build_object(
                 'name', (select i.name from insurers i where i.id = b.insurer_id), 'claim_number', b.insurer_claim_number,
                 'adjuster_name', b.insurer_adjuster_name, 'adjuster_phone', b.insurer_adjuster_phone, 'authorized_days', b.insurer_authorized_days,
                 'authorized_daily_rate_cents', b.insurer_authorized_daily_rate_cents, 'policy_number', b.insurer_policy_number,
                 'policy_province', b.insurer_policy_province, 'policy_expiry', b.insurer_policy_expiry, 'insured_vehicle', b.insured_vehicle) end,
    'payment', jsonb_build_object('rental_pay_method', b.rental_pay_method, 'deposit_pay_method', b.deposit_pay_method,
                                  'card', case when pm.id is not null then initcap(coalesce(pm.card_brand, '')) || ' ' || coalesce(pm.card_last4, '') end,
                                  'deposit_method', dep.method, 'deposit_paid_method', dep.paid_method),
    'pickup', case when pk is not null then jsonb_build_object('report_id', pk ->> 'report_id', 'odometer_km', pk -> 'odometer_km', 'fuel_pct', pk -> 'fuel_pct',
                                                               'completed', pk -> 'completed') end,
    -- the return record, with the return charges (a charge assessed after the check-in makes a new closing copy)
    'return', case when rt is not null then jsonb_build_object('report_id', rt ->> 'report_id', 'odometer_km', rt -> 'odometer_km', 'fuel_pct', rt -> 'fuel_pct',
                 'charges', (select string_agg(coalesce(li.description, li.charge_type) || ' ' || app.fmt_money(li.amount_cents), '; ' order by li.created_at, li.charge_type)
                               from booking_line_items li where li.booking_id = b.id and li.charged_to_renter and li.voided_at is null
                                and li.stage in ('check_in', 'after_return', 'on_decline'))) end);
end $$;

-- After the site renders an open agreement: what it printed (the snapshot of the booking then, and the pickup readings,
-- for an agreement signed at pickup after them). Version 1 is what the signed document printed, not the booking later.
create or replace function public.server_agreement_rendered(p_booking uuid, p_pickup jsonb) returns void
language sql security definer set search_path = public, app as $$
  update rental_agreements set rendered_pickup = case when jsonb_typeof(p_pickup) = 'object' then p_pickup end,
         rendered_snapshot = app.agreement_snapshot(p_booking)
   where booking_id = p_booking and status = 'open'
$$;

-- A snapshot as key/value rows ("price.deposit_cents" = "1000.00"...), every leaf.
create or replace function app.agreement_flat(p jsonb, p_prefix text default '') returns table (k text, v text)
language plpgsql immutable as $$
declare
  e record;
begin
  if p is null or jsonb_typeof(p) = 'null' then return; end if;
  if jsonb_typeof(p) <> 'object' then k := p_prefix; v := p #>> '{}'; return next; return; end if;
  for e in select key, value from jsonb_each(p) loop
    if jsonb_typeof(e.value) = 'object' then
      return query select * from app.agreement_flat(e.value, p_prefix || e.key || '.');
    else
      k := p_prefix || e.key; v := case when jsonb_typeof(e.value) = 'null' then null else e.value #>> '{}' end; return next;
    end if;
  end loop;
end $$;

-- What a key is called on the agreement, and whether a change to it needs the renter's signature.
create or replace function app.agreement_key_label(p_key text, p_names jsonb default '{}'::jsonb, out label text, out material boolean)
language plpgsql immutable as $$
declare
  part text[] := string_to_array(p_key, '.');
  who text;
begin
  material := false;
  if part[1] = 'drivers' then
    who := coalesce(p_names ->> part[2], 'a driver');
    label := case part[3] when 'present' then 'Driver ' || who
                          when 'full_name' then 'Driver ' || who || ': name'
                          when 'date_of_birth' then 'Driver ' || who || ': date of birth'
                          when 'licence_number' then 'Driver ' || who || ': licence number'
                          when 'licence_class' then 'Driver ' || who || ': licence class'
                          when 'licence_issuer' then 'Driver ' || who || ': licence province'
                          when 'licence_expiry' then 'Driver ' || who || ': licence expiry'
                          when 'address' then 'Driver ' || who || ': address'
                          when 'role' then 'Driver ' || who || ': role'
                          else 'Driver ' || who || ': ' || part[3] end;
    material := part[3] in ('present', 'role');
    return;
  end if;
  label := case p_key
    when 'dates.pickup_at' then 'Pickup (time and date out)' when 'dates.return_at' then 'Due back'
    when 'places.pickup_place' then 'Pickup place' when 'places.return_place' then 'Return place'
    when 'places.pickup_method' then 'How the renter gets the car' when 'places.return_method' then 'How the car comes back'
    when 'renter.legal_name' then 'Renter: name' when 'renter.date_of_birth' then 'Renter: date of birth' when 'renter.mobile' then 'Renter: mobile'
    when 'renter.email' then 'Renter: email' when 'renter.address' then 'Renter: address'
    when 'vehicle.id' then 'Car' when 'vehicle.vin' then 'Car: VIN' when 'vehicle.plate' then 'Car: plate' when 'vehicle.year' then 'Car: year'
    when 'vehicle.make' then 'Car: make' when 'vehicle.model' then 'Car: model' when 'vehicle.trim' then 'Car: trim' when 'vehicle.colour' then 'Car: colour'
    when 'vehicle.fuel' then 'Car: fuel' when 'vehicle.fleet_number' then 'Car: fleet number'
    when 'price.rate_applied' then 'Rate applied' when 'price.billable_days' then 'Days' when 'price.daily_rate_cents' then 'Daily rate'
    when 'price.weekend_rate_cents' then 'Weekend rate' when 'price.weekly_rate_cents' then 'Weekly rate' when 'price.monthly_rate_cents' then 'Monthly rate'
    when 'price.rental_charge_cents' then 'Rental charge' when 'price.km_allowance_per_day' then 'Kilometres included a day'
    when 'price.km_allowance_total' then 'Kilometres included' when 'price.overage_cents_per_km' then 'Each kilometre over'
    when 'price.deposit_cents' then 'Deposit' when 'price.subtotal_cents' then 'Subtotal' when 'price.hst_cents' then 'HST'
    when 'price.total_cents' then 'Total' when 'price.lines' then 'Price lines'
    when 'coverage.option' then 'Coverage option' when 'coverage.insurer_name' then 'Coverage: insurer' when 'coverage.policy_number' then 'Coverage: policy number'
    when 'coverage.policy_expiry' then 'Coverage: policy expiry' when 'coverage.card_issuer' then 'Coverage: card issuer' when 'coverage.card_last4' then 'Coverage: card'
    when 'insurer.name' then 'Insurance company' when 'insurer.claim_number' then 'Claim number' when 'insurer.adjuster_name' then 'Adjuster'
    when 'insurer.adjuster_phone' then 'Adjuster phone' when 'insurer.authorized_days' then 'Insurer authorized days'
    when 'insurer.authorized_daily_rate_cents' then 'Insurer authorized rate' when 'insurer.policy_number' then 'Insured''s policy number'
    when 'insurer.policy_province' then 'Insured''s policy province' when 'insurer.policy_expiry' then 'Insured''s policy expiry'
    when 'insurer.insured_vehicle' then 'Insured vehicle'
    when 'payment.rental_pay_method' then 'Rental paid by' when 'payment.deposit_pay_method' then 'Deposit paid by' when 'payment.card' then 'Card on file'
    when 'payment.deposit_method' then 'Deposit held as' when 'payment.deposit_paid_method' then 'Deposit received as'
    else p_key end;
  material := part[1] in ('dates', 'price') or p_key in ('vehicle.id', 'coverage.option');
end $$;

-- A value as the change list prints it.
create or replace function app.agreement_key_value(p_key text, p_value text) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_value is null or btrim(p_value) = '' then return '(blank)'; end if;
  if p_key like '%\_cents' or p_key like '%\_cents\_per\_km' then return app.fmt_money(p_value::numeric); end if;
  if p_key in ('dates.pickup_at', 'dates.return_at') then return app.fmt_datetime(p_value::timestamptz); end if;
  if p_key like 'drivers.%.present' then return case when p_value = 'yes' then 'on the agreement' else '(blank)' end; end if;
  if p_key = 'vehicle.id' then return coalesce((select concat_ws(' ', v.year, v.make, v.model, nullif(v.plate, '')) from vehicles v where v.id::text = p_value), p_value); end if;
  return p_value;
end $$;

-- The differences between two snapshots: [{key, label, before, after, material}], the pickup and return records apart.
create or replace function app.agreement_changes(p_old jsonb, p_new jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with o as (select k, v from app.agreement_flat(coalesce(p_old, '{}'::jsonb) - 'pickup' - 'return')),
       n as (select k, v from app.agreement_flat(coalesce(p_new, '{}'::jsonb) - 'pickup' - 'return')),
       names as (select coalesce(jsonb_object_agg(x.key, x.value ->> 'full_name'), '{}'::jsonb) as m
                   from (select key, value from jsonb_each(coalesce(p_old -> 'drivers', '{}'::jsonb))
                         union all select key, value from jsonb_each(coalesce(p_new -> 'drivers', '{}'::jsonb))) x),
       d as (select coalesce(n.k, o.k) as k, o.v as before, n.v as after from o full join n on n.k = o.k where o.v is distinct from n.v)
  select coalesce(jsonb_agg(jsonb_build_object('key', d.k, 'label', l.label, 'before', app.agreement_key_value(d.k, d.before),
                                               'after', app.agreement_key_value(d.k, d.after), 'material', l.material)
                            order by l.material desc, d.k), '[]'::jsonb)
    from d cross join names cross join lateral app.agreement_key_label(d.k, names.m) l
   -- a payment detail set for the first time (the card saved when the booking is paid, the deposit taken at pickup) is
   -- what the agreement said would happen, not a change; a driver's details change with the driver added or removed:
   -- only the driver line is listed
   where not (d.k like 'payment.%' and d.before is null)
     and not (d.k like 'drivers.%' and d.k not like 'drivers.%.present'
              and exists (select 1 from d d2 where d2.k = split_part(d.k, '.', 1) || '.' || split_part(d.k, '.', 2) || '.present'))
$$;

-- ================================================================ 4. versions
-- Version 1 is the agreement as the renter signed it; each later version is both documents rendered again for the
-- booking as it is now. kind: signed (version 1), pickup (the "as picked up" copy), return (the closing copy), change
-- (a material change: signed again), correction (filed without signing). A version made while an earlier one waits
-- for signatures supersedes it.
create table if not exists agreement_versions (
  id                     uuid primary key default gen_random_uuid(),
  booking_id             uuid not null references bookings (id) on delete cascade,
  version_no             integer not null check (version_no >= 1),
  kind                   text not null check (kind in ('signed', 'pickup', 'return', 'change', 'correction')),
  material               boolean not null default false,
  status                 text not null check (status in ('signed', 'filed', 'awaiting_signature', 'superseded')),
  changes                jsonb not null default '[]'::jsonb,
  snapshot               jsonb not null,
  snapshot_sha           text not null,
  rental_agreement_id    uuid references rental_agreements (id),
  carmacars_document_id  uuid references documents (id),
  carmacars_sha256       text,
  blindspot_document_id  uuid references documents (id),
  blindspot_sha256       text,
  signed_carmacars_document_id uuid references documents (id),
  signed_blindspot_document_id uuid references documents (id),
  condition_report_id    uuid references condition_reports (id),
  countersigned_by       uuid references users (id),
  countersigned_name     text,
  countersigned_at       timestamptz,
  amendment_id           uuid references booking_amendments (id),
  note                   text,
  created_by             uuid references users (id),
  created_at             timestamptz not null default now(),
  signed_at              timestamptz,
  superseded_at          timestamptz,
  unique (booking_id, version_no)
);
create index if not exists agreement_versions_booking on agreement_versions (booking_id, version_no desc);
comment on table agreement_versions is 'Each version of a booking''s two rental agreements after signing (0154): what changed, both documents, who signed or countersigned.';

create table if not exists agreement_version_signers (
  id                uuid primary key default gen_random_uuid(),
  version_id        uuid not null references agreement_versions (id) on delete cascade,
  role              text not null check (role in ('renter', 'additional_driver')),
  booking_driver_id uuid references booking_drivers (id) on delete set null,
  user_id           uuid references users (id),
  name              text not null,
  email             text,
  mobile            text,
  link_token        uuid not null unique default gen_random_uuid(),
  status            text not null default 'waiting' check (status in ('waiting', 'signed', 'void')),
  signed_at         timestamptz,
  method            text check (method in ('drawn', 'typed')),
  signature_path    text,
  ip_address        inet,
  user_agent        text,
  consent_text      text,
  esign_session_id  uuid,
  link_sent_at      timestamptz,
  created_at        timestamptz not null default now(),
  check (status <> 'signed' or (signed_at is not null and method is not null))
);
create index if not exists agreement_version_signers_version on agreement_version_signers (version_id);
comment on table agreement_version_signers is 'Who signs a version of the rental agreement that changed materially (0154): the renter and the drivers it affects, each with their own link.';

-- An additional driver's link to sign a new version is the signer row's token: unguessable, valid while the version waits.
create table if not exists agreement_overrides (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings (id) on delete cascade,
  missing     jsonb not null,
  reason      text not null check (length(btrim(reason)) >= 5),
  by_user     uuid not null references users (id),
  created_at  timestamptz not null default now()
);
comment on table agreement_overrides is 'An Admin lets a check-out go ahead with agreement fields still missing (0154): which ones, why, who.';

-- The background work of the agreements (rendered by the site): a booking whose agreements may need a new version, a
-- version whose signed copies are due, a dispute evidence pack. A row touched again while running runs again.
create table if not exists agreement_jobs (
  kind        text not null check (kind in ('version', 'version_signed', 'dispute_pack')),
  ref         uuid not null,
  seq         integer not null default 1,
  due_at      timestamptz not null default now(),
  attempts    integer not null default 0,
  locked_at   timestamptz,
  locked_seq  integer,
  last_error  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (kind, ref)
);
comment on table agreement_jobs is 'Agreement work the site does in the background (0154): new versions, signed copies of versions, dispute evidence packs.';

do $$
begin
  execute 'alter table agreement_versions enable row level security';
  execute 'alter table agreement_version_signers enable row level security';
  execute 'alter table agreement_overrides enable row level security';
  execute 'alter table agreement_jobs enable row level security';
end $$;
create policy admin_all on agreement_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on agreement_version_signers for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on agreement_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on agreement_jobs for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on agreement_versions, agreement_version_signers, agreement_overrides, agreement_jobs from anon, authenticated;
grant select, insert, update, delete on agreement_versions, agreement_version_signers, agreement_overrides, agreement_jobs to service_role;
create trigger audit_agreement_versions after insert or update or delete on agreement_versions for each row execute function app.audit_row();
create trigger audit_agreement_overrides after insert or update or delete on agreement_overrides for each row execute function app.audit_row();
create trigger audit_agreement_version_signers after insert or update or delete on agreement_version_signers for each row execute function app.audit_row();

create or replace function app.agreement_sha(p jsonb) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p::text, ''), 'UTF8')), 'hex') $$;

-- What the renter signed: the snapshot when the agreement is completed, with the pickup readings the signed document printed.
-- (taken at the countersignature: the payment that confirms a booking saves its card and is no change of the agreement)
create or replace function app.agreement_signed_snapshot() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'completed' and new.signed_snapshot is null then
    new.signed_snapshot := coalesce(new.rendered_snapshot, app.agreement_snapshot(new.booking_id)) - 'pickup' - 'return'
      || jsonb_build_object('pickup', case when new.rendered_pickup is not null then jsonb_build_object(
           'report_id', new.rendered_pickup ->> 'report_id', 'odometer_km', new.rendered_pickup -> 'odometer_km',
           'fuel_pct', new.rendered_pickup -> 'fuel_pct', 'completed', new.rendered_pickup -> 'completed') end,
                            'return', null);
  end if;
  return new;
end $$;
drop trigger if exists agreement_signed_snapshot on rental_agreements;
create trigger agreement_signed_snapshot before insert or update of status on rental_agreements
  for each row execute function app.agreement_signed_snapshot();

-- Version 1: recorded when the agreement is countersigned (completed).
create or replace function app.agreement_version_one(p_agreement uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  v_id uuid;
  v_snap jsonb;
begin
  select * into a from rental_agreements where id = p_agreement;
  if a.id is null or a.status <> 'completed' then return null; end if;
  select id into v_id from agreement_versions where booking_id = a.booking_id and version_no = 1;
  if v_id is not null then return v_id; end if;
  v_snap := coalesce(a.signed_snapshot, app.agreement_snapshot(a.booking_id));
  insert into agreement_versions (booking_id, version_no, kind, material, status, snapshot, snapshot_sha, rental_agreement_id,
                                  carmacars_document_id, carmacars_sha256, signed_carmacars_document_id, signed_at, countersigned_name, countersigned_at)
  values (a.booking_id, 1, 'signed', true, 'signed', v_snap, app.agreement_sha(v_snap), a.id, a.document_id, a.document_sha256,
          (select s.signed_document_id from signature_requests s where s.id = a.signature_request_id), a.renter_signed_at, a.countersigner_name, a.completed_at)
  on conflict (booking_id, version_no) do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function app.agreement_completed_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform app.agreement_version_one(new.id);
    perform app.agreement_touch(new.booking_id);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------- the queue
create or replace function app.agreement_job_put(p_kind text, p_ref uuid, p_delay interval default interval '0') returns void
language sql security definer set search_path = public, app as $$
  insert into agreement_jobs (kind, ref, due_at) values (p_kind, p_ref, now() + p_delay)
  on conflict (kind, ref) do update set seq = agreement_jobs.seq + 1, due_at = least(greatest(agreement_jobs.due_at, now()), now() + p_delay),
                                        attempts = 0, last_error = null, updated_at = now()
$$;

-- A booking whose agreement exists and is still in use: its agreements are checked again a few seconds later (several
-- changes in a row make one version).
create or replace function app.agreement_touch(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_booking is null then return; end if;
  if exists (select 1 from rental_agreements a join bookings b on b.id = a.booking_id
              where a.booking_id = p_booking and a.status in ('open', 'signed', 'completed')
                and b.status in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed')
                and (b.status <> 'closed' or coalesce(b.checked_in_at, b.return_at) > now() - interval '60 days')) then
    perform app.agreement_job_put('version', p_booking, interval '10 seconds');
  end if;
end $$;

create or replace function app.agreement_touch_row() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r record := case when tg_op = 'DELETE' then old else new end;
  b uuid;
begin
  case tg_table_name
  when 'bookings' then perform app.agreement_touch(r.id);
  when 'renters' then
    for b in select x.id from bookings x where x.renter_id = r.id and x.status in ('pending_payment', 'confirmed', 'on_rent', 'returned') loop
      perform app.agreement_touch(b);
    end loop;
  when 'drivers' then
    for b in select x.booking_id from booking_drivers x join bookings y on y.id = x.booking_id
              where x.driver_id = r.id and y.status in ('pending_payment', 'confirmed', 'on_rent', 'returned') loop
      perform app.agreement_touch(b);
    end loop;
  when 'vehicles' then
    for b in select x.id from bookings x where x.vehicle_id = r.id and x.status in ('pending_payment', 'confirmed', 'on_rent', 'returned') loop
      perform app.agreement_touch(b);
    end loop;
  when 'condition_reports' then
    if r.kind in ('pickup', 'return', 'swap_out', 'swap_in') then perform app.agreement_touch(r.booking_id); end if;
  else perform app.agreement_touch(r.booking_id);
  end case;
  return null;
end $$;

drop trigger if exists agreement_touch on bookings;
create trigger agreement_touch after update on bookings for each row
  when ((old.pickup_at, old.return_at, old.vehicle_id, old.pickup_place, old.return_place, old.pickup_method, old.return_method, old.rate_applied,
         old.billable_days, old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents, old.rental_charge_cents,
         old.km_allowance_per_day, old.km_allowance_total, old.overage_cents_per_km, old.deposit_cents, old.subtotal_at_booking_cents,
         old.hst_at_booking_cents, old.total_due_at_booking_cents, old.coverage_option, old.card_on_file_id, old.bill_to, old.insurer_id,
         old.insurer_claim_number, old.insurer_adjuster_name, old.insurer_adjuster_phone, old.insurer_authorized_days,
         old.insurer_authorized_daily_rate_cents, old.insurer_policy_number, old.insurer_policy_province, old.insurer_policy_expiry,
         old.insured_vehicle, old.rental_pay_method, old.deposit_pay_method, old.odometer_out_km, old.odometer_in_km, old.checked_in_at)
        is distinct from
        (new.pickup_at, new.return_at, new.vehicle_id, new.pickup_place, new.return_place, new.pickup_method, new.return_method, new.rate_applied,
         new.billable_days, new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents, new.rental_charge_cents,
         new.km_allowance_per_day, new.km_allowance_total, new.overage_cents_per_km, new.deposit_cents, new.subtotal_at_booking_cents,
         new.hst_at_booking_cents, new.total_due_at_booking_cents, new.coverage_option, new.card_on_file_id, new.bill_to, new.insurer_id,
         new.insurer_claim_number, new.insurer_adjuster_name, new.insurer_adjuster_phone, new.insurer_authorized_days,
         new.insurer_authorized_daily_rate_cents, new.insurer_policy_number, new.insurer_policy_province, new.insurer_policy_expiry,
         new.insured_vehicle, new.rental_pay_method, new.deposit_pay_method, new.odometer_out_km, new.odometer_in_km, new.checked_in_at))
  execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on renters;
create trigger agreement_touch after update on renters for each row
  when ((old.legal_name, old.date_of_birth, old.address_line1, old.address_line2, old.city, old.province, old.postal_code, old.mobile, old.email)
        is distinct from (new.legal_name, new.date_of_birth, new.address_line1, new.address_line2, new.city, new.province, new.postal_code, new.mobile, new.email))
  execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on drivers;
create trigger agreement_touch after update on drivers for each row
  when ((old.full_name, old.date_of_birth, old.licence_number, old.licence_class, old.licence_issuer, old.licence_expiry, old.address_line1,
         old.address_line2, old.city, old.province, old.postal_code)
        is distinct from (new.full_name, new.date_of_birth, new.licence_number, new.licence_class, new.licence_issuer, new.licence_expiry, new.address_line1,
         new.address_line2, new.city, new.province, new.postal_code))
  execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on vehicles;
create trigger agreement_touch after update on vehicles for each row
  when ((old.plate, old.vin, old.year, old.make, old.model, old.trim, old.colour, old.fleet_number)
        is distinct from (new.plate, new.vin, new.year, new.make, new.model, new.trim, new.colour, new.fleet_number))
  execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on booking_drivers;
create trigger agreement_touch after insert or update or delete on booking_drivers for each row execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on booking_line_items;
create trigger agreement_touch after insert or update or delete on booking_line_items for each row execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on coverage_proofs;
create trigger agreement_touch after insert or update on coverage_proofs for each row execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on deposits;
create trigger agreement_touch after insert or update on deposits for each row execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on payments;
create trigger agreement_touch after insert or update of status on payments for each row when (new.booking_id is not null) execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on booking_vehicle_swaps;
create trigger agreement_touch after insert on booking_vehicle_swaps for each row execute function app.agreement_touch_row();
drop trigger if exists agreement_touch on condition_reports;
create trigger agreement_touch after insert or update of odometer_km, fuel_pct, completed_at on condition_reports for each row
  when (new.booking_id is not null) execute function app.agreement_touch_row();
drop trigger if exists agreement_completed on rental_agreements;
create trigger agreement_completed after update of status on rental_agreements for each row execute function app.agreement_completed_after();

-- Claim the due jobs (a job running for more than 5 minutes is taken as lost).
create or replace function public.server_agreement_jobs_claim(p_limit integer default 1, p_ahead_seconds integer default 0) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j agreement_jobs;
  v_out jsonb := '[]'::jsonb;
begin
  for j in select * from agreement_jobs
            where due_at <= now() + make_interval(secs => least(greatest(coalesce(p_ahead_seconds, 0), 0), 20))
              and (locked_at is null or locked_at < now() - interval '5 minutes') and attempts < 8
            order by due_at limit greatest(1, least(coalesce(p_limit, 1), 10)) for update skip locked loop
    update agreement_jobs set locked_at = now(), locked_seq = seq, attempts = attempts + 1, updated_at = now()
     where kind = j.kind and ref = j.ref returning * into j;
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', j.kind, 'ref', j.ref, 'seq', j.seq, 'attempts', j.attempts, 'due_at', j.due_at));
  end loop;
  return v_out;
end $$;

-- Done: gone, unless it was touched again while running (then it runs again).
create or replace function public.server_agreement_job_done(p_kind text, p_ref uuid, p_seq integer) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  delete from agreement_jobs where kind = p_kind and ref = p_ref and seq = p_seq;
  update agreement_jobs set locked_at = null, locked_seq = null, attempts = 0, last_error = null where kind = p_kind and ref = p_ref;
end $$;

-- Failed: again after 1, 2, 5, 15, 60 minutes; the sixth failure gives an Admin a task.
create or replace function public.server_agreement_job_fail(p_kind text, p_ref uuid, p_error text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j agreement_jobs;
  v_booking uuid;
begin
  update agreement_jobs set locked_at = null, last_error = left(coalesce(p_error, 'failed'), 1000), updated_at = now(),
         due_at = now() + (case least(attempts, 6) when 1 then interval '1 minute' when 2 then interval '2 minutes' when 3 then interval '5 minutes'
                                                    when 4 then interval '15 minutes' else interval '60 minutes' end)
   where kind = p_kind and ref = p_ref returning * into j;
  if j.attempts >= 6 then
    v_booking := case p_kind when 'version' then p_ref
                             when 'version_signed' then (select v.booking_id from agreement_versions v where v.id = p_ref)
                             else (select d.booking_id from dispute_packs d where d.id = p_ref) end;
    perform app.raise_task(p_type => 'agreement_job_failed', p_title => format('Rental agreement work failed (%s): %s', p_kind, left(coalesce(p_error, ''), 160)),
      p_booking => v_booking, p_queue => 'admin', p_priority => 'high', p_dedupe => 'agreement_job_failed:' || p_kind || ':' || p_ref);
  end if;
end $$;

-- the Worker's cron runs the agreements' job (/api/jobs/agreements, 0132's: one path for missing agreements and this
-- queue) when there is queued agreement work too
alter function app.server_jobs_due() rename to server_jobs_due_pre0154;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0154();
begin
  if coalesce((v ->> 'agreements')::boolean, false) then return v; end if;
  return v || jsonb_build_object('agreements', exists (select 1 from agreement_jobs j where j.due_at <= now() and j.attempts < 8
                                                         and (j.locked_at is null or j.locked_at < now() - interval '5 minutes')));
end $$;
do $$ begin perform pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0154()'::regprocedure); end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('agreement_job_failed', 'admin', 'A rental agreement version could not be made', 'high', 'business_days', 1, 1, null,
   'The site tried six times to render a new version of a booking''s rental agreements (or its signed copy, or a dispute pack) and failed. The error is in the task; press Make the agreements again on the booking''s Agreement card.'),
  ('agreement_signature_waiting', 'cs', 'A new version of the rental agreement waits for a signature', 'normal', 'business_days', 1, 1, null,
   'The booking changed in a way the renter (or a driver) signs again: the dates, the price, the car, the drivers or the coverage option. The link went out by email and text; resend it or have them sign on your device (Agreement card).'),
  ('dispute_pack_ready', 'admin', 'Card dispute: check the evidence pack and submit it to Stripe', 'urgent', 'business_days', 1, 3, null,
   'A card payment was disputed. The evidence pack (signed agreements with their certificates, the check-out and check-in reports, the licence, receipts and messages) is built and staged in Stripe. Check it on the booking, then press Submit to Stripe before the evidence date.')
on conflict (task_type) do update set title = excluded.title, description = excluded.description, priority = excluded.priority;

-- ---------------------------------------------------------------- what the booking needs now
-- {state, ...}: none (no agreement), unsigned (the open agreement: the site renders it again), wait (signed, not yet
-- countersigned), current (nothing changed), version (a new version is due: kind, material, changes, signers).
create or replace function app.agreement_plan(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  l agreement_versions;
  cur jsonb;
  v_changes jsonb;
  v_material boolean;
  v_kind text;
  v_pick boolean;
  v_ret boolean;
  am booking_amendments;
  v_signers jsonb := '[]'::jsonb;
  v_added text[];
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return jsonb_build_object('state', 'none'); end if;
  select * into a from rental_agreements where booking_id = b.id and status in ('open', 'signed', 'completed') order by opened_at desc limit 1;
  if a.id is null then return jsonb_build_object('state', 'none'); end if;
  if a.status = 'open' then
    return jsonb_build_object('state', 'unsigned', 'agreement_id', a.id, 'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id),
      'any_signed', exists (select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.signed_at is not null));
  end if;
  if a.status = 'signed' then return jsonb_build_object('state', 'wait', 'agreement_id', a.id); end if;
  perform app.agreement_version_one(a.id);
  select * into l from agreement_versions where booking_id = b.id and status <> 'superseded' order by version_no desc limit 1;
  cur := app.agreement_snapshot(b.id);
  -- a record that is not there is JSON null in the snapshot: SQL null here
  cur := jsonb_set(jsonb_set(cur, '{pickup}', coalesce(nullif(cur -> 'pickup', 'null'::jsonb), 'null'::jsonb)), '{return}', coalesce(nullif(cur -> 'return', 'null'::jsonb), 'null'::jsonb));
  v_changes := app.agreement_changes(l.snapshot, cur);
  v_material := exists (select 1 from jsonb_array_elements(v_changes) x where (x ->> 'material')::boolean);
  v_pick := coalesce(jsonb_typeof(cur -> 'pickup') = 'object' and (cur -> 'pickup' ->> 'completed')::boolean, false)
            and (coalesce(jsonb_typeof(l.snapshot -> 'pickup'), 'null') <> 'object'
                 or (cur -> 'pickup' ->> 'report_id') is distinct from (l.snapshot -> 'pickup' ->> 'report_id')
                 or (cur -> 'pickup' ->> 'odometer_km') is distinct from (l.snapshot -> 'pickup' ->> 'odometer_km')
                 or (cur -> 'pickup' ->> 'fuel_pct') is distinct from (l.snapshot -> 'pickup' ->> 'fuel_pct'));
  v_ret := coalesce(jsonb_typeof(cur -> 'return') = 'object', false)
           and (coalesce(jsonb_typeof(l.snapshot -> 'return'), 'null') <> 'object'
                or (cur -> 'return') is distinct from (l.snapshot -> 'return'));
  -- the pickup readings the signed copy printed (signed at pickup after them): a later completion with the same
  -- readings needs no copy of its own; the completed flag alone is not a change
  if v_pick and l.version_no = 1 and (l.snapshot -> 'pickup' ->> 'report_id') = (cur -> 'pickup' ->> 'report_id')
     and (l.snapshot -> 'pickup' ->> 'odometer_km') = (cur -> 'pickup' ->> 'odometer_km') and (l.snapshot -> 'pickup' ->> 'fuel_pct') = (cur -> 'pickup' ->> 'fuel_pct') then
    v_pick := false;
  end if;
  if jsonb_array_length(v_changes) = 0 and not v_pick and not v_ret then
    return jsonb_build_object('state', 'current', 'agreement_id', a.id, 'version_no', l.version_no, 'snapshot_sha', app.agreement_sha(cur));
  end if;
  v_kind := case when v_ret then 'return' when v_pick then 'pickup' when v_material then 'change' else 'correction' end;
  -- a material change the renter already signed as an amendment (an accepted change or extension, 0040)
  if v_material then
    select * into am from booking_amendments where booking_id = b.id and status = 'signed' and signed_at > l.created_at order by signed_at desc limit 1;
  end if;
  if v_material and am.id is null then
    select array_agg(x.key) into v_added from jsonb_each(cur -> 'drivers') x
     where not coalesce(l.snapshot -> 'drivers', '{}'::jsonb) ? x.key and x.value ->> 'role' = 'additional';
    select coalesce(jsonb_agg(s order by s ->> 'role' desc, s ->> 'name'), '[]'::jsonb) into v_signers from (
      select jsonb_build_object('role', 'renter', 'booking_driver_id', d.id, 'user_id', r.user_id, 'name', coalesce(r.legal_name, d.full_name),
                                'email', coalesce(nullif(r.email, ''), (select u.email from users u where u.id = r.user_id)),
                                'mobile', coalesce(r.mobile, (select u.phone from users u where u.id = r.user_id))) as s
        from renters r left join booking_drivers d on d.booking_id = b.id and d.role = 'renter' where r.id = b.renter_id
      union all
      select jsonb_build_object('role', 'additional_driver', 'booking_driver_id', d.id, 'user_id', dv.user_id, 'name', d.full_name, 'email', dv.email, 'mobile', dv.mobile)
        from booking_drivers d join drivers dv on dv.id = d.driver_id
       where d.booking_id = b.id and d.role = 'additional'
         and (d.driver_id::text = any (coalesce(v_added, '{}'))
              or exists (select 1 from jsonb_array_elements(v_changes) x where x ->> 'key' in ('vehicle.id', 'coverage.option', 'dates.pickup_at', 'dates.return_at')))) q;
  end if;
  return jsonb_build_object('state', 'version', 'agreement_id', a.id, 'agreement_number', a.agreement_number, 'kind', v_kind,
    'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id), 'original_signed_at', a.renter_signed_at,
    -- who the site reads the booking as: the renter, else (a renter with no account) the staff member who added it, else an Admin
    'acting_user_id', coalesce((select r.user_id from renters r where r.id = b.renter_id), b.created_by,
                               (select u.id from users u where app.user_is_admin(u.id) order by u.created_at limit 1)),
    'material', v_material and am.id is null, 'changes', v_changes, 'snapshot', cur, 'snapshot_sha', app.agreement_sha(cur),
    'next_no', l.version_no + 1, 'previous_no', l.version_no, 'signers', v_signers, 'amendment_id', am.id, 'amendment_number', am.amendment_number,
    'pickup', app.agreement_pickup(b.id), 'return', app.agreement_return(b.id),
    'countersigner', case when v_kind = 'return' then app.agreement_return(b.id) -> 'staff_user_id' when v_kind = 'pickup' then app.agreement_pickup(b.id) -> 'staff_user_id' end);
end $$;

create or replace function public.server_agreement_plan(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.agreement_plan(p_booking) $$;

-- The versions of a booking, newest first, with their documents and signers.
create or replace function app.agreement_versions_of(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'version_no', v.version_no, 'kind', v.kind, 'material', v.material, 'status', v.status,
           'changes', v.changes, 'created_at', v.created_at, 'signed_at', v.signed_at, 'note', v.note,
           'countersigned_name', v.countersigned_name, 'countersigned_at', v.countersigned_at, 'amendment_id', v.amendment_id,
           'carmacars', coalesce(v.signed_carmacars_document_id, v.carmacars_document_id, case when v.version_no = 1 then
                          (select s.signed_document_id from rental_agreements a join signature_requests s on s.id = a.signature_request_id where a.id = v.rental_agreement_id) end),
           'blindspot', coalesce(v.signed_blindspot_document_id, v.blindspot_document_id, case when v.version_no = 1 then
                          (select coalesce(c.signed_document_id, c.document_id) from rental_agreement_companions c where c.rental_agreement_id = v.rental_agreement_id and c.status <> 'superseded' limit 1) end),
           'carmacars_sha256', v.carmacars_sha256, 'blindspot_sha256', v.blindspot_sha256,
           'signers', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'role', g.role, 'name', g.name, 'status', g.status, 'signed_at', g.signed_at,
                                  'has_email', g.email is not null, 'has_mobile', g.mobile is not null, 'link_sent_at', g.link_sent_at) order by g.role desc, g.name)
                                  from agreement_version_signers g where g.version_id = v.id), '[]'::jsonb))
           order by v.version_no desc), '[]'::jsonb)
    from agreement_versions v where v.booking_id = p_booking
$$;

-- The site rendered both documents for the plan: the version is recorded (refused when the booking changed since the
-- plan was read: the job runs again). p: snapshot_sha, kind, carmacars {path, sha256}, blindspot {path, sha256} or null.
create or replace function public.server_agreement_version_add(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  pl jsonb;
  v_id uuid;
  v_cc uuid;
  v_bs uuid;
  v_no integer;
  v_kind text;
  v_label text;
  s jsonb;
  g agreement_version_signers;
  v_status text;
  v_staff uuid;
begin
  select * into b from bookings where id = p_booking for update;
  pl := app.agreement_plan(p_booking);
  if pl ->> 'state' <> 'version' then return jsonb_build_object('recorded', false, 'state', pl ->> 'state'); end if;
  if pl ->> 'snapshot_sha' is distinct from p ->> 'snapshot_sha' then
    raise exception 'The booking changed while its agreements were being made: they are made again' using errcode = '40001';
  end if;
  v_no := (pl ->> 'next_no')::integer;
  v_kind := pl ->> 'kind';
  v_label := case v_kind when 'pickup' then 'as picked up' when 'return' then 'as returned' when 'change' then 'changed' else 'corrected' end;
  if nullif(p #>> '{carmacars,path}', '') is null or coalesce(p #>> '{carmacars,sha256}', '') !~ '^[0-9a-f]{64}$'
     or p #>> '{carmacars,path}' !~ ('^bookings/' || p_booking || '/') then
    raise exception 'A version needs the CarmaCars document and its SHA-256' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, renter_id, booking_id)
  values ('rental_agreement', format('Rental agreement %s, version %s (%s)', coalesce(pl ->> 'agreement_number', b.booking_number), v_no, v_label), 'agreements',
          p #>> '{carmacars,path}', 'application/pdf', p #>> '{carmacars,sha256}', p ->> 'template_version', 'records_7y', b.renter_id, b.id)
  returning id into v_cc;
  if nullif(p #>> '{blindspot,path}', '') is not null then
    if coalesce(p #>> '{blindspot,sha256}', '') !~ '^[0-9a-f]{64}$' or p #>> '{blindspot,path}' !~ ('^bookings/' || p_booking || '/') then
      raise exception 'The Blind Spot document of a version needs its SHA-256' using errcode = '22023';
    end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, renter_id, booking_id)
    values ('rental_agreement', format('Blind Spot rental agreement %s, version %s (%s)', b.booking_number, v_no, v_label), 'agreements',
            p #>> '{blindspot,path}', 'application/pdf', p #>> '{blindspot,sha256}', p ->> 'blindspot_template_version', 'records_7y', b.renter_id, b.id)
    returning id into v_bs;
  end if;
  v_status := case when (pl ->> 'material')::boolean and jsonb_array_length(pl -> 'signers') > 0 then 'awaiting_signature'
                   when pl ->> 'amendment_id' is not null then 'signed' else 'filed' end;
  -- an earlier version still waiting is replaced by this one (it carries the same changes and more)
  update agreement_version_signers set status = 'void' where status = 'waiting'
     and version_id in (select id from agreement_versions where booking_id = b.id and status = 'awaiting_signature');
  update agreement_versions set status = 'superseded', superseded_at = now() where booking_id = b.id and status = 'awaiting_signature';
  v_staff := nullif(pl ->> 'countersigner', '')::uuid;
  insert into agreement_versions (booking_id, version_no, kind, material, status, changes, snapshot, snapshot_sha, rental_agreement_id,
                                  carmacars_document_id, carmacars_sha256, blindspot_document_id, blindspot_sha256, condition_report_id,
                                  countersigned_by, countersigned_name, countersigned_at, amendment_id, note, signed_at)
  values (b.id, v_no, v_kind, (pl ->> 'material')::boolean, v_status, pl -> 'changes', pl -> 'snapshot', pl ->> 'snapshot_sha', (pl ->> 'agreement_id')::uuid,
          v_cc, p #>> '{carmacars,sha256}', v_bs, p #>> '{blindspot,sha256}',
          nullif(case v_kind when 'pickup' then pl #>> '{pickup,report_id}' when 'return' then pl #>> '{return,report_id}' end, '')::uuid,
          v_staff, coalesce(p ->> 'countersigned_name', (select u.full_name from users u where u.id = v_staff)), case when v_kind in ('pickup', 'return') then now() end,
          nullif(pl ->> 'amendment_id', '')::uuid,
          case when pl ->> 'amendment_id' is not null then format('Signed by the renter as amendment %s', pl ->> 'amendment_number') end,
          case when v_status = 'signed' then now() end)
  returning id into v_id;
  if v_status = 'awaiting_signature' then
    for s in select value from jsonb_array_elements(pl -> 'signers') loop
      insert into agreement_version_signers (version_id, role, booking_driver_id, user_id, name, email, mobile)
      values (v_id, s ->> 'role', nullif(s ->> 'booking_driver_id', '')::uuid, nullif(s ->> 'user_id', '')::uuid, s ->> 'name', nullif(s ->> 'email', ''), nullif(s ->> 'mobile', ''));
    end loop;
    perform app.raise_task(p_type => 'agreement_signature_waiting',
      p_title => format('Booking %s: agreement version %s waits for %s', b.booking_number, v_no,
                        (select string_agg(g2.name, ', ') from agreement_version_signers g2 where g2.version_id = v_id)),
      p_booking => b.id, p_renter => b.renter_id, p_related_table => 'agreement_versions', p_related_id => v_id,
      p_dedupe => 'agreement_signature_waiting:' || b.id);
  end if;
  perform app.log_booking_event(b.id, 'agreement_version', b.status::text, b.status::text, null,
    format('Rental agreement version %s (%s)%s', v_no, v_label, case when v_status = 'awaiting_signature' then ': waiting for signature' else '' end), null, 'system',
    jsonb_build_object('version_id', v_id, 'version_no', v_no, 'kind', v_kind, 'material', (pl ->> 'material')::boolean, 'changes', pl -> 'changes'));
  perform app.agreement_version_notify(v_id);
  return jsonb_build_object('recorded', true, 'version_id', v_id, 'version_no', v_no, 'status', v_status);
end $$;

-- The site's base address, for links in texts and emails.
create or replace function app.agreement_site() returns text
language sql stable security definer set search_path = public, app as $$
  select rtrim(coalesce((select nullif(s.site_url, '') from site_settings s limit 1), 'https://carmacars.ca'), '/')
$$;

-- Each signer of a version waiting: the email (with both documents) and a text with their link; a version filed
-- without signing: the email to the renter with both documents.
create or replace function app.agreement_version_notify(p_version uuid, p_resend boolean default false) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v agreement_versions;
  b bookings;
  g agreement_version_signers;
  n integer := 0;
  v_link text;
  v_disc text := case when p_resend then ':resend:' || to_char(now(), 'YYYYMMDDHH24MISS') else '' end;
begin
  select * into v from agreement_versions where id = p_version;
  select * into b from bookings where id = v.booking_id;
  if v.status = 'awaiting_signature' then
    for g in select * from agreement_version_signers where version_id = v.id and status = 'waiting' loop
      v_link := app.agreement_site() || '/sign/agreement/' || g.link_token;
      if g.email is not null then
        perform app.emit_event('renter_agreement_version', 'agreement_version', v.id,
          jsonb_build_object('booking_id', b.id, 'version_id', v.id, 'signer_id', g.id, 'signer_email', g.email, 'signer_name', g.name,
                             'signer_user_id', g.user_id, 'needs_signature', true, 'sign_token', g.link_token::text),
          'renter_agreement_version:' || v.id || ':' || g.id || v_disc);
        n := n + 1;
      end if;
      if g.mobile is not null then
        perform app.phone_outbox_put(g.mobile, format('CarmaCars: your rental agreement for booking %s changed (version %s). Please review and sign: %s',
                                                      b.booking_number, v.version_no, v_link),
                                     'booking', b.id, case when g.role = 'renter' then b.renter_id end, 'agreement_version', null, 'agreement_version:' || g.id || v_disc, now(), 'queued', null);
        n := n + 1;
      end if;
      update agreement_version_signers set link_sent_at = now() where id = g.id;
    end loop;
  elsif v.version_no > 1 then
    perform app.emit_event('renter_agreement_version', 'agreement_version', v.id,
      jsonb_build_object('booking_id', b.id, 'version_id', v.id, 'needs_signature', false), 'renter_agreement_version:' || v.id || ':renter' || v_disc);
    n := 1;
  end if;
  return n;
end $$;

-- Where a one-time code goes, shown without giving it away.
create or replace function app.esign_mask_email(p text) returns text
language sql immutable as $$
  select case when p is null or position('@' in p) = 0 then null
              else left(split_part(p, '@', 1), 1) || repeat('*', greatest(length(split_part(p, '@', 1)) - 1, 2)) || '@' || split_part(p, '@', 2) end
$$;
create or replace function app.esign_mask_phone(p text) returns text
language sql immutable as $$
  select case when p is null or length(regexp_replace(p, '\D', '', 'g')) < 7 then null
              else '***-***-' || right(regexp_replace(p, '\D', '', 'g'), 4) end
$$;

-- A version signer's link: what the page shows.
create or replace function public.server_agreement_version_link(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('signer_id', g.id, 'role', g.role, 'name', g.name, 'status', g.status, 'signed_at', g.signed_at, 'user_id', g.user_id,
           'masked_email', app.esign_mask_email(g.email), 'masked_mobile', app.esign_mask_phone(g.mobile), 'booking_driver_id', g.booking_driver_id,
           'version', jsonb_build_object('id', v.id, 'version_no', v.version_no, 'kind', v.kind, 'status', v.status, 'changes', v.changes,
                                         'carmacars_document_id', v.carmacars_document_id, 'carmacars_sha256', v.carmacars_sha256,
                                         'blindspot_document_id', v.blindspot_document_id, 'blindspot_sha256', v.blindspot_sha256, 'created_at', v.created_at),
           'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id,
                                         'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id)),
           'documents', jsonb_build_object(
             'carmacars', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'title', d.title) from documents d where d.id = v.carmacars_document_id),
             'blindspot', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'title', d.title) from documents d where d.id = v.blindspot_document_id)))
    from agreement_version_signers g join agreement_versions v on v.id = g.version_id join bookings b on b.id = v.booking_id
   where g.link_token = p_token
$$;

-- ================================================================ 5. electronic signatures that hold up
-- One signing session per signer and document set: identity (a one-time code to the signer's phone or email, the
-- licence on file), the documents viewed, the initials on the key terms, the explicit consents, the drawn signature,
-- and every step with its time, IP address and device (and the place, when the signer allows it). The database refuses
-- a rental agreement, an amendment or a new version signed without a complete session (esign_strict).
create table if not exists esign_sessions (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid references bookings (id) on delete cascade,
  context            text not null check (context in ('rental_agreement', 'amendment', 'agreement_version')),
  signer_ref         uuid not null,          -- rental_agreement_signers, booking_amendments or agreement_version_signers
  signer_role        text not null,
  signer_name        text not null,
  driver_id          uuid references drivers (id),
  method             text not null default 'remote' check (method in ('remote', 'in_person')),
  collected_by       uuid references users (id),
  documents          jsonb not null default '[]'::jsonb,   -- [{title, sha256}] what the signer was shown
  email              text,
  mobile             text,
  required_initials  text[] not null default '{}',
  required_consents  text[] not null default '{}',
  otp_channel        text check (otp_channel in ('sms', 'email')),
  otp_to             text,
  otp_hash           text,
  otp_sent_at        timestamptz,
  otp_expires_at     timestamptz,
  otp_sends          integer not null default 0,
  otp_attempts       integer not null default 0,
  otp_verified_at    timestamptz,
  viewed_at          timestamptz,
  initials           jsonb not null default '{}'::jsonb,   -- {code: {at, path, typed}}
  consents           jsonb not null default '{}'::jsonb,   -- {code: {at, text}}
  geo                jsonb,
  ip_address         inet,
  user_agent         text,
  signature_method   text check (signature_method in ('drawn', 'typed')),
  signature_path     text,
  typed_fallback     boolean not null default false,
  signed_at          timestamptz,
  signature_record_id uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists esign_sessions_ref on esign_sessions (context, signer_ref, created_at desc);
create index if not exists esign_sessions_booking on esign_sessions (booking_id);
comment on table esign_sessions is 'Each electronic signing (0154): identity code, documents viewed, initials, consents, the signature, with time, IP, device and place.';
create table if not exists esign_events (
  id          bigserial primary key,
  session_id  uuid not null references esign_sessions (id) on delete cascade,
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('started', 'code_sent', 'code_failed', 'code_verified', 'viewed', 'document_opened', 'initial',
                                            'consent', 'geolocation', 'signature', 'signed')),
  detail      jsonb not null default '{}'::jsonb,
  ip_address  inet,
  user_agent  text
);
create index if not exists esign_events_session on esign_events (session_id, at);
create trigger audit_esign_sessions after insert or update or delete on esign_sessions for each row execute function app.audit_row();
comment on table esign_events is 'The audit trail of each signing session (0154): one row per step, never changed.';
alter table esign_sessions enable row level security;
alter table esign_events enable row level security;
create policy admin_all on esign_sessions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on esign_events for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on esign_sessions, esign_events from anon, authenticated;
grant select, insert, update on esign_sessions, esign_events to service_role;
grant usage on sequence esign_events_id_seq to service_role;
create or replace function app.esign_events_append_only() returns trigger
language plpgsql as $$ begin raise exception 'The signing audit trail is append-only' using errcode = '42501'; end $$;
drop trigger if exists esign_events_append_only on esign_events;
create trigger esign_events_append_only before update or delete on esign_events for each row execute function app.esign_events_append_only();

-- The key terms each signer initials, and the consents they give.
create or replace function app.esign_requirements(p_context text, p_role text, out initials text[], out consents text[])
language sql immutable as $$
  select case when p_context = 'amendment' then array['charges']
              when p_role = 'renter' then array['damage', 'charges', 'fees', 'coverage', 'cancellation']
              else array['damage', 'fees', 'coverage'] end,
         case when p_role = 'renter' then array['esign', 'erecords', 'card'] else array['esign', 'erecords'] end
$$;

-- Start (or pick up) a signing session. p: context, signer_ref, booking_id, method, collected_by, documents, ip, user_agent.
-- The signer's name, role and contact come from the records, never from the page.
create or replace function public.server_esign_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ctx text := p ->> 'context';
  v_ref uuid := (p ->> 'signer_ref')::uuid;
  v_method text := coalesce(p ->> 'method', 'remote');
  s esign_sessions;
  v_role text; v_name text; v_email text; v_mobile text; v_booking uuid; v_driver uuid;
  rq record;
begin
  if v_ctx = 'rental_agreement' then
    select g.signer_role, g.signer_name, coalesce(g.signer_email, dv.email, r.email), case when g.signer_role = 'renter' then coalesce(r.mobile, u.phone) else dv.mobile end,
           a.booking_id, g.driver_id
      into v_role, v_name, v_email, v_mobile, v_booking, v_driver
      from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id join bookings b on b.id = a.booking_id
      join renters r on r.id = b.renter_id left join users u on u.id = r.user_id left join drivers dv on dv.id = g.driver_id
     where g.id = v_ref and g.signer_role in ('renter', 'additional_driver');
  elsif v_ctx = 'amendment' then
    select 'renter', r.legal_name, coalesce(nullif(r.email, ''), u.email), coalesce(r.mobile, u.phone), m.booking_id,
           (select d.driver_id from booking_drivers d where d.booking_id = m.booking_id and d.role = 'renter')
      into v_role, v_name, v_email, v_mobile, v_booking, v_driver
      from booking_amendments m join bookings b on b.id = m.booking_id join renters r on r.id = b.renter_id left join users u on u.id = r.user_id
     where m.id = v_ref;
  elsif v_ctx = 'agreement_version' then
    select g.role, g.name, g.email, g.mobile, v.booking_id, (select d.driver_id from booking_drivers d where d.id = g.booking_driver_id)
      into v_role, v_name, v_email, v_mobile, v_booking, v_driver
      from agreement_version_signers g join agreement_versions v on v.id = g.version_id where g.id = v_ref and g.status = 'waiting';
  else
    raise exception 'Unknown signing' using errcode = '22023';
  end if;
  if v_name is null then raise exception 'Nothing to sign here' using errcode = 'P0002'; end if;
  if v_method = 'in_person' and not app.user_may_handover(nullif(p ->> 'collected_by', '')::uuid) then
    raise exception 'Only staff collect a signature in person' using errcode = '42501';
  end if;
  select * into s from esign_sessions where context = v_ctx and signer_ref = v_ref and method = v_method and signed_at is null
     and created_at > now() - interval '2 hours' and documents = coalesce(p -> 'documents', '[]'::jsonb)
   order by created_at desc limit 1;
  if s.id is null then
    rq := app.esign_requirements(v_ctx, case when v_role = 'renter' then 'renter' else 'driver' end);
    insert into esign_sessions (booking_id, context, signer_ref, signer_role, signer_name, driver_id, method, collected_by, documents, email, mobile,
                                required_initials, required_consents, ip_address, user_agent)
    values (v_booking, v_ctx, v_ref, v_role, v_name, v_driver, v_method, nullif(p ->> 'collected_by', '')::uuid, coalesce(p -> 'documents', '[]'::jsonb),
            nullif(v_email, ''), nullif(v_mobile, ''), rq.initials, rq.consents, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent')
    returning * into s;
    insert into esign_events (session_id, kind, detail, ip_address, user_agent)
    values (s.id, 'started', jsonb_build_object('method', v_method, 'collected_by', (select u.full_name from users u where u.id = s.collected_by), 'documents', s.documents),
            nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return app.esign_view(s.id);
end $$;

create or replace function app.esign_is_ready(s esign_sessions) returns boolean
language sql stable security definer set search_path = public, app as $$
  select s.id is not null and s.signed_at is null and s.created_at > now() - interval '2 hours' and s.otp_verified_at is not null
     and s.viewed_at is not null
     and (select bool_and(s.initials ? x) from unnest(s.required_initials) x) is not false
     and (select bool_and(s.consents ? x) from unnest(s.required_consents) x) is not false
     and s.signature_path is not null
     and (s.signature_method = 'drawn' or (s.signature_method = 'typed' and s.typed_fallback and coalesce((app.settings()).esign_typed_fallback, false)))
$$;

-- The open rental agreement's signer for a signing page: the renter (p_user must be the booking's renter), an
-- additional driver (by their signer row, the link's), with the documents' SHA-256 the signer is shown.
create or replace function public.server_esign_signer(p_booking uuid, p_user uuid, p_signer uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('signer_id', g.id, 'role', g.signer_role, 'name', g.signer_name, 'booking_id', a.booking_id,
           'documents', jsonb_build_array(jsonb_build_object('title', 'CarmaCars rental agreement', 'sha256', a.document_sha256))
             || coalesce((select jsonb_build_array(jsonb_build_object('title', 'Blind Spot rental agreement', 'sha256', c.document_sha256))
                            from rental_agreement_companions c where c.rental_agreement_id = a.id and c.status = 'open' and g.signer_role = 'renter'), '[]'::jsonb))
    from rental_agreements a join rental_agreement_signers g on g.agreement_id = a.id
   where a.status = 'open' and g.signed_at is null
     and ((p_signer is not null and g.id = p_signer and (p_booking is null or a.booking_id = p_booking))
          or (p_signer is null and a.booking_id = p_booking and g.signer_role = 'renter' and app.is_booking_renter(p_booking, p_user)))
   order by a.opened_at desc limit 1
$$;

-- What the signing page knows about its session (no code, no raw contact).
create or replace function app.esign_view(p_session uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', s.id, 'context', s.context, 'signer_name', s.signer_name, 'signer_role', s.signer_role, 'method', s.method,
           'channels', (select coalesce(jsonb_agg(c), '[]'::jsonb) from (
              select jsonb_build_object('channel', 'sms', 'to', app.esign_mask_phone(s.mobile)) c where s.mobile is not null
              union all select jsonb_build_object('channel', 'email', 'to', app.esign_mask_email(s.email)) where s.email is not null) q),
           'code_sent_to', case s.otp_channel when 'sms' then app.esign_mask_phone(s.otp_to) when 'email' then app.esign_mask_email(s.otp_to) end,
           'verified', s.otp_verified_at is not null, 'viewed', s.viewed_at is not null,
           'required_initials', to_jsonb(s.required_initials), 'required_consents', to_jsonb(s.required_consents),
           'initials', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(s.initials) k),
           'consents', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(s.consents) k),
           'signature', s.signature_method, 'typed_fallback_allowed', coalesce((app.settings()).esign_typed_fallback, false),
           'licence', case when s.driver_id is not null and s.booking_id is not null then app.licence_status(s.booking_id, s.driver_id) end,
           'signed', s.signed_at is not null, 'ready', app.esign_is_ready(s))
    from esign_sessions s where s.id = p_session
$$;

create or replace function public.server_esign_view(p_session uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.esign_view(p_session) $$;

-- The session a signing call may use: the signer's newest complete session (null when there is none).
create or replace function app.esign_ready(p_context text, p_ref uuid) returns esign_sessions
language sql stable security definer set search_path = public, app as $$
  select s.* from esign_sessions s where s.context = p_context and s.signer_ref = p_ref and app.esign_is_ready(s) order by s.created_at desc limit 1
$$;

-- A new one-time code: its hash (the site makes the code and sends it), where it went, and when it expires. At most 5
-- codes a session, 30 seconds apart. Returns where to send it (and, for a text, the CarmaCars number).
create or replace function public.server_esign_code_set(p_session uuid, p_channel text, p_hash text, p_ip text default null, p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v_to text;
begin
  select * into s from esign_sessions where id = p_session for update;
  if s.id is null or s.signed_at is not null then raise exception 'This signing has ended: reload the page' using errcode = '23514'; end if;
  if p_channel not in ('sms', 'email') or coalesce(p_hash, '') !~ '^[0-9a-f]{64}$' then raise exception 'Unknown code' using errcode = '22023'; end if;
  v_to := case p_channel when 'sms' then s.mobile else s.email end;
  if v_to is null then raise exception 'No % on file for %', case p_channel when 'sms' then 'mobile number' else 'email' end, s.signer_name using errcode = '23514'; end if;
  if s.otp_sends >= 5 then raise exception 'Too many codes for this signing. Reload the page in a few minutes' using errcode = '23514'; end if;
  if s.otp_sent_at > now() - interval '30 seconds' then raise exception 'Wait a few seconds before asking for another code' using errcode = '23514'; end if;
  update esign_sessions set otp_channel = p_channel, otp_to = v_to, otp_hash = p_hash, otp_sent_at = now(), otp_sends = otp_sends + 1, otp_attempts = 0,
         otp_expires_at = now() + make_interval(mins => coalesce((app.settings()).esign_code_minutes, 10)), updated_at = now()
   where id = s.id;
  insert into esign_events (session_id, kind, detail, ip_address, user_agent)
  values (s.id, 'code_sent', jsonb_build_object('channel', p_channel, 'to', case p_channel when 'sms' then app.esign_mask_phone(v_to) else app.esign_mask_email(v_to) end),
          nullif(p_ip, '')::inet, p_user_agent);
  if p_channel = 'email' then
    -- the code itself goes in the email's payload only (never stored here in clear)
    null;
  end if;
  return jsonb_build_object('to', v_to, 'from', app.phone_our_number(), 'name', s.signer_name, 'booking_id', s.booking_id);
end $$;

-- Whose session it is (the site checks it against the signer it finds from the records).
create or replace function public.server_esign_owner(p_session uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('signer_ref', s.signer_ref, 'context', s.context, 'booking_id', s.booking_id) from esign_sessions s where s.id = p_session
$$;

-- The code by email: the "renter_signing_code" email to the signer's email on file (the code only in that email).
create or replace function app.esign_code_email(p_session uuid, p_code text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
begin
  select * into s from esign_sessions where id = p_session;
  if s.id is null or s.otp_channel <> 'email' or s.email is null then raise exception 'Ask for the code by email first' using errcode = '23514'; end if;
  perform app.emit_event('renter_signing_code', 'esign_session', s.id,
    jsonb_build_object('booking_id', s.booking_id, 'signer_email', s.email, 'signer_name', s.signer_name, 'code', p_code),
    'renter_signing_code:' || s.id || ':' || s.otp_sends);
end $$;
create or replace function public.server_esign_code_email(p_session uuid, p_code text) returns void
language sql security definer set search_path = public, app as $$ select app.esign_code_email(p_session, p_code) $$;

-- The code typed: right (verified), wrong (5 tries) or expired.
create or replace function public.server_esign_code_check(p_session uuid, p_hash text, p_ip text default null, p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
begin
  select * into s from esign_sessions where id = p_session for update;
  if s.id is null or s.signed_at is not null then raise exception 'This signing has ended: reload the page' using errcode = '23514'; end if;
  if s.otp_verified_at is not null then return app.esign_view(s.id); end if;
  if s.otp_hash is null then raise exception 'Ask for a code first' using errcode = '23514'; end if;
  if s.otp_attempts >= 5 or s.otp_expires_at < now() then raise exception 'That code has expired: ask for a new one' using errcode = '23514'; end if;
  if s.otp_hash <> lower(coalesce(p_hash, '')) then
    update esign_sessions set otp_attempts = otp_attempts + 1, updated_at = now() where id = s.id;
    insert into esign_events (session_id, kind, detail, ip_address, user_agent) values (s.id, 'code_failed', jsonb_build_object('attempt', s.otp_attempts + 1), nullif(p_ip, '')::inet, p_user_agent);
    return app.esign_view(s.id) || jsonb_build_object('wrong', true);
  end if;
  update esign_sessions set otp_verified_at = now(), updated_at = now() where id = s.id;
  insert into esign_events (session_id, kind, detail, ip_address, user_agent)
  values (s.id, 'code_verified', jsonb_build_object('channel', s.otp_channel, 'to', case s.otp_channel when 'sms' then app.esign_mask_phone(s.otp_to) else app.esign_mask_email(s.otp_to) end),
          nullif(p_ip, '')::inet, p_user_agent);
  return app.esign_view(s.id);
end $$;

-- One step of the signer: viewed, document_opened, initial {code, path | typed}, consent {code, text}, geolocation
-- {lat, lng, accuracy}, signature {method, path}. Each is an event; the session keeps the latest.
create or replace function public.server_esign_step(p_session uuid, p_kind text, p_detail jsonb, p_ip text default null, p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  d jsonb := coalesce(p_detail, '{}'::jsonb);
  v_code text := d ->> 'code';
begin
  select * into s from esign_sessions where id = p_session for update;
  if s.id is null or s.signed_at is not null then raise exception 'This signing has ended: reload the page' using errcode = '23514'; end if;
  if p_kind not in ('viewed', 'document_opened', 'initial', 'consent', 'geolocation', 'signature') then raise exception 'Unknown step' using errcode = '22023'; end if;
  if p_kind in ('initial', 'consent', 'signature') and s.otp_verified_at is null then
    raise exception 'Confirm the code first' using errcode = '23514';
  end if;
  if p_kind = 'initial' then
    if not v_code = any (s.required_initials) then raise exception 'Unknown term to initial' using errcode = '22023'; end if;
    if coalesce(d ->> 'path', '') = '' and not (coalesce((d ->> 'typed')::boolean, false) and coalesce((app.settings()).esign_typed_fallback, false)) then
      raise exception 'Initial in the box' using errcode = '22023';
    end if;
    update esign_sessions set initials = initials || jsonb_build_object(v_code, jsonb_build_object('at', now(), 'path', d ->> 'path', 'typed', d ->> 'text')), updated_at = now() where id = s.id;
  elsif p_kind = 'consent' then
    if not v_code = any (s.required_consents) then raise exception 'Unknown consent' using errcode = '22023'; end if;
    update esign_sessions set consents = consents || jsonb_build_object(v_code, jsonb_build_object('at', now(), 'text', left(d ->> 'text', 2000))), updated_at = now() where id = s.id;
  elsif p_kind = 'viewed' then
    update esign_sessions set viewed_at = coalesce(viewed_at, now()), updated_at = now() where id = s.id;
  elsif p_kind = 'geolocation' then
    update esign_sessions set geo = jsonb_build_object('lat', (d ->> 'lat')::numeric, 'lng', (d ->> 'lng')::numeric, 'accuracy_m', (d ->> 'accuracy')::numeric, 'at', now()), updated_at = now() where id = s.id;
  elsif p_kind = 'signature' then
    if d ->> 'method' = 'typed' and not coalesce((app.settings()).esign_typed_fallback, false) then
      raise exception 'Draw your signature in the box' using errcode = '22023';
    end if;
    if d ->> 'method' not in ('drawn', 'typed') or coalesce(d ->> 'path', '') = '' then raise exception 'Draw your signature in the box' using errcode = '22023'; end if;
    update esign_sessions set signature_method = d ->> 'method', signature_path = d ->> 'path', typed_fallback = d ->> 'method' = 'typed', updated_at = now() where id = s.id;
  end if;
  insert into esign_events (session_id, kind, detail, ip_address, user_agent) values (s.id, p_kind, d - 'text' || case when p_kind = 'consent' then jsonb_build_object('text', left(d ->> 'text', 300)) else '{}'::jsonb end,
                                                                                    nullif(p_ip, '')::inet, p_user_agent);
  update esign_sessions set ip_address = coalesce(nullif(p_ip, '')::inet, ip_address), user_agent = coalesce(p_user_agent, user_agent) where id = s.id;
  return app.esign_view(s.id);
end $$;

-- The signing call used the session: it is closed with the signature it made.
create or replace function app.esign_close(p_session uuid, p_record uuid, p_ip inet, p_user_agent text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_session is null then return; end if;
  update esign_sessions set signed_at = now(), signature_record_id = p_record, updated_at = now() where id = p_session;
  insert into esign_events (session_id, kind, detail, ip_address, user_agent) values (p_session, 'signed', jsonb_build_object('record', p_record), p_ip, p_user_agent);
end $$;

-- The rental agreement (remote, in person, additional drivers) is signed only with a complete session.
alter function app.record_signature(uuid, uuid, text, text, inet, text, text, text, jsonb) rename to record_signature_pre0154;
create or replace function app.record_signature(p_request uuid, p_signer uuid, p_typed_name text, p_drawn_signature text,
                                                p_ip inet, p_user_agent text, p_consent_text text,
                                                p_document_sha256 text default null, p_consents jsonb default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v_rec uuid;
  v_role text := (select g.signer_role from rental_agreement_signers g where g.id = p_signer);
begin
  if coalesce((app.settings()).esign_strict, true) and v_role in ('renter', 'additional_driver') then
    s := app.esign_ready('rental_agreement', p_signer);
    if s.id is null then
      raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
    end if;
    if s.signature_method = 'drawn' and p_drawn_signature is distinct from s.signature_path then
      raise exception 'The signature does not match the one drawn: sign again' using errcode = '23514';
    end if;
    if s.signature_method = 'typed' and nullif(btrim(coalesce(p_typed_name, '')), '') is null then
      raise exception 'Type your full legal name' using errcode = '22023';
    end if;
  end if;
  v_rec := app.record_signature_pre0154(p_request, p_signer, p_typed_name, p_drawn_signature, p_ip, p_user_agent, p_consent_text, p_document_sha256, p_consents);
  perform app.esign_close(s.id, v_rec, p_ip, p_user_agent);
  return v_rec;
end $$;

-- ... an amendment too
alter function app.sign_booking_amendment(uuid, uuid, text, text, text, text, inet, text) rename to sign_booking_amendment_pre0154;
create or replace function app.sign_booking_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v jsonb;
begin
  if coalesce((app.settings()).esign_strict, true) then
    s := app.esign_ready('amendment', p_amendment);
    if s.id is null then
      raise exception 'Confirm your identity with the code, initial the payment term, give the consents and draw your signature before signing' using errcode = '23514';
    end if;
    if s.signature_method = 'drawn' and p_drawn_signature is distinct from s.signature_path then
      raise exception 'The signature does not match the one drawn: sign again' using errcode = '23514';
    end if;
  end if;
  v := app.sign_booking_amendment_pre0154(p_amendment, p_by, p_consent_text, p_document_sha256, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
  perform app.esign_close(s.id, (select m.signature_record_id from booking_amendments m where m.id = p_amendment), p_ip, p_user_agent);
  return v;
end $$;

-- A version signer signs (by their link, or on a staff member's device). p: carmacars_sha256, blindspot_sha256,
-- consent_text, typed_name, drawn, ip, user_agent. The last signature signs the version.
create or replace function public.server_agreement_version_sign(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g agreement_version_signers;
  v agreement_versions;
  s esign_sessions;
begin
  select * into g from agreement_version_signers where link_token = p_token for update;
  if g.id is null then raise exception 'This link is not valid' using errcode = 'P0002'; end if;
  select * into v from agreement_versions where id = g.version_id for update;
  if g.status <> 'waiting' or v.status <> 'awaiting_signature' then
    raise exception 'This version of the agreement is no longer waiting for your signature' using errcode = '23514';
  end if;
  if lower(coalesce(p ->> 'carmacars_sha256', '')) <> v.carmacars_sha256 or (v.blindspot_sha256 is not null and lower(coalesce(p ->> 'blindspot_sha256', '')) <> v.blindspot_sha256) then
    raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  s := app.esign_ready('agreement_version', g.id);
  if coalesce((app.settings()).esign_strict, true) and s.id is null then
    raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p ->> 'consent_text', '')), '') is null then raise exception 'The statement signed is recorded with the signature' using errcode = '22023'; end if;
  update agreement_version_signers set status = 'signed', signed_at = now(), method = coalesce(s.signature_method, case when p ->> 'drawn' is not null then 'drawn' else 'typed' end),
         signature_path = coalesce(s.signature_path, p ->> 'drawn'), ip_address = nullif(p ->> 'ip', '')::inet, user_agent = p ->> 'user_agent',
         consent_text = p ->> 'consent_text', esign_session_id = s.id
   where id = g.id;
  perform app.esign_close(s.id, g.id, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  if not exists (select 1 from agreement_version_signers x where x.version_id = v.id and x.status = 'waiting') then
    update agreement_versions set status = 'signed', signed_at = now() where id = v.id;
    update tasks set status = 'done', completed_at = now() where dedupe_key = 'agreement_signature_waiting:' || v.booking_id and status in ('open', 'in_progress', 'waiting');
    perform app.log_booking_event(v.booking_id, 'agreement_version_signed', null, null, null, format('Rental agreement version %s signed', v.version_no), g.user_id,
      case when g.role = 'renter' then 'renter' else 'system' end, jsonb_build_object('version_id', v.id));
    perform app.agreement_job_put('version_signed', v.id);
  end if;
  return jsonb_build_object('signed', true, 'version_signed', not exists (select 1 from agreement_version_signers x where x.version_id = v.id and x.status = 'waiting'));
end $$;

-- The signed copies of a version, rendered by the site.
create or replace function public.server_agreement_version_signed_docs(p_version uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v agreement_versions;
  b bookings;
  v_cc uuid; v_bs uuid;
begin
  select * into v from agreement_versions where id = p_version for update;
  select * into b from bookings where id = v.booking_id;
  if v.status <> 'signed' or v.signed_carmacars_document_id is not null then return; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, renter_id, booking_id)
  values ('rental_agreement', format('Signed rental agreement %s, version %s', b.agreement_number, v.version_no), 'agreements', p #>> '{carmacars,path}', 'application/pdf',
          p #>> '{carmacars,sha256}', 'records_7y', b.renter_id, b.id) returning id into v_cc;
  if nullif(p #>> '{blindspot,path}', '') is not null then
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, renter_id, booking_id)
    values ('rental_agreement', format('Signed Blind Spot rental agreement %s, version %s', b.booking_number, v.version_no), 'agreements', p #>> '{blindspot,path}',
            'application/pdf', p #>> '{blindspot,sha256}', 'records_7y', b.renter_id, b.id) returning id into v_bs;
  end if;
  update agreement_versions set signed_carmacars_document_id = v_cc, signed_blindspot_document_id = v_bs where id = v.id;
  perform app.emit_event('renter_agreement_version', 'agreement_version', v.id,
    jsonb_build_object('booking_id', b.id, 'version_id', v.id, 'needs_signature', false, 'signed_copy', true), 'renter_agreement_version:' || v.id || ':signed');
end $$;

-- What a version's signed copy prints: the version, its signers (with their sessions) and the documents.
create or replace function public.server_agreement_version_facts(p_version uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', v.id, 'booking_id', v.booking_id, 'version_no', v.version_no, 'kind', v.kind, 'status', v.status, 'material', v.material,
           'changes', v.changes, 'created_at', v.created_at, 'signed_at', v.signed_at, 'carmacars_sha256', v.carmacars_sha256, 'blindspot_sha256', v.blindspot_sha256,
           'countersigned_name', v.countersigned_name, 'countersigned_at', v.countersigned_at, 'note', v.note,
           'carmacars', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = v.carmacars_document_id),
           'blindspot', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = v.blindspot_document_id),
           'signers', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'role', g.role, 'name', g.name, 'status', g.status, 'signed_at', g.signed_at,
                                  'method', g.method, 'signature_path', g.signature_path, 'session_id', g.esign_session_id) order by g.role desc, g.name)
                                  from agreement_version_signers g where g.version_id = v.id), '[]'::jsonb))
    from agreement_versions v where v.id = p_version
$$;

-- The certificate of completion of a signed document: each signer's session and every step. p_refs: the signer rows
-- (rental agreement signers, the amendment, version signers).
create or replace function public.server_esign_certificate(p_context text, p_refs uuid[]) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('session_id', s.id, 'signer_name', s.signer_name, 'signer_role', s.signer_role, 'method', s.method,
           'collected_by', (select u.full_name from users u where u.id = s.collected_by), 'documents', s.documents,
           'otp_channel', s.otp_channel, 'otp_to', case s.otp_channel when 'sms' then app.esign_mask_phone(s.otp_to) else app.esign_mask_email(s.otp_to) end,
           'otp_verified_at', s.otp_verified_at, 'viewed_at', s.viewed_at, 'initials', s.initials, 'consents', s.consents, 'geo', s.geo,
           'ip_address', host(s.ip_address), 'user_agent', s.user_agent, 'signature_method', s.signature_method, 'signature_path', s.signature_path,
           'typed_fallback', s.typed_fallback, 'signed_at', s.signed_at,
           'licence', case when s.driver_id is not null and s.booking_id is not null then app.licence_status(s.booking_id, s.driver_id) end,
           'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'detail', e.detail, 'ip_address', host(e.ip_address), 'user_agent', e.user_agent) order by e.at, e.id)
                                 from esign_events e where e.session_id = s.id), '[]'::jsonb))
           order by s.signed_at), '[]'::jsonb)
    from esign_sessions s
   where s.context = p_context and s.signer_ref = any (p_refs) and s.signed_at is not null
     and s.id = (select x.id from esign_sessions x where x.context = s.context and x.signer_ref = s.signer_ref and x.signed_at is not null order by x.signed_at desc limit 1)
$$;

-- The certificate of the booking's live rental agreement (its renter and drivers).
create or replace function public.server_esign_certificate_for_booking(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select public.server_esign_certificate('rental_agreement', array(
    select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
     where a.booking_id = p_booking and a.status in ('open', 'signed', 'completed')))
$$;

-- Anyone holding a signed file can check it: its SHA-256 against the one recorded (no personal data in the answer).
create or replace function public.server_verify_sha(p_sha text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('found', true, 'kind', d.kind, 'title', regexp_replace(coalesce(d.title, 'Document'), '\s*\(.*\)$', ''),
                                             'recorded_at', d.created_at)
                     from documents d where d.sha256 = lower(btrim(p_sha)) and d.purged_at is null
                       and d.kind in ('rental_agreement', 'rental_amendment', 'dispute_evidence') order by d.created_at limit 1),
                  jsonb_build_object('found', false))
$$;

-- ================================================================ 6. the completeness check
-- What the agreements still print blank for want of data: [{key, label, where, required, driver_id}]. required: a claim
-- needs it (check-out stops without it, unless an Admin overrides). where: renter, driver, vehicle, coverage, insurer.
create or replace function app.agreement_missing(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  v vehicles;
  cp coverage_proofs;
  d record;
  out jsonb := '[]'::jsonb;
  add_ text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return out; end if;
  select * into r from renters where id = b.renter_id;
  select * into v from vehicles where id = b.vehicle_id;
  select * into cp from coverage_proofs c where c.booking_id = b.id order by c.created_at desc limit 1;
  out := out
    || case when nullif(btrim(r.legal_name), '') is null then jsonb_build_array(jsonb_build_object('key', 'renter.legal_name', 'label', 'Renter''s legal name', 'where', 'renter', 'required', true)) else '[]' end
    || case when r.date_of_birth is null then jsonb_build_array(jsonb_build_object('key', 'renter.date_of_birth', 'label', 'Renter''s date of birth', 'where', 'renter', 'required', true)) else '[]' end
    || case when nullif(btrim(r.address_line1), '') is null or nullif(btrim(r.city), '') is null or nullif(btrim(r.province), '') is null or nullif(btrim(r.postal_code), '') is null
            then jsonb_build_array(jsonb_build_object('key', 'renter.address', 'label', 'Renter''s home address (street, city, province, postal code)', 'where', 'renter', 'required', true)) else '[]' end
    || case when nullif(btrim(coalesce(r.mobile, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'renter.mobile', 'label', 'Renter''s mobile number', 'where', 'renter', 'required', true)) else '[]' end;
  for d in select bd.driver_id, bd.role, bd.full_name, bd.date_of_birth, coalesce(bd.licence_number, dv.licence_number) as no, coalesce(bd.licence_issuer, dv.licence_issuer) as issuer,
                  coalesce(bd.licence_expiry, dv.licence_expiry) as expiry, coalesce(bd.licence_class, dv.licence_class) as class,
                  app.agreement_address(dv.address_line1, dv.address_line2, dv.city, dv.province, dv.postal_code) as address
             from booking_drivers bd join drivers dv on dv.id = bd.driver_id where bd.booking_id = b.id order by bd.role desc, bd.full_name loop
    add_ := case when d.role = 'renter' then 'Renter' else 'Driver ' || d.full_name end;
    if nullif(btrim(coalesce(d.no, '')), '') is null then out := out || jsonb_build_array(jsonb_build_object('key', 'drivers.' || d.driver_id || '.licence_number', 'label', add_ || ': licence number', 'where', 'driver', 'driver_id', d.driver_id, 'required', true)); end if;
    if nullif(btrim(coalesce(d.issuer, '')), '') is null then out := out || jsonb_build_array(jsonb_build_object('key', 'drivers.' || d.driver_id || '.licence_issuer', 'label', add_ || ': licence province', 'where', 'driver', 'driver_id', d.driver_id, 'required', true)); end if;
    if d.expiry is null then out := out || jsonb_build_array(jsonb_build_object('key', 'drivers.' || d.driver_id || '.licence_expiry', 'label', add_ || ': licence expiry', 'where', 'driver', 'driver_id', d.driver_id, 'required', true)); end if;
    if nullif(btrim(coalesce(d.class, '')), '') is null then out := out || jsonb_build_array(jsonb_build_object('key', 'drivers.' || d.driver_id || '.licence_class', 'label', add_ || ': licence class', 'where', 'driver', 'driver_id', d.driver_id, 'required', false)); end if;
    if d.role = 'additional' and d.address is null then out := out || jsonb_build_array(jsonb_build_object('key', 'drivers.' || d.driver_id || '.address', 'label', add_ || ': home address', 'where', 'driver', 'driver_id', d.driver_id, 'required', false)); end if;
  end loop;
  out := out
    || case when nullif(btrim(coalesce(v.plate, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'vehicle.plate', 'label', 'Car''s licence plate', 'where', 'vehicle', 'required', true)) else '[]' end
    || case when nullif(btrim(coalesce(v.vin, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'vehicle.vin', 'label', 'Car''s VIN', 'where', 'vehicle', 'required', true)) else '[]' end
    || case when nullif(btrim(coalesce(v.colour, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'vehicle.colour', 'label', 'Car''s colour', 'where', 'vehicle', 'required', false)) else '[]' end
    || case when nullif(btrim(coalesce(v.fleet_number, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'vehicle.fleet_number', 'label', 'Car''s fleet number (Blind Spot box 22)', 'where', 'vehicle', 'required', false)) else '[]' end
    || case when b.coverage_option is null and b.booking_type <> 'owner' then jsonb_build_array(jsonb_build_object('key', 'coverage.option', 'label', 'Coverage option', 'where', 'coverage', 'required', true)) else '[]' end
    || case when b.coverage_option = 1 and (nullif(btrim(coalesce(cp.insurer_name, '')), '') is null) then jsonb_build_array(jsonb_build_object('key', 'coverage.insurer_name', 'label', 'OPCF 27: the renter''s insurer', 'where', 'coverage', 'required', true)) else '[]' end
    || case when b.coverage_option = 1 and (nullif(btrim(coalesce(cp.policy_number, '')), '') is null) then jsonb_build_array(jsonb_build_object('key', 'coverage.policy_number', 'label', 'OPCF 27: the policy number', 'where', 'coverage', 'required', true)) else '[]' end
    || case when b.coverage_option = 1 and cp.policy_expiry is null then jsonb_build_array(jsonb_build_object('key', 'coverage.policy_expiry', 'label', 'OPCF 27: the policy expiry', 'where', 'coverage', 'required', false)) else '[]' end
    || case when b.coverage_option = 2 and nullif(btrim(coalesce(cp.card_issuer, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'coverage.card_issuer', 'label', 'Card coverage: the card''s issuer', 'where', 'coverage', 'required', true)) else '[]' end
    || case when b.coverage_option = 2 and nullif(btrim(coalesce(cp.card_last4, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'coverage.card_last4', 'label', 'Card coverage: the card''s last four digits', 'where', 'coverage', 'required', true)) else '[]' end;
  if b.bill_to <> 'renter' and b.insurer_id is not null then
    out := out
      || case when nullif(btrim(coalesce(b.insurer_claim_number, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.claim_number', 'label', 'Claim number', 'where', 'insurer', 'required', true)) else '[]' end
      || case when nullif(btrim(coalesce(b.insurer_adjuster_name, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.adjuster_name', 'label', 'Adjuster''s name', 'where', 'insurer', 'required', true)) else '[]' end
      || case when nullif(btrim(coalesce(b.insurer_adjuster_phone, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.adjuster_phone', 'label', 'Adjuster''s phone', 'where', 'insurer', 'required', false)) else '[]' end
      || case when nullif(btrim(coalesce(b.insurer_policy_number, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.policy_number', 'label', 'Insured''s policy number (Blind Spot box 13)', 'where', 'insurer', 'required', true)) else '[]' end
      || case when nullif(btrim(coalesce(b.insured_vehicle, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.insured_vehicle', 'label', 'Insured vehicle (year, make, model, plate)', 'where', 'insurer', 'required', true)) else '[]' end
      || case when nullif(btrim(coalesce(b.insurer_policy_province, '')), '') is null then jsonb_build_array(jsonb_build_object('key', 'insurer.policy_province', 'label', 'Insured''s policy province', 'where', 'insurer', 'required', false)) else '[]' end
      || case when b.insurer_policy_expiry is null then jsonb_build_array(jsonb_build_object('key', 'insurer.policy_expiry', 'label', 'Insured''s policy expiry', 'where', 'insurer', 'required', false)) else '[]' end;
  end if;
  if nullif(btrim(coalesce((app.settings()).company_hst_number, '')), '') is null then
    out := out || jsonb_build_array(jsonb_build_object('key', 'company.hst_number', 'label', 'CarmaCars'' HST number (Program settings; Blind Spot box 1)', 'where', 'settings', 'required', false));
  end if;
  return out;
end $$;

-- Check-out with a field a claim needs still blank: refused, unless an Admin overrode it for exactly those fields.
alter function app.complete_handover(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_handover_pre0154;
create or replace function app.complete_handover(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_missing jsonb;
  v_keys text[];
begin
  select * into b from bookings where id = p_booking;
  if b.id is not null and b.booking_type <> 'owner' and coalesce((app.settings()).agreement_claim_check, true) then
    select coalesce(jsonb_agg(x), '[]'::jsonb), array_agg(x ->> 'key') into v_missing, v_keys
      from jsonb_array_elements(app.agreement_missing(p_booking)) x where (x ->> 'required')::boolean;
    if jsonb_array_length(v_missing) > 0 and not exists (
         select 1 from agreement_overrides o where o.booking_id = p_booking
            and (select bool_and(o.missing ? k) from unnest(v_keys) k)) then
      raise exception 'The rental agreement is missing what a claim needs: %. Fill them on the booking (Agreement card), or an Admin overrides with a reason',
        (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(v_missing) x) using errcode = '23514';
    end if;
  end if;
  return app.complete_handover_pre0154(p_booking, p_by, p_report, p_job, p_now);
end $$;

-- An Admin lets the check-out go ahead with the fields missing now (the reason is kept).
create or replace function app.agreement_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_missing jsonb;
  v_id uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin overrides the agreement check' using errcode = '42501'; end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if length(btrim(coalesce(p ->> 'reason', ''))) < 5 then raise exception 'Say why the check-out may go ahead without these fields' using errcode = '22023'; end if;
  select coalesce(jsonb_object_agg(x ->> 'key', x ->> 'label'), '{}'::jsonb) into v_missing
    from jsonb_array_elements(app.agreement_missing(b.id)) x where (x ->> 'required')::boolean;
  insert into agreement_overrides (booking_id, missing, reason, by_user) values (b.id, v_missing, btrim(p ->> 'reason'), p_by) returning id into v_id;
  perform app.log_booking_event(b.id, 'agreement_override', b.status::text, b.status::text, null,
    format('Check-out allowed with agreement fields missing: %s. Reason: %s', (select string_agg(value, '; ') from jsonb_each_text(v_missing)), btrim(p ->> 'reason')),
    p_by, 'staff', jsonb_build_object('override_id', v_id, 'missing', v_missing));
  return jsonb_build_object('id', v_id, 'missing', v_missing);
end $$;

-- Staff fill what the agreements are missing, in one place. p: booking, renter {date_of_birth, address_line1, address_line2,
-- city, province, postal_code, mobile}, drivers [{driver_id, licence_number, licence_issuer, licence_expiry, licence_class,
-- address_line1, address_line2, city, province, postal_code}], vehicle {plate, vin, colour, fleet_number}, coverage
-- {insurer_name, policy_number, policy_expiry, card_issuer, card_last4}, insurer {claim_number, adjuster_name,
-- adjuster_phone, policy_number, policy_province, policy_expiry, insured_vehicle}. Blank values are left as they were.
create or replace function app.agreement_fill(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d jsonb;
  x jsonb;
  n integer := 0;
  v_cp uuid;
  f text;
  nz text;
begin
  if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  x := coalesce(p -> 'renter', '{}'::jsonb);
  if x <> '{}'::jsonb then
    update renters set
      date_of_birth = coalesce(nullif(x ->> 'date_of_birth', '')::date, date_of_birth),
      address_line1 = coalesce(nullif(btrim(x ->> 'address_line1'), ''), address_line1), address_line2 = coalesce(nullif(btrim(x ->> 'address_line2'), ''), address_line2),
      city = coalesce(nullif(btrim(x ->> 'city'), ''), city), province = coalesce(nullif(upper(btrim(x ->> 'province')), ''), province),
      postal_code = coalesce(nullif(regexp_replace(upper(regexp_replace(coalesce(x ->> 'postal_code', ''), '\s', '', 'g')), '^([A-Z][0-9][A-Z])([0-9][A-Z][0-9])$', '\1 \2'), ''), postal_code), mobile = coalesce(nullif(btrim(x ->> 'mobile'), ''), mobile)
     where id = b.renter_id;
    n := n + 1;
  end if;
  for d in select value from jsonb_array_elements(coalesce(p -> 'drivers', '[]'::jsonb)) loop
    if not exists (select 1 from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = (d ->> 'driver_id')::uuid) then
      raise exception 'That driver is not on this booking' using errcode = '22023';
    end if;
    if nullif(d ->> 'licence_expiry', '') is not null and (d ->> 'licence_expiry')::date < app.local_date(b.return_at) then
      raise exception 'The licence expires before the return: it cannot be used for this rental' using errcode = '23514';
    end if;
    update drivers set
      licence_number = coalesce(nullif(upper(btrim(d ->> 'licence_number')), ''), licence_number), licence_issuer = coalesce(nullif(upper(btrim(d ->> 'licence_issuer')), ''), licence_issuer),
      licence_expiry = coalesce(nullif(d ->> 'licence_expiry', '')::date, licence_expiry), licence_class = coalesce(nullif(upper(btrim(d ->> 'licence_class')), ''), licence_class),
      address_line1 = coalesce(nullif(btrim(d ->> 'address_line1'), ''), address_line1), address_line2 = coalesce(nullif(btrim(d ->> 'address_line2'), ''), address_line2),
      city = coalesce(nullif(btrim(d ->> 'city'), ''), city), province = coalesce(nullif(upper(btrim(d ->> 'province')), ''), province),
      postal_code = coalesce(nullif(regexp_replace(upper(regexp_replace(coalesce(d ->> 'postal_code', ''), '\s', '', 'g')), '^([A-Z][0-9][A-Z])([0-9][A-Z][0-9])$', '\1 \2'), ''), postal_code)
     where id = (d ->> 'driver_id')::uuid;
    update booking_drivers set
      licence_number = coalesce(nullif(upper(btrim(d ->> 'licence_number')), ''), licence_number), licence_issuer = coalesce(nullif(upper(btrim(d ->> 'licence_issuer')), ''), licence_issuer),
      licence_expiry = coalesce(nullif(d ->> 'licence_expiry', '')::date, licence_expiry), licence_class = coalesce(nullif(upper(btrim(d ->> 'licence_class')), ''), licence_class)
     where booking_id = b.id and driver_id = (d ->> 'driver_id')::uuid;
    n := n + 1;
  end loop;
  x := coalesce(p -> 'vehicle', '{}'::jsonb);
  if x <> '{}'::jsonb then
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'An Admin or Fleet corrects the car' using errcode = '42501'; end if;
    if nullif(btrim(x ->> 'vin'), '') is not null and upper(btrim(x ->> 'vin')) !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'A VIN is 17 letters and digits (no I, O or Q)' using errcode = '22023'; end if;
    update vehicles set plate = coalesce(nullif(upper(regexp_replace(btrim(x ->> 'plate'), '\s+', '', 'g')), ''), plate), vin = coalesce(nullif(upper(btrim(x ->> 'vin')), ''), vin),
           colour = coalesce(nullif(btrim(x ->> 'colour'), ''), colour), fleet_number = coalesce(nullif(btrim(x ->> 'fleet_number'), ''), fleet_number)
     where id = b.vehicle_id;
    n := n + 1;
  end if;
  x := coalesce(p -> 'coverage', '{}'::jsonb);
  if x <> '{}'::jsonb then
    select id into v_cp from coverage_proofs where booking_id = b.id order by created_at desc limit 1;
    if v_cp is null then raise exception 'There is no coverage proof on this booking yet: record it on Drivers and documents' using errcode = '23514'; end if;
    if nullif(btrim(x ->> 'card_last4'), '') is not null and btrim(x ->> 'card_last4') !~ '^[0-9]{4}$' then raise exception 'The last four digits of the card' using errcode = '22023'; end if;
    update coverage_proofs set insurer_name = coalesce(nullif(btrim(x ->> 'insurer_name'), ''), insurer_name), policy_number = coalesce(nullif(btrim(x ->> 'policy_number'), ''), policy_number),
           policy_expiry = coalesce(nullif(x ->> 'policy_expiry', '')::date, policy_expiry), card_issuer = coalesce(nullif(btrim(x ->> 'card_issuer'), ''), card_issuer),
           card_last4 = coalesce(nullif(btrim(x ->> 'card_last4'), ''), card_last4)
     where id = v_cp;
    n := n + 1;
  end if;
  x := coalesce(p -> 'insurer', '{}'::jsonb);
  if x <> '{}'::jsonb then
    update bookings set insurer_claim_number = coalesce(nullif(btrim(x ->> 'claim_number'), ''), insurer_claim_number),
           insurer_adjuster_name = coalesce(nullif(btrim(x ->> 'adjuster_name'), ''), insurer_adjuster_name),
           insurer_adjuster_phone = coalesce(nullif(btrim(x ->> 'adjuster_phone'), ''), insurer_adjuster_phone),
           insurer_policy_number = coalesce(nullif(btrim(x ->> 'policy_number'), ''), insurer_policy_number),
           insurer_policy_province = coalesce(nullif(upper(btrim(x ->> 'policy_province')), ''), insurer_policy_province),
           insurer_policy_expiry = coalesce(nullif(x ->> 'policy_expiry', '')::date, insurer_policy_expiry),
           insured_vehicle = coalesce(nullif(btrim(x ->> 'insured_vehicle'), ''), insured_vehicle)
     where id = b.id;
    n := n + 1;
  end if;
  perform app.log_booking_event(b.id, 'agreement_fields_filled', b.status::text, b.status::text, null, 'Agreement fields filled in', p_by, 'staff',
    jsonb_build_object('parts', (select jsonb_agg(k) from jsonb_object_keys(p - 'booking') k)));
  return jsonb_build_object('updated', n, 'missing', app.agreement_missing(b.id));
end $$;

-- The Agreement card of a booking: versions, what waits, what is missing, the overrides, the dispute packs.
create or replace function app.agreement_state(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  pl jsonb;
begin
  if not app.user_is_staff(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  pl := app.agreement_plan(b.id);
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'plan_state', pl ->> 'state',
    'pending', case when pl ->> 'state' = 'version' then jsonb_build_object('kind', pl ->> 'kind', 'material', pl -> 'material', 'changes', pl -> 'changes') end,
    'versions', app.agreement_versions_of(b.id),
    'waiting', (select jsonb_build_object('version_no', v.version_no, 'signers', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'role', g.role, 'token', g.link_token))
                                                                                 from agreement_version_signers g where g.version_id = v.id and g.status = 'waiting'))
                  from agreement_versions v where v.booking_id = b.id and v.status = 'awaiting_signature' order by v.version_no desc limit 1),
    'missing', app.agreement_missing(b.id),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('at', o.created_at, 'reason', o.reason, 'missing', o.missing, 'by', (select u.full_name from users u where u.id = o.by_user)) order by o.created_at desc)
                             from agreement_overrides o where o.booking_id = b.id), '[]'::jsonb),
    'job', (select jsonb_build_object('due_at', j.due_at, 'attempts', j.attempts, 'last_error', j.last_error) from agreement_jobs j where j.kind = 'version' and j.ref = b.id),
    'is_admin', app.user_is_admin(p_by),
    'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'built_at', d.built_at, 'staged_at', d.staged_at, 'submitted_at', d.submitted_at,
                            'document_id', d.document_id, 'error', d.error, 'stripe_dispute_ref', d.stripe_dispute_ref, 'size', d.file_size) order by d.created_at desc)
                            from dispute_packs d where d.booking_id = b.id), '[]'::jsonb));
end $$;

-- ================================================================ 7. the dispute evidence pack
-- One PDF for a booking (the signed agreements with their certificates, the check-out and check-in reports with
-- photos, kilometres and fuel, the licence, the receipts, the messages, the card checks from Stripe), built by the site
-- on demand and when a card payment is disputed, staged in Stripe as the dispute's evidence; an Admin submits it.
create table if not exists dispute_packs (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null references bookings (id) on delete cascade,
  dispute_id         uuid references disputes (id),
  stripe_dispute_ref text,
  status             text not null default 'queued' check (status in ('queued', 'built', 'staged', 'submitted', 'failed')),
  document_id        uuid references documents (id),
  sha256             text,
  file_size          integer,
  stripe_file_id     text,
  contents           jsonb not null default '{}'::jsonb,
  error              text,
  built_at           timestamptz,
  staged_at          timestamptz,
  submitted_at       timestamptz,
  submitted_by       uuid references users (id),
  created_by         uuid references users (id),
  created_at         timestamptz not null default now()
);
create index if not exists dispute_packs_booking on dispute_packs (booking_id, created_at desc);
comment on table dispute_packs is 'Dispute evidence packs (0154): one PDF of everything that proves the rental, staged and submitted to Stripe.';
alter table dispute_packs enable row level security;
create policy admin_all on dispute_packs for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on dispute_packs from anon, authenticated;
grant select, insert, update on dispute_packs to service_role;
create trigger audit_dispute_packs after insert or update or delete on dispute_packs for each row execute function app.audit_row();

create or replace function app.dispute_pack_queue(p_booking uuid, p_dispute uuid, p_by uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  insert into dispute_packs (booking_id, dispute_id, stripe_dispute_ref, created_by)
  values (p_booking, p_dispute, (select d.processor_dispute_ref from disputes d where d.id = p_dispute), p_by)
  returning id into v_id;
  perform app.agreement_job_put('dispute_pack', v_id);
  -- the evidence stays as long as the dispute needs it
  update documents set legal_hold = true where booking_id = p_booking and kind in ('rental_agreement', 'rental_amendment', 'condition_report', 'id_front', 'id_back', 'face_photo');
  return v_id;
end $$;

create or replace function app.dispute_pack_on_dispute() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- 0139's server_stripe_dispute_event records charge.dispute.created here; one already decided needs no evidence
  if new.booking_id is not null and coalesce(new.status, 'open') not in ('won', 'lost') then perform app.dispute_pack_queue(new.booking_id, new.id, null); end if;
  return null;
end $$;
drop trigger if exists dispute_pack on disputes;
create trigger dispute_pack after insert on disputes for each row execute function app.dispute_pack_on_dispute();

-- Everything the pack prints, for the site.
create or replace function public.server_dispute_evidence(p_pack uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  k dispute_packs;
  b bookings;
  r renters;
begin
  select * into k from dispute_packs where id = p_pack;
  select * into b from bookings where id = k.booking_id;
  select * into r from renters where id = b.renter_id;
  return jsonb_build_object(
    'pack', jsonb_build_object('id', k.id, 'status', k.status, 'stripe_dispute_ref', k.stripe_dispute_ref, 'created_at', k.created_at),
    'dispute', (select jsonb_build_object('id', d.id, 'amount_cents', d.amount_cents, 'reason', d.reason, 'status', d.status, 'evidence_due_at', d.evidence_due_at,
                                          'charge_id', pd.processor_charge_id, 'intent_id', pd.processor_payment_id)
                  from disputes d left join payment_processor_details pd on pd.payment_id = d.payment_id where d.id = k.dispute_id),
    'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'agreement_number', b.agreement_number, 'status', b.status,
                                  'pickup_at', b.pickup_at, 'return_at', b.return_at, 'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at,
                                  'vehicle', app.agreement_vehicle(b.vehicle_id), 'total_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents),
    'renter', jsonb_build_object('legal_name', r.legal_name, 'email', coalesce(nullif(r.email, ''), (select u.email from users u where u.id = r.user_id)),
                                 'mobile', r.mobile, 'address', app.agreement_address(r.address_line1, r.address_line2, r.city, r.province, r.postal_code),
                                 'postal_code', r.postal_code, 'created_at', r.created_at),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'bucket', d.storage_bucket, 'path', d.storage_path,
                             'sha256', d.sha256, 'created_at', d.created_at, 'mime', d.mime_type) order by d.created_at)
                             from documents d where d.booking_id = b.id and d.purged_at is null and d.storage_path is not null
                              and (d.kind in ('rental_amendment', 'receipt', 'renter_statement')
                                   or (d.kind = 'rental_agreement' and d.title ilike 'signed%'))), '[]'::jsonb),
    'versions', app.agreement_versions_of(b.id),
    'licence', coalesce((select jsonb_agg(jsonb_build_object('kind', u.kind, 'status', u.status, 'driver', (select dv.full_name from drivers dv where dv.id = u.driver_id),
                           'bucket', d.storage_bucket, 'path', d.storage_path, 'mime', d.mime_type, 'uploaded_at', u.uploaded_at) order by u.uploaded_at)
                           from verification_uploads u join documents d on d.id = u.document_id
                          where u.booking_id = b.id and u.kind in ('licence_front', 'licence_back', 'selfie') and u.status in ('submitted', 'approved') and d.storage_path is not null), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('kind', c.kind, 'performed_at', c.performed_at, 'completed_at', c.completed_at, 'odometer_km', c.odometer_km,
                           'fuel_pct', c.fuel_pct, 'keys', c.keys_count, 'by', (select u.full_name from users u where u.id = coalesce(c.completed_by, c.performed_by)),
                           'renter_signed_at', c.renter_signed_at, 'plate', (select v.plate from vehicles v where v.id = c.vehicle_id),
                           'damages', coalesce((select jsonb_agg(jsonb_build_object('label', dm.label, 'location', dm.location, 'description', dm.description, 'is_new', dm.is_new) order by dm.label)
                                                  from condition_report_damages dm where dm.condition_report_id = c.id), '[]'::jsonb),
                           'photos', coalesce((select jsonb_agg(jsonb_build_object('shot', ph.shot, 'bucket', ph.storage_bucket, 'path', ph.storage_path, 'taken_at', ph.taken_at,
                                                  'latitude', ph.latitude, 'longitude', ph.longitude) order by ph.seq)
                                                 from condition_report_photos ph where ph.condition_report_id = c.id), '[]'::jsonb)) order by c.performed_at)
                           from condition_reports c where c.booking_id = b.id and c.kind in ('pickup', 'return', 'swap_out', 'swap_in') and c.completed_at is not null), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('purpose', p.purpose, 'kind', p.kind, 'method', p.method, 'amount_cents', p.amount_cents, 'status', p.status,
                           'card_brand', p.card_brand, 'card_last4', p.card_last4, 'at', coalesce(p.processed_at, p.created_at),
                           'charge_id', pd.processor_charge_id, 'intent_id', pd.processor_payment_id, 'receipt_url', pd.receipt_url) order by p.created_at)
                           from payments p left join payment_processor_details pd on pd.payment_id = p.id where p.booking_id = b.id), '[]'::jsonb),
    'lines', app.agreement_extra(b.id) -> 'lines',
    'messages', coalesce((select jsonb_agg(m order by m ->> 'at') from (
                   select jsonb_build_object('at', o.created_at, 'channel', 'email', 'code', o.code, 'status', o.status, 'to', app.esign_mask_email(o.to_address)) m
                     from notification_outbox o where o.booking_id = b.id and o.audience = 'renter'
                   union all
                   select jsonb_build_object('at', po.created_at, 'channel', 'text', 'code', coalesce(po.sms_kind, po.kind), 'status', po.status, 'body', left(po.body, 300))
                     from phone_outbox po where po.booking_id = b.id) q), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'kind', e.kind, 'note', e.note) order by e.created_at)
                          from booking_events e where e.booking_id = b.id), '[]'::jsonb),
    'signing', jsonb_build_object(
       'rental_agreement', public.server_esign_certificate('rental_agreement', array(select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = b.id)),
       'amendments', public.server_esign_certificate('amendment', array(select m.id from booking_amendments m where m.booking_id = b.id)),
       'versions', public.server_esign_certificate('agreement_version', array(select g.id from agreement_version_signers g join agreement_versions v on v.id = g.version_id where v.booking_id = b.id))),
    'trips', (select jsonb_build_object('previous_completed', count(*)) from bookings x where x.renter_id = b.renter_id and x.id <> b.id and x.status in ('returned', 'closed')));
end $$;

create or replace function public.server_dispute_pack_built(p_pack uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  k dispute_packs;
  v_doc uuid;
begin
  select * into k from dispute_packs where id = p_pack for update;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, legal_hold, renter_id, booking_id)
  values ('dispute_evidence', format('Dispute evidence, booking %s', (select b.booking_number from bookings b where b.id = k.booking_id)), 'documents', p ->> 'path',
          'application/pdf', p ->> 'sha256', 'records_7y', true, (select b.renter_id from bookings b where b.id = k.booking_id), k.booking_id)
  returning id into v_doc;
  update dispute_packs set status = case when p ->> 'stripe_file_id' is not null then 'staged' else 'built' end, document_id = v_doc, sha256 = p ->> 'sha256',
         file_size = (p ->> 'size')::integer, stripe_file_id = p ->> 'stripe_file_id', contents = coalesce(p -> 'contents', '{}'::jsonb), error = p ->> 'stage_error',
         built_at = now(), staged_at = case when p ->> 'stripe_file_id' is not null then now() end
   where id = k.id;
  if k.dispute_id is not null then
    update disputes set evidence_document_ids = array(select distinct x from unnest(evidence_document_ids || v_doc) x) where id = k.dispute_id;
    perform app.raise_task(p_type => 'dispute_pack_ready', p_booking => k.booking_id, p_related_table => 'dispute_packs', p_related_id => k.id,
      p_due_at => (select d.evidence_due_at from disputes d where d.id = k.dispute_id), p_dedupe => 'dispute_pack_ready:' || k.id);
  end if;
  perform app.log_booking_event(k.booking_id, 'dispute_pack', null, null, null, 'Dispute evidence pack built' || case when p ->> 'stripe_file_id' is not null then ' and staged in Stripe' else '' end,
    null, 'system', jsonb_build_object('pack_id', k.id));
end $$;

create or replace function public.server_dispute_pack_submitted(p_pack uuid, p_by uuid, p_error text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  k dispute_packs;
begin
  select * into k from dispute_packs where id = p_pack for update;
  if p_error is not null then update dispute_packs set error = left(p_error, 1000) where id = k.id; return; end if;
  update dispute_packs set status = 'submitted', submitted_at = now(), submitted_by = p_by, error = null where id = k.id;
  if k.dispute_id is not null then update disputes set status = 'evidence_submitted', evidence_submitted_at = now() where id = k.dispute_id and status = 'open'; end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by where dedupe_key = 'dispute_pack_ready:' || k.id and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(k.booking_id, 'dispute_pack', null, null, null, 'Dispute evidence submitted to Stripe', p_by, 'staff', jsonb_build_object('pack_id', k.id));
end $$;

create or replace function public.server_dispute_pack(p_pack uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(k) || jsonb_build_object('document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = k.document_id),
                                           'evidence_due_at', (select x.evidence_due_at from disputes x where x.id = k.dispute_id))
    from dispute_packs k where k.id = p_pack
$$;

-- ================================================================ 8. the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0154;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_b uuid;
  v_v uuid;
begin
  if (p_call = 'ops_read' and p_name in ('agreement_state'))
     or (p_call = 'ops_do' and p_name in ('agreement_fill', 'agreement_override', 'agreement_resend', 'agreement_regenerate', 'dispute_pack_build', 'dispute_pack_get')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    v_b := coalesce((select id from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' limit 1), '00000000-0000-0000-0000-000000000000'::uuid);
    case p_name
    when 'agreement_state' then return app.agreement_state(p_user, v_b);
    when 'agreement_fill' then return app.agreement_fill(p_user, p_ || jsonb_build_object('booking', v_b));
    when 'agreement_override' then return app.agreement_override(p_user, p_ || jsonb_build_object('booking', v_b));
    when 'agreement_resend' then
      if not app.user_may_handover(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
      select v.id into v_v from agreement_versions v where v.booking_id = v_b and v.status = 'awaiting_signature' order by v.version_no desc limit 1;
      if v_v is null then raise exception 'No version of the agreement waits for a signature' using errcode = '23514'; end if;
      return jsonb_build_object('sent', app.agreement_version_notify(v_v, true));
    when 'agreement_regenerate' then
      if not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
      perform app.agreement_job_put('version', v_b);
      return jsonb_build_object('queued', true);
    when 'dispute_pack_build' then
      if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'finance')) then raise exception 'An Admin or Finance builds the dispute evidence' using errcode = '42501'; end if;
      return jsonb_build_object('id', app.dispute_pack_queue(v_b, (select d.id from disputes d where d.booking_id = v_b and d.status in ('open', 'evidence_submitted') order by d.opened_at desc limit 1), p_user));
    else
      if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'finance')) then raise exception 'Not permitted' using errcode = '42501'; end if;
      return public.server_dispute_pack((select k.id from dispute_packs k where k.id = (p_ ->> 'pack')::uuid and k.booking_id = v_b));
    end case;
  end if;
  return app.door_pre0154(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 9. the renter's emails
insert into notification_link_paths (key, path) values ('agreement_version_sign', '/sign/agreement/{{sign_token}}')
on conflict (key) do update set path = excluded.path;

-- CATALOGUE 0154 START (generated by supabase/seed/0154_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_agreement_version', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', '{{version_title}}, booking {{booking_number}}', '{{kind_line}}', 'Immediate', 'A new version of the booking''s two rental agreements (CarmaCars'' and Blind Spot''s) is made after the agreement was signed (migration 0154): the car checked out (the "as picked up" copy), checked in (the closing copy), a correction, or a material change (dates, price, car, drivers, coverage option) that the renter and the affected drivers sign again with their own link. Also sent with the signed copies once every signature of a changed version is in. Both PDFs are attached.', null, '/sign/agreement/{{sign_token}}', '[{"name":"booking_number","type":"string"},{"name":"changes","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"has_changes","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"kind_line","type":"string"},{"name":"needs_signature","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_token","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"version_title","type":"string"}]'::jsonb, 'templates/renter_agreement_version.html', 'templates/renter_agreement_version.txt'),
  ('renter_signing_code', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your CarmaCars signing code: {{code}}', 'Enter it on the signing page within {{minutes}} minutes.', 'Immediate', 'A renter or driver about to sign a rental agreement, an amendment or a new version asks for the identity code by email (migration 0154). The code proves the signer controls the email on file; it is never stored in clear.', null, null, '[{"name":"booking_number","type":"string"},{"name":"code","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"minutes","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_signing_code.html', 'templates/renter_signing_code.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0154 END

update notification_catalogue set emitted_by = 'public.server_agreement_version_add (0154)' where code = 'renter_agreement_version';
update notification_catalogue set emitted_by = 'the signing pages'' identity step (0154)' where code = 'renter_signing_code';
-- never a text: the code was asked for by email (a text of it would be the other channel), and a version's signers get
-- their own text with their link (app.agreement_version_notify); the copies are documents, always emailed
update notification_catalogue set no_text = true, always_email = true where code in ('renter_agreement_version', 'renter_signing_code');

alter function app.notification_payload(text, app_events, jsonb) rename to notification_payload_pre0154;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.notification_payload_pre0154(p_code, p_event, p_to);
  v agreement_versions;
  p jsonb := coalesce(p_event.payload, '{}'::jsonb);
begin
  if p_code = 'renter_agreement_version' then
    select * into v from agreement_versions where id = p_event.entity_id;
    x := x || jsonb_build_object(
      'version_no', v.version_no::text,
      'version_title', case when coalesce((p ->> 'signed_copy')::boolean, false) then format('Your signed agreement, version %s', v.version_no)
                            when coalesce((p ->> 'needs_signature')::boolean, false) then format('Version %s of your rental agreement needs your signature', v.version_no)
                            when v.kind = 'pickup' then 'Your rental agreement as picked up'
                            when v.kind = 'return' then 'Your rental agreement as returned'
                            else format('Your rental agreement, version %s', v.version_no) end,
      'kind_line', case when coalesce((p ->> 'signed_copy')::boolean, false) then 'Every signature is in. Your signed copy of both agreements is attached.'
                        when coalesce((p ->> 'needs_signature')::boolean, false) then 'Your booking changed in a way you sign again. Read what changed, then sign with the button below. Until you sign, the earlier version applies.'
                        when v.kind = 'pickup' then format('The car was checked out on %s at %s km with the fuel at %s%%. Both agreements, with the pickup record, are attached.',
                                                           coalesce(app.fmt_datetime((select c.performed_at from condition_reports c where c.id = v.condition_report_id)), 'pickup'),
                                                           coalesce(v.snapshot #>> '{pickup,odometer_km}', '?'), coalesce(v.snapshot #>> '{pickup,fuel_pct}', '?'))
                        when v.kind = 'return' then format('The car was checked in at %s km with the fuel at %s%%. Both agreements, with the return record and the final charges, are attached.',
                                                           coalesce(v.snapshot #>> '{return,odometer_km}', '?'), coalesce(v.snapshot #>> '{return,fuel_pct}', '?'))
                        else 'We corrected details on your rental agreement. Nothing you agreed to changes; both corrected agreements are attached.' end,
      'needs_signature', coalesce((p ->> 'needs_signature')::boolean, false),
      'has_changes', jsonb_array_length(v.changes) > 0 and not coalesce((p ->> 'signed_copy')::boolean, false),
      'changes', coalesce((select jsonb_agg(jsonb_build_object('label', c ->> 'label', 'before', c ->> 'before', 'after', c ->> 'after')) from jsonb_array_elements(v.changes) c), '[]'::jsonb),
      'sign_token', coalesce(p ->> 'sign_token', ''),
      '_url', case when coalesce((p ->> 'needs_signature')::boolean, false) then app.ntf_link('agreement_version_sign', jsonb_build_object('sign_token', p ->> 'sign_token'))
                   else app.ntf_link('booking', jsonb_build_object('booking_number', (select b.booking_number from bookings b where b.id = v.booking_id))) end);
  elsif p_code = 'renter_signing_code' then
    x := x || jsonb_build_object('code', coalesce(p ->> 'code', ''), 'minutes', coalesce((app.settings()).esign_code_minutes, 10)::text);
  end if;
  return x;
end $$;

-- the version email carries both documents of the version (or its signed copies)
alter function app.outbox_attachments(uuid) rename to outbox_attachments_pre0154;
create or replace function app.outbox_attachments(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v agreement_versions;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null or o.code <> 'renter_agreement_version' or o.entity <> 'agreement_version' then return app.outbox_attachments_pre0154(p_outbox); end if;
  select * into v from agreement_versions where id = o.entity_id;
  return app.outbox_attachments_pre0154(p_outbox) || coalesce((
    select jsonb_agg(jsonb_build_object('k', 'document', 'key', d.id::text, 'filename', d.title || '.pdf'))
      from documents d where d.id in (coalesce(v.signed_carmacars_document_id, v.carmacars_document_id), coalesce(v.signed_blindspot_document_id, v.blindspot_document_id))), '[]'::jsonb);
end $$;

-- ================================================================ 10. version 1 for the agreements already signed
insert into agreement_versions (booking_id, version_no, kind, material, status, snapshot, snapshot_sha, rental_agreement_id, carmacars_document_id, carmacars_sha256,
                                signed_carmacars_document_id, signed_at, countersigned_name, countersigned_at, note)
select a.booking_id, 1, 'signed', true, 'signed', s.snap, app.agreement_sha(s.snap), a.id, a.document_id, a.document_sha256,
       (select sr.signed_document_id from signature_requests sr where sr.id = a.signature_request_id), a.renter_signed_at, a.countersigner_name, a.completed_at,
       'Recorded when versions began (October 24, 2026): the booking as it was then'
  from rental_agreements a join bookings b on b.id = a.booking_id
  cross join lateral (select app.agreement_snapshot(a.booking_id) as snap) s
 where a.status = 'completed' and b.status in ('confirmed', 'on_rent', 'returned')
on conflict (booking_id, version_no) do nothing;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['agreement_address', 'agreement_vehicle', 'agreement_pickup', 'agreement_return', 'agreement_extra',
              'agreement_snapshot', 'agreement_flat', 'agreement_key_label', 'agreement_key_value', 'agreement_changes', 'agreement_sha', 'agreement_signed_snapshot',
              'agreement_version_one', 'agreement_completed_after', 'agreement_job_put', 'agreement_touch', 'agreement_touch_row', 'server_jobs_due_pre0154',
              'agreement_plan', 'agreement_versions_of', 'agreement_site', 'agreement_version_notify', 'esign_mask_email', 'esign_mask_phone',
              'esign_events_append_only', 'esign_requirements', 'esign_code_email', 'esign_view', 'esign_is_ready', 'esign_ready', 'esign_close', 'record_signature_pre0154',
              'sign_booking_amendment_pre0154', 'agreement_missing', 'complete_handover_pre0154', 'agreement_override', 'agreement_fill', 'agreement_state',
              'dispute_pack_queue', 'dispute_pack_on_dispute', 'door_pre0154', 'notification_payload_pre0154', 'outbox_attachments_pre0154',
              'record_signature', 'sign_booking_amendment', 'complete_handover', 'door', 'notification_payload', 'outbox_attachments']))
        or (n.nspname = 'public' and p.proname = any (array['server_agreement_extra', 'server_agreement_rendered', 'server_agreement_jobs_claim', 'server_agreement_job_done',
              'server_agreement_job_fail', 'server_agreement_plan', 'server_agreement_version_add', 'server_agreement_version_link', 'server_esign_start',
              'server_esign_view', 'server_esign_signer', 'server_esign_owner', 'server_esign_code_email', 'server_esign_code_set', 'server_esign_code_check', 'server_esign_step', 'server_agreement_version_sign',
              'server_agreement_version_signed_docs', 'server_agreement_version_facts', 'server_esign_certificate', 'server_esign_certificate_for_booking', 'server_verify_sha',
              'server_dispute_evidence', 'server_dispute_pack_built', 'server_dispute_pack_submitted', 'server_dispute_pack']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- GUIDES 0154 START (generated by supabase/seed/0154_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'sign-and-pay', 'chapter', 'your-offer', 'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Signing with our staff

At pickup or at our desk, you can sign on a CarmaCars phone or tablet.

1. Our staff member checks your name and your original licence, then hands you the device.
2. Read the agreements, tick the statements and sign with your name or your finger. Then hand the device back.
3. It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Confirm it is you: press **Send the code** and type the 6-digit code we text (or email) you. Tick that you read the agreements, initial each key term in its box, tick the three consents and draw your signature with your finger or the mouse.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies, with a certificate of each step, are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Signing with our staff

At pickup or at our desk, you can sign on a CarmaCars phone or tablet.

1. Our staff member checks your name and your original licence, then hands you the device.
2. Read the agreements, confirm the code we text you, initial the key terms, tick the consents and sign with your finger. Then hand the device back.
3. It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.

## When your booking changes after you sign

Your agreements always match your booking.

1. If the dates, the price, the car, the drivers or your coverage change, you get an email and a text with a link to the new version: read what changed and sign it the same way. Until you sign, the earlier version applies.
2. A correction that changes nothing you agreed to (a typo in an address) comes as a corrected copy by email, with nothing to sign.
3. At pickup and at return you get your agreements as picked up and as returned: the time, kilometres and fuel, and at return the final charges.

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot&#39;s insurance, so it is part of your rental too. Press its <b class="gd-ui">Download PDF</b> to read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Confirm it is you: press <b class="gd-ui">Send the code</b> and type the 6-digit code we text (or email) you. Tick that you read the agreements, initial each key term in its box, tick the three consents and draw your signature with your finger or the mouse.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>. Your one signature signs both agreements; the signed copies, with a certificate of each step, are in Documents and in the email that confirms your booking.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-signing-with-our-staff" data-gd-task><h2 class="gd-h2">Signing with our staff</h2><p class="gd-p">At pickup or at our desk, you can sign on a CarmaCars phone or tablet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Our staff member checks your name and your original licence, then hands you the device.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreements, confirm the code we text you, initial the key terms, tick the consents and sign with your finger. Then hand the device back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.</div></li></ol></div></section><section class="gd-task" id="sign-and-pay-when-your-booking-changes-after-you-sign" data-gd-task><h2 class="gd-h2">When your booking changes after you sign</h2><p class="gd-p">Your agreements always match your booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">If the dates, the price, the car, the drivers or your coverage change, you get an email and a text with a link to the new version: read what changed and sign it the same way. Until you sign, the earlier version applies.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A correction that changes nothing you agreed to (a typo in an address) comes as a corrected copy by email, with nothing to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At pickup and at return you get your agreements as picked up and as returned: the time, kilometres and fuel, and at return the final charges.</div></li></ol></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section><section class="gd-task" id="sign-and-pay-a-rental-we-booked-for-you" data-gd-task><h2 class="gd-h2">A rental we booked for you</h2><p class="gd-p">Booked by phone, in person or through a partner? We add the rental and you sign it online.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email: &quot;Read and sign your rental agreement; your card is charged when you sign.&quot;</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open it. Check the car, the dates and the price, and read the agreement.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Accept and sign</b>. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.</div></li></ol></div></section>');
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
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

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

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).

## Signing that holds up in a dispute

Every signature of a rental agreement, an amendment or a new version is made the same way, remotely or on your device.

1. The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.
2. They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
4. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

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
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

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
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-rental-agreements-every-version-every-field" data-gd-task><h2 class="gd-h2">Rental agreements: every version, every field</h2><p class="gd-p">The booking&#39;s Rental agreements card: the current version of CarmaCars&#39; and Blind Spot&#39;s agreements, every earlier one, and what is still blank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows &quot;Agreement v3 waiting for signature&quot;. A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check-out makes the &quot;as picked up&quot; copy (time out, km out, fuel out, the car&#39;s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Every version</b> lists each one with what changed and both PDFs. <b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your phone or tablet.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The card lists what the agreements still print blank (a licence expiry, the insurer&#39;s policy number, the insured vehicle, a VIN). Type the values and press <b class="gd-ui">Save the missing fields</b>: the agreements follow.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press <b class="gd-ui">Override</b>; the reason is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Make the agreements again</b> checks both against the booking at once (they also follow every change by themselves).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signing-that-holds-up-in-a-dispute" data-gd-task><h2 class="gd-h2">Signing that holds up in a dispute</h2><p class="gd-p">Every signature of a rental agreement, an amendment or a new version is made the same way, remotely or on your device.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at <span class="gd-url">carmacars.ca/verify</span>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Esign typed fallback.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-card-disputes-the-evidence-pack" data-gd-task><h2 class="gd-h2">Card disputes: the evidence pack</h2><p class="gd-p">Everything that proves the rental, in one PDF for Stripe.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute&#39;s evidence, and To do gets an urgent task.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the booking: the Rental agreements card shows the pack. Press <b class="gd-ui">Download</b> to check it, then <b class="gd-ui">Submit to Stripe</b> before the evidence date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Build the dispute evidence pack</b> makes one at any time (an Admin or Finance).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments by day</b>: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section>');
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
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.
3. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
4. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

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

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-out stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.
3. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
4. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

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
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (<b class="gd-ui">Record a payment</b>, For: the rental and fees).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-the-booking-s-rental-agreements" data-gd-task><h2 class="gd-h2">The booking&#39;s rental agreements</h2><p class="gd-p">The Rental agreements card keeps both agreements in step with the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter&#39;s signature: they get the link by email and text, and the card says &quot;Agreement v3 waiting for signature&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fields still blank (a licence expiry, an insurer&#39;s policy number) are listed: type them and press <b class="gd-ui">Save the missing fields</b>. Check-out stops on a field a claim needs until it is filled or an Admin overrides.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every signature: a code to the signer&#39;s phone or email, the key terms initialled, three consents, a drawn signature.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Renters are asked for a review by email and text after each trip. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Review requests</b> shows the ones on hold and the Google reviews to match.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter should be asked now anyway? Press <b class="gd-ui">Send anyway</b>. Should never be asked? Press <b class="gd-ui">Do not ask</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google reviews: a possible match to a renter shows &quot;possible match&quot;. Press <b class="gd-ui">Confirm</b> if it is them, <b class="gd-ui">Not this renter</b> if not, or <b class="gd-ui">Match to a booking</b> with the booking number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On a booking, the card Review requests has <b class="gd-ui">Ask for a review</b> (for example after a call that went well) and <b class="gd-ui">Mark reviewed</b> when the renter says they already left one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('field', 'a-handover', 'chapter', 'my-jobs', 'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: agreement signed, identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. A red line shows what you can do about it right under it (see the next part). Fix it, then press **Check again**.
3. All green? Press **Next**.
4. Coverage or the calendar not ready? Only the office fixes those: call CarmaCars. Still not ready? Press **Stop: do not release the car**.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## Fix the ready check on the spot

Most red lines are fixed on your phone, without calling the office. Everything you do is recorded with your name.

1. Agreement not signed: press **Sign now on this device** and hand the phone to the renter. Signed on paper instead? Open **Signed on paper instead? Scan it**, take a photo of each page, then press **Record the signed paper copy**.
2. Identity not verified: for each driver, press **Take** for the licence front, the back and the selfie. Hold the original licence: tick that the name matches, the photo is the person, it is valid past the return and it is class G2 or G. No expiry on file? Type the licence number and the expiry. Press **The licence checks out**.
3. Deposit not taken: press **Card hold: hand this phone to the renter**. They type their card in Stripe''s secure form; take the phone back and press **Back to the job**.
4. Paid by e-Transfer instead: open **Paid by e-Transfer**, type the reference number from their confirmation and press **Record the e-Transfer**.
5. Paid in cash: open **Paid in cash**, count the amount in front of the renter and press **I received**. Keep the cash apart from your own money and hand it to CarmaCars within 1 business day, as Finance directs: Finance gets a task to collect it from you.
6. Additional driver not accepted: press **Sign now on this device (additional driver)**.

> Tip: An expired licence, a face that does not match or a renter who will not sign: do not fix it. Press Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. The car has to go anyway? Open **The car has to go anyway?**, say why and press **Release without the tracker**: an Admin is told at once. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Checked out. The rental has started." The renter gets the photo report by email and in their Documents.

> Tip: Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. Each photo keeps its time, and the place when your phone allows location.

## Sign now on this device

The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.

1. On the job, press **Sign now on this device**. It shows who still has to sign and whether their licence is on file.
2. Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press **Photograph: Licence, front** (and the back and the selfie).
3. Press **Hand the device to** and their name. They read the agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign with their name or their finger.
4. They hand the phone back: press **Back to the staff view**. The signature record says it was signed in person, collected by you, on your phone.

## The deposit on your phone

Deposit not taken yet? The ready check shows how to take it under the Deposit line. You never type a card number.

1. Press **Card hold: hand this phone to the renter**. They type their credit card in Stripe''s secure form and press the button with the amount.
2. They see "Hold placed": take the phone back and press **Back to the job**. The ready check shows the deposit taken.
3. A rental longer than the hold limit shows **Save the card on this phone (long rental)** instead: Finance charges the deposit to that card.
4. No credit card? When CarmaCars allows it, the renter pays the deposit by e-Transfer or in cash: record it under the Deposit line.

## Add-ons to put in the car

A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.

1. Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").
2. Put every item in the car before the handover. The Car ready step lists them again.
3. Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.
4. A chauffeur on the booking: Fleet tells you who drives and when.

> Tip: An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
', 'A handover', 'The ready check, ID, card, odometer, photos, damage, signatures and the keys.',
  'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: agreement signed, identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. A red line shows what you can do about it right under it (see the next part). Fix it, then press **Check again**.
3. All green? Press **Next**.
4. Coverage or the calendar not ready? Only the office fixes those: call CarmaCars. Still not ready? Press **Stop: do not release the car**.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## Fix the ready check on the spot

Most red lines are fixed on your phone, without calling the office. Everything you do is recorded with your name.

1. Agreement not signed: press **Sign now on this device** and hand the phone to the renter. Signed on paper instead? Open **Signed on paper instead? Scan it**, take a photo of each page, then press **Record the signed paper copy**.
2. Identity not verified: for each driver, press **Take** for the licence front, the back and the selfie. Hold the original licence: tick that the name matches, the photo is the person, it is valid past the return and it is class G2 or G. No expiry on file? Type the licence number and the expiry. Press **The licence checks out**.
3. Deposit not taken: press **Card hold: hand this phone to the renter**. They type their card in Stripe''s secure form; take the phone back and press **Back to the job**.
4. Paid by e-Transfer instead: open **Paid by e-Transfer**, type the reference number from their confirmation and press **Record the e-Transfer**.
5. Paid in cash: open **Paid in cash**, count the amount in front of the renter and press **I received**. Keep the cash apart from your own money and hand it to CarmaCars within 1 business day, as Finance directs: Finance gets a task to collect it from you.
6. Additional driver not accepted: press **Sign now on this device (additional driver)**.

> Tip: An expired licence, a face that does not match or a renter who will not sign: do not fix it. Press Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. The car has to go anyway? Open **The car has to go anyway?**, say why and press **Release without the tracker**: an Admin is told at once. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Checked out. The rental has started." The renter gets the photo report by email and in their Documents.

> Tip: Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. Each photo keeps its time, and the place when your phone allows location.

## Sign now on this device

The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.

1. On the job, press **Sign now on this device**. It shows who still has to sign and whether their licence is on file.
2. Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press **Photograph: Licence, front** (and the back and the selfie).
3. Press **Hand the device to** and their name. They read the agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign with their name or their finger.
4. They hand the phone back: press **Back to the staff view**. The signature record says it was signed in person, collected by you, on your phone.

## The agreements at check-out

Both rental agreements follow the check-out.

1. Signing at pickup? Record the odometer and the fuel on the check-out first, then hand over the device: the agreement then shows the time, kilometres and fuel out, and the signed copy holds them.
2. The signer gets a code on their phone, initials the key terms, ticks the consents and draws their signature.
3. Already signed online? When you complete the check-out, the "as picked up" copy of both agreements is made with your readings and your countersignature, and emailed to the renter.
4. The check-out stops if the agreement is missing something a claim needs (a licence expiry, a VIN). Ask the office to fill it on the booking, or an Admin to override.

## The deposit on your phone

Deposit not taken yet? The ready check shows how to take it under the Deposit line. You never type a card number.

1. Press **Card hold: hand this phone to the renter**. They type their credit card in Stripe''s secure form and press the button with the amount.
2. They see "Hold placed": take the phone back and press **Back to the job**. The ready check shows the deposit taken.
3. A rental longer than the hold limit shows **Save the card on this phone (long rental)** instead: Finance charges the deposit to that card.
4. No credit card? When CarmaCars allows it, the renter pays the deposit by e-Transfer or in cash: record it under the Deposit line.

## Add-ons to put in the car

A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.

1. Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").
2. Put every item in the car before the handover. The Car ready step lists them again.
3. Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.
4. A chauffeur on the booking: Fleet tells you who drives and when.

> Tip: An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
',
  '<p class="gd-p">You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.</p><section class="gd-task" id="a-handover-before-you-start-the-ready-check" data-gd-task><h2 class="gd-h2">Before you start: the ready check</h2><p class="gd-p">The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each line should show a green tick: agreement signed, identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A red line shows what you can do about it right under it (see the next part). Fix it, then press <b class="gd-ui">Check again</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">All green? Press <b class="gd-ui">Next</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Coverage or the calendar not ready? Only the office fixes those: call CarmaCars. Still not ready? Press <b class="gd-ui">Stop: do not release the car</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/995"><img src="/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg" alt="" loading="lazy" decoding="async" width="390" height="995"><span class="gd-pin" style="left:93.6%;top:71.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:98%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.</div></aside></section><section class="gd-task" id="a-handover-fix-the-ready-check-on-the-spot" data-gd-task><h2 class="gd-h2">Fix the ready check on the spot</h2><p class="gd-p">Most red lines are fixed on your phone, without calling the office. Everything you do is recorded with your name.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Agreement not signed: press <b class="gd-ui">Sign now on this device</b> and hand the phone to the renter. Signed on paper instead? Open <b class="gd-ui">Signed on paper instead? Scan it</b>, take a photo of each page, then press <b class="gd-ui">Record the signed paper copy</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Identity not verified: for each driver, press <b class="gd-ui">Take</b> for the licence front, the back and the selfie. Hold the original licence: tick that the name matches, the photo is the person, it is valid past the return and it is class G2 or G. No expiry on file? Type the licence number and the expiry. Press <b class="gd-ui">The licence checks out</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit not taken: press <b class="gd-ui">Card hold: hand this phone to the renter</b>. They type their card in Stripe&#39;s secure form; take the phone back and press <b class="gd-ui">Back to the job</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Paid by e-Transfer instead: open <b class="gd-ui">Paid by e-Transfer</b>, type the reference number from their confirmation and press <b class="gd-ui">Record the e-Transfer</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Paid in cash: open <b class="gd-ui">Paid in cash</b>, count the amount in front of the renter and press <b class="gd-ui">I received</b>. Keep the cash apart from your own money and hand it to CarmaCars within 1 business day, as Finance directs: Finance gets a task to collect it from you.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Additional driver not accepted: press <b class="gd-ui">Sign now on this device (additional driver)</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An expired licence, a face that does not match or a renter who will not sign: do not fix it. Press Stop and call us.</div></aside></section><section class="gd-task" id="a-handover-the-steps-one-by-one" data-gd-task><h2 class="gd-h2">The steps, one by one</h2><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">1</span><div>Car ready: fuel full or charged 80%, clean, extras in. <b class="gd-ui">Yes</b> or <b class="gd-ui">No</b>, with a note for Fleet.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/385"><img src="/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg" alt="" loading="lazy" decoding="async" width="390" height="385"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">2</span><div>Is this the renter? Compare the person with the name and photo on file.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/325"><img src="/guides/img/field-23-handover-03-renter-phone-b718388d.jpg" alt="" loading="lazy" decoding="async" width="390" height="325"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">3</span><div>Original licence: name, photo and expiry match. A photo of a licence is not enough.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">4</span><div>Card on File: you have seen the physical card with the same last four digits, in the renter&#39;s name.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">5</span><div>Odometer: type the reading in km.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">6</span><div>Fuel or charge: slide to the level on the gauge.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/275"><img src="/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg" alt="" loading="lazy" decoding="async" width="390" height="275"></div></div></figure></div></div><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">7</span><div>Keys: how many keys and fobs you hand over. Use <b class="gd-ui">+</b> and <b class="gd-ui">−</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/235"><img src="/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg" alt="" loading="lazy" decoding="async" width="390" height="235"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">8</span><div>Photo set: 19 photos in order. <b class="gd-ui">Take</b> each one; <b class="gd-ui">Retake</b> if needed.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">9</span><div>Damage: tap the car diagram where it is, choose Where and Type, then <b class="gd-ui">Add the damage</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/605"><img src="/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg" alt="" loading="lazy" decoding="async" width="390" height="605"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">10</span><div>Tracker: it should say in place and reporting. <b class="gd-ui">Check again</b> if not. The car has to go anyway? Open <b class="gd-ui">The car has to go anyway?</b>, say why and press <b class="gd-ui">Release without the tracker</b>: an Admin is told at once.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/295"><img src="/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg" alt="" loading="lazy" decoding="async" width="390" height="295"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">11</span><div>Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/365"><img src="/guides/img/field-32-handover-12-summary-phone-96736994.jpg" alt="" loading="lazy" decoding="async" width="390" height="365"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">12</span><div>Signatures: the renter signs, then you. <b class="gd-ui">Use this signature</b> for each.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div></div><div class="gd-stepblock"><ol class="gd-ol" start="13"><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Hand over the keys</b>. You see &quot;Checked out. The rental has started.&quot; The renter gets the photo report by email and in their Documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. Each photo keeps its time, and the place when your phone allows location.</div></aside></section><section class="gd-task" id="a-handover-sign-now-on-this-device" data-gd-task><h2 class="gd-h2">Sign now on this device</h2><p class="gd-p">The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the job, press <b class="gd-ui">Sign now on this device</b>. It shows who still has to sign and whether their licence is on file.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press <b class="gd-ui">Photograph: Licence, front</b> (and the back and the selfie).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Hand the device to</b> and their name. They read the agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign with their name or their finger.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They hand the phone back: press <b class="gd-ui">Back to the staff view</b>. The signature record says it was signed in person, collected by you, on your phone.</div></li></ol></div></section><section class="gd-task" id="a-handover-the-agreements-at-check-out" data-gd-task><h2 class="gd-h2">The agreements at check-out</h2><p class="gd-p">Both rental agreements follow the check-out.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Signing at pickup? Record the odometer and the fuel on the check-out first, then hand over the device: the agreement then shows the time, kilometres and fuel out, and the signed copy holds them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The signer gets a code on their phone, initials the key terms, ticks the consents and draws their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already signed online? When you complete the check-out, the &quot;as picked up&quot; copy of both agreements is made with your readings and your countersignature, and emailed to the renter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The check-out stops if the agreement is missing something a claim needs (a licence expiry, a VIN). Ask the office to fill it on the booking, or an Admin to override.</div></li></ol></div></section><section class="gd-task" id="a-handover-the-deposit-on-your-phone" data-gd-task><h2 class="gd-h2">The deposit on your phone</h2><p class="gd-p">Deposit not taken yet? The ready check shows how to take it under the Deposit line. You never type a card number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Card hold: hand this phone to the renter</b>. They type their credit card in Stripe&#39;s secure form and press the button with the amount.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They see &quot;Hold placed&quot;: take the phone back and press <b class="gd-ui">Back to the job</b>. The ready check shows the deposit taken.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A rental longer than the hold limit shows <b class="gd-ui">Save the card on this phone (long rental)</b> instead: Finance charges the deposit to that card.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">No credit card? When CarmaCars allows it, the renter pays the deposit by e-Transfer or in cash: record it under the Deposit line.</div></li></ol></div></section><section class="gd-task" id="a-handover-add-ons-to-put-in-the-car" data-gd-task><h2 class="gd-h2">Add-ons to put in the car</h2><p class="gd-p">A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the job. Under Put in the car you see each add-on, how many, and what to do (for example &quot;Put the bouquet on the front passenger seat&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Put every item in the car before the handover. The Car ready step lists them again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur on the booking: Fleet tells you who drives and when.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The photo count shows &quot;19 of 19 photos taken · all uploaded&quot; when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.</div></aside></section>');
select app.guide_release_section('field', 'a-return', 'chapter', 'a-handover', 'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
', 'A return', 'Odometer, fuel, keys, cleanliness, photos, new damage, belongings and signatures.',
  'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.
10. The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
',
  '<p class="gd-p">The return mirrors the handover. You record the car as it comes back and compare it with the pickup.</p><section class="gd-task" id="a-return-take-the-car-back" data-gd-task><h2 class="gd-h2">Take the car back</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Car and keys received: confirm you have the car and its keys.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Odometer, then Fuel or charge, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Keys and extras: count what came back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cleanliness: inside and out.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Photo set: the same shots, in the same order, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press <b class="gd-ui">Add the damage</b> and take a close-up photo.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Belongings: check the seats, the trunk, the glovebox and the door pockets.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Renter reviews and signs. Then you sign.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Press <b class="gd-ui">Complete the return</b>. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.</div></aside></section>');
-- GUIDES 0154 END
