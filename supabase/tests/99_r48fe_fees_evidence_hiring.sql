-- 99: release 48, part FE (migrations 3190 to 3192): return charges (non-return, improper return, theft recovery, tires and
-- roadside), evidence for every fee (the registry, needs evidence, the statement gate, attach and override), cleanliness
-- evidence at the return, the dispute kit's evidence and deadline alerts, and the hiring funnel (Yes, put me in Sales, the
-- re-send, the Sales bar, academy nudges, WhatsApp member tags and links).
-- Fixtures start with "fe"; the months are 2035, where no other test puts money.

select test.suite('99 r48 FE: return charges and evidence');
select test.mk_user('fe_admin', 'admin');
select test.mk_user('fe_fin', 'va', 'finance');
select test.mk_user('fe_fleet', 'va', 'fleet');
select test.mk_user('fe_sales', 'va', 'sales');
select test.mk_owner('fe_own');
select test.mk_vehicle('FE1', 'fe_own', p_enrolled => date '2035-01-01');
select test.mk_renter('fe_r1', false);
select test.mk_renter('fe_r2', false);
select test.mk_booking('FE-1', 'FE1', 'fe_r1', '2035-03-01 10:00', '2035-03-05 10:00', 'returned', p_checked_in => '2035-03-05 16:00');
select test.mk_booking('FE-2', 'FE1', 'fe_r2', '2035-04-01 10:00', '2035-04-04 10:00', 'returned');
select test.mk_booking('FE-0', 'FE1', 'fe_r1', '2035-02-01 10:00', '2035-02-03 10:00', 'closed');

select test.eq('the defaults: non-return $1,000, improper $250, theft $1,500, roadside admin $50, the gate on, 3 photos',
  (select non_return_fee_cents || '/' || improper_return_fee_cents || '/' || theft_recovery_fee_cents || '/' || roadside_admin_fee_cents || '/' || fee_evidence_gate || '/' || clean_evidence_min_photos from app.settings() x),
  '100000/25000/150000/5000/true/3');
select test.eq('the new fees are company revenue with HST; the costs pass through',
  (select string_agg(code || ':' || revenue_class || ':' || hst_applies, ' ' order by code) from fee_types where code in ('non_return_fee', 'improper_return_fee', 'theft_recovery_fee', 'roadside_admin_fee', 'tire_cost')),
  'improper_return_fee:company_only:true non_return_fee:company_only:true roadside_admin_fee:company_only:true theft_recovery_fee:company_only:true tire_cost:pass_through:false');
select test.ok('the registry covers every fee the owner listed',
  (select count(*) = 22 from fee_evidence_rules where fee_code in ('late_return_fee', 'mileage_overage', 'fuel', 'toll_amount', 'ticket_amount', 'speeding_180', 'smoking', 'cleaning',
     'damage_at_cost', 'non_return_fee', 'improper_return_fee', 'theft_recovery_fee', 'tire_cost', 'roadside_callout', 'roadside_admin_fee', 'addon', 'young_driver_18_20', 'delivery',
     'cleaning_heavy', 'pet_cleaning', 'recovery_cost', 'speeding_300')));

-- the return charges: who, the reasons, the mechanical fault
select test.throws('Sales does not add a return charge',
  format($$select app.return_charge_add(%L, '{"booking": "FE-1", "kind": "improper_return", "reason": "unlocked", "note": "Left unlocked"}')$$, test.id('fe_sales')), 'Fleet');
select test.throws('an improper return says what was wrong',
  format($$select app.return_charge_add(%L, '{"booking": "FE-1", "kind": "improper_return", "note": "Left somewhere"}')$$, test.id('fe_fleet')), 'wrong_place');
select test.throws('a mechanical fault that is not the renter''s is not charged',
  format($$select app.return_charge_add(%L, '{"booking": "FE-1", "kind": "tire", "mechanical_fault": true, "note": "Bearing failed", "costs": [{"amount_cents": 20000}]}')$$, test.id('fe_fleet')), 'mechanical fault');
select test.throws('a roadside charge needs the actual cost',
  format($$select app.return_charge_add(%L, '{"booking": "FE-1", "kind": "roadside", "note": "Boost at the mall"}')$$, test.id('fe_fleet')), 'actual cost');

select app.return_charge_add(test.id('fe_fleet'), '{"booking": "FE-1", "kind": "improper_return", "reason": "unlocked", "note": "Left unlocked on the street with the windows open"}'::jsonb);
select test.eq('an improper return: $250 plus HST, company revenue, waiting for photos or the Tracker',
  (select amount_cents || '/' || hst_cents || '/' || evidence_status || '/' || array_to_string(evidence_missing, ',') from booking_line_items
    where booking_id = test.id('booking:FE-1') and charge_type = 'improper_return_fee'), '25000/3250/needs_evidence/improper_proof');
select test.eq('a To do asks Field for exactly what is missing (the fleet queue)',
  (select queue || '/' || (title like 'Field: Evidence needed:%')::text || '/' || (detail like '%photos or the Tracker location at the return%')::text from tasks
    where dedupe_key = 'fee_evidence:' || (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'improper_return_fee') and status = 'open'),
  'fleet/true/true');
select app.fee_evidence_attach(test.id('fe_fleet'), jsonb_build_object('line', (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'improper_return_fee'),
  'kind', 'photo', 'photo_ids', '["p1", "p2"]'::jsonb, 'note', 'The car on the street, doors unlocked'));
select test.eq('photos attached: the evidence is complete and the To do is done',
  (select li.evidence_status || '/' || t.status from booking_line_items li join tasks t on t.dedupe_key = 'fee_evidence:' || li.id
    where li.booking_id = test.id('booking:FE-1') and li.charge_type = 'improper_return_fee'), 'ok/done');

-- roadside: the cost with its invoice, the $50 with it
select app.return_charge_add(test.id('fe_fleet'), '{"booking": "FE-1", "kind": "roadside", "note": "Lockout at the mall", "costs": [{"label": "Lockout service", "amount_cents": 9500}]}'::jsonb);
select test.eq('roadside: the cost and the $50 wait for the invoice',
  (select string_agg(charge_type || ':' || amount_cents || ':' || evidence_status, ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:FE-1') and charge_type in ('roadside_callout', 'roadside_admin_fee')),
  'roadside_admin_fee:5000:needs_evidence roadside_callout:9500:needs_evidence');
insert into documents (id, kind, title, storage_bucket, storage_path, booking_id) values (test.id('doc:fe-inv'), 'receipt', 'Lockout invoice', 'documents', 'fe/lockout.pdf', test.id('booking:FE-1'));
select app.fee_evidence_attach(test.id('fe_fin'), jsonb_build_object('line', (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'roadside_callout'),
  'kind', 'invoice', 'document_id', test.id('doc:fe-inv')));
select test.eq('the invoice on the cost satisfies both lines',
  (select string_agg(evidence_status, ' ' order by charge_type) from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type in ('roadside_callout', 'roadside_admin_fee')), 'ok ok');

-- non-return: the final notice's deadline and the Tracker
select app.return_charge_add(test.id('fe_admin'), '{"booking": "FE-1", "kind": "non_return", "note": "Not back after the final notice", "costs": [{"label": "Tow and impound", "amount_cents": 42000}]}'::jsonb);
select test.eq('non-return without the final notice or Tracker readings waits',
  (select evidence_status || '/' || array_to_string(evidence_missing, ',') from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'non_return_fee'),
  'needs_evidence/final_notice,tracker_map');
select test.throws('a second non-return charge on the same booking is refused',
  format($$select app.return_charge_add(%L, '{"booking": "FE-1", "kind": "non_return", "note": "Again please"}')$$, test.id('fe_admin')), 'already has');
insert into notification_outbox (code, category, priority, audience, booking_id, payload, dedupe_key, status, send_after, sent_at, created_at)
values ('renter_late_return_final', 'transactional', 1, 'renter', test.id('booking:FE-1'), '{}'::jsonb, 'fe-final-1', 'sent', '2035-03-05 12:00-05', '2035-03-05 12:00-05', '2035-03-05 12:00-05');
insert into tracker_points (vehicle_id, at, lat_e6, lng_e6, speed_kmh, ignition)
values (test.id('vehicle:FE1'), '2035-03-05 15:50-05', 43650000, -79380000, 0, false), (test.id('vehicle:FE1'), '2035-03-03 15:50-05', 43700000, -79400000, 64, true);
select app.fee_evidence_recheck(test.id('booking:FE-1'));
select test.eq('the final notice sent 4 hours before the return and the Tracker readings: complete',
  (select evidence_status from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'non_return_fee'), 'ok');
select test.eq('the recovery cost still needs its receipt', (select evidence_status from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'recovery_cost'), 'needs_evidence');

-- override: an Admin only, with the reason
select test.throws('Finance does not override evidence',
  format($$select app.fee_evidence_override(%L, jsonb_build_object('line', %L, 'reason', 'The tow company never sends invoices'))$$, test.id('fe_fin'),
    (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'recovery_cost')), 'Admin');
select test.throws('an override says why',
  format($$select app.fee_evidence_override(%L, jsonb_build_object('line', %L, 'reason', 'no'))$$, test.id('fe_admin'),
    (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'recovery_cost')), 'Say why');
select app.fee_evidence_override(test.id('fe_admin'), jsonb_build_object('line', (select id from booking_line_items where booking_id = test.id('booking:FE-1') and charge_type = 'recovery_cost'),
  'reason', 'Paid in cash at the pound, the receipt was lost'));
select test.eq('overridden, kept with the reason and the To do closed',
  (select li.evidence_status || '/' || li.evidence_override_reason || '/' || t.status from booking_line_items li join tasks t on t.dedupe_key = 'fee_evidence:' || li.id
    where li.booking_id = test.id('booking:FE-1') and li.charge_type = 'recovery_cost'), 'overridden/Paid in cash at the pound, the receipt was lost/done');

-- the statement leaves out a fee that needs evidence
select test.suite('99 r48 FE: the statement gate');
insert into condition_reports (id, vehicle_id, booking_id, kind, performed_by, performed_by_role, completed_at, reviewed_at, reviewed_by, cleanliness, odometer_km, fuel_pct, keys_count)
values (test.id('cr:FE-2:return'), test.id('vehicle:FE1'), test.id('booking:FE-2'), 'return', test.id('fe_fleet'), 'staff', now(), now(), test.id('fe_fleet'), 'smoking', 12000, 80, 1);
select app.booking_fees_change(test.id('fe_admin'), jsonb_build_object('booking', 'FE-2', 'reason', 'Smoking in the car',
  'lines', jsonb_build_array(jsonb_build_object('op', 'add', 'fee', 'smoking', 'amount_cents', 30000, 'note', 'Smelled of smoke at the return'),
                             jsonb_build_object('op', 'add', 'fee', 'cleaning', 'amount_cents', 7500, 'note', 'Crumbs on every seat'))));
select test.eq('change_booking_fees: both fees wait for the guided photos and the description',
  (select string_agg(charge_type || ':' || evidence_status || ':' || array_to_string(evidence_missing, ','), ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:FE-2') and charge_type in ('smoking', 'cleaning')),
  'cleaning:needs_evidence:clean_description,guided_photos smoking:needs_evidence:clean_description,guided_photos');
-- the description on the report and the cleaning fee's photos: the cleaning fee is complete, the smoking fee is not
update condition_reports set clean_evidence = '{"description": "Strong smoke smell in the cabin, ash in both cupholders"}' where id = test.id('cr:FE-2:return');
select app.fee_evidence_attach(test.id('fe_fleet'), jsonb_build_object('line', (select id from booking_line_items where booking_id = test.id('booking:FE-2') and charge_type = 'cleaning'),
  'kind', 'photo', 'photo_ids', '["c1", "c2", "c3"]'::jsonb));
select test.eq('the cleaning fee is complete; the smoking fee still waits',
  (select string_agg(charge_type || ':' || evidence_status, ' ' order by charge_type) from booking_line_items where booking_id = test.id('booking:FE-2') and charge_type in ('smoking', 'cleaning')),
  'cleaning:ok smoking:needs_evidence');
select app.issue_booking_statement(test.id('booking:FE-2'), test.id('fe_fin'));
select test.eq('the Check-out statement carries the cleaning fee and holds the smoking fee back',
  (select string_agg(charge_type || ':' || (statement_id is not null)::text, ' ' order by charge_type) from booking_line_items where booking_id = test.id('booking:FE-2') and charge_type in ('smoking', 'cleaning')),
  'cleaning:true smoking:false');
select test.throws('a later statement with only the held fee says what is missing',
  format($$select app.issue_booking_statement(%L, %L)$$, test.id('booking:FE-2'), test.id('fe_fin')), 'Waiting for evidence');
select test.eq('charging after the rental waits for the evidence (nothing issued, nothing raised)',
  (select app.charge_after_rental(test.id('booking:FE-2'), test.id('fe_fin')) ->> 'waiting_for'), 'evidence');
-- the guided photos arrive on the report: the smoking fee is complete, Finance is asked to bill it
insert into condition_report_photos (condition_report_id, seq, shot, storage_path, latitude, longitude)
values (test.id('cr:FE-2:return'), 40, 'clean_ash', 'fe/40.jpg', 43.65, -79.38), (test.id('cr:FE-2:return'), 41, 'clean_seats', 'fe/41.jpg', 43.65, -79.38),
       (test.id('cr:FE-2:return'), 42, 'clean_headliner', 'fe/42.jpg', 43.65, -79.38);
select test.eq('three guided photos and the description: complete, and Finance has a To do to bill it',
  (select li.evidence_status || '/' || t.queue from booking_line_items li join tasks t on t.dedupe_key = 'fee_evidence_ready:' || li.id
    where li.booking_id = test.id('booking:FE-2') and li.charge_type = 'smoking'), 'ok/finance');
select app.issue_booking_statement(test.id('booking:FE-2'), test.id('fe_fin'));
select test.eq('the later statement bills it and closes the To do',
  (select (li.statement_id is not null)::text || '/' || t.status from booking_line_items li join tasks t on t.dedupe_key = 'fee_evidence_ready:' || li.id
    where li.booking_id = test.id('booking:FE-2') and li.charge_type = 'smoking'), 'true/done');
select test.eq('a booking-stage fee needs no evidence beyond the booking', (select evidence_status from booking_line_items where booking_id = test.id('booking:FE-2') and charge_type = 'rental_charge'), 'not_required');

-- the cleanliness rule of the return (the Checklist and the staff check-in complete through app.complete_return)
select test.suite('99 r48 FE: cleanliness evidence at the return');
insert into condition_reports (id, vehicle_id, booking_id, kind, performed_by, performed_by_role, cleanliness)
values (test.id('cr:FE-0:return'), test.id('vehicle:FE1'), test.id('booking:FE-0'), 'return', test.id('fe_fleet'), 'staff', 'heavy');
select test.ok('not clean and no photos: completing the return is refused with what to take',
  app.clean_evidence_missing(test.id('cr:FE-0:return')) like 'The car is not clean: take 3 or more evidence photos%');
insert into condition_report_photos (condition_report_id, seq, shot, storage_path)
values (test.id('cr:FE-0:return'), 40, 'clean_floor', 'fe/a.jpg'), (test.id('cr:FE-0:return'), 41, 'clean_seats', 'fe/b.jpg'), (test.id('cr:FE-0:return'), 42, 'clean_cupholders', 'fe/c.jpg');
select test.ok('three photos but no description: still refused', app.clean_evidence_missing(test.id('cr:FE-0:return')) like '%describe it in writing%');
update condition_reports set clean_evidence = '{"description": "Mud on the rear floor and seats, wet dog smell"}' where id = test.id('cr:FE-0:return');
select test.ok('photos and description: nothing missing', app.clean_evidence_missing(test.id('cr:FE-0:return')) is null);
update condition_reports set cleanliness = 'clean', clean_evidence = '{}' where id = test.id('cr:FE-0:return');
select test.ok('a clean car needs nothing', app.clean_evidence_missing(test.id('cr:FE-0:return')) is null);
select test.ok('the guided shots are allowed on a photo', exists (select 1 from condition_report_photos where shot = 'clean_ash'));

-- ================================================================ the dispute kit
select test.suite('99 r48 FE: the dispute kit');
insert into dispute_packs (id, booking_id, variant) values (test.id('pack:FE-1'), test.id('booking:FE-1'), 'small_claims');
select test.eq('every extra charge carries its clause',
  (select string_agg(distinct c ->> 'clause', ' | ' order by c ->> 'clause') from jsonb_array_elements(public.server_dispute_evidence(test.id('pack:FE-1')) -> 'charges') c
    where c ->> 'charge_type' in ('improper_return_fee', 'non_return_fee')), '10.6 Non-return | 10.7 Improper return');
select test.eq('the evidence found is in the pack (the final notice, the Tracker readings) with the route',
  (select (c -> 'evidence' ? 'final_notice')::text || '/' || (c -> 'tracker' ->> 'kind') || '/' || (jsonb_array_length(c -> 'tracker' -> 'points') > 0)::text
     from jsonb_array_elements(public.server_dispute_evidence(test.id('pack:FE-1')) -> 'charges') c where c ->> 'charge_type' = 'non_return_fee'), 'true/route/true');
select test.eq('the receipts attached to a charge are listed with it',
  (select c -> 'documents' -> 0 ->> 'title' from jsonb_array_elements(public.server_dispute_evidence(test.id('pack:FE-1')) -> 'charges') c where c ->> 'charge_type' = 'roadside_callout'), 'Lockout invoice');
select test.eq('the previous trips of the same person, the variant, the offline payments',
  (select jsonb_array_length(v -> 'history' -> 'same_person') || '/' || (v ->> 'variant') || '/' || jsonb_typeof(v -> 'offline') from (select public.server_dispute_evidence(test.id('pack:FE-1')) v) x),
  '1/small_claims/array');
select test.ok('the identity checks and the staff notes are in the pack',
  (select jsonb_typeof(v -> 'identity') = 'array' and jsonb_typeof(v -> 'staff_notes') = 'array' and jsonb_typeof(v -> 'renter_replies') = 'array' from (select public.server_dispute_evidence(test.id('pack:FE-1')) v) x));
select test.eq('a non-card pack is built from the booking by an Admin', (select app.dispute_pack_build_variant(test.id('fe_admin'), '{"booking": "FE-2", "variant": "etransfer_cash"}'::jsonb) ->> 'variant'), 'etransfer_cash');
select test.throws('Sales does not build a dispute pack', format($$select app.dispute_pack_build_variant(%L, '{"booking": "FE-2", "variant": "insurer"}')$$, test.id('fe_sales')), 'Admin');
-- a Stripe dispute: the pack is queued by itself, and the deadline alerts go once each
insert into disputes (id, payment_id, booking_id, processor_dispute_ref, amount_cents, reason, status, evidence_due_at)
values (test.id('dispute:FE-2'), (select id from payments where booking_id = test.id('booking:FE-2') limit 1), test.id('booking:FE-2'), 'dp_fe2', 37500, 'fraudulent', 'open', now() + interval '36 hours');
select test.ok('the Stripe dispute queued its pack', exists (select 1 from dispute_packs where dispute_id = test.id('dispute:FE-2')));
select test.eq('the deadline alert (2 days) goes once', (select app.dispute_deadline_alerts(now()) || '/' || app.dispute_deadline_alerts(now())), '1/0');
select test.eq('the next alert under a day before', (select app.dispute_deadline_alerts(now() + interval '13 hours')), 1);

-- ================================================================ hiring
select test.suite('99 r48 FE: hiring');
insert into job_applications (id, role_id, status, full_name, email, phone, answers, referred_role_id, location_country)
values (test.id('app:fe-cs'), (select id from hiring_roles where slug = 'va-customer-service'), 'referred', 'Fe Applicant', 'fe.applicant@example.test', '+639170000000',
        '{"years": 3}', (select id from hiring_roles where slug = 'sales-remote'), 'PH');
select test.eq('the one-click page knows the person and the Sales role',
  (select (v ->> 'first_name') || '/' || (v ->> 'eligible') || '/' || (v ->> 'done') from (select public.server_hiring_sales_offer((select token from job_applications where id = test.id('app:fe-cs')))) x(v)),
  'Fe/true/false');
select test.eq('Yes, put me in Sales: the Sales application is made from theirs and the interview link goes at once',
  (select (v ->> 'interview_state') || '/' || ((v ->> 'interview_url') like '%/careers/interview/%')::text from (select public.server_hiring_sales_yes((select token from job_applications where id = test.id('app:fe-cs')))) x(v)),
  'sent/true');
select test.eq('the new application: Sales, invited, from the referral, with their answers and phone',
  (select r.slug || '/' || a.status || '/' || a.source || '/' || (a.answers ->> 'years') || '/' || a.phone from job_applications a join hiring_roles r on r.id = a.role_id
    where a.referred_from = test.id('app:fe-cs')), 'sales-remote/invited/referral/3/+639170000000');
select public.server_hiring_sales_yes((select token from job_applications where id = test.id('app:fe-cs')));
select test.eq('pressing again makes no second application', (select count(*) from job_applications where referred_from = test.id('app:fe-cs')), 1::bigint);
select test.ok('the referral email links to the one click', position('/careers/sales-yes/' in pg_get_functiondef('app.hiring_decision_apply(uuid, uuid)'::regprocedure)) > 0);

-- the bar: a Sales applicant at 87 whom the AI recommended declining, with an answer at 5, passes; another role does not
insert into job_applications (id, role_id, status, full_name, email) values
  (test.id('app:fe-s87'), (select id from hiring_roles where slug = 'sales-remote'), 'interviewed', 'Fe Eighty Seven', 'fe.87@example.test'),
  (test.id('app:fe-c87'), (select id from hiring_roles where slug = 'va-customer-service'), 'interviewed', 'Fe Cs Eighty Seven', 'fe.c87@example.test'),
  (test.id('app:fe-s79'), (select id from hiring_roles where slug = 'sales-remote'), 'interviewed', 'Fe Seventy Nine', 'fe.79@example.test');
insert into ai_interviews (application_id, role_id, questions, expires_at, state, interview_score, recommendation, result)
select a.id, a.role_id, '[]'::jsonb, now() + interval '7 days', 'scored', s, 'decline',
       '{"english": {"level": "good"}, "answers": [{"seq": 1, "score": 9}, {"seq": 2, "score": 5}, {"seq": 3, "score": 6}]}'::jsonb
  from job_applications a, (values (test.id('app:fe-s87'), 87), (test.id('app:fe-c87'), 87), (test.id('app:fe-s79'), 79)) v(id, s) where a.id = v.id;
select test.eq('Sales at 87 passes; customer service at 87 with "decline" does not; Sales at 79 is under the bar',
  (select string_agg(a.full_name || ':' || app.ai_interview_passes(i, a, r), ' ' order by a.full_name) from job_applications a join ai_interviews i on i.application_id = a.id join hiring_roles r on r.id = a.role_id
    where a.id in (test.id('app:fe-s87'), test.id('app:fe-c87'), test.id('app:fe-s79'))),
  'Fe Cs Eighty Seven:false Fe Eighty Seven:true Fe Seventy Nine:false');
select test.eq('the reasons in words', (select array_to_string(app.ai_interview_fail_reasons(i, a, r), '; ') from job_applications a join ai_interviews i on i.application_id = a.id
    join hiring_roles r on r.id = a.role_id where a.id = test.id('app:fe-s79')), 'score 79 under the bar of 80');
update ai_interviews set result = jsonb_set(result, '{english,level}', '"basic"') where application_id = test.id('app:fe-s87');
select test.eq('a passed interview is still required: basic English does not pass',
  (select app.ai_interview_passes(i, a, r) from job_applications a join ai_interviews i on i.application_id = a.id join hiring_roles r on r.id = a.role_id where a.id = test.id('app:fe-s87')), false);

-- the re-send: once per email, sent by the job
insert into job_applications (id, role_id, status, full_name, email, referred_role_id) values
  (test.id('app:fe-ref2'), (select id from hiring_roles where slug = 'va-fleet-operations'), 'referred', 'Fe Second', 'fe.second@example.test', (select id from hiring_roles where slug = 'sales-remote'));
insert into hiring_resends (application_id, kind, email, due_at) values (test.id('app:fe-ref2'), 'sales_referral', 'fe.second@example.test', now() - interval '1 minute');
select test.throws('the same email is listed once', $$insert into hiring_resends (application_id, kind, email, due_at) values ('$$ || test.id('app:fe-cs') || $$', 'sales_referral', 'FE.second@example.test', now())$$, 'duplicate');
select app.hiring_resends_run(now());
select test.eq('the job sends it once', (select result from hiring_resends where application_id = test.id('app:fe-ref2')), 'sent');
select test.eq('and never again', app.hiring_resends_run(now()), 0);

-- WhatsApp: the member tag, the links, the Sales group for who passed the Sales path
select test.suite('99 r48 FE: onboarding WhatsApp and the academy');
update staff_profiles set functions = '{sales}' where user_id = test.id('fe_sales');
update users set full_name = 'Darren Fe' where id = test.id('fe_sales');
select test.eq('the member tag: first name and position', app.staff_member_tag(test.id('fe_sales')), 'Darren - Sales');
select test.eq('each group shows the tag', (select string_agg((g ->> 'key') || ':' || (g ->> 'member_tag'), ' ' order by g ->> 'key') from jsonb_array_elements(app.staff_group_list(test.id('fe_sales'))) g),
  'sales:Darren - Sales team:Darren - Sales');
select test.throws('"I joined" needs "I set my member tag"', format($$select app.staff_whatsapp_confirm(%L, '{"sales": true, "team": true}')$$, test.id('fe_sales')), 'member tag');
select test.eq('with the tag ticked the groups are confirmed',
  (select app.staff_whatsapp_confirm(test.id('fe_sales'), '{"sales": true, "team": true, "tag_set": true}'::jsonb) ->> 'done'), 'true');
select test.ok('and the tag is kept as set', (select whatsapp_tag_set_at is not null from staff_profiles where user_id = test.id('fe_sales')));
select test.eq('field staff who did not pass the Sales path see the Team group only',
  (select string_agg(g ->> 'key', ',') from jsonb_array_elements(app.staff_group_list(test.id('fe_fleet'))) g), 'team');
select test.ok('the empty links are named', app.whatsapp_links_missing() @> array['whatsapp_team_group_url', 'whatsapp_sales_group_url']);
select app.whatsapp_links_check();
select test.ok('an Admin To do stays open while a link is empty', exists (select 1 from tasks where dedupe_key = 'whatsapp_links_missing' and status = 'open' and queue = 'admin'));
create temp table fe_links as select id, whatsapp_team_group_url t, whatsapp_sales_group_url s from program_settings;
update program_settings set whatsapp_team_group_url = 'https://chat.whatsapp.com/FeTeamLink12345', whatsapp_sales_group_url = 'https://chat.whatsapp.com/FeSalesLink1234';
select app.whatsapp_links_check();
select test.ok('both links set: the To do is done', exists (select 1 from tasks where dedupe_key = 'whatsapp_links_missing' and status = 'done'));
update program_settings p set whatsapp_team_group_url = f.t, whatsapp_sales_group_url = f.s from fe_links f where f.id = p.id;

-- academy progress for Sales, and the nudges at day 1, 2 and 4
select test.ok('the Sales path progress of a Sales staff member', (select (app.sales_academy_progress(test.id('fe_sales')) ->> 'total')::int > 0));
select test.ok('the counts for Admin', (select jsonb_typeof(app.sales_academy_counts() -> 'not_started') = 'number'));
select test.mk_user('fe_new_sales', 'va', 'sales');
update staff_profiles set functions = '{sales}', onboarding_exempt = false, agreement_waived_at = now() where user_id = test.id('fe_new_sales'); -- 3198: the agreement comes first
update staff_profiles set created_at = now() - interval '3 days' where user_id = test.id('fe_new_sales');
insert into academy_enrollments (user_id, path_code, enrolled_at) values (test.id('fe_new_sales'), 'sales_remote', now() - interval '3 days') on conflict do nothing;
update academy_enrollments set enrolled_at = now() - interval '3 days' where user_id = test.id('fe_new_sales');
create temp table fe_gate as select id, academy_gate g from program_settings;
update program_settings set academy_gate = true;
select test.eq('three days without progress: one nudge', app.academy_nudges_run(now()), 1);
select test.eq('the day 2 nudge, to the person', (select string_agg(day::text, ',') from academy_nudges where user_id = test.id('fe_new_sales')), '2');
select test.eq('not twice', app.academy_nudges_run(now()), 0);
select test.eq('two more days: the day 4 nudge', (select app.academy_nudges_run(now() + interval '2 days')), 1);
update program_settings p set academy_gate = f.g from fe_gate f where f.id = p.id;

-- ================================================================ owner use (3195)
select test.suite('99 r48 FE: owner use of their own car');
select test.mk_owner('fe_karan');
select test.mk_vehicle('FEK', 'fe_karan', p_enrolled => date '2035-01-01');
-- the status of each case is set straight (the status flow's own rules are not what is tested here)
alter table vehicles disable trigger a0_status_flow;
update vehicles set status = 'onboarding' where id = test.id('vehicle:FEK');
create temp table fe_ob as select app.owner_book_own_vehicle(test.id('fe_karan'), test.id('vehicle:FEK'), now() + interval '40 days', now() + interval '42 days', 'Family trip') as id;
select test.eq('a car still onboarding can be booked by its owner (Karan''s Sonata)', (select booking_type::text from bookings where id = (select id from fe_ob)), 'owner');
update vehicles set status = 'out_of_service' where id = test.id('vehicle:FEK');
select test.throws('a car out of service says why', format($$select app.owner_book_own_vehicle(%L, %L, now() + interval '50 days', now() + interval '51 days')$$, test.id('fe_karan'), test.id('vehicle:FEK')), 'out of service');
update vehicles set status = 'exited' where id = test.id('vehicle:FEK');
select test.throws('a car no longer in the program says why', format($$select app.owner_book_own_vehicle(%L, %L, now() + interval '50 days', now() + interval '51 days')$$, test.id('fe_karan'), test.id('vehicle:FEK')), 'no longer in the program');
update vehicles set status = 'available' where id = test.id('vehicle:FEK');
alter table vehicles enable trigger a0_status_flow;
select test.mk_renter('fe_r3', false);
select test.mk_booking('FE-K1', 'FEK', 'fe_r3', '2035-06-10 10:00', '2035-06-13 10:00', 'confirmed');
select test.throws('a renter''s confirmed booking comes first, with the dates', format($$select app.owner_book_own_vehicle(%L, %L, '2035-06-11 10:00-04', '2035-06-12 10:00-04')$$, test.id('fe_karan'), test.id('vehicle:FEK')), 'A renter has this car');
select test.throws('owner use needs the responsibility confirmed', format($$select app.owner_book_for(%L, jsonb_build_object('vehicle', %L, 'pickup', now() + interval '70 days', 'return', now() + interval '72 days', 'for', 'self'))$$, test.id('fe_karan'), test.id('vehicle:FEK')), 'responsible');
select test.throws('someone else driving needs their details', format($$select app.owner_book_for(%L, jsonb_build_object('vehicle', %L, 'pickup', now() + interval '70 days', 'return', now() + interval '72 days', 'for', 'other', 'ack', true, 'driver', '{"full_name": "Sam Friend"}'::jsonb))$$, test.id('fe_karan'), test.id('vehicle:FEK')), 'name, email, phone');
create temp table fe_ob2 as select app.owner_book_for(test.id('fe_karan'), jsonb_build_object('vehicle', test.id('vehicle:FEK'), 'pickup', now() + interval '70 days', 'return', now() + interval '72 days',
  'for', 'other', 'ack', true, 'driver', '{"full_name": "Sam Friend", "email": "sam.friend@example.test", "mobile": "416-555-0101", "date_of_birth": "1992-03-04"}'::jsonb)) as r;
select test.eq('the friend is the main driver; no price, no deposit; the owner stays responsible',
  (select string_agg(bd.role || ':' || bd.full_name, ',') || '/' || max(b.owner_use_for) || '/' || max(b.total_due_at_booking_cents)::text || '/' || max(b.deposit_cents)::text || '/' || bool_and(b.owner_use_ack_at is not null)::text
     from bookings b join booking_drivers bd on bd.booking_id = b.id where b.id = (select (r ->> 'booking_id')::uuid from fe_ob2)),
  'renter:Sam Friend/other/0/0/true');
-- the agreement: the owner signs as the account holder, the friend with their own link as the main driver
insert into documents (id, kind, title, storage_bucket, storage_path, booking_id) values (test.id('doc:fe-ra'), 'rental_agreement', 'Rental agreement RA-FE-K2', 'documents', 'fe/ra.pdf', (select (r ->> 'booking_id')::uuid from fe_ob2));
insert into signature_requests (id, document_id, provider, provider_envelope, status, sent_at) values (test.id('sr:fe-ra'), test.id('doc:fe-ra'), 'builtin', 'fe-ra', 'sent', now());
insert into rental_agreements (booking_id, agreement_number, template_version, status, document_id, document_sha256, signature_request_id, countersigner_name)
values ((select (r ->> 'booking_id')::uuid from fe_ob2), 'RA-FE-K2', 'test', 'open', test.id('doc:fe-ra'), repeat('a', 64), test.id('sr:fe-ra'), 'CarmaCars');
insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email)
select a.id, 'renter', bd.id, bd.driver_id, test.id('fe_karan'), bd.full_name, 'fe_karan@example.test'
  from rental_agreements a join booking_drivers bd on bd.booking_id = a.booking_id where a.agreement_number = 'RA-FE-K2';
select test.eq('two signers: the owner (account holder) and the friend (main driver, own link)',
  (select string_agg(g.signer_role || ':' || g.signer_name || ':' || coalesce(g.signer_email, '') || ':' || coalesce(g.is_primary_driver, false), ' ' order by g.signer_role desc)
     from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.agreement_number = 'RA-FE-K2'),
  'renter:Fe Karan:fe_karan@example.test:false additional_driver:Sam Friend:sam.friend@example.test:true');

-- ================================================================ a staff agreement that waits for something (3196)
select test.suite('99 r48 FE: the staff agreement asks for what is missing');
select test.mk_user('fe_jamal', 'va', 'sales');
update staff_profiles set functions = '{sales,field}', sales_work_mode = 'in_person', home_address = null, home_postal_code = null, licence_number = null where user_id = test.id('fe_jamal');
insert into staff_agreement_auto (user_id, tries, last_at, missing) values (test.id('fe_jamal'), 1, now(), array['Driver''s licence number', 'Hourly Wage (CA$)']);
select test.eq('Sales and Field: the in-person agreement; he gives the licence and the address, CarmaCars the wage',
  (select (v ->> 'kind') || '/' || (select string_agg(m ->> 'key', ',') from jsonb_array_elements(v -> 'mine') m) || '/' || (v -> 'theirs' ->> 0) from (select app.staff_agreement_needs(test.id('fe_jamal')) v) x),
  'in_person/licence,address/Hourly Wage (CA$)');
select app.staff_home_address_save(test.id('fe_jamal'), '{"home_address": "12 Main St, Pawtucket, RI", "home_postal_code": "02860"}'::jsonb);
select test.ok('a home address outside Ontario of in-person staff is saved and flagged to confirm', app.staff_address_flag(test.id('fe_jamal')) like 'Your home address is not in Ontario%');
select app.staff_home_address_save(test.id('fe_jamal'), '{"home_address": "12 Main St, Pawtucket, RI", "home_postal_code": "02860", "confirm_outside_ontario": true}'::jsonb);
select test.ok('confirmed: kept, flagged, and the agreement is tried again',
  (select home_address_outside_ok_at is not null from staff_profiles where user_id = test.id('fe_jamal')) and not exists (select 1 from staff_agreement_auto where user_id = test.id('fe_jamal')));
select app.staff_home_address_save(test.id('fe_jamal'), '{"home_address": "88 Queen St W, Toronto, ON", "home_postal_code": "M5H 2N2"}'::jsonb);
select test.eq('an Ontario address needs no confirming', (select (home_address_outside_ok_at is null)::text || '/' || coalesce(app.staff_address_flag(test.id('fe_jamal')), 'none') from staff_profiles where user_id = test.id('fe_jamal')), 'true/none');
select app.staff_licence_number_save(test.id('fe_jamal'), '{"licence_number": "J1234-12345-12345"}'::jsonb);
select test.eq('licence and address given: nothing of his left', (select jsonb_array_length(app.staff_agreement_needs(test.id('fe_jamal')) -> 'mine')), 0);

-- ================================================================ data checks (3197): one test per check, the severities, Admin
select test.suite('99 r48 FE: data checks');
select test.ok('every check of the registry is a function that exists', (select bool_and(to_regproc(fn) is not null) from data_checks));
-- staff_agreement (blocking): an in-person hire with no licence and no address
select test.mk_user('fe_dc', 'va', 'sales');
update users set phone = '416-555-0123' where id = test.id('fe_dc');
update staff_profiles set functions = '{sales,field}', sales_work_mode = 'in_person', home_address = null, home_postal_code = null, licence_number = null where user_id = test.id('fe_dc');
select test.eq('staff_agreement: blocking, names the licence and the address',
  (select (x ->> 'severity') || '/' || (x ->> 'message' like 'Your staff agreement needs: Driver''s licence number, Home address%')::text from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_agreement'), 'blocking/true');
select test.throws('a blocking check cannot be dismissed', format($$select app.data_check_answer(%L, '{"key": "staff_agreement", "action": "dismiss"}')$$, test.id('fe_dc')), 'fixed first');
-- staff_address: Pawtucket, RI, confirmed with a reason
select app.staff_home_address_save(test.id('fe_dc'), '{"home_address": "12 Main St, Pawtucket, RI", "home_postal_code": "02860", "confirm_outside_ontario": true}'::jsonb);
update staff_profiles set home_address_outside_ok_at = null where user_id = test.id('fe_dc');
select test.eq('staff_address: names the place, outside Canada',
  (select x ->> 'message' from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_address'),
  'Your home address is in Pawtucket, RI, outside Canada. You work in person in Toronto: is this right?');
select test.throws('"It''s correct" needs the reason', format($$select app.data_check_answer(%L, '{"key": "staff_address", "action": "confirm"}')$$, test.id('fe_dc')), 'Say why');
select app.data_check_answer(test.id('fe_dc'), '{"key": "staff_address", "action": "confirm", "reason": "I commute from my family home on weekends"}'::jsonb);
select test.ok('confirmed: gone while the address is the same', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_address'));
-- staff_licence: expiring soon (warning), dismissed for 24 hours; expired (blocking)
select app.staff_licence_number_save(test.id('fe_dc'), '{"licence_number": "D1234-12345-12345"}'::jsonb);
update staff_profiles set licence_expiry = app.today() + 10 where user_id = test.id('fe_dc');
select test.eq('staff_licence: expiring in 10 days is a warning', (select x ->> 'severity' from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_licence'), 'warning');
select app.data_check_answer(test.id('fe_dc'), '{"key": "staff_licence", "action": "dismiss"}'::jsonb);
select test.ok('a warning dismissed is gone for 24 hours', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_licence'));
update data_check_answers set at = now() - interval '25 hours' where user_id = test.id('fe_dc') and check_key = 'staff_licence';
select test.ok('and comes back after 24 hours', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_licence'));
update staff_profiles set licence_expiry = app.today() - 1 where user_id = test.id('fe_dc');
select test.eq('staff_licence: expired is blocking', (select x ->> 'severity' from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_licence'), 'blocking');
select app.data_fix_save(test.id('fe_dc'), jsonb_build_object('kind', 'licence', 'licence_expiry', app.today() + 400));
select test.ok('the renewed expiry fixes it', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_licence'));
-- staff_pay: field work with no pay details
select test.ok('staff_pay: field work with no pay details', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_pay' and x -> 'fix' ->> 'kind' = 'link'));
-- staff_phone
update users set phone = '123' where id = test.id('fe_dc');
select test.ok('staff_phone: a number that is not valid', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_phone'));
select test.throws('the phone fix checks the number', format($$select app.data_fix_save(%L, '{"kind": "phone", "phone": "12ab"}')$$, test.id('fe_dc')), 'area code');
select app.data_fix_save(test.id('fe_dc'), '{"kind": "phone", "phone": "+1 647 555 0188"}'::jsonb);
select test.ok('saved: the phone check is closed', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_phone'));
-- staff_whatsapp_tag
update staff_profiles set whatsapp_joined = '{team}', whatsapp_tag_set_at = null where user_id = test.id('fe_dc');
select test.ok('staff_whatsapp_tag: joined without the tag', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_whatsapp_tag'));
select app.data_fix_save(test.id('fe_dc'), '{"kind": "whatsapp_tag", "tag_set": true}'::jsonb);
select test.ok('tag ticked: closed', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_dc'))) x where x ->> 'key' = 'staff_whatsapp_tag'));
-- owner_phone, renter_phone, renter_licence, renter_name
update owners set phone = 'call me' where user_id = test.id('fe_karan');
select test.ok('owner_phone', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_karan'))) x where x ->> 'key' = 'owner_phone'));
select test.mk_renter('fe_rx', true);
update renters set mobile = '555' where id = test.id('renter:fe_rx');
update drivers set licence_expiry = app.today() + 5, full_name = 'Someone Else' where id = test.id('driver:fe_rx');
select test.eq('renter_phone, renter_licence and renter_name',
  (select string_agg(x ->> 'key', ',' order by x ->> 'key') from jsonb_array_elements(app.data_checks_for(test.id('fe_rx'))) x), 'renter_licence,renter_name,renter_phone');
update drivers set full_name = 'Fe Rx Middle' where id = test.id('driver:fe_rx');
select test.ok('a middle name on one side is the same person', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_rx'))) x where x ->> 'key' = 'renter_name'));
-- Admin: the issues per person and Send reminder
select test.ok('Admin sees the staff member''s open issues', exists (select 1 from jsonb_array_elements(app.data_issues(test.id('fe_admin'), 'staff')) p where p ->> 'user_id' = test.id('fe_dc')::text));
select test.throws('only an Admin sees them', format($$select app.data_issues(%L, 'staff')$$, test.id('fe_fin')), '');
select app.data_check_answer(test.id('fe_rx'), '{"key": "renter_phone", "action": "dismiss"}'::jsonb);
select test.ok('dismissed', not exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_rx'))) x where x ->> 'key' = 'renter_phone'));
select app.data_check_remind(test.id('fe_admin'), jsonb_build_object('user', test.id('fe_rx')));
select test.ok('the reminder queues the branded email to the renter (3199)', exists (select 1 from app_events e where e.code = 'renter_data_check' and e.entity_id = test.id('renter:fe_rx')));
select test.ok('Send reminder brings a dismissed warning back at once', exists (select 1 from jsonb_array_elements(app.data_checks_for(test.id('fe_rx'))) x where x ->> 'key' = 'renter_phone'));

-- ================================================================ 3198: the agreement before the academy, updated documents, the install fee
select test.suite('99 r48 FE: agreement first, updated documents, install fee');
select test.mk_user('fe_neo', 'va', 'cs');
update staff_profiles set onboarding_exempt = false, functions = '{cs}' where user_id = test.id('fe_neo');
create temp table fe_gate2 as select id, academy_gate g, staff_agreement_gate a from program_settings;
update program_settings set academy_gate = true, staff_agreement_gate = true;
insert into academy_enrollments (user_id, path_code, enrolled_at, lock_from) values (test.id('fe_neo'), 'cs', now() - interval '1 day', now() - interval '1 day') on conflict do nothing;
select test.eq('a new hire who has not signed nor passed the academy: the agreement first',
  (select (s ->> 'step') || '/' || (s -> 'waiting_on' ->> 0) from (select app.staff_onboarding_state(test.id('fe_neo')) s) x), 'agreement/Staff agreement signature');
select test.ok('unsigned is locked on the agreement even before the academy is passed', app.agreement_locked(test.id('fe_neo')));
select test.eq('Welcome lists the agreement before the academy',
  (select string_agg(y ->> 'key', ',' order by n) from jsonb_array_elements(app.staff_welcome(test.id('fe_neo')) -> 'steps') with ordinality t(y, n) where y ->> 'key' in ('agreement', 'academy')), 'agreement,academy');
update staff_profiles set agreement_waived_at = now() where user_id = test.id('fe_neo');
select test.eq('signed (here waived): the academy is next', (select app.staff_onboarding_state(test.id('fe_neo')) ->> 'step'), 'academy');
update program_settings p set academy_gate = f.g, staff_agreement_gate = f.a from fe_gate2 f where f.id = p.id;
-- the updated documents: published, declined (kept, the portal stays closed), accepted
select test.eq('three versions to accept: the rental, owner and staff agreements',
  (select string_agg(doc_key, ',' order by doc_key) from terms_versions where version like '%r48fe'), 'owner_agreement,rental_agreement,staff_agreement');
update users set created_at = now() - interval '30 days' where id = test.id('fe_neo');
select test.ok('the staff agreement version waits for a staff member who joined before', exists (select 1 from jsonb_array_elements(app.terms_pending(test.id('fe_neo'))) x where x ->> 'doc_key' = 'staff_agreement'));
select app.terms_decline(test.id('fe_neo'), jsonb_build_object('version_id', (select id from terms_versions where version = 'staff-r48fe'), 'ip', '203.0.113.7', 'user_agent', 'test'));
select test.ok('a decline is kept and the version still waits', exists (select 1 from terms_declines where user_id = test.id('fe_neo'))
  and exists (select 1 from jsonb_array_elements(app.terms_pending(test.id('fe_neo'))) x where x ->> 'doc_key' = 'staff_agreement'));
select test.eq('the Admin report counts the decline', (select (x ->> 'declined')::int from jsonb_array_elements(app.terms_versions_admin(test.id('fe_admin'), '{}'::jsonb) -> 'versions') x where x ->> 'version' = 'staff-r48fe'), 1);
select app.terms_accept(test.id('fe_neo'), jsonb_build_object('version_id', (select id from terms_versions where version = 'staff-r48fe'), 'body_sha256', (select body_sha256 from terms_versions where version = 'staff-r48fe'), 'ip', '203.0.113.7', 'user_agent', 'test', 'portal', 'staff'));
select test.ok('accepted with the version, IP and device; no longer waiting',
  exists (select 1 from terms_acceptances a join terms_versions v on v.id = a.version_id where v.version = 'staff-r48fe' and a.user_id = test.id('fe_neo') and host(a.ip_address) = '203.0.113.7' and a.user_agent = 'test')
  and not exists (select 1 from jsonb_array_elements(app.terms_pending(test.id('fe_neo'))) x where x ->> 'doc_key' = 'staff_agreement'));
select test.eq('the install fee is $150 for new terms', (select install_fee_cents || '/' || tracker_product_install_cents from app.settings() x), '15000/15000');
select test.ok('a decline alerts the Admins (3199)', exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'terms_declined'));
select test.ok('a fee waiting for evidence alerts the role (3199)', exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'fee_evidence_needed'));
