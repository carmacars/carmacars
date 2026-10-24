-- 32: the defects found while collecting the legal texts (migration 0051): one Late Fee rule, the settings in words,
-- the PAD notice days, the PAD confirmation, the amendment and paper countersignatures (also in 25 and 28), rentals
-- added by hand awaiting signature. Fixtures start with "lt".
select test.suite('32 legal texts');

select test.mk_user('lt_admin', 'admin');
select test.mk_owner('lt_olga');
select test.mk_vehicle('LTA', 'lt_olga', p_enrolled => date '2026-09-01');
select test.mk_renter('lt_rita');

create temp table lt as select null::text as k, null::jsonb as v limit 0;
create or replace function test.lt(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.lt where k = p_k $$;
-- the merge values of one email for an event that is not stored
create or replace function test.lt_payload(p_code text, p_entity text, p_id uuid, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select app.notification_payload(p_code, row(0, p_code, p_entity, p_id, p, 'lt:' || p_code, null, now(), null, null)::app_events, jsonb_build_object('audience', 'owner'))
$$;

-- ================================================================ 1. one Late Fee rule (Enrollment Agreement 4.4)
select test.eq('rule (0053): the approved sentence, word for word',
  app.owner_debit_terms() ->> 'late_fee_rule',
  'If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.');
select test.ok('rule: no email says an unpaid invoice takes a Late Fee (the code never adds one for that)',
  not exists (select 1 from notification_catalogue where concat(subject, preheader) ~* 'unpaid after its due date'));

-- the code: a returned automatic debit adds the Late Fee once; a debit the owner started from the invoice page does not
insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, billing_date, status)
values (test.id('lt_inv1'), test.id('owner:lt_olga'), test.id('vehicle:LTA'), 'monthly', date '2027-02-01', date '2027-02-15', 'draft'),
       (test.id('lt_inv2'), test.id('owner:lt_olga'), test.id('vehicle:LTA'), 'monthly', date '2027-03-01', date '2027-03-15', 'draft');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies)
values (test.id('lt_inv1'), 'insurance_fee', 'Insurance Fee', 45000, true), (test.id('lt_inv2'), 'insurance_fee', 'Insurance Fee', 45000, true);
update owner_invoices set status = 'issued' where id in (test.id('lt_inv1'), test.id('lt_inv2'));
select test.eq('rule: the same sentence in every owner billing email (debit notice, no debit on file, invoice, failed debit, in arrears)',
  (select count(distinct test.lt_payload(c, 'owner_invoice', i.id, jsonb_build_object('owner_id', i.owner_id)) ->> 'late_fee_rule')
     from unnest(array['owner_debit_notice', 'owner_debit_setup_needed', 'owner_fee_invoice', 'owner_payment_failed', 'owner_in_arrears']) c
     cross join (select * from owner_invoices where id = test.id('lt_inv1')) i), 1::bigint);
update owner_invoices set status = 'failed' where id = test.id('lt_inv1');
select test.eq('code: a returned debit adds the Late Fee to that invoice', (select late_fee_cents from owner_invoices where id = test.id('lt_inv1')), 5000::bigint);
update owner_invoices set status = 'retry_processing' where id = test.id('lt_inv1');
update owner_invoices set status = 'failed' where id = test.id('lt_inv1');
select test.eq('code: once per invoice, not again when the retry is returned', (select count(*) from owner_invoice_lines where owner_invoice_id = test.id('lt_inv1') and kind = 'late_fee'), 1::bigint);
select app.record_owner_invoice_payment(test.id('lt_inv2'), jsonb_build_object('status', 'pending', 'method', 'pre_authorized_debit', 'amount_cents', 50850,
  'processor', jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_lt_own')), null);
select app.record_owner_invoice_payment(test.id('lt_inv2'), jsonb_build_object('status', 'failed', 'method', 'pre_authorized_debit', 'amount_cents', 50850,
  'processor', jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_lt_own'), 'failure_message', 'NSF'), null);
select test.eq('code: a debit the owner started from the invoice page and the bank returned adds no Late Fee (the agreement says so)',
  (select status || '/' || late_fee_cents from owner_invoices where id = test.id('lt_inv2')), 'issued/0');
select test.ok('agreement: says what happens to a debit the owner started', app.owner_debit_terms() ->> 'own_debit_rule' like 'A debit you start yourself from an invoice page%adds no Late Fee%');

-- ================================================================ 2. the settings in words, never typed
select test.eq('words: the debit, retry and payout days, the day to approve by, and the other values the copy used to type',
  (select string_agg(k || '=' || (app.ntf_setting_words() ->> k), ',' order by k)
     from unnest(array['debit_day', 'retry_day', 'payout_day', 'approve_by_day', 'deductible_amount', 'non_refundable_percent', 'refund_days', 'arrears_removal_days']) k),
  'approve_by_day=9th,arrears_removal_days=30,debit_day=15th,deductible_amount=$2,500.00,non_refundable_percent=10%,payout_day=10th,refund_days=10,retry_day=18th');
select test.ok('words: the catalogue rows of 0051 read them (no typed 15th, 18th or 10th left in a subject or preheader)',
  not exists (select 1 from notification_catalogue where concat(subject, ' ', preheader) ~ '\m(15th|18th|10th|9th)\M')
  and (select preheader from notification_catalogue where code = 'owner_fee_invoice') like 'Due on {{due_date}}%');
update program_settings set billing_day = 20, retry_day = 23, payout_day = 12 where id = (app.settings()).id;
select test.eq('words: a change in Admin > Settings changes every text (rule, days, the invoice''s due date)',
  (app.owner_debit_terms() #>> '{agreement,personal,0}' like '%on the 20th of each month.') || '/' || (app.ntf_setting_words() ->> 'debit_day') || '/'
  || (app.ntf_setting_words() ->> 'payout_day') || '/' || (app.owner_debit_terms() ->> 'payout_day_text') || '/' || (app.owner_program_facts() ->> 'payout_day_text'),
  'true/20th/12th/12th/12th');
update program_settings set billing_day = 15, retry_day = 18, payout_day = 10 where id = (app.settings()).id;
select test.eq('words: the fee invoice email''s due date is the invoice''s',
  test.lt_payload('owner_fee_invoice', 'owner_invoice', test.id('lt_inv2')) ->> 'due_date', app.fmt_day(date '2027-03-15'));

-- ================================================================ 3. PAD notice days: at least 10 (Rule H1)
select test.throws('notice: fewer than 10 days is refused', format($$update program_settings set owner_debit_notice_days = 9 where id = %L$$, (app.settings()).id),
  'owner_debit_notice_days_check');
select test.lives('notice: 10 to 30 days are allowed', format($$update program_settings set owner_debit_notice_days = 30 where id = %L$$, (app.settings()).id));
update program_settings set owner_debit_notice_days = 10 where id = (app.settings()).id;
select test.eq('notice: 10 by default', (app.settings()).owner_debit_notice_days::integer, 10);

-- ================================================================ 4. the PAD confirmation
select app.owner_record_debit_setup(test.id('lt_olga'), test.id('owner:lt_olga'), '{"status":"requires_action","customer_id":"cus_lt","method_id":"pm_lt","mandate_id":"mandate_lt","bank":{"name":"Test Bank","last4":"4321"}}');
select test.eq('confirmation: none while the account is being confirmed', (select count(*) from app_events where code = 'owner_pad_confirmed'
  and (payload ->> 'owner_id')::uuid = test.id('owner:lt_olga')), 0::bigint);
select app.owner_debit_setup_verified('pm_lt', 'mandate_lt');
select app.owner_debit_setup_verified('pm_lt', 'mandate_lt');
select test.eq('confirmation: once, when the mandate becomes active', (select count(*) from app_events where code = 'owner_pad_confirmed'
  and (payload ->> 'owner_id')::uuid = test.id('owner:lt_olga')), 1::bigint);
select app.process_events(100000);
insert into lt select 'pad', (select payload from notification_outbox where code = 'owner_pad_confirmed' and to_address = 'lt_olga@example.test' order by created_at desc limit 1);
select test.eq('confirmation: to the owner, with the payee by its business name, the address and phone of the settings, the account, the type and the timing',
  (test.lt('pad') ->> 'payee_name') || '/' || (test.lt('pad') ->> 'payee_email') || '/' || (test.lt('pad') ->> 'payee_address' = app.ntf_contact() ->> 'company_address')
  || '/' || (test.lt('pad') ->> 'payee_phone' = app.ntf_contact() ->> 'support_phone') || '/' || (test.lt('pad') ->> 'bank_name') || ' ' || (test.lt('pad') ->> 'bank_last4')
  || '/' || (test.lt('pad') ->> 'agreement_type') || '/' || (test.lt('pad') ->> 'debit_day') || '/' || (test.lt('pad') ->> 'notice_days')
  || '/' || (test.lt('pad') ->> 'accepted_on' = app.fmt_day(app.today())) || '/' || (test.lt('pad') ->> 'late_fee_rule' = app.owner_debit_terms() ->> 'late_fee_rule'),
  (select company_legal_name || ', operating as ' || company_trade_name from app.settings()) || '/billing@carmacars.ca/true/true/Test Bank 4321/Personal/15th/10/true/true');
select test.ok('confirmation: the first automatic debit is at least 10 days after it (0053)',
  app.owner_debit_next_date(app.today()) >= app.today() + 10);
select test.eq('confirmation (0053): the full text of the accepted recurring agreement, below the summary, the payee "<legal name>, operating as <business name>" (0053, 0128)',
  (test.lt('pad') ->> 'agreement_1') || '|' || (test.lt('pad') ->> 'agreement_2') || '|' || (test.lt('pad') ->> 'agreement_3') || '|' || (test.lt('pad') ->> 'agreement_4'),
  (select string_agg(case when o = 1 then replace(x, 'You authorize ' || app.owner_payee_name() || ' to debit', 'You authorize ' || app.owner_email_payee_name() || ', to debit') else x end, '|' order by o)
     from jsonb_array_elements_text(app.owner_debit_terms() #> '{agreement,personal}') with ordinality t(x, o)));
select test.eq('payee (0053, 0122): always the legal name alone', app.owner_debit_terms() #>> '{payee,name}',
  (select company_legal_name from app.settings()));
select test.eq('confirmation: the catalogue row says what emits it', (select emitted_by from notification_catalogue where code = 'owner_pad_confirmed'),
  'owner_payment_methods_pad_confirmed (0051)');

-- ================================================================ 5. rentals added by hand: awaiting signature
insert into lt select 'car', app.vehicle_add(test.id('lt_admin'), '{"supply_type": "company", "vin": "1LTC0MPANY0000001", "plate": "LTCO 001",
  "year": 2024, "make": "Toyota", "model": "Corolla", "colour": "White", "rates": {"daily": 8000}}');
insert into lt select 'r1', app.manual_rental_create(test.id('lt_admin'), jsonb_build_object('vehicle_id', test.lt('car') ->> 'vehicle_id',
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '4 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:lt_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')));
create or replace function test.ltb() returns uuid language sql stable as $$ select (test.lt('r1') ->> 'booking_id')::uuid $$;
select test.eq('awaiting: a rental added by hand is confirmed but awaiting signature, not ready for handover',
  (select b.status::text from bookings b where b.id = test.ltb()) || '/' || (app.booking_readiness(test.ltb()) ->> 'awaiting_signature') || '/'
  || (app.booking_readiness(test.ltb()) ->> 'ready_for_handover'), 'confirmed/true/false');
select test.eq('awaiting: the Admin list shows it', (app.admin_list(test.id('lt_admin'), 'bookings', jsonb_build_object('eq', jsonb_build_object('id', test.ltb()))) #>> '{rows,0,awaiting_signature}'), 'true');
select test.throws('awaiting: the car is not released before the renter signs', format($$update bookings set status = 'on_rent' where id = %L$$, test.ltb()),
  'has not signed the rental agreement');
select app.open_rental_agreement(test.ltb(), test.id('lt_admin'), 'v2-test', repeat('c', 64), 'bookings/lt/ra.pdf');
select app.record_signature((select signature_request_id from rental_agreements where booking_id = test.ltb()),
  (select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = test.ltb() and g.signer_role = 'renter'),
  'Lt Rita', null, null, 'test', 'I sign this agreement.', repeat('c', 64), null);
select test.eq('awaiting: no longer once the renter has signed and CarmaCars countersigned',
  (app.booking_readiness(test.ltb()) ->> 'awaiting_signature') || '/' || (app.booking_readiness(test.ltb()) -> 'missing' ? 'agreement')::text, 'false/false');
insert into lt select 'past', app.manual_rental_create(test.id('lt_admin'), jsonb_build_object('vehicle_id', test.lt('car') ->> 'vehicle_id',
  'pickup_at', date_trunc('hour', now()) - interval '20 days', 'return_at', date_trunc('hour', now()) - interval '18 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:lt_rita'), 'past', true, 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')));
select test.eq('awaiting: a past rental recorded for history is not concerned', app.booking_awaiting_signature((test.lt('past') ->> 'booking_id')::uuid), false);
select test.eq('awaiting: a booking made online (signed before it was confirmed) is not concerned',
  (select count(*) from bookings b where not b.added_by_staff and app.booking_awaiting_signature(b.id)), 0::bigint);
