-- 02: the owner billing specification's worked month (section 10, November 2026) run through the
-- real tables: bookings and their line items -> split -> fee invoices on the 15th -> failed debit,
-- Late Fee, failed retry on the 18th -> statement and payout on December 10.
-- Then the second worked month from the VA hiring package (answer key: payout $1,364.05).
select test.suite('02 owner month');

select test.mk_user('admin_abbas', 'admin');
select test.mk_user('admin_mahad', 'admin');
select test.mk_user('field_frank', 'field', null, 'driver_detailer', 'FRANK20');

-- ------------------------------------------------------------------ owner spec section 10
-- One Owner, one agreement, two Managed vehicles at $450, 35% and $25, not HST-registered.
select test.mk_owner('olivia');                       -- the Owner of vehicles A and B
select test.mk_owner('otto', 'OTTO20');               -- another Owner, who referred A2's renter
select test.mk_vehicle('A', 'olivia');
select test.mk_vehicle('B', 'olivia');
select test.mk_renter('ra1', false); select test.mk_renter('ra2', false);
select test.mk_renter('rb1', false); select test.mk_renter('rb2', false);

select test.eq('O10 one agreement covers both vehicles',
  (select count(distinct owner_agreement_id) || ' agreement, ' || count(*) || ' schedules' from vehicle_schedules
    where vehicle_id in (test.id('vehicle:A'), test.id('vehicle:B'))), '1 agreement, 2 schedules');

-- October's run (so that November's run has nothing to catch up), all paid
select app.generate_owner_invoices(date '2026-10-15');
update owner_invoices set status = 'issued';
update owner_invoices set status = 'paid';

-- The four bookings
select test.mk_booking('A1', 'A', 'ra1', '2026-11-02 10:00', '2026-11-11 10:00', 'closed', 90000);
select test.mk_line('A1', 'mileage_overage', 6000);
select test.mk_line('A1', 'delivery', 15000);
select test.mk_booking('A2', 'A', 'ra2', '2026-11-12 10:00', '2026-11-22 10:00', 'closed', 100000, 'standard', 'OTTO20');
select test.mk_line('A2', 'cleaning', 5000);
select test.mk_booking('B1', 'B', 'rb1', '2026-11-03 10:00', '2026-11-10 10:00', 'closed', 70000);
-- B2 came back 3 hours late: one extra day at $100 is Owner Revenue; the $75 late return fee is company only
select test.mk_booking('B2', 'B', 'rb2', '2026-11-12 10:00', '2026-11-24 10:00', 'closed', 120000, 'standard', null, null, '2026-11-24 13:00');
select test.mk_line('B2', 'late_return_extra_days', (select extra_days_cents from public.calc_late_return(180, 10000)));
select test.mk_line('B2', 'late_return_fee', (select late_fee_cents from public.calc_late_return(180, 10000)));
select test.mk_line('B2', 'mileage_overage', 10000);

select app.compute_booking_split(test.id('booking:' || n)) from unnest(array['A1', 'A2', 'B1', 'B2']) n;

select test.eq('O10 A1 Owner Revenue $960 ($900 + $60 overage)', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:A1')), test.money('960.00'));
select test.eq('O10 A2 referred by another Owner: the code resolves to that Owner',
  (select referrer_type || ':' || (referrer_owner_id = test.id('owner:otto')) from bookings where id = test.id('booking:A2')), 'owner:true');
select test.eq('O10 A2 Referral Kickback $200', (select kickback_cents from booking_splits where booking_id = test.id('booking:A2')), test.money('200.00'));
select test.eq('O10 A2 Owner Revenue $800', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:A2')), test.money('800.00'));
select test.eq('O10 B1 Owner Revenue $700', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:B1')), test.money('700.00'));
select test.eq('O10 B2 Owner Revenue $1,400 ($1,200 + $100 extra day + $100 overage)', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:B2')), test.money('1,400.00'));
select test.eq('O10 company-only fees never enter Owner Revenue: $150 + $50 + $75 = $275',
  (select sum(company_only_cents) from booking_splits where vehicle_id in (test.id('vehicle:A'), test.id('vehicle:B'))), test.money('275.00'));
select test.eq('O10 every line is tagged: owner revenue / company only',
  (select string_agg(distinct revenue_class::text, ',' order by revenue_class::text) from booking_line_items
    where booking_id in (select test.id('booking:' || n) from unnest(array['A1', 'A2', 'B1', 'B2']) n)), 'company_only,owner_revenue');
select test.eq('O10 HST is stored per line (B2 late return fee $75: HST $9.75)',
  (select hst_cents from booking_line_items where booking_id = test.id('booking:B2') and charge_type = 'late_return_fee'), test.money('9.75'));

-- Fees billed November 15, per vehicle
select test.eq('O10 the November run issues one invoice per vehicle', app.generate_owner_invoices(date '2026-11-15'), 2);
select test.eq('O10 running it again creates nothing', app.generate_owner_invoices(date '2026-11-15'), 0);
select test.eq('O10 each invoice: $450 + $25 + HST $61.75 = $536.75',
  (select string_agg(fees_cents || '+' || hst_cents || '=' || total_cents, ' | ') from owner_invoices where period_month = date '2026-11-01'),
  '47500+6175=53675 | 47500+6175=53675');
update owner_invoices set status = 'issued' where period_month = date '2026-11-01';
update owner_invoices set status = 'processing' where period_month = date '2026-11-01';
-- Vehicle A's debit clears. Vehicle B's fails.
update owner_invoices set status = 'paid' where period_month = date '2026-11-01' and vehicle_id = test.id('vehicle:A');
update owner_invoices set status = 'failed', first_failed_on = date '2026-11-15' where period_month = date '2026-11-01' and vehicle_id = test.id('vehicle:B');
select test.eq('O10 failed debit: a $50 Late Fee is added to that vehicle, with no HST',
  (select l.amount_cents || '/' || l.hst_cents from owner_invoice_lines l join owner_invoices i on i.id = l.owner_invoice_id
    where i.vehicle_id = test.id('vehicle:B') and i.period_month = date '2026-11-01' and l.kind = 'late_fee'), '5000/0');
select test.eq('O10 the retry is $586.75', (select balance_cents from owner_invoices where vehicle_id = test.id('vehicle:B') and period_month = date '2026-11-01'), test.money('586.75'));
select test.eq('O10 Vehicle A is untouched by B''s failure', (select status || '/' || late_fee_cents from owner_invoices where vehicle_id = test.id('vehicle:A') and period_month = date '2026-11-01'), 'paid/0');
-- the retry of $586.75 fails on November 18
update owner_invoices set status = 'retry_processing' where period_month = date '2026-11-01' and vehicle_id = test.id('vehicle:B');
update owner_invoices set status = 'in_arrears', retry_failed_on = date '2026-11-18' where period_month = date '2026-11-01' and vehicle_id = test.id('vehicle:B');
select test.eq('O6 failed retry: only one Late Fee, and the vehicle is in arrears',
  (select i.late_fee_cents || '/' || v.in_arrears from owner_invoices i join vehicles v on v.id = i.vehicle_id
    where i.vehicle_id = test.id('vehicle:B') and i.period_month = date '2026-11-01'), '5000/true');
select test.eq('O6 30 days after the failed retry the vehicle may be removed',
  (select removal_allowed_on from owner_invoices where vehicle_id = test.id('vehicle:B') and period_month = date '2026-11-01'), date '2026-12-18');
select test.eq('O6 an admin is told (task in the admin queue)',
  (select count(*) from tasks where queue = 'admin' and task_type = 'owner_retry_failed' and vehicle_id = test.id('vehicle:B')), 1::bigint);

-- The statement issued on the 10th
select app.build_owner_statement(test.id('owner:olivia'), date '2026-11-01');
create temp view st_olivia as select * from owner_statements where owner_id = test.id('owner:olivia') and statement_month = date '2026-11-01';
create temp view sv as select v.fleet_number, sv.* from owner_statement_vehicles sv join vehicles v on v.id = sv.vehicle_id
  where sv.owner_statement_id = (select id from st_olivia);

select test.eq('O10 Vehicle A Owner Revenue $1,760.00', (select owner_revenue_cents from sv where fleet_number = 'F-A'), test.money('1,760.00'));
select test.eq('O10 Vehicle A Revenue Share 35% $616.00', (select revenue_share_cents from sv where fleet_number = 'F-A'), test.money('616.00'));
select test.eq('O10 Vehicle A net earnings $1,144.00', (select net_earnings_cents from sv where fleet_number = 'F-A'), test.money('1,144.00'));
select test.eq('O10 Vehicle A payable $1,144.00', (select payable_cents from sv where fleet_number = 'F-A'), test.money('1,144.00'));
select test.eq('O10 Vehicle B Owner Revenue $2,100.00', (select owner_revenue_cents from sv where fleet_number = 'F-B'), test.money('2,100.00'));
select test.eq('O10 Vehicle B Revenue Share 35% $735.00', (select revenue_share_cents from sv where fleet_number = 'F-B'), test.money('735.00'));
select test.eq('O10 Vehicle B net earnings $1,365.00', (select net_earnings_cents from sv where fleet_number = 'F-B'), test.money('1,365.00'));
select test.eq('O10 Vehicle B unpaid Fees deducted $536.75', (select fees_deducted_cents from sv where fleet_number = 'F-B'), test.money('536.75'));
select test.eq('O10 Vehicle B Late Fee deducted $50.00', (select late_fees_deducted_cents from sv where fleet_number = 'F-B'), test.money('50.00'));
select test.eq('O10 Vehicle B payable $778.25', (select payable_cents from sv where fleet_number = 'F-B'), test.money('778.25'));
select test.eq('O10 Referral Kickbacks earned $0.00', (select kickbacks_earned_cents from st_olivia), 0::bigint);
select test.eq('O10 no HST on the payout: the Owner has no HST number on file', (select hst_on_payout_cents from st_olivia), 0::bigint);
select test.eq('O10 PAYOUT ON DECEMBER 10: $1,922.25', (select payout_cents from st_olivia), test.money('1,922.25'));
select test.eq('O10 payout date is December 10', (select payout_date from st_olivia), date '2026-12-10');
select test.eq('O10 CarmaCars keeps $1,351 Revenue Share', (select revenue_share_cents from st_olivia), test.money('1,351.00'));
select test.eq('O10 the A2 rental line shows the kickback column: $200',
  (select kickback_cents from owner_statement_lines where owner_statement_id = (select id from st_olivia) and booking_id = test.id('booking:A2')), test.money('200.00'));

-- ... and pays the other Owner's $200 kickback
select app.build_owner_statement(test.id('owner:otto'), date '2026-11-01');
select test.eq('O10 the other Owner is paid the $200 kickback',
  (select kickbacks_earned_cents || '/' || payout_cents from owner_statements where owner_id = test.id('owner:otto')), '20000/20000');

-- Admin approves the run; the deduction is applied; the payout exists; then it is paid
select test.throws('O5 a VA cannot approve a payout run',
  format('select app.approve_owner_statement(%L, %L)', (select id from st_olivia), test.id('field_frank')), 'Only an Admin');
select app.approve_owner_statement((select id from st_olivia), test.id('admin_abbas'));
select test.eq('O10 approved payout row: $1,922.25 by bank transfer, scheduled December 10',
  (select amount_cents || '/' || method || '/' || scheduled_for || '/' || status from payouts where owner_statement_id = (select id from st_olivia)),
  '192225/bank_transfer/2026-12-10/approved');
select test.eq('O6 the unpaid invoice is now settled by deduction and the vehicle is out of arrears',
  (select i.status || '/' || i.balance_cents || '/' || v.in_arrears from owner_invoices i join vehicles v on v.id = i.vehicle_id
    where i.vehicle_id = test.id('vehicle:B') and i.period_month = date '2026-11-01'), 'deducted/0/false');
select test.throws('O5 an approved statement cannot be rebuilt',
  format('select app.build_owner_statement(%L, date ''2026-11-01'')', test.id('owner:olivia')), 'already approved');
update payouts set status = 'sent' where owner_statement_id = (select id from st_olivia);
update payouts set status = 'paid', paid_at = timestamptz '2026-12-10 15:00+00', reference = 'EFT-1' where owner_statement_id = (select id from st_olivia);
select test.eq('O5 paying the payout marks the statement paid', (select status from st_olivia), 'paid');
select test.eq('O2 nothing is carried forward', (select balance_carried_forward_cents from owners where id = test.id('owner:olivia')), 0::bigint);
select app.build_owner_statement(test.id('owner:olivia'), date '2026-12-01');
select test.eq('O2 a second statement for December pays nothing twice',
  (select payout_cents from owner_statements where owner_id = test.id('owner:olivia') and statement_month = date '2026-12-01'), 0::bigint);

-- ------------------------------------------------------------------ VA hiring package: November statement test
-- One Owner, not registered for HST, two Managed vehicles on $450 / $25 / 35%.
select test.mk_owner('paula', 'PAULA20');
select test.mk_owner('quinn');
select test.mk_vehicle('V1', 'paula'); select test.mk_vehicle('V2', 'paula'); select test.mk_vehicle('E', 'quinn');
select test.mk_renter(n, false) from unnest(array['c1', 'c2', 'c3', 'd1', 'd2', 'd3', 'e9']) n;
update owner_invoices set status = 'issued' where status = 'draft';   -- nothing pending
select app.generate_owner_invoices(date '2026-10-15');
update owner_invoices set status = 'issued' where status = 'draft';
update owner_invoices set status = 'paid' where status = 'issued';

-- C1: ended Nov 6. Rental Charge $840. Delivery $100. Drove 1,600 km; allowance 1,400 km; overage $0.35 a km
select test.mk_booking('C1', 'V1', 'c1', '2026-10-30 10:00', '2026-11-06 10:00', 'closed', 84000);
select test.mk_line('C1', 'delivery', 10000);
select test.mk_line('C1', 'mileage_overage', public.calc_mileage_overage(20000, 21600, 1400, 35));
-- C2: ended Nov 14. Rental Charge $540 after the non-refundable discount. First rental, referred by field staff. Young driver $100
select test.mk_booking('C2', 'V1', 'c2', '2026-11-09 10:00', '2026-11-14 10:00', 'closed', 60000, 'non_refundable', 'FRANK20');
select test.mk_line('C2', 'young_driver_21_25', 10000);
-- C3: ended Nov 22. Rental Charge $400. First rental, referred by this Owner (own vehicle). Cleaning $75
select test.mk_booking('C3', 'V1', 'c3', '2026-11-18 10:00', '2026-11-22 10:00', 'closed', 40000, 'standard', 'PAULA20');
select test.mk_line('C3', 'cleaning', 7500);
-- D1: ended Nov 9, three hours late. Rental Charge $1,100. Extra day $90. Late fee $75. Fuel $60. Toll $22 plus $15 fee
select test.mk_booking('D1', 'V2', 'd1', '2026-10-30 10:00', '2026-11-09 10:00', 'closed', 110000, 'standard', null, null, '2026-11-09 13:00');
select test.mk_line('D1', 'late_return_extra_days', 9000);
select test.mk_line('D1', 'late_return_fee', 7500);
select test.mk_line('D1', 'fuel', 6000);
select test.mk_line('D1', 'toll_amount', 2200);
select test.mk_line('D1', 'toll_admin_fee', 1500);
-- D2: cancelled Nov 20. Renter paid $400 Rental Charge plus $52 HST; 75% refunded
select test.mk_booking('D2', 'V2', 'd2', '2026-11-25 10:00', '2026-11-29 10:00', 'cancelled', 40000, 'standard', null, '2026-11-10 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:D2'), timestamp '2026-11-20 15:00' at time zone 'America/Toronto', 'renter', 'renter_request', 'email', 45200);
select test.eq('R5 D2 cancellation is priced by the table: 75% of $452 = $339 refunded, $113 kept',
  (select tier || '/' || refund_cents || '/' || retained_cents from booking_cancellations where booking_id = test.id('booking:D2')),
  'notice_48h_plus/33900/11300');
insert into refunds (id, booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, approved_by, paid_at)
values (test.id('refund:D2'), test.id('booking:D2'), test.id('payment:D2'), 'cancellation', 7500, 33900, 'paid',
        test.id('admin_abbas'), test.id('admin_abbas'), timestamptz '2026-11-21 15:00+00');
select app.allocate_refund(test.id('refund:D2'));
select test.eq('R5 the retained amount is split across the lines in proportion: rental $300 + HST $39 refunded',
  (select amount_cents || '+' || hst_cents from refund_allocations where refund_id = test.id('refund:D2')), '30000+3900');
-- D3: Nov 26 to Dec 3. Rental Charge $700, paid
select test.mk_booking('D3', 'V2', 'd3', '2026-11-30 10:00', '2026-12-03 10:00', 'closed', 70000);
-- E9: another Owner's vehicle. Ended Nov 18. Rental Charge $500. First rental, referred by this Owner
select test.mk_booking('E9', 'E', 'e9', '2026-11-13 10:00', '2026-11-18 10:00', 'closed', 50000, 'standard', 'PAULA20');

-- Fees billed November 15. Vehicle 1 cleared. Vehicle 2 failed, and the November 18 retry failed.
select app.generate_owner_invoices(date '2026-11-15');
update owner_invoices set status = 'issued' where status = 'draft';
update owner_invoices set status = 'paid' where status = 'issued' and vehicle_id in (test.id('vehicle:V1'), test.id('vehicle:E'));
update owner_invoices set status = 'failed' where status = 'issued' and vehicle_id = test.id('vehicle:V2');
update owner_invoices set status = 'retry_processing' where status = 'failed' and vehicle_id = test.id('vehicle:V2');
update owner_invoices set status = 'in_arrears', retry_failed_on = date '2026-11-18' where status = 'retry_processing' and vehicle_id = test.id('vehicle:V2');
-- CarmaCars paid Vehicle 1's $120 plate renewal
insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on)
values (test.id('owner:paula'), test.id('vehicle:V1'), 'plate_renewal', 'Plate renewal', 12000, date '2026-11-12');

select app.build_owner_statement(test.id('owner:paula'), date '2026-11-01');
create temp view st_paula as select * from owner_statements where owner_id = test.id('owner:paula') and statement_month = date '2026-11-01';
create temp view pv as select v.fleet_number, sv.* from owner_statement_vehicles sv join vehicles v on v.id = sv.vehicle_id
  where sv.owner_statement_id = (select id from st_paula);

select test.eq('VA C1 Owner Revenue $910 ($840 + 200 km x $0.35)', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:C1')), test.money('910.00'));
select test.eq('VA C2 kickback $108 comes off first (20% of $540 after the discount), referred by field staff',
  (select kickback_cents || '/' || referrer_type from booking_splits where booking_id = test.id('booking:C2')), '10800/field_staff');
select test.eq('VA C2 Owner Revenue $432', (select owner_revenue_cents from booking_splits where booking_id = test.id('booking:C2')), test.money('432.00'));
select test.eq('VA C3 carries no kickback: the referring Owner''s own vehicle',
  (select kickback_cents || '/' || kickback_ineligible_reason from booking_splits where booking_id = test.id('booking:C3')), '0/referring Owner''s own vehicle');
select test.eq('VA D2 keeps $100 of Rental Charge, counted in November, with no kickback',
  (select owner_revenue_cents || '/' || payout_month from booking_splits where booking_id = test.id('booking:D2')), '10000/2026-11-01');
select test.eq('VA D3 belongs to December', (select payout_month from booking_splits where booking_id = test.id('booking:D3')), date '2026-12-01');
select test.eq('VA Vehicle 1 Owner Revenue $910 + $432 + $400 = $1,742.00', (select owner_revenue_cents from pv where fleet_number = 'F-V1'), test.money('1,742.00'));
select test.eq('VA Vehicle 1 Revenue Share 35% $609.70', (select revenue_share_cents from pv where fleet_number = 'F-V1'), test.money('609.70'));
select test.eq('VA Vehicle 1 net earnings $1,132.30', (select net_earnings_cents from pv where fleet_number = 'F-V1'), test.money('1,132.30'));
select test.eq('VA Vehicle 1 Owner cost, plate renewal $120.00', (select owner_costs_deducted_cents from pv where fleet_number = 'F-V1'), test.money('120.00'));
select test.eq('VA Vehicle 1 payable $1,012.30', (select payable_cents from pv where fleet_number = 'F-V1'), test.money('1,012.30'));
select test.eq('VA Vehicle 2 Owner Revenue $1,190 + $100 = $1,290.00', (select owner_revenue_cents from pv where fleet_number = 'F-V2'), test.money('1,290.00'));
select test.eq('VA Vehicle 2 Revenue Share 35% $451.50', (select revenue_share_cents from pv where fleet_number = 'F-V2'), test.money('451.50'));
select test.eq('VA Vehicle 2 net earnings $838.50', (select net_earnings_cents from pv where fleet_number = 'F-V2'), test.money('838.50'));
select test.eq('VA Vehicle 2 unpaid Fees ($475 + HST $61.75) $536.75', (select fees_deducted_cents from pv where fleet_number = 'F-V2'), test.money('536.75'));
select test.eq('VA Vehicle 2 Late Fee $50.00', (select late_fees_deducted_cents from pv where fleet_number = 'F-V2'), test.money('50.00'));
select test.eq('VA Vehicle 2 payable $251.75', (select payable_cents from pv where fleet_number = 'F-V2'), test.money('251.75'));
select test.eq('VA Referral Kickback earned on E9: $100.00', (select kickbacks_earned_cents from st_paula), test.money('100.00'));
select test.eq('VA PAYOUT ON DECEMBER 10: $1,364.05', (select payout_cents from st_paula), test.money('1,364.05'));
select test.eq('VA the $425 of company-only fees never enters',
  (select sum(company_only_cents) from booking_splits where owner_id = test.id('owner:paula') and payout_month = date '2026-11-01'), test.money('425.00'));
select test.eq('VA the toll amount is a pass-through with no HST; only the $15 fee is taxed',
  (select string_agg(charge_type || ':' || revenue_class || ':' || hst_cents, ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:D1') and charge_type like 'toll%'), 'toll_admin_fee:company_only:195 toll_amount:pass_through:0');
select test.eq('VA field staff kickback goes to payroll, not to an Owner statement',
  (select referrer_type || '/' || status || '/' || amount_cents from referral_kickbacks where booking_id = test.id('booking:C2')), 'field_staff/earned/10800');

-- ------------------------------------------------------------------ kickback rules (owner spec section 8)
select test.mk_renter('k1', false);
select test.mk_booking('K1', 'E', 'k1', '2026-12-01 10:00', '2026-12-04 10:00', 'closed', 30000, 'standard', 'OTTO20');
select test.mk_booking('K2', 'E', 'k1', '2026-12-10 10:00', '2026-12-13 10:00', 'closed', 30000, 'standard', 'OTTO20');
select app.compute_booking_split(test.id('booking:K1')), app.compute_booking_split(test.id('booking:K2'));
select test.eq('O8 the first rental earns the kickback', (select kickback_cents from booking_splits where booking_id = test.id('booking:K1')), test.money('60.00'));
select test.eq('O8 the same renter''s second rental earns none',
  (select kickback_cents || '/' || kickback_ineligible_reason from booking_splits where booking_id = test.id('booking:K2')), '0/not the renter''s first rental');
select test.mk_renter('k3', false);
select test.mk_booking('K3', 'E', 'k3', '2027-01-04 10:00', '2027-01-07 10:00', 'closed', 30000);
select test.mk_booking('K4', 'E', 'k3', '2027-01-07 10:00', '2027-01-10 10:00', 'closed', 30000, 'standard', 'OTTO20', '2027-01-06 10:00', null, 'K3');
select app.compute_booking_split(test.id('booking:K4'));
select test.eq('O8 a renewal earns none',
  (select kickback_cents || '/' || kickback_ineligible_reason from booking_splits where booking_id = test.id('booking:K4')), '0/renewal');
select test.mk_user('va_vera', 'va', 'cs');
select test.throws('O8 a virtual assistant cannot hold a referral code',
  format('update staff_profiles set referral_code = ''VERA20'' where user_id = %L', test.id('va_vera')), 'check');
select test.throws('O8 a virtual assistant cannot be put on a booking as referrer',
  format('update bookings set referrer_type = ''field_staff'', referrer_staff_id = %L where id = %L', test.id('va_vera'), test.id('booking:K3')), null);
-- Self-Managed: 0% share, no kickback, and the delivery fee stays with CarmaCars
select test.mk_owner('sam');
select test.mk_vehicle('S', 'sam', 'self_managed', 45000, 2500, 0);
select test.mk_renter('s1', false);
select test.mk_booking('S1', 'S', 's1', '2026-12-01 10:00', '2026-12-11 10:00', 'closed', 100000, 'standard', 'OTTO20');
select test.mk_line('S1', 'delivery', 15000);
select app.compute_booking_split(test.id('booking:S1'));
select test.eq('O3 Self-Managed $1,000 rental with $150 delivery: Owner is paid $1,000, CarmaCars keeps the $150, no kickback',
  (select owner_payout_cents || '/' || company_only_cents || '/' || kickback_cents || '/' || company_share_cents from booking_splits where booking_id = test.id('booking:S1')),
  '100000/15000/0/0');
-- Shareholder-owned: 90/10, kickback still deducted, no Fees
select test.mk_owner('holdco_a', null, null, true);
select test.mk_vehicle('H', 'holdco_a', 'managed', 0, 0, 1000, date '2026-09-01', true);
select test.mk_renter('h1', false);
select test.mk_booking('H1', 'H', 'h1', '2026-12-01 10:00', '2026-12-11 10:00', 'closed', 100000, 'standard', 'OTTO20');
select app.compute_booking_split(test.id('booking:H1'));
select test.eq('R8.2 shareholder-owned car through the tables: kickback $200, Owner Revenue $800, company $80, owner $720',
  (select kickback_cents || '/' || owner_revenue_cents || '/' || company_share_cents || '/' || owner_payout_cents from booking_splits where booking_id = test.id('booking:H1')),
  '20000/80000/8000/72000');
select test.eq('O3 the four cases are derived on the vehicle',
  (select string_agg(fleet_number || '=' || billing_case, ' ' order by fleet_number) from vehicles where fleet_number in ('F-A', 'F-S', 'F-H')),
  'F-A=managed F-H=shareholder F-S=self_managed');
select test.eq('O3 no fee invoice is ever issued for a shareholder-owned vehicle',
  (select count(*) from owner_invoices where vehicle_id = test.id('vehicle:H')), 0::bigint);
select test.throws('O3 no upfront charges for a shareholder-owned vehicle',
  format('select app.issue_upfront_invoice(%L)', test.id('vehicle:H')), 'No upfront charges');
-- Owner Booking: no rental charge, no split
select test.mk_renter('olivia_as_renter', false);
update renters set user_id = test.id('olivia'), is_owner_account = true where id = test.id('renter:olivia_as_renter');
select test.mk_booking('OB1', 'A', 'olivia_as_renter', '2026-12-20 10:00', '2026-12-22 10:00', 'closed', null, 'owner');
select app.compute_booking_split(test.id('booking:OB1'));
select test.eq('R9 an Owner Booking has no rental charge, no Owner Revenue and no split',
  (select rental_charge_cents || '/' || deposit_cents || '/' || (select count(*) from booking_splits where booking_id = b.id) from bookings b where id = test.id('booking:OB1')), '0/0/0');

-- ------------------------------------------------------------------ Turo-Only payout record (owner spec section 3)
select test.mk_owner('tina');
select test.mk_vehicle('T', 'tina', 'turo_only', 0, 0, 3500);
insert into turo_trips (vehicle_id, turo_trip_ref, starts_at, ends_at, gross_cents, turo_fees_cents, company_extras_cents,
                        revenue_share_bps, revenue_share_cents, statement_month, received_at)
values (test.id('vehicle:T'), 'TURO-1', timestamptz '2026-11-05 15:00+00', timestamptz '2026-11-08 15:00+00', 40000, 10000, 5000,
        3500, public.calc_bps(30000, 3500), date '2026-11-01', timestamptz '2026-11-12 15:00+00');
select app.build_owner_statement(test.id('owner:tina'), date '2026-11-01');
select test.eq('O3 Turo-Only: split on Turo''s payout after Turo''s fees ($400 - $100 = $300; 35% kept; $195 to the Owner); extras stay with CarmaCars',
  (select owner_revenue_cents || '/' || revenue_share_cents || '/' || payout_cents from owner_statements where owner_id = test.id('owner:tina')), '30000/10500/19500');
select test.eq('O3 Turo-Only: no Fees are billed', app.generate_owner_invoice(test.id('vehicle:T'), date '2026-11-01') is null, true);
select test.throws('O3 a Turo trip is never a platform booking',
  $$select test.mk_booking('T1', 'T', 's1', '2026-12-01 10:00', '2026-12-03 10:00', 'closed', 20000)$$, 'check');

-- ------------------------------------------------------------------ upfront charges, prepaid months and pro-rating (sections 1 and 9)
select test.mk_owner('nora');
select test.mk_vehicle('N', 'nora', 'managed', 45000, 2500, 3500, date '2026-11-16');
select app.issue_upfront_invoice(test.id('vehicle:N'));
select test.eq('O1 upfront: 2 x $450 Insurance Fee + HST = $1,017.00 (the $100 Install Fee is its own invoice since 0029)',
  (select fees_cents || '+' || hst_cents || '=' || total_cents from owner_invoices where vehicle_id = test.id('vehicle:N') and kind = 'upfront'), '90000+11700=101700');
update owner_invoices set status = 'issued' where vehicle_id = test.id('vehicle:N') and kind = 'upfront';
update owner_invoices set status = 'paid' where vehicle_id = test.id('vehicle:N') and kind = 'upfront';
select test.eq('O1 paying it funds the prepaid first and last month',
  (select string_agg(kind || ':' || remaining_cents, ' ' order by kind) from vehicle_prepaids where vehicle_id = test.id('vehicle:N')),
  'first_month_insurance:45000 last_month_insurance:45000');
select app.generate_owner_invoice(test.id('vehicle:N'), date '2026-11-01');
select test.eq('O1 enrollment month (15 of 30 days): the prepaid first month pays the $225 Insurance Fee; only the $12.50 Tracker Fee + HST is charged',
  (select days_billed || '/' || fees_cents || '/' || hst_cents || '/' || total_cents from owner_invoices where vehicle_id = test.id('vehicle:N') and period_month = date '2026-11-01'),
  '15/1250/163/1413');
select app.generate_owner_invoice(test.id('vehicle:N'), date '2026-12-01');
select test.eq('O1 the unused $225 is credited to the next charge: December = $450 - $225 + $25 = $250 + HST $32.50',
  (select fees_cents || '/' || hst_cents || '/' || total_cents from owner_invoices where vehicle_id = test.id('vehicle:N') and period_month = date '2026-12-01'),
  '25000/3250/28250');
select test.eq('O5 the prepaid last month is still held', (select remaining_cents from vehicle_prepaids where vehicle_id = test.id('vehicle:N') and kind = 'last_month_insurance'), test.money('450.00'));
update vehicles set exit_date = date '2027-01-10' where id = test.id('vehicle:N');
select app.generate_owner_invoice(test.id('vehicle:N'), date '2027-01-01');
select test.eq('O9 exit month (10 of 31 days): Insurance Fee from the prepaid last month; the Tracker Fee is billed pro-rated ($8.06 + HST)',
  (select days_billed || '/' || fees_cents || '/' || hst_cents from owner_invoices where vehicle_id = test.id('vehicle:N') and period_month = date '2027-01-01'), '10/806/105');
select test.eq('O9 the unused part of the prepaid last month ($450 - $145.16 = $304.84) is due back to the Owner',
  (select remaining_cents || '/' || refund_due_since from vehicle_prepaids where vehicle_id = test.id('vehicle:N') and kind = 'last_month_insurance'), '30484/2027-01-10');
select test.eq('O9 no Fees after the Exit Date', app.generate_owner_invoice(test.id('vehicle:N'), date '2027-02-01') is null, true);

-- ------------------------------------------------------------------ arrears moved to another vehicle; debt carried forward
select test.mk_owner('ravi');
select test.mk_vehicle('R1', 'ravi'); select test.mk_vehicle('R2', 'ravi');
select test.mk_renter('rr', false);
select test.mk_booking('RV1', 'R1', 'rr', '2027-03-01 10:00', '2027-03-11 10:00', 'closed', 100000);   -- only R1 earns
select app.generate_owner_invoice(test.id('vehicle:R2'), date '2027-03-01');
update owner_invoices set status = 'issued' where vehicle_id = test.id('vehicle:R2');
update owner_invoices set status = 'failed' where vehicle_id = test.id('vehicle:R2');
update owner_invoices set status = 'retry_processing' where vehicle_id = test.id('vehicle:R2');
update owner_invoices set status = 'in_arrears', retry_failed_on = date '2027-03-18' where vehicle_id = test.id('vehicle:R2');
select app.build_owner_statement(test.id('owner:ravi'), date '2027-03-01');
select test.eq('O6 balance still left: R2 earned nothing, so its $586.75 is deducted from the Owner''s other vehicle ($650.00 - $586.75 = $63.25)',
  (select arrears_moved_cents || '/' || payout_cents from owner_statements where owner_id = test.id('owner:ravi')), '58675/6325');
select test.eq('O5 the statement shows the move: from R2 to R1',
  (select (from_vehicle_id = test.id('vehicle:R2')) || '/' || (vehicle_id = test.id('vehicle:R1')) || '/' || amount_cents
     from owner_statement_lines where line_type = 'arrears_moved' and owner_statement_id = (select id from owner_statements where owner_id = test.id('owner:ravi'))),
  'true/true/-58675');
