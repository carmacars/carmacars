-- 99: discounts on the rental charge only; e-sign initials that can be cleared; e-sign without the one-time code
-- (migration 0186, docs/changes/2026-10-28-esign-no-code-discount-scope.md). Uses the fixtures of 87 (the car AGV,
-- test.ag_req, test.ag_signer, test.ag_consents); its own bookings start with "ds" (discounts) and "nc" (no code).
select test.suite('99 e-sign without the code, discounts on the rental charge');

-- ---------------------------------------------------------------- 1. discounts come off the rental charge only
insert into promo_codes (id, code, percent_bps, source) values (test.id('promo:ds20'), 'DSSCOPE20', 2000, 'manual');
create temp table ds_spec as select jsonb_build_object(
  'booking_type', 'standard', 'pickup_at', '2027-03-03 15:00+00', 'return_at', '2027-03-06 15:00+00', 'hst_bps', 1300,
  'daily_rate_cents', 10000, 'weekend_rate_cents', 12000, 'weekly_rate_cents', 56000, 'monthly_rate_cents', 180000,
  'delivery_fee_cents', 7500, 'managed', true, 'coverage_option', '3',
  'drivers', '[{"role": "renter", "name": "Young Renter", "age_band": "21_to_25"}]'::jsonb,
  'fee_terms', '{"young_driver_21_25": {"amount_cents": 2500}, "coverage_sold": {"amount_cents": 3000, "per_day": true}}'::jsonb,
  'addons', '[{"name": "Phone holder", "pricing_unit": "per_rental", "unit_price_cents": 1500, "quantity": 1}]'::jsonb) s;
create temp table ds_out as select k, app.price_lines(s || v) o from ds_spec, (values
  ('none', '{}'::jsonb),
  ('promo', jsonb_build_object('promo_code_id', test.id('promo:ds20'))),
  ('staff_big', '{"staff_discount_cents": 99999999}'::jsonb),
  ('staff_promo', jsonb_build_object('staff_discount_cents', 5000, 'promo_code_id', test.id('promo:ds20'))),
  ('nonref_big', '{"booking_type": "non_refundable", "non_refundable_discount_bps": 1000, "staff_discount_cents": 99999999}'::jsonb)) x(k, v);
create function test.ds(p text) returns jsonb language sql stable as $$ select o from pg_temp.ds_out where k = p $$;
create function test.ds_fees(p text) returns bigint language sql stable as $$
  select sum((l ->> 'amount_cents')::bigint) from jsonb_array_elements(test.ds(p) -> 'lines') l
   where l ->> 'charge_type' not in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount') $$;

select test.eq('scope: the booking has fees, the Protection Plan, a young driver fee, delivery and an add-on',
  (select string_agg(l ->> 'charge_type', ',' order by l ->> 'charge_type') from jsonb_array_elements(test.ds('none') -> 'lines') l),
  'addon,coverage_sold,delivery,rental_charge,young_driver_21_25');
select test.eq('promo: a percentage code is that percentage of the rental charge only',
  (test.ds('promo') ->> 'promo_discount_cents')::bigint, public.calc_bps((test.ds('promo') ->> 'rental_charge_cents')::bigint, 2000));
select test.eq('promo: the fees, add-ons and the Protection Plan are unchanged', test.ds_fees('promo'), test.ds_fees('none'));
select test.eq('promo: the subtotal is lower by the discount only',
  (test.ds('none') ->> 'subtotal_cents')::bigint - (test.ds('promo') ->> 'subtotal_cents')::bigint, (test.ds('promo') ->> 'promo_discount_cents')::bigint);
select test.eq('staff: a discount larger than the rental charge is capped at the rental charge',
  (test.ds('staff_big') ->> 'staff_discount_cents')::bigint, (test.ds('staff_big') ->> 'rental_charge_cents')::bigint);
select test.eq('staff: the capped discount leaves every fee to pay (subtotal = the fees)', (test.ds('staff_big') ->> 'subtotal_cents')::bigint, test.ds_fees('none'));
select test.eq('staff and promo: the code takes its percentage of what is left of the rental charge',
  (test.ds('staff_promo') ->> 'promo_discount_cents')::bigint, public.calc_bps((test.ds('staff_promo') ->> 'rental_charge_cents')::bigint - 5000, 2000));
select test.eq('non-refundable: the staff discount is capped at the rental charge less the non-refundable discount',
  (test.ds('nonref_big') ->> 'non_refundable_discount_cents')::bigint + (test.ds('nonref_big') ->> 'staff_discount_cents')::bigint,
  (test.ds('nonref_big') ->> 'rental_charge_cents')::bigint);
select test.eq('non-refundable: the fees are still paid in full', (test.ds('nonref_big') ->> 'subtotal_cents')::bigint, test.ds_fees('none'));

-- a booking: a promo code, then an Admin's discount larger than the rental charge on the review screen
insert into test.ag select 'ds', (app.submit_booking_request(test.ag_req('ds', 45)) ->> 'booking_id')::uuid;
select test.lives('booking: the promo code goes on the request', $$select app.apply_promo_code(test.agb('ds'), 'DSSCOPE20', test.id('ag_admin'))$$);
select test.eq('booking: the code is 20% of the rental charge',
  (select promo_discount_cents = public.calc_bps(rental_charge_cents, 2000) and promo_discount_cents > 0 from bookings where id = test.agb('ds')), true);
select test.lives('booking: an Admin gives a discount larger than the rental charge (no error)',
  $$select app.adjust_booking(test.agb('ds'), test.id('ag_admin'), '{"staff_discount_cents": 99999999, "staff_discount_reason": "Regular renter"}', 'test')$$);
select test.eq('booking: the discount is capped at the rental charge, the code then takes nothing',
  (select (staff_discount_cents = rental_charge_cents)::text || '/' || promo_discount_cents from bookings where id = test.agb('ds')), 'true/0');
select test.eq('booking: the discount lines take exactly the rental charge; the fees stay',
  (select -sum(amount_cents) filter (where charge_type in ('staff_discount', 'promo_discount', 'non_refundable_discount'))
          = sum(amount_cents) filter (where charge_type = 'rental_charge')
     from booking_line_items where booking_id = test.agb('ds') and stage = 'booking' and voided_at is null)::text
  || '/' || (select total_due_at_booking_cents > 0 from bookings where id = test.agb('ds'))::text, 'true/true');
select test.lives('booking: a direct write is capped too (never the database''s refusal)',
  $$update bookings set staff_discount_cents = rental_charge_cents + 5000 where id = test.agb('ds')$$);
select test.eq('booking: still the rental charge', (select staff_discount_cents = rental_charge_cents from bookings where id = test.agb('ds')), true);

-- ---------------------------------------------------------------- 2. e-sign: the code is optional (off by default)
select test.eq('setting: the one-time code is off by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'esign_code_required'), 'false');
update program_settings set esign_code_required = false, esign_strict = true;

insert into test.ag select 'nc', (app.submit_booking_request(test.ag_req('nc', 30)) ->> 'booking_id')::uuid;
update renters set address_line1 = '1 Example Street', city = 'Toronto', province = 'ON', postal_code = 'M5H 2N2' where id = (select renter_id from bookings where id = test.agb('nc'));
select app.send_offer(test.agb('nc'), test.id('ag_cs'));
select public.renter_approve_offer(test.agb('nc'), 1, test.agu('nc'));
select public.renter_open_agreement(test.agb('nc'), test.agu('nc'), 'rental-test', repeat('a', 64), 'bookings/' || test.agb('nc') || '/agreement.pdf');

create temp table nc_s as select (public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', test.ag_signer('nc', 'renter'),
  'ip', '203.0.113.9', 'user_agent', 'test')) ->> 'id')::uuid id;
create function test.nc() returns uuid language sql stable as $$ select id from pg_temp.nc_s $$;
select test.eq('view: the page is told the code is not required', public.server_esign_view(test.nc()) ->> 'code_required', 'false');
select test.throws('signing: a typed name alone is still refused, the message without the code',
  $$select public.renter_sign_agreement(test.agb('nc'), test.agu('nc'), 'I sign.', repeat('a', 64), test.ag_consents(), 'Ana Accurate', null, '203.0.113.7', 'test')$$,
  'Read the agreement, initial the key terms%');
select public.server_esign_step(test.nc(), 'viewed', '{}', '203.0.113.9', 'test');
select test.lives('session: initials without a code', $$select public.server_esign_step(test.nc(), 'initial', '{"code": "damage", "path": "sig/initials-damage.png"}', '203.0.113.9', 'test')$$);

-- ---------------------------------------------------------------- 3. e-sign: initials can be cleared
select test.lives('clear: the signer clears the initials of a term', $$select public.server_esign_step(test.nc(), 'initial_clear', '{"code": "damage"}', '203.0.113.9', 'test')$$);
select test.eq('clear: the term is no longer initialled', public.server_esign_view(test.nc()) -> 'initials', '[]'::jsonb);
select test.eq('clear: the audit trail has it, with the term',
  (select count(*) || '/' || max(detail ->> 'code') || '/' || max(detail ->> 'had_initials') from esign_events where session_id = test.nc() and kind = 'initial_clear'), '1/damage/true');
select test.throws('clear: an unknown term is refused', $$select public.server_esign_step(test.nc(), 'initial_clear', '{"code": "nonsense"}')$$, 'Unknown term to initial');
do $$
declare k text;
begin
  for k in select unnest(required_initials) from esign_sessions where id = test.nc() loop
    perform public.server_esign_step(test.nc(), 'initial', jsonb_build_object('code', k, 'path', 'sig/initials-' || k || '.png'), '203.0.113.9', 'test');
  end loop;
  for k in select unnest(required_consents) from esign_sessions where id = test.nc() loop
    perform public.server_esign_step(test.nc(), 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  perform public.server_esign_step(test.nc(), 'signature', '{"method": "drawn", "path": "bookings/nc/sig.png"}', '203.0.113.9', 'test');
end $$;
select test.eq('ready: read, initialled, consented and drawn, without a code', public.server_esign_view(test.nc()) ->> 'ready', 'true');
select public.server_esign_step(test.nc(), 'initial_clear', '{"code": "fees"}', '203.0.113.9', 'test');
select test.eq('clear: a cleared initial makes the session not ready', public.server_esign_view(test.nc()) ->> 'ready', 'false');
select test.throws('clear: and the signature is refused until it is initialled again',
  $$select public.renter_sign_agreement(test.agb('nc'), test.agu('nc'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'bookings/nc/sig.png', '203.0.113.7', 'test')$$, 'Read the agreement%');
select public.server_esign_step(test.nc(), 'initial', '{"code": "fees", "path": "sig/initials-fees-2.png"}', '203.0.113.9', 'test');

-- ---------------------------------------------------------------- 4. the setting on: the code is required again
update program_settings set esign_code_required = true;
select test.eq('on: the same session is no longer ready without the code', public.server_esign_view(test.nc()) ->> 'ready', 'false');
select test.throws('on: the signature is refused, asking for the code',
  $$select public.renter_sign_agreement(test.agb('nc'), test.agu('nc'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'bookings/nc/sig.png', '203.0.113.7', 'test')$$,
  'Confirm your identity with the code%');
select test.throws('on: no initial before the code', $$select public.server_esign_step(test.nc(), 'initial_clear', '{"code": "damage"}')$$, 'Confirm the code first');
select public.server_esign_code_set(test.nc(), 'email', repeat('7', 64));
select public.server_esign_code_check(test.nc(), repeat('7', 64));
select test.eq('on: with the code confirmed it is ready', public.server_esign_view(test.nc()) ->> 'ready', 'true');

-- off again: the renter signs without the code; the certificate says so (no code confirmed)
update program_settings set esign_code_required = false;
create temp table nc_s2 as select (public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', test.ag_signer('nc', 'additional_driver'),
  'ip', '203.0.113.9', 'user_agent', 'test')) ->> 'id')::uuid id;
do $$
declare
  v uuid := (select id from pg_temp.nc_s2);
  k text;
begin
  perform public.server_esign_step(v, 'viewed', '{}', '203.0.113.9', 'test');
  for k in select unnest(required_initials) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'initial', jsonb_build_object('code', k, 'path', 'sig/d-initials-' || k || '.png'), '203.0.113.9', 'test');
  end loop;
  for k in select unnest(required_consents) from esign_sessions where id = v loop
    perform public.server_esign_step(v, 'consent', jsonb_build_object('code', k, 'text', 'I agree'), '203.0.113.9', 'test');
  end loop;
  perform public.server_esign_step(v, 'signature', '{"method": "drawn", "path": "drivers/nc/sig.png"}', '203.0.113.9', 'test');
end $$;
select test.lives('off: the driver signs without a code',
  $$select public.driver_sign_agreement(test.ag_signer('nc', 'additional_driver'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'drivers/nc/sig.png', '203.0.113.8', 'test')$$);
select test.eq('certificate: the driver''s identity was not confirmed by a code; the steps, IP and device are kept',
  (select (c -> 0 ->> 'otp_verified_at') is null and (c -> 0 ->> 'ip_address') is not null and (c -> 0 ->> 'user_agent') = 'test'
          and (select count(*) from jsonb_array_elements(c -> 0 -> 'events') e where e ->> 'kind' in ('viewed', 'initial', 'consent', 'signature', 'signed')) >= 7
     from public.server_esign_certificate('rental_agreement', array[test.ag_signer('nc', 'additional_driver')]) c), true);
select test.lives('off: the renter signs with the session (its code confirmed earlier)',
  $$select public.renter_sign_agreement(test.agb('nc'), test.agu('nc'), 'I sign.', repeat('a', 64), test.ag_consents(), null, 'bookings/nc/sig.png', '203.0.113.7', 'test')$$);

-- leave the settings as the later suites expect
update program_settings set esign_code_required = false, esign_strict = false;
