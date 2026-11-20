-- 99: release 48 RW (3270, 3271): the charges of an owner-use booking billed to the owner by themselves (card on file,
-- bank debit the same day, invoice due now, then the statement at whichever comes first of 7 days and the cut-off), and
-- the Late Fee of 5% of the unpaid insurance. Fixtures start with "zrm"; every address is example.test.
select test.suite('99 r48 RW: owner-use charges billed to the owner, the Late Fee on unpaid insurance (3270, 3271)');

select test.mk_user('zrm_admin', 'admin');
select test.mk_renter('zrm_r');
select test.mk_owner('zrm_card');
select test.mk_owner('zrm_pad');
select test.mk_owner('zrm_none');
select test.mk_vehicle('ZRMC', 'zrm_card', p_enrolled => date '2026-01-01');
select test.mk_vehicle('ZRMP', 'zrm_pad', p_enrolled => date '2026-01-01');
select test.mk_vehicle('ZRMN', 'zrm_none', p_enrolled => date '2026-01-01');
insert into owner_payment_methods (id, owner_id, kind, last4, brand_or_bank, status) values
  (test.id('opm:zrm_card'), test.id('owner:zrm_card'), 'card', '4242', 'Visa', 'active'),
  (test.id('opm:zrm_card_pad'), test.id('owner:zrm_card'), 'pre_authorized_debit', '1111', 'TD', 'active'),
  (test.id('opm:zrm_pad'), test.id('owner:zrm_pad'), 'pre_authorized_debit', '6789', 'RBC', 'active');
insert into owner_payment_method_secrets (owner_payment_method_id, processor_customer_id, processor_method_id, processor_mandate_id) values
  (test.id('opm:zrm_card'), 'cus_zrm_card', 'pm_zrm_card', null),
  (test.id('opm:zrm_card_pad'), 'cus_zrm_card', 'pm_zrm_card_pad', 'mandate_zrm_card'),
  (test.id('opm:zrm_pad'), 'cus_zrm_pad', 'pm_zrm_pad', 'mandate_zrm_pad');
update program_settings set owner_debit_enabled = true, fee_evidence_gate = false where id = (app.settings()).id;

select test.mk_booking('ZRM-C', 'ZRMC', 'zrm_r', '2026-11-01 10:00', '2026-11-03 10:00', 'returned', null, 'owner');
select test.mk_booking('ZRM-P', 'ZRMP', 'zrm_r', '2026-11-01 10:00', '2026-11-03 10:00', 'returned', null, 'owner');
select test.mk_booking('ZRM-N', 'ZRMN', 'zrm_r', '2026-11-01 10:00', '2026-11-03 10:00', 'returned', null, 'owner');
select test.mk_booking('ZRM-N2', 'ZRMN', 'zrm_r', '2026-11-05 10:00', '2026-11-06 10:00', 'returned', null, 'owner');
select test.mk_booking('ZRM-N3', 'ZRMN', 'zrm_r', '2026-11-08 10:00', '2026-11-09 10:00', 'returned', null, 'owner');
select test.mk_booking('ZRM-N4', 'ZRMN', 'zrm_r', '2026-11-10 10:00', '2026-11-11 10:00', 'returned', null, 'owner');
update bookings set owner_id = v.owner_id from vehicles v where v.id = bookings.vehicle_id and bookings.booking_number like 'ZRM-%' and bookings.owner_id is null;

create function pg_temp.rw_line(p_number text, p_type text, p_amount bigint) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, charged_to_renter, stage)
  select test.id('booking:' || p_number), f.code, f.label, 1, p_amount, p_amount, f.hst_applies, case when f.hst_applies then public.calc_hst(p_amount) else 0 end,
         f.revenue_class, true, 'after_return' from fee_types f where f.code = p_type
  returning id into v_id;
  if v_id is null then raise exception 'unknown fee %', p_type; end if;
  return v_id;
end $$;
create function pg_temp.rw_inv(p_number text) returns owner_invoices language sql as $$
  select i.* from owner_invoices i where i.owner_use_booking_id = test.id('booking:' || p_number) order by i.created_at desc limit 1
$$;

-- ================================================================ A. a card on file: charged at once
select pg_temp.rw_line('ZRM-C', 'fuel', 6500);
select pg_temp.rw_line('ZRM-C', 'toll_amount', 1840);
select test.eq('A nothing is put on a renter statement for an owner-use booking', app.issue_booking_statement(test.id('booking:ZRM-C'), test.id('zrm_admin')), null::uuid);
select test.eq('A that call billed the owner instead: one invoice, issued and due the same day',
  (select i.status || ' ' || (i.due_on = i.billing_date)::text || ' ' || i.kind from pg_temp.rw_inv('ZRM-C') i), 'issued true custom');
select test.eq('A both charges are lines of the invoice, with HST as on the booking',
  (select count(*) || ' ' || sum(amount_cents) || ' ' || sum(hst_cents) from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-C')).id),
  (select '2 8340 ' || sum(hst_cents) from booking_line_items where booking_id = test.id('booking:ZRM-C')));
select test.eq('A the booking lines carry the invoice and no statement',
  (select count(*) filter (where owner_invoice_id = (pg_temp.rw_inv('ZRM-C')).id and statement_id is null) from booking_line_items where booking_id = test.id('booking:ZRM-C')), 2::bigint);
select test.eq('A the card comes before the bank debit: one attempt, at once, on the card',
  (select a.method_kind || ' ' || a.immediate || ' ' || a.status || ' ' || a.processor_method_id || ' ' || (a.debit_on = (pg_temp.rw_inv('ZRM-C')).billing_date)
     from owner_debit_attempts a where a.owner_invoice_id = (pg_temp.rw_inv('ZRM-C')).id), 'card true scheduled pm_zrm_card true');
select test.eq('A the invoice says how it is collected', (pg_temp.rw_inv('ZRM-C')).owner_use_state, 'card');
select test.eq('A the owner is told, with each charge',
  (select count(*) || ' ' || bool_and(payload ->> 'state' = 'card' and jsonb_array_length(payload -> 'charge_lines') = 2) from app_events
    where code = 'owner_use_charges' and entity_id = (pg_temp.rw_inv('ZRM-C')).id), '1 true');
select test.eq('A the "invoice issued" email of a hand-made invoice is not sent as well',
  (select count(*) from app_events where code = 'owner_invoice_issued' and entity_id = (pg_temp.rw_inv('ZRM-C')).id), 0::bigint);
select test.eq('A billing again adds nothing', (app.owner_use_bill(test.id('booking:ZRM-C')) ->> 'billed')::int, 0);
-- the runner claims it whatever the hour (the monthly run waits for its hour) and as a card charge
create temp table zrm_claim as select app.owner_debit_claim((current_date::timestamp + interval '1 minute') at time zone 'America/Toronto', 25) as c;
select test.eq('A the charge is claimed at once, as a card charge without a mandate',
  (select x ->> 'method_kind' || ' ' || (x ->> 'amount_cents') || ' ' || (x ->> 'payment_method_id') from zrm_claim, jsonb_array_elements(c) x
    where x ->> 'attempt_id' = (select a.id::text from owner_debit_attempts a where a.owner_invoice_id = (pg_temp.rw_inv('ZRM-C')).id)),
  (select 'card ' || i.total_cents || ' pm_zrm_card' from pg_temp.rw_inv('ZRM-C') i));
select app.owner_debit_submitted((select a.id from owner_debit_attempts a where a.owner_invoice_id = (pg_temp.rw_inv('ZRM-C')).id), '{"intent_id":"pi_zrm_c1","status":"processing"}');
select test.eq('A the card charge succeeding pays the invoice', app.owner_debit_result('pi_zrm_c1', '{"status":"succeeded","charge_id":"ch_zrm_c1"}') ->> 'invoice_status', 'paid');
select test.eq('A charge_after_rental never charges a renter for an owner-use booking',
  app.charge_after_rental(test.id('booking:ZRM-C'), test.id('zrm_admin')) ? 'owner_use', true);

-- ================================================================ B. no card: the bank debit the same day; it fails; due now; reminders
select pg_temp.rw_line('ZRM-P', 'cleaning', 7500);
select test.eq('B the job bills a charge once it has settled', (app.job_owner_use_charges(now() + interval '20 minutes') ->> 'billed')::int >= 1, true);
select test.eq('B the pre-authorized debit starts the same day, not on the 15th',
  (select a.method_kind || ' ' || a.immediate || ' ' || a.processor_mandate_id || ' ' || (a.debit_on = i.billing_date) || ' ' || i.owner_use_state
     from pg_temp.rw_inv('ZRM-P') i join owner_debit_attempts a on a.owner_invoice_id = i.id), 'pre_authorized_debit true mandate_zrm_pad true debit');
select app.owner_debit_claim(now(), 25);
select test.eq('B the bank returns it: no retry, the invoice is due now',
  app.owner_debit_fail((select a.id from owner_debit_attempts a where a.owner_invoice_id = (pg_temp.rw_inv('ZRM-P')).id), 'insufficient_funds', 'Insufficient funds') ->> 'invoice_status', 'issued');
select test.eq('B no Late Fee and no second attempt for an owner-use charge',
  (select count(*) from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-P')).id and kind = 'late_fee')
  + (select count(*) from owner_debit_attempts where owner_invoice_id = (pg_temp.rw_inv('ZRM-P')).id and status = 'scheduled'), 0::bigint);
select test.eq('B the owner gets the pay link and Admins the exception',
  (select (pg_temp.rw_inv('ZRM-P')).owner_use_state || ' ' || count(*) filter (where e.code = 'owner_use_charges' and e.payload ->> 'state' = 'pay_now' and (e.payload ->> 'pay_now')::boolean)
          || ' ' || count(*) filter (where e.code = 'staff_owner_debit_exception')
     from app_events e where e.created_at >= now() - interval '5 minutes'
      and (e.entity_id = (pg_temp.rw_inv('ZRM-P')).id or e.entity_id in (select a.id from owner_debit_attempts a where a.owner_invoice_id = (pg_temp.rw_inv('ZRM-P')).id))),
  'pay_now 1 1');
select test.eq('B a reminder after the reminder days', (app.job_owner_use_charges(now() + interval '2 days 1 hour') ->> 'reminded')::int, 1);
select test.eq('B the reminder is its own email',
  (select count(*) from app_events where code = 'owner_use_charges' and entity_id = (pg_temp.rw_inv('ZRM-P')).id and payload ->> 'state' = 'reminder'), 1::bigint);
select test.eq('B not again the same hour', (app.job_owner_use_charges(now() + interval '2 days 2 hours') ->> 'reminded')::int, 0);

-- ================================================================ C. no method on file: due now; damage up to the deductible
select pg_temp.rw_line('ZRM-N', 'damage_at_cost', 300000);
select pg_temp.rw_line('ZRM-N', 'ticket_amount', 12000);
select test.eq('C no method on file: an invoice due now with the pay link', app.owner_use_bill(test.id('booking:ZRM-N'), null, timestamptz '2035-03-10 15:00+00') ->> 'collect', 'pay_now');
select test.eq('C damage is billed up to the deductible, the ticket in full',
  (select string_agg(amount_cents::text, ',' order by sort_order) from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-N')).id), '250000,12000');
select test.ok('C the capped line says so', (select note like 'Damage is billed up to the $2,500.00 deductible%' from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-N')).id and sort_order = 1));
select test.eq('C no attempt is made without a method', (select count(*) from owner_debit_attempts where owner_invoice_id = (pg_temp.rw_inv('ZRM-N')).id), 0::bigint);
select pg_temp.rw_line('ZRM-N', 'damage_at_cost', 50000);
select test.eq('C more damage on the same booking is over the deductible: nothing more is invoiced',
  (app.owner_use_bill(test.id('booking:ZRM-N'), null, timestamptz '2035-03-10 16:00+00') ->> 'billed')::int, 0);

-- ================================================================ D. whichever comes first: 7 days, or the statement cut-off (the 7th)
select test.eq('D issued Nov 20: 7 days (Nov 27) come before the cut-off of Dec 7', app.owner_use_deduct_on(date '2026-11-20'), date '2026-11-27');
select test.eq('D issued Dec 3: the cut-off of Dec 7 comes before the 7 days (Dec 10)', app.owner_use_deduct_on(date '2026-12-03'), date '2026-12-07');
select test.eq('D issued on the cut-off day itself: that day''s statement takes it', app.owner_use_deduct_on(date '2026-12-07'), date '2026-12-07');
-- issued Mar 10, 2035 (C): 7 days first (Mar 17; the next cut-off is Apr 7)
select test.eq('D 7 days first: not on day 6', app.owner_use_fallback(test.id('owner:zrm_none'), timestamptz '2035-03-16 15:00+00'), 0);
select test.eq('D 7 days first: on day 7 it goes to the statement', app.owner_use_fallback(test.id('owner:zrm_none'), timestamptz '2035-03-17 15:00+00'), 1);
select test.eq('D it is now deducted from the next statement and the owner is told',
  (select i.collect_by || ' ' || i.owner_use_state || ' ' || i.owner_use_fallback_on || ' ' ||
          (select count(*) from app_events e where e.code = 'owner_use_charges' and e.entity_id = i.id and e.payload ->> 'state' = 'deducting')
     from pg_temp.rw_inv('ZRM-N') i), 'payout deducting 2035-03-17 1');
select test.eq('D the statements take an invoice handed to them (collect_by payout, issued)',
  (select count(*) from owner_invoices i where i.id = (pg_temp.rw_inv('ZRM-N')).id and i.collect_by = 'payout' and i.status in ('issued', 'failed')), 1::bigint);
-- issued Apr 5, 2035: the cut-off of Apr 7 comes first
select pg_temp.rw_line('ZRM-N2', 'fuel', 4000);
select app.owner_use_bill(test.id('booking:ZRM-N2'), null, timestamptz '2035-04-05 15:00+00');
select test.eq('D cut-off first: not the day before', app.owner_use_fallback(test.id('owner:zrm_none'), timestamptz '2035-04-06 15:00+00'), 0);
select test.eq('D cut-off first: on the 7th, after 2 days, it goes to that statement', app.owner_use_fallback(test.id('owner:zrm_none'), timestamptz '2035-04-07 15:00+00'), 1);
select test.eq('D cut-off first: recorded', (pg_temp.rw_inv('ZRM-N2')).collect_by || ' ' || (pg_temp.rw_inv('ZRM-N2')).owner_use_fallback_on, 'payout 2035-04-07');
-- paid in time: never deducted
select pg_temp.rw_line('ZRM-N3', 'fuel', 3000);
select app.owner_use_bill(test.id('booking:ZRM-N3'), null, timestamptz '2035-05-10 15:00+00');
select app.record_owner_invoice_payment((pg_temp.rw_inv('ZRM-N3')).id, jsonb_build_object('amount_cents', (pg_temp.rw_inv('ZRM-N3')).balance_cents, 'method', 'card', 'status', 'succeeded', 'processor', jsonb_build_object('name', 'stripe', 'payment_id', 'pi_zrm_n3')), test.id('zrm_admin'));
select test.eq('D an invoice paid from the link is never handed to the statement',
  app.owner_use_fallback(test.id('owner:zrm_none'), timestamptz '2035-06-30 15:00+00') || ' ' || (pg_temp.rw_inv('ZRM-N3')).status, '0 paid');

-- ================================================================ E. the evidence rules apply as usual; the charge functions accept an Owner Booking
update program_settings set fee_evidence_gate = true where id = (app.settings()).id;
select test.lives('E an Admin can add a fee to an owner-use booking',
  format($$select app.booking_fees_change(%L, jsonb_build_object('booking', 'ZRM-N4', 'reason', 'Smoking in the car',
    'lines', jsonb_build_array(jsonb_build_object('op', 'add', 'fee', 'smoking', 'amount_cents', 30000, 'note', 'Smelled of smoke at the return'))))$$, test.id('zrm_admin')));
select test.eq('E the fee waits for its evidence',
  (select evidence_status from booking_line_items where booking_id = test.id('booking:ZRM-N4') and charge_type = 'smoking' and voided_at is null), 'needs_evidence');
select test.eq('E a charge without its evidence is not billed to the owner',
  (select (x ->> 'billed') || ' ' || (x ->> 'waiting_for_evidence') from app.owner_use_bill(test.id('booking:ZRM-N4')) x), '0 1');
select app.fee_evidence_override(test.id('zrm_admin'), jsonb_build_object('line',
  (select id from booking_line_items where booking_id = test.id('booking:ZRM-N4') and charge_type = 'smoking' and voided_at is null), 'reason', 'The field report describes the smell and the ash'));
select test.eq('E with the evidence settled it is billed', (app.owner_use_bill(test.id('booking:ZRM-N4')) ->> 'billed')::int, 1);
select test.ok('E the invoice line carries the evidence it rests on',
  (select note like 'Evidence:%approved by an Admin%' from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-N4')).id));
update program_settings set owner_use_bill = false where id = (app.settings()).id;
select test.throws('E switched off, an Owner Booking has no fees as before',
  format($$select app.booking_fees_change(%L, jsonb_build_object('booking', 'ZRM-N4', 'reason', 'Cleaning after the trip',
    'lines', jsonb_build_array(jsonb_build_object('op', 'add', 'fee', 'cleaning', 'amount_cents', 7500, 'note', 'Crumbs'))))$$, test.id('zrm_admin')), 'owner booking has no fees');
update program_settings set owner_use_bill = true where id = (app.settings()).id;
select test.eq('E the email is in the catalogue as a charge notice nobody can switch off',
  (select c.pref_type || ' ' || t.locked from notification_catalogue c join notify_types t on t.code = c.pref_type where c.code = 'owner_use_charges'), 'charges true');

-- ================================================================ F. the Late Fee: 5% of the unpaid insurance
create function pg_temp.rw_monthly(p_label text, p_vehicle text, p_month date, p_insurance bigint, p_tracker bigint) returns uuid language plpgsql as $$
declare v_id uuid := test.id('oinv:' || p_label);
begin
  insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, billing_date, status)
  select v_id, v.owner_id, v.id, 'monthly', p_month, p_month + 14, 'draft' from vehicles v where v.id = test.id('vehicle:' || p_vehicle);
  if p_insurance > 0 then
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies) values (v_id, 'insurance_fee', 'Insurance Fee', p_insurance, false);
  end if;
  if p_tracker > 0 then
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values (v_id, 'tracker_fee', 'Tracker Fee', p_tracker, true, public.calc_hst(p_tracker));
  end if;
  perform set_config('app.invoice_quiet', v_id::text, true);
  update owner_invoices set status = 'issued' where id = v_id;
  perform set_config('app.invoice_quiet', '', true);
  return v_id;
end $$;
select test.eq('F the setting: 5%, with HST on the fee', (select owner_insurance_late_fee_bps || ' ' || owner_insurance_late_fee_hst || ' ' || owner_insurance_late_reminder_days from program_settings), '500 true 3');
select pg_temp.rw_monthly('zrm_m1', 'ZRMN', date '2035-08-01', 45000, 2500);
select test.eq('F nothing 4 days before the due date (the 15th)', (app.job_owner_insurance_late(timestamptz '2035-08-11 15:00+00') ->> 'reminded')::int, 0);
select test.eq('F the reminder 3 days before', (app.job_owner_insurance_late(timestamptz '2035-08-12 15:00+00') ->> 'reminded')::int, 1);
select test.eq('F the reminder names the fee that would be added',
  (select count(*) || ' ' || bool_and(not (payload ->> 'applied')::boolean and payload ->> 'late_fee_amount' = '$22.50') from app_events
    where code = 'owner_insurance_late_fee' and entity_id = test.id('oinv:zrm_m1')), '1 true');
select test.eq('F reminded once', (app.job_owner_insurance_late(timestamptz '2035-08-13 15:00+00') ->> 'reminded')::int, 0);
select test.eq('F not on the due date', (app.job_owner_insurance_late(timestamptz '2035-08-15 15:00+00') ->> 'applied')::int, 0);
select test.eq('F the day after the due date the Late Fee is added', (app.job_owner_insurance_late(timestamptz '2035-08-16 15:00+00') ->> 'applied')::int, 1);
select test.eq('F it is 5% of the unpaid insurance ($450.00), with HST on the fee, as its own line',
  (select amount_cents || ' ' || hst_cents || ' ' || hst_applies || ' ' || description from owner_invoice_lines where owner_invoice_id = test.id('oinv:zrm_m1') and kind = 'late_fee'),
  '2250 293 true Late Fee: 5% of the unpaid insurance ($450.00)');
select test.eq('F the insurance itself has no HST', (select hst_cents from owner_invoice_lines where owner_invoice_id = test.id('oinv:zrm_m1') and kind = 'insurance_fee'), 0::bigint);
select test.eq('F the invoice: the Late Fee apart from the fees, and both go to the next statement',
  (select late_fee_cents || ' ' || collect_by || ' ' || status from owner_invoices where id = test.id('oinv:zrm_m1')), '2250 payout issued');
select test.eq('F the owner is told when it is applied',
  (select count(*) from app_events where code = 'owner_insurance_late_fee' and entity_id = test.id('oinv:zrm_m1') and (payload ->> 'applied')::boolean), 1::bigint);
select test.eq('F never twice', (app.job_owner_insurance_late(timestamptz '2035-08-20 15:00+00') ->> 'applied')::int || ' ' || app.owner_late_fee_add(test.id('oinv:zrm_m1')), '0 0');
-- a failed debit (the status the bank's return sets) adds the same fee
select pg_temp.rw_monthly('zrm_m2', 'ZRMP', date '2035-08-01', 45000, 0);
update owner_invoices set status = 'processing' where id = test.id('oinv:zrm_m2');
update owner_invoices set status = 'failed' where id = test.id('oinv:zrm_m2');
select test.eq('F a failed debit: 5% of the unpaid insurance, not the flat $50',
  (select string_agg(amount_cents::text, ',') from owner_invoice_lines where owner_invoice_id = test.id('oinv:zrm_m2') and kind = 'late_fee'), '2250');
-- part paid: 5% of what is still unpaid
select pg_temp.rw_monthly('zrm_m3', 'ZRMC', date '2035-08-01', 40000, 0);
select app.record_owner_invoice_payment(test.id('oinv:zrm_m3'), jsonb_build_object('amount_cents', 30000, 'method', 'card', 'status', 'succeeded', 'processor', jsonb_build_object('name', 'stripe', 'payment_id', 'pi_zrm_m3')), test.id('zrm_admin'));
select test.eq('F part paid: the fee is on the part not paid', app.owner_invoice_unpaid_insurance(test.id('oinv:zrm_m3')), 10000::bigint);
-- HST switched off by the accountant
update program_settings set owner_insurance_late_fee_hst = false where id = (app.settings()).id;
select app.owner_late_fee_add(test.id('oinv:zrm_m3'));
select test.eq('F with HST off the fee has none', (select amount_cents || ' ' || hst_cents from owner_invoice_lines where owner_invoice_id = test.id('oinv:zrm_m3') and kind = 'late_fee'), '500 0');
update program_settings set owner_insurance_late_fee_hst = true where id = (app.settings()).id;
-- an invoice with no insurance keeps the flat Late Fee; an owner-use invoice never gets one
select pg_temp.rw_monthly('zrm_m4', 'ZRMC', date '2035-09-01', 0, 2500);
select test.eq('F no insurance on the invoice: the flat Late Fee', app.owner_late_fee_add(test.id('oinv:zrm_m4')), 5000::bigint);
select test.eq('F the job leaves an invoice without insurance and owner-use invoices alone',
  (select count(*) from owner_invoice_lines l join owner_invoices i on i.id = l.owner_invoice_id where l.kind = 'late_fee' and i.owner_use_booking_id is not null), 0::bigint);
select test.ok('F the statement shows the unpaid amount and the Late Fee as two lines',
  pg_get_functiondef('app.owner_statement_take_fees(uuid)'::regprocedure) like '%''Late Fee, invoice '' || inv.invoice_number%'
  and pg_get_functiondef('app.build_owner_statement_0025(uuid, date, uuid)'::regprocedure) like '%''Late Fee, invoice '' || inv.invoice_number%');
select test.ok('F the rule the owner reads says 5% of the unpaid insurance', app.owner_late_fee_rule() like '%5% of the unpaid insurance%two lines%');
select test.eq('F the updated owner agreement is published to accept, without signing again',
  (select requires_acceptance::text || ' ' || (body like '%5%% of the unpaid Insurance Fee%')::text from terms_versions where doc_key = 'owner_agreement' and version = 'owner-v4-r48rw'), 'true true');

-- ================================================================ G. the tolls, tickets and claim deductible of an Owner Booking (owner deductions) are due at once too
insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id) values
  (test.id('owner:zrm_none'), test.id('vehicle:ZRMN'), 'owner_booking_toll', 'Booking ZRM-N4: 407 ETR toll', 1840, date '2026-11-10', test.id('booking:ZRM-N4')),
  (test.id('owner:zrm_none'), test.id('vehicle:ZRMN'), 'owner_booking_deductible', 'Booking ZRM-N4, claim CL-1: deductible on an Owner Booking', 250000, date '2026-11-10', test.id('booking:ZRM-N4'));
select test.eq('G the toll and the deductible go on an invoice of the owner-use booking', (app.owner_use_bill(test.id('booking:ZRM-N4')) ->> 'billed')::int, 2);
select test.eq('G they are marked invoiced, so no statement deducts them a second time',
  (select string_agg(d.status || ':' || (d.owner_invoice_id = (pg_temp.rw_inv('ZRM-N4')).id), ',' order by d.amount_cents) from owner_deductions d where d.booking_id = test.id('booking:ZRM-N4')),
  'invoiced:true,invoiced:true');
select test.eq('G the invoice lines: the toll and the deductible in full (the deductible is the cap)',
  (select string_agg(amount_cents::text, ',' order by sort_order) from owner_invoice_lines where owner_invoice_id = (pg_temp.rw_inv('ZRM-N4')).id), '1840,250000');
