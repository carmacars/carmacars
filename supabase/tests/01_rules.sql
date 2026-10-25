-- 01: the pure rules, asserted against every worked example in the two billing specifications
-- (and the agreements' own examples), to the cent.
select test.suite('01 rules');

-- ============================================================ renter spec section 2: rate selection
-- Examples: daily $100, weekend $120, weekly $560, monthly $1,800. 2026-11-05 is a Thursday.
with t as (select timestamp '2026-11-05 10:00' at time zone 'America/Toronto' as pickup,
                  timestamp '2026-11-08 10:00' at time zone 'America/Toronto' as ret)
select test.eq('R2.1 Thursday 10:00 to Sunday 10:00 is 3 billable days', public.calc_billable_days(pickup, ret), 3) from t;
select test.eq('R2.1 Thu-Sun: $100 + $120 + $120 = $340',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-05 10:00' at time zone 'America/Toronto', 3, 10000, 12000, 56000, 180000)),
  test.money('340.00'));
select test.eq('R2.1 Thu-Sun: one daily day and two weekend days',
  (select daily_days || '+' || weekend_days from public.calc_rental_charge(timestamp '2026-11-05 10:00' at time zone 'America/Toronto', 3, 10000, 12000, 56000, 180000)),
  '1+2');
select test.eq('R2.2 Monday 09:00 to Sunday 09:00 is 6 billable days',
  public.calc_billable_days(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', timestamp '2026-11-15 09:00' at time zone 'America/Toronto'), 6);
select test.eq('R2.2 Mon-Sun: 4 x $100 + 2 x $120 = $640, capped at the weekly rate $560',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', 6, 10000, 12000, 56000, 180000)),
  test.money('560.00'));
select test.eq('R2.3 10 days: $560 / 7 x 10 = $800',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', 10, 10000, 12000, 56000, 180000)),
  test.money('800.00'));
select test.eq('R2.4 45 days wanted: first transaction, 30 days at the monthly rate = $1,800',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', 30, 10000, 12000, 56000, 180000)),
  test.money('1,800.00'));
select test.eq('R2.4 45 days wanted: renewal of 15 days = $560 / 7 x 15 = $1,200',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-12-09 09:00' at time zone 'America/Toronto', 15, 10000, 12000, 56000, 180000)),
  test.money('1,200.00'));
select test.eq('R2.4 45 days wanted: $3,000 over two transactions',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', 30, 10000, 12000, 56000, 180000))
  + (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-12-09 09:00' at time zone 'America/Toronto', 15, 10000, 12000, 56000, 180000)),
  test.money('3,000.00'));
-- 0132: a booking longer than 30 days is one booking cut into monthly periods, each 30 days at the monthly rate
select test.eq('R2 45 days in one booking: the monthly rate for each 30 days ($1,800 x 45 / 30 = $2,700)',
  (select rental_charge_cents from public.calc_rental_charge(now(), 45, 10000, 12000, 56000, 180000)), test.money('2,700.00'));
select test.throws('R2 past 3,660 days is refused',
  $$select * from public.calc_rental_charge(now(), 4000, 10000, 12000, 56000, 180000)$$, '1 to 3,660 days');
select test.eq('R2 7 to 29 days is capped at the monthly rate (29 days: $2,320 -> $1,800)',
  (select rental_charge_cents from public.calc_rental_charge(now(), 29, 10000, 12000, 56000, 180000)), test.money('1,800.00'));
select test.eq('R2 7 days is the weekly rate',
  (select rental_charge_cents from public.calc_rental_charge(now(), 7, 10000, 12000, 56000, 180000)), test.money('560.00'));
select test.eq('R2 rate applied: 1-6 daily, 7-29 weekly, 30 monthly',
  (select string_agg(rate_applied, ',' order by d) from (values (1), (6), (7), (29), (30)) v(d),
     lateral public.calc_rental_charge(now(), d, 10000, 12000, 56000, 180000)), 'daily,daily,weekly,weekly,monthly');
select test.eq('R2 billable days round up: 25 hours is 2 days',
  public.calc_billable_days(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', timestamp '2026-11-10 10:00' at time zone 'America/Toronto'), 2);
select test.eq('R2 billable days: minimum 1',
  public.calc_billable_days(timestamp '2026-11-09 09:00' at time zone 'America/Toronto', timestamp '2026-11-09 12:00' at time zone 'America/Toronto'), 1);
select test.eq('R2 rounding to the cent, half up: weekly $100.01 / 7 x 8 = $114.30',
  (select rental_charge_cents from public.calc_rental_charge(now(), 8, 5000, 5000, 10001, 900000)), 11430::bigint);

-- Toronto rules, with the database session in UTC
select test.eq('TZ the session runs in UTC', current_setting('timezone'), 'UTC');
select test.eq('TZ a Thursday 22:00 Toronto pickup (already Friday in UTC) starts on a Thursday: daily rate',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-05 22:00' at time zone 'America/Toronto', 1, 10000, 12000, 56000, 180000)),
  test.money('100.00'));
select test.eq('TZ a Saturday 23:30 Toronto pickup (Sunday in UTC) starts on a Saturday: weekend rate',
  (select rental_charge_cents from public.calc_rental_charge(timestamp '2026-11-07 23:30' at time zone 'America/Toronto', 1, 10000, 12000, 56000, 180000)),
  test.money('120.00'));
select test.eq('TZ 10:00 to 10:00 across the end of daylight saving (Nov 1, 2026) is 1 day, not 25 hours',
  public.calc_billable_days(timestamp '2026-10-31 10:00' at time zone 'America/Toronto', timestamp '2026-11-01 10:00' at time zone 'America/Toronto'), 1);
select test.eq('TZ 10:00 to 10:00 across the start of daylight saving (Mar 14, 2027) is 1 day',
  public.calc_billable_days(timestamp '2027-03-13 10:00' at time zone 'America/Toronto', timestamp '2027-03-14 10:00' at time zone 'America/Toronto'), 1);
select test.eq('TZ 03:30 UTC on Dec 1 is still Nov 30 in Toronto', app.local_date(timestamptz '2026-12-01 03:30+00'), date '2026-11-30');
select test.eq('TZ fee billing date for November 2026 is the 15th', app.billing_date(date '2026-11-01'), date '2026-11-15');
select test.eq('TZ retry date is the 18th', app.retry_date(date '2026-11-15'), date '2026-11-18');
select test.eq('TZ the November statement is paid on December 10', app.payout_date(date '2026-11-01'), date '2026-12-10');
select test.eq('TZ 7 business days after Friday Nov 6 is Tuesday Nov 17', app.add_business_days(date '2026-11-06', 7), date '2026-11-17');
select test.eq('TZ 10 business days after Monday Nov 9 is Monday Nov 23', app.add_business_days(date '2026-11-09', 10), date '2026-11-23');

-- ============================================================ renter spec section 5: cancellation
-- Examples: rental charge $600 + HST $78 = $678 paid.
select test.eq('R5.1 booked 10 days ahead, cancelled 5 hours after booking: 95% tier',
  (select refund_bps from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-01 17:00-04', timestamptz '2026-11-11 12:00-05', false, 67800)), 9500);
select test.eq('R5.1 refund $644.10',
  (select refund_cents from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-01 17:00-04', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('644.10'));
select test.eq('R5.1 retained $33.90',
  (select retained_cents from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-01 17:00-04', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('33.90'));
select test.eq('R5.2 cancelled 3 days before start: 75% tier',
  (select refund_bps from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-08 12:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), 7500);
select test.eq('R5.2 refund $508.50',
  (select refund_cents from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-08 12:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('508.50'));
select test.eq('R5.2 retained $169.50',
  (select retained_cents from public.calc_cancellation(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-08 12:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('169.50'));
select test.eq('R5.3 booked 30 hours before start, cancelled 1 hour later: 50% tier',
  (select refund_bps from public.calc_cancellation(timestamptz '2026-11-10 06:00-05', timestamptz '2026-11-10 07:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), 5000);
select test.eq('R5.3 refund $339.00',
  (select refund_cents from public.calc_cancellation(timestamptz '2026-11-10 06:00-05', timestamptz '2026-11-10 07:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('339.00'));
select test.eq('R5.3 retained $339.00',
  (select retained_cents from public.calc_cancellation(timestamptz '2026-11-10 06:00-05', timestamptz '2026-11-10 07:00-05', timestamptz '2026-11-11 12:00-05', false, 67800)), test.money('339.00'));
select test.eq('R5 less than 24 hours before start: none',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-10 13:00-05', timestamptz '2026-11-11 12:00-05'), 0);
select test.eq('R5 after start, or a no-show: none',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-11 15:00-05', timestamptz '2026-11-11 12:00-05'), 0);
select test.eq('R5 exactly 48 hours before start: 75%',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-09 12:00-05', timestamptz '2026-11-11 12:00-05'), 7500);
select test.eq('R5 one minute under 48 hours: 50%',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-09 12:01-05', timestamptz '2026-11-11 12:00-05'), 5000);
select test.eq('R5 exactly 24 hours before start: 50%',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-10 12:00-05', timestamptz '2026-11-11 12:00-05'), 5000);
select test.eq('R5 the 95% rule needs both: within 24 hours of booking but only 30 hours before start is 50%',
  public.calc_refund_bps(timestamptz '2026-11-10 05:00-05', timestamptz '2026-11-10 06:00-05', timestamptz '2026-11-11 12:00-05'), 5000);
select test.eq('R5 exactly 24 hours after booking and 48 hours or more before start: 95%',
  public.calc_refund_bps(timestamptz '2026-11-02 12:00-05', timestamptz '2026-11-03 12:00-05', timestamptz '2026-11-11 12:00-05'), 9500);
select test.eq('R5 the first row that fits: 25 hours after booking, 8 days before start: 75%',
  public.calc_refund_bps(timestamptz '2026-11-02 12:00-05', timestamptz '2026-11-03 13:00-05', timestamptz '2026-11-11 12:00-05'), 7500);
select test.eq('R5 the 48-hour window is elapsed time, also across the daylight-saving change',
  public.calc_refund_bps(timestamptz '2026-10-20 12:00-04', timestamp '2026-10-31 12:30' at time zone 'America/Toronto',
                         timestamp '2026-11-02 12:00' at time zone 'America/Toronto'), 7500);
select test.eq('R5 non-refundable booking: never refunded',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-01 17:00-04', timestamptz '2026-11-11 12:00-05', true), 0);
select test.eq('R5 CarmaCars cancels: 100%, including a non-refundable booking',
  public.calc_refund_bps(timestamptz '2026-11-01 12:00-04', timestamptz '2026-11-11 09:00-05', timestamptz '2026-11-11 12:00-05', true, true), 10000);
select test.eq('R5 non-refundable discount is 10% of the rental charge only', public.calc_bps(60000, 1000), test.money('60.00'));

-- ============================================================ renter spec section 8: splitting a booking
select test.eq('R8.1 referred $1,000 rental, third-party car at 25%: kickback $200',
  (select kickback_cents from public.calc_booking_split(100000, 0, true, 2500)), test.money('200.00'));
select test.eq('R8.1 Owner Revenue $800',
  (select owner_revenue_cents from public.calc_booking_split(100000, 0, true, 2500)), test.money('800.00'));
select test.eq('R8.1 company $200',
  (select company_share_cents from public.calc_booking_split(100000, 0, true, 2500)), test.money('200.00'));
select test.eq('R8.1 owner $600',
  (select owner_payout_cents from public.calc_booking_split(100000, 0, true, 2500)), test.money('600.00'));
select test.eq('R8.2 shareholder-owned car, 90/10: kickback $200',
  (select kickback_cents from public.calc_booking_split(100000, 0, true, 1000)), test.money('200.00'));
select test.eq('R8.2 Owner Revenue $800',
  (select owner_revenue_cents from public.calc_booking_split(100000, 0, true, 1000)), test.money('800.00'));
select test.eq('R8.2 company $80',
  (select company_share_cents from public.calc_booking_split(100000, 0, true, 1000)), test.money('80.00'));
select test.eq('R8.2 owner $720',
  (select owner_payout_cents from public.calc_booking_split(100000, 0, true, 1000)), test.money('720.00'));
select test.eq('R8 not referred: no kickback; $1,000 at 25% pays the owner $750',
  (select kickback_cents || '/' || owner_payout_cents from public.calc_booking_split(100000, 0, false, 2500)), '0/75000');
select test.eq('R8 the kickback is on the rental charge only, never on mileage overage',
  (select kickback_cents || '/' || owner_revenue_cents from public.calc_booking_split(100000, 6000, true, 2500)), '20000/86000');
select test.eq('O3 Self-Managed: $1,000 Rental Charge pays the Owner $1,000 (the $150 delivery stays with CarmaCars)',
  (select owner_payout_cents from public.calc_booking_split(100000, 0, false, 0)), test.money('1,000.00'));

-- ============================================================ renter spec sections 1, 3 and 6: fees
select test.eq('R1 young driver 21-25, 3 days: 3 x $20 = $60 (VA hiring package quote)', public.calc_capped_per_day(2000, 3, 20000), test.money('60.00'));
select test.eq('R1 young driver 21-25 caps at $200 per rental', public.calc_capped_per_day(2000, 14, 20000), test.money('200.00'));
select test.eq('R1 young driver 18-20 caps at $350 per rental', public.calc_capped_per_day(3500, 30, 35000), test.money('350.00'));
select test.eq('R1 additional driver caps at $70 per rental, per driver (2 drivers, 10 days: $140)', public.calc_capped_per_day(1000, 10, 7000, 2), test.money('140.00'));
select test.eq('R1 winter tire caps at $150', public.calc_capped_per_day(1500, 12, 15000), test.money('150.00'));
select test.eq('R1 baby seat caps at $70 per seat', public.calc_capped_per_day(1200, 6, 7000), test.money('70.00'));
select test.eq('R1 quote Thu-Sun, delivered and collected, age 23: $340 + $150 + $60, HST $71.50',
  public.calc_hst(34000 + 15000 + 6000), test.money('71.50'));
select test.eq('R1 quote total $621.50', 34000 + 15000 + 6000 + public.calc_hst(34000 + 15000 + 6000), test.money('621.50'));
select test.eq('R6 mileage allowance = allowance per day x billable days (200 x 3 = 600 km)', 200 * 3, 600);
select test.eq('R1 mileage overage: 260 km over at $0.35 = $91.00', public.calc_mileage_overage(10000, 10860, 600, 35), test.money('91.00'));
select test.eq('R1 mileage overage: none inside the allowance', public.calc_mileage_overage(10000, 10500, 600, 35), 0::bigint);
select test.eq('R1 fuel: $19.20 + 25% + $25 = $49.00', (select total_cents from public.calc_fuel_charge(1920)), test.money('49.00'));
select test.eq('R1 late return: 30 minutes late or less costs nothing',
  (select extra_days || '/' || late_fee_cents from public.calc_late_return(30, 10000)), '0/0');
select test.eq('R1 late return: 31 minutes is one started hour ($25) and one extra day',
  (select extra_days || '/' || late_fee_cents from public.calc_late_return(31, 10000)), '1/2500');
select test.eq('O10 late return: 3 hours late, daily $100: fee $75 and one extra day at $100',
  (select late_fee_cents || '/' || extra_days_cents from public.calc_late_return(180, 10000)), '7500/10000');
select test.eq('R1 late return fee is capped at 1.5 x daily rate per 24 hours (10 hours: $150, not $250)',
  (select late_fee_cents from public.calc_late_return(600, 10000)), test.money('150.00'));
select test.eq('R1 late return, 26 hours: $150 for the first 24 hours + 2 x $25, and 2 extra days',
  (select late_fee_cents || '/' || extra_days from public.calc_late_return(1560, 10000)), '20000/2');
select test.eq('R3 deposit: 7 days or less is a card hold', public.calc_deposit_method(7), 'card_hold');
select test.eq('R3 deposit: over 7 days is charged, then refunded', public.calc_deposit_method(8), 'charged');
select test.eq('R7 interest: 1.5% a month on $200 overdue = $3.00', public.calc_monthly_interest(20000), test.money('3.00'));
select test.eq('R1 HST is 13%', public.calc_hst(60000), test.money('78.00'));

-- damage
select test.eq('R1 Damage under $2,500: actual cost plus the $50 administration fee, no claim',
  (select path || '/' || damage_billed_cents || '/' || deductible_billed_cents || '/' || admin_fee_cents from public.calc_damage_billing(180000)), 'at_cost/180000/0/5000');
select test.eq('R1 Damage of $2,500 or more: the $2,500 deductible plus $75, a fleet policy claim',
  (select path || '/' || damage_billed_cents || '/' || deductible_billed_cents || '/' || admin_fee_cents from public.calc_damage_billing(250000)), 'fleet_policy/0/250000/7500');
select test.eq('R1 Damage of $8,200: the deductible only; loss of use is not added on top',
  (select damage_billed_cents + deductible_billed_cents from public.calc_damage_billing(820000)), test.money('2,500.00'));
select test.eq('R9 Owner Booking, under $2,500: the Owner repairs it; nothing billed',
  (select damage_billed_cents + deductible_billed_cents + admin_fee_cents from public.calc_damage_billing(180000, true)), 0::bigint);
select test.eq('R9 Owner Booking, fleet policy claim: $2,500 deductible, no administration fee',
  (select deductible_billed_cents || '/' || admin_fee_cents from public.calc_damage_billing(400000, true)), '250000/0');
select test.eq('R1 loss of use: daily rate per day out of service, max 30 days', public.calc_loss_of_use(10000, 45), test.money('3,000.00'));

-- ============================================================ owner spec: fees and claims
select test.eq('O10 fee invoice: $450 + $25 + HST $61.75 = $536.75',
  45000 + 2500 + public.calc_hst(45000) + public.calc_hst(2500), test.money('536.75'));
select test.eq('O10 retry after the $50 Late Fee (no HST): $586.75',
  45000 + 2500 + public.calc_hst(45000) + public.calc_hst(2500) + 5000, test.money('586.75'));
select test.eq('O10 Revenue Share 35% of $1,760.00 = $616.00', public.calc_bps(176000, 3500), test.money('616.00'));
select test.eq('O10 Revenue Share 35% of $2,100.00 = $735.00', public.calc_bps(210000, 3500), test.money('735.00'));
select test.eq('O1 standard grid: 1-2 vehicles $450 / 35% / $25',
  (select insurance_fee_cents || '/' || revenue_share_bps || '/' || tracker_fee_cents from owner_fee_grid where min_vehicles = 1), '45000/3500/2500');
select test.eq('O1 standard grid: 3-9 vehicles $400 / 30% / $20',
  (select insurance_fee_cents || '/' || revenue_share_bps || '/' || tracker_fee_cents from owner_fee_grid where min_vehicles = 3), '40000/3000/2000');
select test.eq('O1 standard grid: 10 or more $350 / 25% / $15',
  (select insurance_fee_cents || '/' || revenue_share_bps || '/' || tracker_fee_cents from owner_fee_grid where min_vehicles = 10), '35000/2500/1500');
select test.eq('O1 fees pro-rated by day: enrolled Nov 16 is 15 of 30 days', public.calc_fee_days(date '2026-11-01', date '2026-11-16', null), 15);
select test.eq('O1 pro-rated Insurance Fee for 15 of 30 days of $450 = $225.00', public.calc_prorated_fee(45000, 15, 30), test.money('225.00'));
select test.eq('O9 exit month: Exit Date Dec 10 is 10 of 31 days', public.calc_fee_days(date '2026-12-01', date '2026-09-01', date '2026-12-10'), 10);

select test.eq('O7 shareholder claim: $7,500 + $2,500 - $8,200 - $300 = Claim Profit $1,500',
  (select result_cents from public.calc_claim_result(750000 + 250000, 820000, 0, 30000, true)), test.money('1,500.00'));
select test.eq('O7 owning shareholder, 90%: $1,350',
  (select owner_cents from public.calc_claim_result(750000 + 250000, 820000, 0, 30000, true)), test.money('1,350.00'));
select test.eq('O7 company, 10%: $150',
  (select company_cents from public.calc_claim_result(750000 + 250000, 820000, 0, 30000, true)), test.money('150.00'));
select test.eq('O7 third-party Owner, same claim: the $1,500 balance belongs to CarmaCars, the Owner gets none',
  (select owner_cents || '/' || company_cents from public.calc_claim_result(750000 + 250000, 820000, 0, 30000, false)), '0/150000');
select test.eq('O7 third-party Owner, shortfall of $700: the Owner pays it',
  (select owner_cents || '/' || company_cents from public.calc_claim_result(750000, 820000, 0, 0, false)), '-70000/0');
select test.eq('O7 a shortfall CarmaCars caused is not the Owner''s',
  (select owner_cents || '/' || company_cents from public.calc_claim_result(750000, 820000, 0, 0, false, 9000, true)), '0/-70000');
select test.eq('O7 shareholder shortfall of $700 splits 90/10',
  (select owner_cents || '/' || company_cents from public.calc_claim_result(750000, 820000, 0, 0, true)), '-63000/-7000');
select test.eq('O7 total loss: $30,000 settlement pays the lender $18,000, then $586.75 owed to CarmaCars, then the Owner',
  (select lender_cents || '/' || company_cents || '/' || owner_cents from public.calc_total_loss(3000000, 1800000, 58675)), '1800000/58675/1141325');
select test.eq('O7 total loss: a lender owed more than the settlement takes it all',
  (select lender_cents || '/' || company_cents || '/' || owner_cents from public.calc_total_loss(1000000, 1800000, 58675)), '1000000/0/0');

-- ============================================================ investment agreement, Schedule B
select test.eq('I-B1 $20,000 at 30%: monthly Return $500', public.calc_investment_return(2000000, 3000, 31, 31), test.money('500.00'));
select test.eq('I-B2 month 3 on $21,012.50: $525.31', public.calc_investment_return(2101250, 3000, 30, 30), test.money('525.31'));
select test.eq('I-B2 after 12 months of reinvestment, monthly Return on $26,897.77: $672.44', public.calc_investment_return(2689777, 3000, 31, 31), test.money('672.44'));
select test.eq('I 4.1 an election received Jun 25 applies from the August Return Month', public.calc_election_effective_month(date '2027-06-25'), date '2027-08-01');
select test.eq('I 4.1 an election received Jun 21 applies from July 1 (exactly 10 days)', public.calc_election_effective_month(date '2027-06-21'), date '2027-07-01');

-- ============================================================ rounding, extensions, retries, exit
select test.eq('RND half a cent rounds up: HST on $12.50 is $1.63 (1.625)', public.calc_hst(1250), 163::bigint);
select test.eq('RND a credit mirrors the charge: HST on -$12.50 is -$1.63', public.calc_hst(-1250), -163::bigint);
select test.eq('R6 extension: Thu-Sun (3 days, $340) extended to 10 days is repriced to $800; the renter pays the $460 difference',
  (select previous_rental_charge_cents || '/' || new_rental_charge_cents || '/' || rental_difference_cents
     from public.calc_extension(timestamp '2026-11-05 10:00' at time zone 'America/Toronto', 3, 10, 10000, 12000, 56000, 180000)), '34000/80000/46000');
select test.eq('R6 an extension past 30 days is priced at the monthly rate for each 30 days (0132)',
  (select new_rental_charge_cents from public.calc_extension(now(), 25, 31, 10000, 12000, 56000, 180000)), test.money('1,860.00'));
select test.eq('R7 declined card: retries after 1, 3 and 7 days, then none',
  (select string_agg(coalesce((public.calc_payment_retry_at(timestamptz '2026-11-01 12:00+00', n) - timestamptz '2026-11-01 12:00+00')::text, 'none'), ', ' order by n)
     from generate_series(0, 3) n), '1 day, 3 days, 7 days, none');
select test.eq('O9 transfer-back fees: under 6 months the Owner pays; after 6 months CarmaCars pays',
  public.calc_retransfer_payer(5) || '/' || public.calc_retransfer_payer(6), 'owner/carmacars');
select test.eq('O9 transfer-back fees: Owner default, the Owner always pays', public.calc_retransfer_payer(24, true), 'owner');
select test.eq('O9 transfer-back fees: insurer declines after registration, CarmaCars pays unless the Owner failed to disclose',
  public.calc_retransfer_payer(1, false, true) || '/' || public.calc_retransfer_payer(1, false, true, true), 'carmacars/owner');
select test.eq('O9 buyout: Black Book $20,000 x 1.10 = $22,000', public.calc_buyout_price(2000000), test.money('22,000.00'));
