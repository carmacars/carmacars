-- 99: release 48, part MR (migrations 3100 to 3102): owner payouts on the term in force each rental day, a versioned
-- correction of a car's terms, statements recomputed, shareholders' 90% of everything charged, the owner referral share,
-- extensions handled by a salesperson (commission, money), the debit deposit switch for Sales, the deposit hold tapped
-- twice, deposits kept 30 days, speeding charges and named fees added by line.
-- Fixtures start with "mr"; the months are 2034, where no other test puts money.

select test.suite('99 r48 money rules: terms by day');
select test.mk_user('mr_admin', 'admin');
select test.mk_user('mr_fin', 'va', 'finance');
select test.mk_user('mr_cs', 'va', 'cs');
select test.mk_user('mr_s1', 'va', 'sales');
select test.mk_user('mr_s2', 'va', 'sales');
select test.mk_owner('mr_max');
select test.mk_owner('mr_kar');
select test.mk_vehicle('MR1', 'mr_max', p_insurance => 35000, p_tracker => 0, p_share_bps => 3000, p_enrolled => date '2034-01-01');
select test.mk_vehicle('MRK', 'mr_kar', p_insurance => 35000, p_tracker => 0, p_share_bps => 3000, p_enrolled => date '2034-01-01');
select test.mk_renter('mr_r1', false);
select test.mk_renter('mr_r2', false);
-- ten rental days, February 10 to 20, booked on February 1 at 30%
select test.mk_booking('MR-1', 'MR1', 'mr_r1', '2034-02-10 10:00', '2034-02-20 10:00', 'closed', 100000, p_booked => '2034-02-01 09:00');
select app.compute_booking_split(test.id('booking:MR-1'));
select test.eq('the booking starts on the 30% it was booked at', (select company_share_bps from booking_splits where booking_id = test.id('booking:MR-1')), 3000);

-- a correction from February 15: five days at 30%, five at 40%
select test.throws('a correction says why (10 characters or more)',
  format($$select app.car_terms_correct(%L, '{"vehicle_id": "%s", "revenue_share_bps": 4000, "reason": "oops"}')$$, test.id('mr_admin'), test.id('vehicle:MR1')), 'Say why');
select test.throws('only an Admin corrects terms',
  format($$select app.car_terms_correct(%L, '{"vehicle_id": "%s", "revenue_share_bps": 4000, "reason": "Agreed 40 percent from the start"}')$$, test.id('mr_fin'), test.id('vehicle:MR1')), 'Admin');
select test.throws('a correction starts on the car''s start or later',
  format($$select app.car_terms_correct(%L, '{"vehicle_id": "%s", "revenue_share_bps": 4000, "effective_from": "2033-12-01", "reason": "Agreed 40 percent from the start"}')$$, test.id('mr_admin'), test.id('vehicle:MR1')), 'start');
select test.eq('the preview changes nothing and says the owner gets less',
  (select (app.car_terms_correct(test.id('mr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:MR1'), 'revenue_share_bps', 4000, 'effective_from', '2034-02-15',
     'reason', 'Agreed 40 percent from mid February', 'preview', true)) ->> 'owner_gets_less') || '/' || (select count(*) from vehicle_fee_history where vehicle_id = test.id('vehicle:MR1'))),
  'true/1');
select app.car_terms_correct(test.id('mr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:MR1'), 'revenue_share_bps', 4000, 'effective_from', '2034-02-15',
  'reason', 'Agreed 40 percent from mid February'));
select test.eq('the periods: 30% to February 15, 40% from it (the replaced one is kept with the correction)',
  (select string_agg(h.effective_from || ':' || h.revenue_share_bps || ':' || h.source, ' ' order by h.effective_from) from vehicle_fee_history h where h.vehicle_id = test.id('vehicle:MR1')),
  '2034-01-01:3000:signed_schedule 2034-02-15:4000:correction');
select test.eq('the correction keeps the periods before it', (select jsonb_array_length(periods_before) || '/' || owner_gets_less from vehicle_terms_corrections where vehicle_id = test.id('vehicle:MR1')), '1/true');
select test.eq('a statement uses the term in force on each rental day: 5 days at 30%, 5 at 40%',
  (select company_share_bps || '/' || company_share_cents || '/' || owner_payout_cents from booking_splits where booking_id = test.id('booking:MR-1')),
  '3500/' || public.calc_bps((select owner_revenue_cents from booking_splits where booking_id = test.id('booking:MR-1')), 3500)
    || '/' || ((select owner_revenue_cents from booking_splits where booking_id = test.id('booking:MR-1'))
               - public.calc_bps((select owner_revenue_cents from booking_splits where booking_id = test.id('booking:MR-1')), 3500)));
select test.eq('the owner gets less: an updated Vehicle Schedule waits for the owner''s signature',
  (select count(*) from vehicle_term_changes where vehicle_id = test.id('vehicle:MR1') and status = 'awaiting_signature' and revenue_share_bps = 4000), 1::bigint);
-- the connector's change_owner_terms: correction true, from the car's start, though a later term exists
select app.owner_terms_save(test.id('mr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:MR1'), 'correction', true, 'revenue_share_bps', 4000,
  'effective_from', '2034-01-01', 'note', 'Agreed 40 percent from the start'));
select test.eq('corrected from the start: every rental day at 40%', (select company_share_bps from booking_splits where booking_id = test.id('booking:MR-1')), 4000);
select test.eq('two corrections kept', (select count(*) from vehicle_terms_corrections where vehicle_id = test.id('vehicle:MR1')), 2::bigint);
select test.throws('the same terms again are refused',
  format($$select app.car_terms_correct(%L, '{"vehicle_id": "%s", "revenue_share_bps": 4000, "reason": "Agreed 40 percent from the start"}')$$, test.id('mr_admin'), test.id('vehicle:MR1')), 'already in place');
-- the owner gets more: no new signature
select app.car_terms_correct(test.id('mr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:MRK'), 'insurance_fee_cents', 28400, 'reason', 'Agreed $284 a car from the start'));
select test.eq('a lower Insurance Fee needs no signature', (select owner_gets_less::text || '/' || coalesce(resign_change_id::text, 'none') from vehicle_terms_corrections where vehicle_id = test.id('vehicle:MRK')), 'false/none');
select test.eq('the connector''s get_car shows the terms and their periods', (app.api_vehicle_row(test.id('vehicle:MR1')) -> 'terms' -> 'periods' -> -1 ->> 'revenue_share_bps')::integer, 4000);
select test.eq('the connector''s get_owner shows each car''s terms',
  (select (c -> 'terms' -> 'periods' -> -1 ->> 'insurance_fee_cents')::bigint from jsonb_array_elements(app.api_owner_row(test.id('owner:mr_kar')) -> 'cars') c), 28400::bigint);

-- ================================================================ statements recomputed, the owner referral share
select test.suite('99 r48 money rules: statements recomputed');
select test.mk_booking('MR-2', 'MR1', 'mr_r2', '2034-03-01 10:00', '2034-03-05 10:00', 'closed', 50000, p_booked => '2034-02-20 09:00');
-- approved at 30% (as ST-1002 was), then corrected to 40% from the start
update vehicle_fee_history set revenue_share_bps = 3000 where vehicle_id = test.id('vehicle:MR1');
select app.compute_booking_split(test.id('booking:MR-2'));
create temp table mr_st as select app.build_owner_statement(test.id('owner:mr_max'), date '2034-02-01') as id;
select app.approve_owner_statement((select id from mr_st), test.id('mr_admin'));
select test.eq('approved at 30%: the payout is 70% of the revenue',
  (select payout_cents = owner_revenue_cents - public.calc_bps(owner_revenue_cents, 3000) from owner_statements where id = (select id from mr_st)), true);
insert into owner_referral_links (referrer_owner_id, referred_owner_id, share_bps, sees_cars, effective_from, created_by)
values (test.id('owner:mr_kar'), test.id('owner:mr_max'), 1000, true, date '2034-01-01', test.id('mr_admin'));
select app.car_terms_correct(test.id('mr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:MR1'), 'revenue_share_bps', 4000, 'reason', 'Agreed 40 percent from the start',
  'recompute_statements', true));
select test.eq('the approved statement not paid out is voided and built again', (select status from owner_statements where id = (select id from mr_st)), 'void');
select test.eq('the new statement is approved, at 40%: the payout is 60% of the revenue',
  (select status || '/' || (payout_cents = owner_revenue_cents - public.calc_bps(owner_revenue_cents, 4000)) from owner_statements
    where owner_id = test.id('owner:mr_max') and statement_month = date '2034-02-01' and status <> 'void'), 'approved/true');
select test.eq('an audit line keeps the amounts before and after',
  (select count(*) from audit_log where action = 'owner_statement_recompute' and entity_id = (select id::text from mr_st)), 1::bigint);
select test.eq('the old payout is cancelled, the new one approved',
  (select string_agg(status, ',' order by status) from payouts where owner_id = test.id('owner:mr_max')), 'approved,cancelled');
-- the referrer's statement: 10 points of the referred owner's revenue base
select app.build_owner_statement(test.id('owner:mr_kar'), date '2034-02-01');
select test.eq('the referrer earns 10% of the revenue base of the referred owner''s cars',
  (select sum(amount_cents) from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
    where s.owner_id = test.id('owner:mr_kar') and s.statement_month = date '2034-02-01' and s.status = 'draft' and l.line_type = 'referral_share'),
  (select round(sum(owner_revenue_cents) * 0.1)::bigint from booking_splits where owner_id = test.id('owner:mr_max') and payout_month <= date '2034-02-01'));
select test.eq('the referrer sees the referred owner''s cars (get_owner)',
  (select (l ->> 'sees_cars')::boolean from jsonb_array_elements(app.api_owner_row(test.id('owner:mr_kar')) -> 'referral_links') l), true);

-- ================================================================ shareholders: 90% of everything charged
select test.suite('99 r48 money rules: shareholders');
select test.mk_owner('mr_sh', p_shareholder => true);
select test.mk_vehicle('MRS', 'mr_sh', p_insurance => 0, p_tracker => 0, p_share_bps => 1000, p_enrolled => date '2034-01-01', p_shareholder => true);
select test.mk_renter('mr_r3', false);
select test.mk_booking('MR-3', 'MRS', 'mr_r3', '2034-04-01 10:00', '2034-04-05 10:00', 'closed', 50000);
select test.mk_line('MR-3', 'young_driver_21_25', 8000);
select test.mk_line('MR-3', 'coverage_sold', 6000);
select test.mk_line('MR-3', 'smoking', 30000);
select test.mk_line('MR-3', 'ticket_amount', 4000);
select app.compute_booking_split(test.id('booking:MR-3'));
select test.eq('the shareholder keeps 90% of the rental and every fee and amount kept, before tax',
  (select owner_revenue_cents || '/' || company_share_bps || '/' || company_share_cents || '/' || owner_payout_cents from booking_splits where booking_id = test.id('booking:MR-3')),
  '98000/1000/9800/88200');
select test.eq('HST stays out (it is remitted)', (select hst_cents > 0 and owner_revenue_cents = 98000 from booking_splits where booking_id = test.id('booking:MR-3')), true);
select test.throws('a shareholder car has fixed terms',
  format($$select app.car_terms_correct(%L, '{"vehicle_id": "%s", "revenue_share_bps": 2000, "reason": "Not for a shareholder"}')$$, test.id('mr_admin'), test.id('vehicle:MRS')), 'shareholder');

-- ================================================================ extensions
select test.suite('99 r48 money rules: extensions');
select test.mk_vehicle('MRE', 'mr_kar', p_enrolled => date '2034-01-01');
select test.mk_renter('mr_r4', false);
select test.mk_booking('MR-4', 'MRE', 'mr_r4', '2034-05-01 10:00', '2034-05-08 10:00', 'closed', 70000);
update bookings set sales_staff_id = test.id('mr_s1'), sales_source = 'offer', sales_attributed_at = booked_at, sales_sourced = true, confirmed_at = booked_at where id = test.id('booking:MR-4');
insert into booking_extensions (id, booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
    previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, total_cents, approved_at, paid_at, confirmed_in_writing_at)
select test.id('ext:mr4'), b.id, 1, 'confirmed', b.return_at - interval '2 days', b.return_at, 5, 7, 50000, 70000, 20000, 22600, b.pickup_at + interval '3 days',
       b.pickup_at + interval '3 days', b.pickup_at + interval '3 days'
  from bookings b where b.id = test.id('booking:MR-4');
select test.eq('an extension goes to the booking''s salesperson by default',
  (select handled_by || '/' || handled_queue from booking_extensions where id = test.id('ext:mr4')), test.id('mr_s1') || '/sales');
select test.throws('customer service does not give an extension away',
  format($$select app.door(%L, 'aal2', 'ops_do', 'extension_assign', '{"extension": "%s", "to": "%s", "reason": "Not answering"}')$$, test.id('mr_cs'), test.id('ext:mr4'), test.id('mr_s2')), 'salesperson handling it');
select test.throws('an extension is handled by a salesperson or Admin',
  format($$select app.extension_assign(%L, '{"extension": "%s", "to": "%s", "reason": "Not answering"}')$$, test.id('mr_admin'), test.id('ext:mr4'), test.id('mr_cs')), 'salesperson or by Admin');
select app.commission_sync(test.id('booking:MR-4'));
select test.eq('before: the booking''s salesperson earns on the whole rental',
  (select base_cents from staff_commissions where booking_id = test.id('booking:MR-4') and staff_id = test.id('mr_s1') and kind = 'commission'), 70000::bigint);
select app.door(test.id('mr_admin'), 'aal2', 'ops_do', 'extension_assign', jsonb_build_object('extension', test.id('ext:mr4'), 'to', test.id('mr_s2'), 'reason', 'The salesperson was not answering'));
select test.eq('given to another salesperson: the commission on the extension is theirs',
  (select string_agg(u.full_name || ':' || c.base_cents || ':' || c.status, ' ' order by u.full_name) from staff_commissions c join users u on u.id = c.staff_id
    where c.booking_id = test.id('booking:MR-4') and c.kind = 'commission' and c.status not in ('void', 'reversed')),
  (select string_agg(x, ' ' order by x) from (values ('Mr S1:50000:' || (select status from staff_commissions where booking_id = test.id('booking:MR-4') and staff_id = test.id('mr_s1') and kind = 'commission')),
                                                    ('Mr S2:20000:' || (select status from staff_commissions where booking_id = test.id('booking:MR-4') and staff_id = test.id('mr_s2') and kind = 'commission'))) v(x)));
select app.extension_assign(test.id('mr_admin'), jsonb_build_object('extension', test.id('ext:mr4'), 'to', 'admin', 'reason', 'Admin finished it'));
select test.eq('given to Admin: nobody earns on the extension', (select count(*) from staff_commissions where booking_id = test.id('booking:MR-4') and staff_id = test.id('mr_s2')
  and kind = 'commission' and status not in ('void', 'reversed')), 0::bigint);
select test.eq('the booking''s salesperson still earns on the rest', (select base_cents from staff_commissions where booking_id = test.id('booking:MR-4') and staff_id = test.id('mr_s1') and kind = 'commission'), 50000::bigint);
select test.eq('the reassignment is in the booking''s history',
  (select count(*) from booking_events where booking_id = test.id('booking:MR-4') and note like 'Extension 1 given to%'), 2::bigint);
select test.eq('the booking page shows the money of the extension',
  (select (x -> 'money' ->> 'state') || '/' || (x -> 'money' ->> 'amount_cents') || '/' || (x -> 'money' ->> 'handler')
     from jsonb_array_elements(app.admin_booking_detail(test.id('booking:MR-4')) -> 'extensions') x), 'paid/22600/Admin');
-- an approved extension paid another way, recorded by the salesperson handling it
select test.mk_vehicle('MRE2', 'mr_kar', p_enrolled => date '2034-01-01');
select test.mk_renter('mr_r5', false);
select test.mk_booking('MR-5', 'MRE2', 'mr_r5', to_char(now() - interval '2 days', 'YYYY-MM-DD HH24:MI'), to_char(now() + interval '1 day', 'YYYY-MM-DD HH24:MI'), 'on_rent', 30000);
update bookings set sales_staff_id = test.id('mr_s2'), sales_source = 'offer', sales_attributed_at = booked_at, sales_sourced = true, confirmed_at = booked_at, bill_to = 'renter' where id = test.id('booking:MR-5');
insert into booking_extensions (id, booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
    previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, total_cents, approved_at)
select test.id('ext:mr5'), b.id, 1, 'approved', b.return_at, b.return_at + interval '1 day', b.billable_days, b.billable_days + 1, b.rental_charge_cents, b.rental_charge_cents + 10000, 10000, 11300, now()
  from bookings b where b.id = test.id('booking:MR-5');
select test.eq('approved, not paid yet', (select x -> 'money' ->> 'state' from jsonb_array_elements(app.admin_booking_detail(test.id('booking:MR-5')) -> 'extensions') x), 'waiting for payment');
select test.throws('a salesperson not on it does not collect it',
  format($$select app.extension_record_payment(%L, '{"extension": "%s", "method": "cash"}')$$, test.id('mr_s1'), test.id('ext:mr5')), 'salesperson handling');
select test.throws('an e-Transfer needs its reference',
  format($$select app.extension_record_payment(%L, '{"extension": "%s", "method": "e_transfer"}')$$, test.id('mr_s2'), test.id('ext:mr5')), 'reference');
select app.door(test.id('mr_s2'), 'aal2', 'ops_do', 'extension_record_payment', jsonb_build_object('extension', test.id('ext:mr5'), 'method', 'e_transfer', 'reference', 'CAmr5ref'));
select test.eq('recorded: paid by e-Transfer with its reference, and the return moved',
  (select (x -> 'money' ->> 'state') || '/' || (x -> 'money' ->> 'method') || '/' || (x -> 'money' ->> 'reference')
     from jsonb_array_elements(app.admin_booking_detail(test.id('booking:MR-5')) -> 'extensions') x)
   || '/' || ((select return_at from bookings where id = test.id('booking:MR-5')) = (select new_return_at from booking_extensions where id = test.id('ext:mr5'))),
  'paid/e_transfer/CAmr5ref/true');
select test.throws('a paid extension is not charged again',
  format($$select app.extension_charge_begin(%L, '{"extension": "%s"}')$$, test.id('mr_admin'), test.id('ext:mr5')), 'already paid');

-- ================================================================ deposits
select test.suite('99 r48 money rules: deposits');
select test.mk_vehicle('MRD', 'mr_kar', p_enrolled => date '2034-01-01');
select test.mk_renter('mr_r6', false);
select test.mk_booking('MR-6', 'MRD', 'mr_r6', to_char(now() + interval '3 days', 'YYYY-MM-DD HH24:MI'), to_char(now() + interval '6 days', 'YYYY-MM-DD HH24:MI'), 'confirmed', 30000);
update payment_methods set is_credit = false, funding = 'debit' where id = test.id('card:mr_r6');
select test.throws('customer service does not allow debit cards',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_allow_debit', '{"booking": "MR-6", "allow": true, "reason": "Renter has only a debit card"}')$$, test.id('mr_cs')), 'salesperson');
select app.door(test.id('mr_s1'), 'aal2', 'ops_do', 'booking_allow_debit', '{"booking": "MR-6", "allow": true, "reason": "Renter has only a debit card"}'::jsonb);
select test.eq('a salesperson allows debit and prepaid cards for the booking, logged',
  (select (debit_allowed_by = test.id('mr_s1'))::text from bookings where id = test.id('booking:MR-6'))
   || '/' || (select count(*) from audit_log where action = 'booking_allow_debit' and entity_id = test.id('booking:MR-6')::text)
   || '/' || (select count(*) from booking_events where booking_id = test.id('booking:MR-6') and note like 'Debit and prepaid cards allowed%'), 'true/1/1');
-- the deposit hold on the card on file, tapped twice
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id)
values (test.id('card:mr_r6'), 'stripe', 'cus_mr6', 'pm_mr6');
select app.deposit_hold_saved_begin(test.id('mr_fin'), jsonb_build_object('booking', 'MR-6', 'token_sha256', repeat('a', 64)));
select test.throws('a second tap while the first is with the bank says so in plain words',
  format($$select app.deposit_hold_saved_begin(%L, '{"booking": "MR-6", "token_sha256": "%s"}')$$, test.id('mr_fin'), repeat('b', 64)), 'already being placed');
select app.deposit_hold_saved_failed(test.id('mr_fin'), jsonb_build_object('id', (select id from payment_requests where booking_id = test.id('booking:MR-6') order by created_at desc limit 1),
  'error', 'Your card has insufficient funds.'));
select test.ok('declined, then tapped again: a new try, not "already recorded"',
  (app.deposit_hold_saved_begin(test.id('mr_fin'), jsonb_build_object('booking', 'MR-6', 'token_sha256', repeat('c', 64))) ->> 'ok')::boolean);
select test.eq('the pickup-day hold of the job is still once per booking',
  (select indexdef like '%channel = ''auto''::text) AND auto)' from pg_indexes where indexname = 'payment_requests_auto_hold_once'), true);
select test.eq('deposits are kept 30 days after the return before release', (app.settings()).deposit_toll_window_days, 30);

-- ================================================================ speeding charges and named fees
select test.suite('99 r48 money rules: speeding and named fees');
select test.mk_vehicle('MRP', 'mr_kar', p_enrolled => date '2034-01-01');
select test.mk_renter('mr_r7', false);
select test.mk_booking('MR-7', 'MRP', 'mr_r7', '2034-06-01 10:00', '2034-06-04 10:00', 'returned', 30000);
insert into tracker_points (vehicle_id, at, lat_e6, lng_e6, speed_kmh) values
  (test.id('vehicle:MRP'), timestamptz '2034-06-02 14:00 America/Toronto', 43700000, -79400000, 150),
  (test.id('vehicle:MRP'), timestamptz '2034-06-02 14:01 America/Toronto', 43710000, -79410000, 197);
select test.throws('Sales does not add a speeding charge',
  format($$select app.speeding_charge_add(%L, '{"booking": "MR-7", "over": 180, "at": "2034-06-02T14:00:30-04:00"}')$$, test.id('mr_s1')), 'Finance');
select test.throws('no tracker reading, no charge',
  format($$select app.speeding_charge_add(%L, '{"booking": "MR-7", "over": 180, "at": "2034-06-03T14:00:00-04:00"}')$$, test.id('mr_fin')), 'tracker');
select test.throws('197 km/h is not over 220',
  format($$select app.speeding_charge_add(%L, '{"booking": "MR-7", "over": 220, "at": "2034-06-02T14:00:30-04:00"}')$$, test.id('mr_fin')), 'not over 220');
select test.eq('over 180: the Program setting''s amount, with the tracker''s reading kept',
  (select (r ->> 'amount_cents') || '/' || (r ->> 'speed_kmh') from (select app.speeding_charge_add(test.id('mr_fin'), '{"booking": "MR-7", "over": 180, "at": "2034-06-02T14:00:30-04:00"}'::jsonb) r) x),
  (app.settings()).speeding_180_fee_cents || '/197');
select test.eq('the line: a separate speeding charge with its evidence',
  (select charge_type || '/' || (supporting_refs ->> 'speed_kmh') || '/' || hst_applies from booking_line_items where booking_id = test.id('booking:MR-7') and charge_type like 'speeding%'), 'speeding_180/197/true');
select test.throws('the same reading is not charged twice',
  format($$select app.speeding_charge_add(%L, '{"booking": "MR-7", "over": 180, "at": "2034-06-02T14:00:30-04:00"}')$$, test.id('mr_fin')), 'already charged');
select test.eq('three speeding settings', (select count(*) from information_schema.columns where table_name = 'program_settings' and column_name like 'speeding_%_fee_cents'), 3::bigint);
-- change_booking_fees with a list of named fees (the connector)
select app.door(test.id('mr_admin'), 'aal2', 'ops_do', 'booking_fees_change', jsonb_build_object('booking', 'MR-7',
  'lines', jsonb_build_array(jsonb_build_object('op', 'add', 'fee', 'smoking', 'amount_cents', 30000, 'note', 'Smelled of smoke at the return')), 'reason', 'Smoking in the car'));
select test.eq('a smoking fee added to a returned booking by line',
  (select amount_cents || '/' || hst_cents || '/' || stage from booking_line_items where booking_id = test.id('booking:MR-7') and charge_type = 'smoking' and voided_at is null), '30000/3900/check_in');
select test.eq('the other spellings are taken: action and fee_code',
  (app.booking_fees_change(test.id('mr_admin'), jsonb_build_object('booking', 'MR-7', 'lines', jsonb_build_array(jsonb_build_object('action', 'add', 'fee_code', 'cleaning', 'amount_cents', 7500, 'note', 'Sand on the floor mats'))))
    -> 'added' -> 0 ->> 'fee'), 'cleaning');
select test.throws('an unknown fee is named in the refusal',
  format($$select app.booking_fees_change(%L, '{"booking": "MR-7", "lines": [{"op": "add", "fee": "glitter", "amount_cents": 100, "note": "glitter everywhere"}]}')$$, test.id('mr_admin')), 'Unknown fee "glitter"');
select test.throws('a list line only adds',
  format($$select app.booking_fees_change(%L, '{"booking": "MR-7", "lines": [{"op": "remove", "fee": "smoking"}]}')$$, test.id('mr_admin')), 'adds a named fee');
