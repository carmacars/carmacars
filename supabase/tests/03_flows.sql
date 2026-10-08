-- 03: status flows and the guards around them: booking lifecycle, 30-day maximum, renewals,
-- deposits, vehicle and onboarding flow, owner invoice flow, claims and their ledger,
-- tracker commands, tolls, investors, the fleet minimum and the audit log.
select test.suite('03 flows');

select test.mk_owner('fiona', 'FIONA20');
select test.mk_vehicle('F1', 'fiona');
select test.mk_renter('lia', false);

-- ------------------------------------------------------------------ booking lifecycle
select test.throws('B a booking over 30 days is refused',
  $$select test.mk_booking('L31', 'F1', 'lia', '2027-02-01 10:00', '2027-03-04 10:00', 'tentative')$$, '1 to 30 days');
select test.mk_booking('L1', 'F1', 'lia', '2027-02-01 10:00', '2027-02-04 10:00', 'tentative');
select test.eq('B the booking snapshots the vehicle''s owner, mode and Revenue Share',
  (select (owner_id = test.id('owner:fiona')) || '/' || management_mode || '/' || company_share_bps from bookings where id = test.id('booking:L1')), 'true/managed/3500');
select test.throws('B extending a booking past 30 days in one transaction is refused by the table itself',
  format($$update bookings set return_at = pickup_at + interval '31 days', billable_days = 31, km_allowance_total = 6200 where id = %L$$, test.id('booking:L1')), 'billable_days');
select test.throws('B tentative cannot jump to on rent',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'cannot go from tentative to on_rent');
update bookings set status = 'pending_payment' where id = test.id('booking:L1');
select test.throws('B not confirmed until the agreement is signed',
  format('update bookings set status = ''confirmed'' where id = %L', test.id('booking:L1')), 'agreement is signed');
insert into documents (id, kind, storage_bucket, storage_path, booking_id) values (test.id('doc:L1'), 'rental_agreement', 'agreements', 'bookings/L1/agreement.pdf', test.id('booking:L1'));
insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at)
values (test.id('sig:L1'), test.id('doc:L1'), 'esign', 'env-L1', 'completed', now());
update bookings set signature_request_id = test.id('sig:L1'), agreement_document_id = test.id('doc:L1') where id = test.id('booking:L1');
update payments set status = 'failed' where id = test.id('payment:L1');
select test.throws('B not confirmed until payment succeeds',
  format('update bookings set status = ''confirmed'' where id = %L', test.id('booking:L1')), 'payment succeeds');
update payments set status = 'succeeded' where id = test.id('payment:L1');
select test.lives('B signed and paid: confirmed', format('update bookings set status = ''confirmed'' where id = %L', test.id('booking:L1')));
-- (migration 0016: only a confirmed or on rent booking blocks the car, so this check moved here from before the confirmation)
select test.throws('B a vehicle holds only one confirmed booking for any moment',
  $$select test.mk_booking('L1X', 'F1', 'lia', '2027-02-03 10:00', '2027-02-05 10:00', 'confirmed')$$, 'conflicting');
select test.throws('B a referrer cannot be added after the booking is made',
  format('update bookings set referred_by_code = ''FIONA20'' where id = %L', test.id('booking:L1')), 'before the booking is made');
select test.throws('B the rates stored on a confirmed booking cannot change',
  format('update bookings set daily_rate_cents = 1 where id = %L', test.id('booking:L1')), 'cannot change');

-- handover needs identity, coverage, deposit and the pickup report
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:L1'), test.id('driver:lia'), 'renter', 'Lia', date '1990-05-05', 36, '26_plus');
select test.throws('B no handover until every driver''s identity is verified',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'identity is verified');
update booking_drivers set identity_method = 'staff_review', identity_verified_on = date '2027-01-30' where booking_id = test.id('booking:L1');
select test.throws('B no handover until a Coverage Option is confirmed',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'Coverage Option');
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at)
values (test.id('booking:L1'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.id('booking:L1');
select test.throws('B no handover until the Deposit is taken',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'Deposit is taken');
insert into deposits (id, booking_id, amount_cents, method, status, taken_at, hold_expires_at)
values (test.id('dep:L1'), test.id('booking:L1'), 100000, 'card_hold', 'held', now(), now() + interval '7 days');
select test.throws('B no handover without the pickup Condition Report',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'pickup Condition Report');
insert into condition_reports (id, vehicle_id, booking_id, kind, odometer_km, fuel_pct, tracker_reporting, licence_seen, card_seen)
values (test.id('cr:L1:out'), test.id('vehicle:F1'), test.id('booking:L1'), 'pickup', 20000, 100, true, true, true);
insert into condition_report_photos (condition_report_id, seq, shot, storage_path)
select test.id('cr:L1:out'), row_number() over (), s, 'bookings/L1/pickup/' || s || '.jpg'
  from unnest(array['front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right', 'roof', 'windshield']) s;
select test.lives('B handed over: on rent', format($$update bookings set status = 'on_rent', handed_over_at = pickup_at where id = %L$$, test.id('booking:L1')));
select test.eq('B the vehicle is on rent too', (select status::text from vehicles where id = test.id('vehicle:F1')), 'on_rent');
select test.eq('T during a rental CarmaCars manages, the Owner''s controls are blocked',
  app.owner_controls_blocked(test.id('vehicle:F1'), timestamp '2027-02-02 12:00' at time zone 'America/Toronto'), true);

-- extension past 7 days: the hold must be captured first
select test.throws('R3 extension past 7 days in total: capture the card hold first',
  format($$update bookings set return_at = pickup_at + interval '8 days', billable_days = 8, km_allowance_total = 1600 where id = %L$$, test.id('booking:L1')), 'capture the card hold');
select test.throws('R3 a rental over 7 days cannot start on a card hold',
  $$select test.mk_booking('L9', 'F1', 'lia', '2027-05-01 10:00', '2027-05-10 10:00', 'tentative');
    insert into deposits (booking_id, amount_cents, method) values (test.id('booking:L9'), 100000, 'card_hold')$$, 'charged Deposit');

select test.throws('B no Check-in without the return Condition Report',
  format('update bookings set status = ''returned'' where id = %L', test.id('booking:L1')), 'return Condition Report');
insert into condition_reports (id, vehicle_id, booking_id, kind, odometer_km, fuel_pct)
values (test.id('cr:L1:in'), test.id('vehicle:F1'), test.id('booking:L1'), 'return', 20500, 100);
select test.lives('B Check-in: returned', format($$update bookings set status = 'returned', checked_in_at = return_at, odometer_out_km = 20000, odometer_in_km = 20500 where id = %L$$, test.id('booking:L1')));
select test.eq('B after Check-in the vehicle is in cleaning and the Owner''s controls are restored',
  (select status::text from vehicles where id = test.id('vehicle:F1')) || '/'
  || app.owner_controls_blocked(test.id('vehicle:F1'), timestamp '2027-02-04 12:00' at time zone 'America/Toronto'), 'cleaning/false');
select test.eq('R3 the Deposit balance is due back within 7 business days of Check-in (Thursday Feb 4 -> Monday Feb 15, 2027)',
  (select release_due_on from deposits where booking_id = test.id('booking:L1')), date '2027-02-15');
select test.eq('B the renter''s first completed booking is recorded', (select first_completed_booking_id from renters where id = test.id('renter:lia')), test.id('booking:L1'));
select test.eq('B the split is computed at Check-in (3 days Mon-Thu = $300; 35% kept)',
  (select owner_revenue_cents || '/' || company_share_cents || '/' || status from booking_splits where booking_id = test.id('booking:L1')), '30000/10500/provisional');
select test.lives('B statement issued, deposit settled: closed', format('update bookings set status = ''closed'' where id = %L', test.id('booking:L1')));
select test.throws('B a closed booking does not reopen',
  format('update bookings set status = ''on_rent'' where id = %L', test.id('booking:L1')), 'cannot go from closed');
select test.eq('B every status change is in the history',
  (select string_agg(to_status, ' > ' order by id) from status_history where entity = 'booking' and entity_id = test.id('booking:L1')),
  'tentative > pending_payment > confirmed > on_rent > returned > closed');

-- renewal: a new booking linked to the earlier one
update vehicles set status = 'available' where id = test.id('vehicle:F1');
select test.mk_booking('L2', 'F1', 'lia', '2027-02-04 10:00', '2027-02-19 10:00', 'tentative', null, 'standard', null, '2027-02-03 10:00', null, 'L1');
select test.eq('R6 a renewal is its own booking, linked to the earlier one, priced on its own length (15 days = $1,200)',
  (select (renews_booking_id = test.id('booking:L1')) || '/' || rental_charge_cents from bookings where id = test.id('booking:L2')), 'true/120000');
select test.throws('R6 a booking has at most one renewal',
  $$select test.mk_booking('L3', 'F1', 'lia', '2027-03-01 10:00', '2027-03-05 10:00', 'tentative', null, 'standard', null, '2027-02-03 10:00', null, 'L1')$$, 'bookings_one_renewal');
select test.mk_renter('other', false);
select test.throws('R6 a renewal belongs to the same renter',
  $$select test.mk_booking('L4', 'F1', 'other', '2027-04-01 10:00', '2027-04-05 10:00', 'tentative', null, 'standard', null, '2027-02-03 10:00', null, 'L2')$$, 'same renter');

-- non-refundable discount is fixed at 10%
select test.throws('R1 the non-refundable discount is fixed at 10% of the rental charge',
  $$select test.mk_booking('NR1', 'F1', 'other', '2027-06-01 10:00', '2027-06-03 10:00', 'tentative', null, 'non_refundable');
    update bookings set discount_cents = 5000 where id = test.id('booking:NR1')$$, null);
select test.throws('R1 a standard booking carries no discount',
  $$select test.mk_booking('NR2', 'F1', 'other', '2027-06-10 10:00', '2027-06-12 10:00', 'tentative');
    update bookings set discount_cents = 100 where id = test.id('booking:NR2')$$, 'check');

-- cancellation: logged, tier computed, then cancelled
select test.mk_booking('CX', 'F1', 'other', '2027-07-10 10:00', '2027-07-13 10:00', 'confirmed', null, 'standard', null, '2027-07-01 10:00');
select test.throws('R5 a confirmed booking is cancelled only after the three times are logged',
  format('update bookings set status = ''cancelled'' where id = %L', test.id('booking:CX')), 'Log the cancellation');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason)
values (test.id('booking:CX'), timestamp '2027-07-09 09:00' at time zone 'America/Toronto', 'renter', 'renter_request');
select test.eq('R5 the tier is computed, never typed: 25 hours before start is 50%',
  (select tier || '/' || refund_bps from booking_cancellations where booking_id = test.id('booking:CX')), 'notice_24_to_48h/5000');
select test.lives('R5 cancelled', format('update bookings set status = ''cancelled'' where id = %L', test.id('booking:CX')));
select test.mk_booking('CY', 'F1', 'other', '2027-07-20 10:00', '2027-07-23 10:00', 'confirmed', null, 'non_refundable', null, '2027-07-01 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason)
values (test.id('booking:CY'), timestamp '2027-07-02 09:00' at time zone 'America/Toronto', 'carmacars', 'carmacars_no_vehicle');
select test.eq('R5 CarmaCars cancels a non-refundable booking: everything paid is refunded',
  (select refund_bps || '/' || (refund_cents = total_paid_cents) from booking_cancellations where booking_id = test.id('booking:CY')), '10000/true');

-- young drivers
update drivers set date_of_birth = date '2008-01-01' where id = test.id('driver:other');
select test.lives('P2 (0025) every car takes drivers aged 18 to 20 (the flag defaults to allowed)',
  format($$insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
           values (%L, %L, 'renter', 'Other', date '2008-01-01', 19, '18_to_20')$$, test.id('booking:CY'), test.id('driver:other')));
select test.throws('P2 nobody under 18 drives',
  format($$insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
           values (%L, %L, 'renter', 'Other', date '2010-01-01', 17, '26_plus')$$, test.id('booking:CY'), test.id('driver:other')), 'check');

-- ------------------------------------------------------------------ vehicle and onboarding flow
select test.throws('V an exited vehicle does not come back by a status edit',
  format($$update vehicles set status = 'exit_notice' where id = %L; update vehicles set status = 'exited' where id = %L; update vehicles set status = 'available' where id = %L$$,
         test.id('vehicle:R2'), test.id('vehicle:R2'), test.id('vehicle:R2')), 'cannot go from exited');
select test.throws('O6 a Self-Managed vehicle in arrears takes no new bookings',
  format($$update vehicles set in_arrears = true where id = %L;
           select test.mk_booking('SA', 'S', 'other', '2027-08-01 10:00', '2027-08-03 10:00', 'tentative')$$, test.id('vehicle:S')), 'not open for new bookings');

insert into vehicles (id, owner_id, year, make, model, vin, class) values (test.id('vehicle:NEW'), test.id('owner:fiona'), 2024, 'BMW', 'X3', 'NEWVIN00000000001', 'suv');
insert into vehicle_onboardings (id, vehicle_id) values (test.id('onb:NEW'), test.id('vehicle:NEW'));
select test.throws('ON onboarding cannot skip to enrolled',
  format('update vehicle_onboardings set status = ''enrolled'' where id = %L', test.id('onb:NEW')), 'cannot go from intake to enrolled');
update vehicle_onboardings set status = 'terms_set' where id = test.id('onb:NEW');
update vehicle_onboardings set status = 'documents_sent' where id = test.id('onb:NEW');
select test.throws('ON documents are not signed until the Vehicle Schedule is signed',
  format('update vehicle_onboardings set status = ''documents_signed'' where id = %L', test.id('onb:NEW')), 'Vehicle Schedule is not signed');
insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, is_additional, held_by, title_status,
    management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, signed_at)
values (test.id('vehicle:NEW'), test.id('agreement:fiona'), 'VS-NEW', 2, true, 'individual', 'owned_outright', 'managed', 'transfer', 40000, 2000, 3000, now());
update vehicle_onboardings set status = 'documents_signed' where id = test.id('onb:NEW');
select test.throws('ON only a Turo-Only vehicle is enrolled straight after signature',
  format('update vehicle_onboardings set status = ''enrolled'' where id = %L', test.id('onb:NEW')), 'Turo-Only');
select test.throws('ON only a shareholder-owned vehicle skips the upfront charges',
  format('update vehicle_onboardings set status = ''registry_booked'' where id = %L', test.id('onb:NEW')), 'shareholder-owned');
select test.throws('ON upfront charges must be paid first',
  format('update vehicle_onboardings set status = ''upfront_paid'' where id = %L', test.id('onb:NEW')), 'not paid');
select app.issue_upfront_invoice(test.id('vehicle:NEW'));
select test.eq('ON upfront amounts come from the signed schedule, never from a tier: $100 + 2 x $400 + HST',
  (select total_cents from owner_invoices where vehicle_id = test.id('vehicle:NEW') and kind = 'upfront'), test.money('1,017.00'));
select test.throws('INV an invoice cannot be paid before it is issued',
  format('update owner_invoices set status = ''paid'' where vehicle_id = %L', test.id('vehicle:NEW')), 'cannot go from draft to paid');
update owner_invoices set status = 'issued' where vehicle_id = test.id('vehicle:NEW');
update owner_invoices set status = 'paid' where vehicle_id = test.id('vehicle:NEW');
select test.throws('INV a paid upfront invoice cannot be voided',
  format('update owner_invoices set status = ''void'' where vehicle_id = %L', test.id('vehicle:NEW')), 'cannot go from paid to void');
update vehicle_onboardings set status = 'upfront_paid' where id = test.id('onb:NEW');
update vehicle_onboardings set status = 'registry_booked' where id = test.id('onb:NEW');
update vehicle_onboardings set status = 'registered' where id = test.id('onb:NEW');
select test.throws('ON no Fleet Policy without a tested Tracker',
  format('update vehicle_onboardings set status = ''tracker_installed'' where id = %L', test.id('onb:NEW')), 'Tracker must be installed');
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at)
values (test.id('trk:NEW'), 'TRK-NEW', test.id('vehicle:NEW'), 'installed', now(), now());
update vehicle_onboardings set status = 'tracker_installed' where id = test.id('onb:NEW');
update vehicle_onboardings set status = 'on_fleet_policy', on_fleet_policy_at = timestamptz '2027-01-14 18:00+00' where id = test.id('onb:NEW');
update vehicle_onboardings set status = 'enrolled', enrolled_confirmed_at = timestamp '2027-01-15 23:30' at time zone 'America/Toronto' where id = test.id('onb:NEW');
select test.eq('ON the written confirmation''s Toronto date is the Enrollment Date (23:30 Toronto on Jan 15 is Jan 16 in UTC)',
  (select enrollment_date || '/' || status || '/' || on_fleet_policy from vehicles where id = test.id('vehicle:NEW')), '2027-01-15/ready_to_list/true');
select test.eq('ON the fee terms open from the signed schedule on the Enrollment Date',
  (select insurance_fee_cents || '/' || tracker_fee_cents || '/' || revenue_share_bps || '/' || effective_from from vehicle_fee_history where vehicle_id = test.id('vehicle:NEW')),
  '40000/2000/3000/2027-01-15');
select test.throws('O1 a fee change needs 30 days'' written notice',
  format($$update vehicle_fee_history set effective_to = date '2027-02-01' where vehicle_id = %L;
           insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, notice_sent_on)
           values (%L, 'fee_notice', 42000, 2000, 3000, date '2027-02-01', date '2027-01-20')$$, test.id('vehicle:NEW'), test.id('vehicle:NEW')), 'check');
select test.throws('O1 a Revenue Share changes only by a new signed Vehicle Schedule',
  format($$update vehicle_fee_history set effective_to = date '2027-04-01' where vehicle_id = %L;
           insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, notice_sent_on)
           values (%L, 'fee_notice', 42000, 2000, 2500, date '2027-04-01', date '2027-02-20')$$, test.id('vehicle:NEW'), test.id('vehicle:NEW')), 'new signed Vehicle Schedule');
select test.throws('O1 one live agreement per Owner',
  format($$insert into owner_agreements (owner_id, kind, agreement_number, status) values (%L, 'enrollment', 'EA-fiona-2', 'draft')$$, test.id('owner:fiona')), 'owner_agreements_one_live');

-- ------------------------------------------------------------------ claims and their ledger
insert into incidents (id, kind, vehicle_id, booking_id, occurred_at) values (test.id('inc:1'), 'accident', test.id('vehicle:H'), test.id('booking:H1'), now());
insert into incident_costs (incident_id, kind, amount_cents, approved_shop) values (test.id('inc:1'), 'repair_estimate', 820000, true);
insert into incident_costs (incident_id, kind, amount_cents) values (test.id('inc:1'), 'towing', 30000);
select app.open_claim(test.id('inc:1'));
create temp view cl1 as select * from claims where incident_id = test.id('inc:1');
select test.eq('C Damage of $8,500 on a shareholder car: fleet policy claim, renter billed the $2,500 deductible plus $75, 90% owner share',
  (select path || '/' || deductible_billed_cents || '/' || admin_fee_cents || '/' || owner_share_bps from cl1), 'fleet_policy/250000/7500/9000');
update claims set status = 'submitted' where id = (select id from cl1);
update claims set status = 'accepted' where id = (select id from cl1);
update claims set status = 'in_repair' where id = (select id from cl1);
update claims set status = 'repaired' where id = (select id from cl1);
update claims set status = 'settling' where id = (select id from cl1);
select test.throws('C a claim is not closed before it is settled',
  format('update claims set status = ''closed'' where id = %L', (select id from cl1)), 'Settle the claim');
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'insurer_payment', 750000 from cl1;
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'renter_deductible', 250000 from cl1;
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'repair', 820000 from cl1;
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'towing', 20000 from cl1;
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'appraisal', 10000 from cl1;
select test.throws('C the claim ledger is append-only',
  format('update claim_ledger_entries set amount_cents = 1 where claim_id = %L', (select id from cl1)), 'append-only');
select test.throws('C a shareholder claim needs both Principals',
  format('select app.settle_claim(%L, %L)', (select id from cl1), test.id('admin_abbas')), 'both Principals');
select test.throws('C the same Principal cannot approve twice',
  format('select app.settle_claim(%L, %L, %L)', (select id from cl1), test.id('admin_abbas'), test.id('admin_abbas')), 'both Principals');
select app.settle_claim((select id from cl1), test.id('admin_abbas'), test.id('admin_mahad'));
select test.eq('O7 through the ledger: Claim Profit $1,500; owning shareholder $1,350; company $150',
  (select result_cents || '/' || owner_result_cents || '/' || company_result_cents from cl1), '150000/135000/15000');
select test.eq('O7 the 90% is a payout needing both Principals; the 10% is posted as company surplus',
  (select p.amount_cents || '/' || p.requires_both_principals || '/' || (p.second_approved_by = test.id('admin_mahad'))
     from payouts p where p.claim_id = (select id from cl1))
  || ' ' || (select amount_cents from claim_ledger_entries where claim_id = (select id from cl1) and kind = 'company_surplus'),
  '135000/true/true 15000');
select test.lives('C settled: closed', format('update claims set status = ''closed'' where id = %L', (select id from cl1)));

-- third-party vehicle: under $2,500 at cost; and a shortfall on a claim goes to the Owner as a cost
insert into incidents (id, kind, vehicle_id, booking_id) values (test.id('inc:2'), 'damage_at_return', test.id('vehicle:A'), test.id('booking:A1'));
insert into incident_costs (incident_id, kind, amount_cents, approved_shop) values (test.id('inc:2'), 'repair_invoice', 160000, true);
insert into incident_costs (incident_id, kind, amount_cents, days) values (test.id('inc:2'), 'loss_of_use', public.calc_loss_of_use(10000, 2), 2);
select app.open_claim(test.id('inc:2'));
select test.eq('C Damage of $1,800 ($1,600 repair + 2 days loss of use): billed at cost plus the $50 fee, no claim',
  (select path || '/' || damage_cost_cents || '/' || deductible_billed_cents || '/' || admin_fee_cents from claims where incident_id = test.id('inc:2')), 'at_cost/180000/0/5000');
select test.throws('C an at-cost repair is never submitted to the insurer',
  format('update claims set status = ''submitted'' where incident_id = %L', test.id('inc:2')), 'Only a fleet policy claim');
insert into incidents (id, kind, vehicle_id, booking_id) values (test.id('inc:3'), 'accident', test.id('vehicle:B'), test.id('booking:B1'));
insert into incident_costs (incident_id, kind, amount_cents, approved_shop) values (test.id('inc:3'), 'repair_invoice', 500000, true);
select app.open_claim(test.id('inc:3'));
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'insurer_payment', 200000 from claims where incident_id = test.id('inc:3');
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'renter_deductible', 250000 from claims where incident_id = test.id('inc:3');
insert into claim_ledger_entries (claim_id, kind, amount_cents) select id, 'repair', 500000 from claims where incident_id = test.id('inc:3');
select app.settle_claim((select id from claims where incident_id = test.id('inc:3')), test.id('admin_abbas'));
select test.eq('O7 third-party shortfall of $500: billed to the Owner as an Owner cost; no claim money on the Owner''s account',
  (select kind || '/' || amount_cents || '/' || status from owner_deductions where vehicle_id = test.id('vehicle:B') and kind = 'claim_shortfall'), 'claim_shortfall/50000/open');

-- total loss: Fees stop on the Insurer's decision date; settlement order
insert into incidents (id, kind, vehicle_id) values (test.id('inc:4'), 'theft', test.id('vehicle:E'));
insert into claims (id, incident_id, vehicle_id, owner_id, path) values (test.id('claim:4'), test.id('inc:4'), test.id('vehicle:E'), test.id('owner:quinn'), 'total_loss');
update claims set status = 'total_loss', insurer_decision_on = date '2027-02-10' where id = test.id('claim:4');
select app.generate_owner_invoice(test.id('vehicle:E'), date '2027-02-01');
select test.eq('O1 on a total loss, Fees stop on the date of the Insurer''s decision (10 of 28 days in February)',
  (select days_billed from owner_invoices where vehicle_id = test.id('vehicle:E') and period_month = date '2027-02-01'), 10);
select test.eq('O1 and nothing is billed for March', app.generate_owner_invoice(test.id('vehicle:E'), date '2027-03-01') is null, true);
select test.throws('C settlement must be recorded before it is marked received',
  format('update claims set status = ''settlement_received'' where id = %L', test.id('claim:4')), 'Record the settlement');
select app.record_total_loss_settlement(test.id('claim:4'), 3000000, date '2027-03-01', 1800000, test.id('admin_abbas'));
select test.eq('O7 total loss: lender first, then what the Owner owes CarmaCars, then the Owner, due within 10 business days of cleared funds',
  (select lender_paid_cents || '/' || (company_setoff_cents = owner_owes_cents) || '/' || (lender_paid_cents + company_setoff_cents + owner_balance_cents = settlement_cents) || '/' || owner_balance_due_by
     from claims where id = test.id('claim:4')), '1800000/true/true/2027-03-15');

-- ------------------------------------------------------------------ tracker command log
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:F1'), 'TRK-F1', test.id('vehicle:F1'), 'installed', now(), now());
select test.throws('T a command needs its reason',
  format($$insert into tracker_commands (tracker_device_id, vehicle_id, command, actor_type, requested_by, reason_code, reason)
           values (%L, %L, 'locate', 'staff', %L, 'late_return', ' ')$$, test.id('trk:F1'), test.id('vehicle:F1'), test.id('admin_abbas')), 'check');
select test.throws('T a command needs who requested it',
  format($$insert into tracker_commands (tracker_device_id, vehicle_id, command, actor_type, reason_code, reason)
           values (%L, %L, 'locate', 'staff', 'late_return', 'overdue')$$, test.id('trk:F1'), test.id('vehicle:F1')), 'check');
insert into tracker_commands (id, tracker_device_id, vehicle_id, command, actor_type, requested_by, reason_code, reason)
values (test.id('cmd:1'), test.id('trk:F1'), test.id('vehicle:F1'), 'engine_disable', 'staff', test.id('admin_mahad'), 'late_return', '3 hours overdue, T14 notice expired');
select test.throws('T only an Admin approves disabling',
  format($$update tracker_commands set status = 'approved', approved_by = %L where id = %L$$, test.id('field_frank'), test.id('cmd:1')), 'Only an Admin');
update tracker_commands set status = 'approved', approved_by = test.id('admin_abbas'), approved_at = now() where id = test.id('cmd:1');
select test.throws('T never while moving: speed 40 km/h',
  format($$update tracker_commands set status = 'sent', sent_at = now(), observed_at = now(), observed_speed_kmh = 40, observed_ignition_on = true where id = %L$$, test.id('cmd:1')), 'Never disable while moving');
select test.throws('T never while the ignition is on, even when stationary',
  format($$update tracker_commands set status = 'sent', sent_at = now(), observed_at = now(), observed_speed_kmh = 0, observed_ignition_on = true where id = %L$$, test.id('cmd:1')), 'Never disable while moving');
select test.throws('T never without a reading',
  format($$update tracker_commands set status = 'sent', sent_at = now() where id = %L$$, test.id('cmd:1')), 'Never disable while moving');
select test.throws('T never on a stale reading',
  format($$update tracker_commands set status = 'sent', sent_at = now(), observed_at = now() - interval '20 minutes', observed_speed_kmh = 0, observed_ignition_on = false where id = %L$$, test.id('cmd:1')), '5 minutes old');
select test.lives('T stationary, ignition off, Admin approved: sent',
  format($$update tracker_commands set status = 'sent', sent_at = now(), observed_at = now(), observed_speed_kmh = 0, observed_ignition_on = false where id = %L$$, test.id('cmd:1')));
select test.throws('T the log cannot be rewritten', format($$update tracker_commands set reason = 'x' where id = %L$$, test.id('cmd:1')), 'cannot be rewritten');
select test.throws('T the log cannot be deleted', format($$delete from tracker_commands where id = %L$$, test.id('cmd:1')), 'append-only');

-- ------------------------------------------------------------------ tolls and tickets
select test.eq('P11 a toll during the rental period is matched to the renter''s booking',
  (select matched_to || '/' || (booking_id = test.id('booking:A1')) from app.match_toll_ticket(test.id('vehicle:A'), timestamp '2026-11-05 14:00' at time zone 'America/Toronto')), 'renter/true');
select test.eq('P11 on an Owner Booking it is billed to the Owner',
  (select matched_to from app.match_toll_ticket(test.id('vehicle:A'), timestamp '2026-12-21 14:00' at time zone 'America/Toronto')), 'owner_booking');
select test.eq('P11 a Turo-Only car: forwarded to the Owner',
  (select matched_to from app.match_toll_ticket(test.id('vehicle:T'), now())), 'turo_only');
select test.eq('P11 nobody had the car: no match, escalate',
  (select matched_to from app.match_toll_ticket(test.id('vehicle:A'), timestamp '2026-11-11 18:00' at time zone 'America/Toronto')), 'unmatched');
select test.eq('R1 administration fee: $15 per toll invoice, $40 per ticket, none for an Owner',
  app.toll_ticket_admin_fee('toll_invoice', 'renter', test.id('booking:A1')) || '/' || app.toll_ticket_admin_fee('ticket', 'renter', test.id('booking:A1'))
  || '/' || app.toll_ticket_admin_fee('ticket', 'owner_booking', test.id('booking:OB1')), '1500/4000/0');
select test.throws('R9 an Owner is never charged an administration fee on a toll',
  format($$insert into toll_tickets (kind, plate, occurred_at, amount_cents, matched_to, booking_id, admin_fee_cents)
           values ('toll_invoice', 'X', now(), 2200, 'owner_booking', %L, 1500)$$, test.id('booking:OB1')), 'check');

-- ------------------------------------------------------------------ investors (Investment Agreement and Schedule B)
insert into investors (id, legal_name, investor_type, tax_information_complete) values (test.id('inv:ivy'), 'Ivy Investor', 'individual', true);
insert into investment_agreements (id, investor_id, agreement_number, status) values (test.id('ia:ivy'), test.id('inv:ivy'), 'IA-1', 'draft');
select test.throws('I no funds before the agreement and Schedules C and D are signed',
  format($$insert into investments (investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
           values (%L, %L, true, 2000000, 3000, date '2027-01-01', date '2027-07-01')$$, test.id('inv:ivy'), test.id('ia:ivy')), 'Schedules C and D');
insert into documents (id, kind, storage_bucket, storage_path, investor_id) values
  (test.id('doc:ivy:c'), 'investment_schedule_c', 'admin', 'investors/ivy/c.pdf', test.id('inv:ivy')),
  (test.id('doc:ivy:d'), 'investment_schedule_d', 'admin', 'investors/ivy/d.pdf', test.id('inv:ivy'));
update investment_agreements set status = 'signed', schedule_c_document_id = test.id('doc:ivy:c'), schedule_d_document_id = test.id('doc:ivy:d'),
       exemption_category = 'accredited_investor', legal_advice_choice = 'declined' where id = test.id('ia:ivy');
select test.throws('I the minimum initial investment is $20,000',
  format($$insert into investments (investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
           values (%L, %L, true, 1999900, 3000, date '2027-01-01', date '2027-07-01')$$, test.id('inv:ivy'), test.id('ia:ivy')), 'minimum initial investment');
select test.throws('I the lockup is six months from the Investment Date',
  format($$insert into investments (investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
           values (%L, %L, true, 2000000, 3000, date '2027-01-01', date '2027-04-01')$$, test.id('inv:ivy'), test.id('ia:ivy')), 'check');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
values (test.id('invm:ivy'), test.id('inv:ivy'), test.id('ia:ivy'), true, 2000000, 3000, date '2027-01-01', date '2027-07-01');
insert into investment_elections (agreement_id, mode, received_on, is_initial) values (test.id('ia:ivy'), 'reinvest', date '2027-01-01', true);
select test.eq('I no return is earned for the Lockup Period', app.accrue_investment_return(test.id('invm:ivy'), date '2027-06-01') is null, true);
select app.accrue_investment_return(test.id('invm:ivy'), (date '2027-07-01' + make_interval(months => m))::date) from generate_series(0, 11) m;
select test.eq('I-B2 reinvested Returns, months 1 to 12, match Schedule B to the cent',
  (select string_agg(return_cents::text, ' ' order by return_month) from investment_returns where investment_id = test.id('invm:ivy')),
  '50000 51250 52531 53845 55191 56570 57985 59434 60920 62443 64004 65604');
select test.eq('I-B2 Invested Amount after 12 months: $26,897.77', (select invested_amount_cents from investments where id = test.id('invm:ivy')), test.money('26,897.77'));
select test.eq('I a reinvested Return pays no cash', (select count(*) from payouts where investor_id = test.id('inv:ivy')), 0::bigint);
insert into investment_elections (agreement_id, mode, received_on) values (test.id('ia:ivy'), 'pay', date '2028-06-10');
select app.accrue_investment_return(test.id('invm:ivy'), date '2028-07-01');
select test.eq('I-B2 switching to payment: $672.44, due on the 15th of the next month, waiting for an Admin',
  (select amount_cents || '/' || scheduled_for || '/' || status from payouts where investor_id = test.id('inv:ivy')), '67244/2028-08-15/pending_approval');
select test.throws('I Return Months are accrued in order',
  format('select app.accrue_investment_return(%L, date ''2028-10-01'')', test.id('invm:ivy')), 'in order');
select test.throws('I the Company redeems on at least six months'' written notice',
  format($$insert into investment_redemptions (investment_id, kind, notice_date, redemption_date, amount_cents)
           values (%L, 'company_redemption', date '2028-08-01', date '2028-12-01', 1000000)$$, test.id('invm:ivy')), 'check');
select test.lives('I six months'' notice is accepted',
  format($$insert into investment_redemptions (investment_id, kind, notice_date, redemption_date, amount_cents)
           values (%L, 'company_redemption', date '2028-08-01', date '2029-02-01', 1000000)$$, test.id('invm:ivy')));
insert into investors (id, legal_name, investor_type) values (test.id('inv:ian'), 'Ian Investor', 'individual');
insert into documents (id, kind, storage_bucket, storage_path, investor_id) values
  (test.id('doc:ian:c'), 'investment_schedule_c', 'admin', 'investors/ian/c.pdf', test.id('inv:ian')),
  (test.id('doc:ian:d'), 'investment_schedule_d', 'admin', 'investors/ian/d.pdf', test.id('inv:ian'));
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
values (test.id('ia:ian'), test.id('inv:ian'), 'IA-2', 'signed', test.id('doc:ian:c'), test.id('doc:ian:d'), 'accredited_investor', 'obtained');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
values (test.id('invm:ian'), test.id('inv:ian'), test.id('ia:ian'), true, 2000000, 3000, date '2027-01-01', date '2027-07-01');
select test.throws('I a purchase can be requested only after the Lockup Period',
  format($$insert into investment_redemptions (investment_id, kind, notice_date, redemption_date, amount_cents, status)
           values (%L, 'purchase_on_request', date '2027-03-01', date '2027-04-01', 500000, 'requested')$$, test.id('invm:ian')), 'after the Lockup Period');
select app.accrue_investment_return(test.id('invm:ian'), date '2027-07-01');
select test.eq('I-B1 Return paid monthly: $500 for July 2027, first paid on August 15, 2027 (held: tax information outstanding)',
  (select return_cents || '/' || payment_date || '/' || status from investment_returns where investment_id = test.id('invm:ian')), '50000/2027-08-15/held');

-- ------------------------------------------------------------------ franchise: fleet report and the 10-vehicle minimum
select test.eq('F Turo-Only cars are never counted in the fleet',
  (select count(*) from vehicles where management_mode = 'turo_only' and fleet_policy_added_on is not null), 0::bigint);
select app.build_fleet_report(date '2027-04-01');
select test.eq('F the report for the 1st counts every vehicle on the Fleet Policy and flags the minimum',
  (select (vehicle_count = app.fleet_count(date '2027-04-01')) || '/' || min_required || '/' || meets_minimum
          || '/' || (vehicle_count = (select count(*) from fleet_report_vehicles v where v.fleet_report_id = r.id and v.change <> 'removed'))
     from fleet_reports r where report_month = date '2027-04-01'), 'true/10/' || (app.fleet_count(date '2027-04-01') >= 10) || '/true');
update fleet_reports set status = 'sent', sent_at = now() where report_month = date '2027-04-01';
select test.throws('F a sent report is not rebuilt', $$select app.build_fleet_report(date '2027-04-01')$$, 'already been sent');
delete from tasks where task_type = 'fleet_minimum';
update vehicles set fleet_policy_removed_on = app.today() where id = test.id('vehicle:R1');
select test.eq('F a removal that leaves the fleet at 11 or fewer raises an urgent admin task (the removal itself is never blocked)',
  (select count(*) > 0 from tasks where task_type = 'fleet_minimum' and priority = 'urgent' and queue = 'admin'), true);

-- ------------------------------------------------------------------ audit log
select test.eq('A every table that holds money, pricing or status is audited',
  (select string_agg(c.relname, ',') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and c.relname not in ('audit_log', 'status_history', 'data_access_log', 'job_runs', 'tracker_status',
                            'condition_report_photos', 'vehicle_photos', 'photo_jobs', 'messages', 'incident_events', 'app_events')
      and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), null::text);
select test.eq('A a new rate card is logged',
  (select count(*) > 0 from audit_log where entity_table = 'rate_cards' and action = 'INSERT' and after ->> 'daily_rate_cents' = '10000'), true);
update fee_defaults set amount_cents = 8000 where fee_type_code = 'cleaning';
select test.eq('A changing a default fee writes who, what, before and after',
  (select (before ->> 'amount_cents') || ' -> ' || (after ->> 'amount_cents') from audit_log
    where entity_table = 'fee_defaults' and action = 'UPDATE' order by id desc limit 1), '7500 -> 8000');
update fee_defaults set amount_cents = 7500 where fee_type_code = 'cleaning';
select test.eq('A a status change is logged', (select count(*) > 0 from audit_log where entity_table = 'owner_invoices' and action = 'UPDATE' and before ->> 'status' <> after ->> 'status'), true);
insert into owner_payout_accounts (owner_id, method, account_holder, institution_no, transit_no, account_no, account_last4)
values (test.id('owner:fiona'), 'bank_transfer', 'Fiona', '001', '00011', '1234567', '4567');
insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (test.id('card:lia'), 'cus_test', 'pm_test');
select test.eq('A bank and card secrets are logged without their values',
  (select count(*) || '/' || bool_and(before is null and after is null) from audit_log where entity_table in ('payment_method_secrets', 'owner_payout_accounts')), '2/true');
select test.throws('A the audit log cannot be edited', 'update audit_log set action = ''x''', 'append-only');
select test.throws('A the audit log cannot be deleted', 'delete from audit_log', 'append-only');

-- ------------------------------------------------------------------ catalogue: every charge in the renter spec has a home
select test.eq('CAT every catalogue charge is tagged owner revenue / company only / pass-through (the deposit is not revenue)',
  (select string_agg(code, ',') from fee_types where revenue_class is null), 'deposit');
select test.eq('CAT owner revenue is exactly: rental charge, its discounts (non-refundable, promo code, staff), extra days, mileage overage',
  (select string_agg(code, ',' order by code) from fee_types where revenue_class = 'owner_revenue'),
  'late_return_extra_days,mileage_overage,non_refundable_discount,promo_discount,rental_charge,staff_discount');
select test.eq('CAT pass-through amounts',
  (select string_agg(code, ',' order by code) from fee_types where revenue_class = 'pass_through'),
  'collection_cost,damage_at_cost,lost_key_cost,recovery_cost,roadside_callout,ticket_amount,toll_amount');
select test.eq('CAT no HST on: deposit, toll and ticket amounts, deductible, loss of use, interest (damage as invoiced)',
  (select string_agg(code, ',' order by code) from fee_types where not hst_applies and not hst_as_invoiced and family <> 'expense'),
  'deductible,deposit,interest,loss_of_use,ticket_amount,toll_amount');
select test.eq('CAT default deposits: $500 economy and standard, $1,000 premium and SUV, $2,500 luxury and exotic',
  (select string_agg(vehicle_class || '=' || amount_cents, ' ' order by amount_cents, vehicle_class::text) from fee_defaults where fee_type_code = 'deposit'),
  'economy=50000 standard=50000 premium=100000 suv=100000 exotic=250000 luxury=250000');
select test.eq('CAT a fee resolves vehicle override, then class default, then general default',
  (select amount_cents || '/' || source from public.effective_fee('deposit', test.id('vehicle:A'))), '100000/default');
insert into vehicle_fee_overrides (vehicle_id, fee_type_code, amount_cents, reason) values (test.id('vehicle:A'), 'deposit', 150000, 'test');
select test.eq('CAT a per-vehicle override wins', (select amount_cents || '/' || source from public.effective_fee('deposit', test.id('vehicle:A'))), '150000/vehicle');
select test.throws('CAT a per-booking override needs an Admin',
  format($$insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, source, override_by, override_reason)
           values (%L, 'cleaning', 0, 'booking', %L, 'goodwill')$$, test.id('booking:A1'), test.id('field_frank')), 'Only an Admin');
select test.throws('CAT fixed charges (the deductible) cannot be overridden per booking',
  format($$insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, source, override_by, override_reason)
           values (%L, 'deductible', 100000, 'booking', %L, 'goodwill')$$, test.id('booking:A1'), test.id('admin_abbas')), 'fixed');
select test.lives('CAT an Admin overrides a B-marked charge on one booking, with a reason',
  format($$insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, source, override_by, override_reason)
           values (%L, 'cleaning', 0, 'booking', %L, 'goodwill')$$, test.id('booking:A1'), test.id('admin_abbas')));
