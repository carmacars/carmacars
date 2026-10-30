-- 99: record a pickup or return now with the details later, renters complete the agreement's blanks, the VLF on
-- insurer-billed rentals (migration 0195, docs/changes/2026-10-30-record-now-renter-details-vlf.md). Uses the helpers of
-- 06 (test.rq_new, test.b), 09 (test.op_confirm, test.op_photos, test.op_deposit_payment) and 82 (test.ho_local).
-- Fixtures start with "rn".
select test.suite('99 record now, renter details, VLF');
update program_settings set booking_return_auto_charges = true, statement_fuel_cents_per_eighth = 1000;

select test.mk_user('rn_admin', 'admin');
select test.mk_user('rn_fleet', 'va', 'fleet');
select test.mk_user('rn_fin', 'va', 'finance');
select test.mk_user('rn_cs', 'va', 'cs');
select test.mk_owner('rn_o');
select test.mk_vehicle('RNV', 'rn_o');
select test.mk_vehicle('RNW', 'rn_o');
select test.mk_renter('rn_r');
select test.mk_renter('rn_q');
create function test.rn_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;

-- ---------------------------------------------------------------- 1. the pickup now
select test.rq_new('rnA', 'rn_r', 'RNV', test.ho_local(interval '3 hours'), test.ho_local(interval '2 days 3 hours'));
select test.op_confirm('rnA', 'rn_r');
select test.throws('pickup now: Finance does not record a pickup',
  format($$select test.rn_do('rn_fin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died'))$$, test.b('rnA')), 'check-out or check-in');
select test.throws('pickup now: the reason is asked',
  format($$select test.rn_do('rn_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', ''))$$, test.b('rnA')), 'Say why');
select test.throws('pickup now: the deposit not taken stops Fleet',
  format($$select test.rn_do('rn_fleet', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died at the lot'))$$, test.b('rnA')), 'deposit is not taken');
select app.record_deposit_taken(test.b('rnA'), test.op_deposit_payment('rnA'), test.id('rn_fin'));
select test.throws('pickup now: without the renter''s signature only an Admin, with a reason',
  format($$select test.rn_do('rn_fleet', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died at the lot'))$$, test.b('rnA')), 'has not signed the check-out report');
create temp table rn_p as select test.rn_do('rn_admin', 'handover_record_now', jsonb_build_object('booking', test.b('rnA'), 'kind', 'pickup',
  'reason', 'Phone died at the lot', 'signature_override_reason', 'Renter signed on paper', 'odometer_km', 20000, 'at', now() - interval '10 minutes')) r;
select test.eq('pickup now: on rent, the report waits for its details, one Fleet task, the history says why',
  (select status::text || ':' || odometer_out_km || ':' || (handed_over_at < now() - interval '9 minutes') from bookings where id = test.b('rnA'))
  || '/' || (select details_pending::text || ':' || (completed_at is null) || ':' || (recorded_now ->> 'signature_override') from condition_reports where booking_id = test.b('rnA') and kind = 'pickup')
  || '/' || (select count(*) || ':' || min(queue) || ':' || min(title) from tasks where booking_id = test.b('rnA') and task_type = 'handover_details' and status = 'open')
  || '/' || (select count(*) from booking_events where booking_id = test.b('rnA') and kind = 'recorded_now' and note like '%Renter signed on paper%'),
  'on_rent:20000:true/true:true:Renter signed on paper/1:fleet:Add the photos and readings for ' || (select booking_number from bookings where id = test.b('rnA')) || '/1');
select test.eq('pickup now: the task cannot be closed by hand while the details wait',
  (select app.task_completion_problem(id) from tasks where booking_id = test.b('rnA') and task_type = 'handover_details'), 'Add the photos and readings first: open the check-out or check-in from the booking');

-- the details later, through the usual checklist (handover_open gives the job; the completion does not move the booking)
create temp table rn_pj as select (test.rn_do('rn_fleet', 'handover_open', jsonb_build_object('booking', test.b('rnA'), 'kind', 'pickup')) ->> 'job')::uuid as id;
select test.eq('details: the checklist says the details come later',
  (public.door(test.id('rn_fleet'), null, 'field_read', 'job', jsonb_build_object('id', (select id from rn_pj))) ->> 'details_later'), 'true');
create temp table rn_pd as select public.door(test.id('rn_fleet'), null, 'field_do', 'complete_handover', jsonb_build_object('job', (select id from rn_pj), 'report', jsonb_build_object(
  'odometer_km', 20010, 'fuel_pct', 100, 'keys_count', 2, 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup')))) r;
select test.eq('details: the report is complete, the readings follow, the booking stays on rent, the task closes',
  (select r ->> 'booking_status' from rn_pd) || '/' || (select (not details_pending)::text || ':' || (completed_at is not null) from condition_reports where booking_id = test.b('rnA') and kind = 'pickup')
  || '/' || (select odometer_out_km from bookings where id = test.b('rnA'))
  || '/' || (select status from tasks where booking_id = test.b('rnA') and task_type = 'handover_details'), 'on_rent/true:true/20010/done');

-- ---------------------------------------------------------------- 2. the return now, late, then the deposit
set session_replication_role = replica;
update bookings set pickup_at = now() - interval '2 days 3 hours', handed_over_at = now() - interval '2 days 3 hours', return_at = now() - interval '5 hours'
 where id = test.b('rnA');
set session_replication_role = origin;
select test.throws('return now: not in the future',
  format($$select test.rn_do('rn_fleet', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'return', 'reason', 'Keys in the drop box', 'at', now() + interval '1 day'))$$, test.b('rnA')), 'not in the future');
create temp table rn_r as select test.rn_do('rn_fleet', 'handover_record_now', jsonb_build_object('booking', test.b('rnA'), 'kind', 'return',
  'reason', 'Keys in the drop box, no photos yet', 'at', now() - interval '2 hours', 'fuel_pct', 100)) r;
select test.eq('return now: returned at the actual time, late against it (one extra day), the late lines written',
  (select status::text || ':' || (minutes_late between 179 and 181) || ':' || extra_days from bookings where id = test.b('rnA'))
  || '/' || (select count(*) from booking_line_items where booking_id = test.b('rnA') and assessment_key = 'late_return_extra_days' and voided_at is null),
  'returned:true:1/1');
select test.lives('return now: Finance issues the statement before the photos are in',
  format($$select app.issue_booking_statement(%L, %L)$$, test.b('rnA'), test.id('rn_fin')));
select test.eq('return now: the deposit names what waits (the photos) as a blocker',
  (select string_agg(x ->> 'kind', ',') from jsonb_array_elements(app.deposit_blockers(test.b('rnA'))) x where x ->> 'kind' = 'details'), 'details');
select test.throws('deposit: Finance cannot release it before the photos are in',
  format($$select public.door(%L, null, 'ops_do', 'deposit_settle', jsonb_build_object('booking', %L, 'release_now', true))$$, test.id('rn_fin'), test.b('rnA')), 'stays held');
select test.lives('deposit: an Admin settles it with the reason (DepositSettle)',
  format($$select public.door(%L, null, 'ops_do', 'deposit_settle', jsonb_build_object('booking', %L, 'release_now', true, 'override_reason', 'Checked the car in person, no damage'))$$, test.id('rn_admin'), test.b('rnA')));
create temp table rn_rj as select (test.rn_do('rn_admin', 'handover_open', jsonb_build_object('booking', test.b('rnA'), 'kind', 'return')) ->> 'job')::uuid as id;
create temp table rn_rd as select public.door(test.id('rn_admin'), null, 'field_do', 'complete_return', jsonb_build_object('job', (select id from rn_rj), 'report', jsonb_build_object(
  'odometer_km', 20300, 'fuel_pct', 100, 'keys_count', 2, 'cleanliness', 'clean', 'renter_present', false, 'staff_signature_ref', 'sig/s2', 'photos', test.op_photos('return')))) r;
select test.eq('return details: complete, km in follows, the booking stays where it is (closed once the deposit was settled), the task closed, the blocker gone',
  (select r ->> 'booking_status' from rn_rd) || '/' || (select odometer_in_km || ':' || status::text from bookings where id = test.b('rnA'))
  || '/' || (select count(*) from tasks where booking_id = test.b('rnA') and task_type = 'handover_details' and status = 'open')
  || '/' || jsonb_array_length(coalesce((select jsonb_agg(x) from jsonb_array_elements(app.deposit_blockers(test.b('rnA'))) x where x ->> 'kind' = 'details'), '[]')),
  'closed/20300:closed/0/0');

-- ---------------------------------------------------------------- 3. the renter completes the agreement's blanks
select test.rq_new('rnB', 'rn_q', 'RNW', test.ho_local(interval '5 days'), test.ho_local(interval '8 days'));
select test.op_confirm('rnB', 'rn_q');
update renters set address_line1 = null, city = null, province = null, postal_code = null where id = test.id('renter:rn_q');
update booking_drivers set licence_issuer = null, licence_expiry = null where booking_id = test.b('rnB');
update drivers set licence_issuer = null, licence_expiry = null where id = test.id('driver:rn_q');
select test.eq('renter: the blanks they fill are listed (address, licence issuer and expiry), not the car''s',
  (select string_agg(x ->> 'field', ',' order by x ->> 'field') from jsonb_array_elements(public.renter_agreement_missing(test.b('rnB'), test.id('rn_q'))) x),
  'address,licence_expiry,licence_issuer');
select test.eq('renter: staff see what waits for the renter on the Agreement card',
  jsonb_array_length(app.agreement_state(test.id('rn_admin'), test.b('rnB')) -> 'renter_missing'), 3);
select test.throws('renter: another renter cannot fill them',
  format($$select public.renter_agreement_fill(%L, %L, '{"city": "Toronto"}')$$, test.id('rn_r'), test.b('rnB')), 'for the renter of the booking');
select test.throws('renter: only their own details',
  format($$select public.renter_agreement_fill(%L, %L, '{"plate": "ABC123"}')$$, test.id('rn_q'), test.b('rnB')), 'Only your own details');
select test.throws('renter: the licence must last until the return',
  format($$select public.renter_agreement_fill(%L, %L, '{"licence_issuer": "ON", "licence_expiry": "2026-01-01"}')$$, test.id('rn_q'), test.b('rnB')), 'valid until the return');
create temp table rn_f as select public.renter_agreement_fill(test.id('rn_q'), test.b('rnB'), jsonb_build_object('address_line1', '1 Queen St W', 'city', 'Toronto',
  'province', 'on', 'postal_code', 'm5h2n2', 'licence_issuer', 'ON', 'licence_expiry', (now() + interval '3 years')::date)) r;
select test.eq('renter: saved to the renter, their driver and the booking''s copy; nothing left; the history says it',
  (select jsonb_array_length(r -> 'missing') from rn_f)::text || '/' || (select province || ':' || postal_code from renters where id = test.id('renter:rn_q'))
  || '/' || (select licence_issuer from booking_drivers where booking_id = test.b('rnB') and role = 'renter')
  || '/' || (select count(*) from booking_events where booking_id = test.b('rnB') and kind = 'agreement_fields_filled' and actor_type = 'renter'),
  '0/ON:M5H 2N2/ON/1');

-- ---------------------------------------------------------------- 4. the VLF on an insurer-billed rental
insert into insurers (id, name) values (test.id('ins:rn'), 'RN Mutual');
select test.eq('vlf: none by default', (select vlf_daily_cents from program_settings limit 1), 0);
select test.rn_do('rn_cs', 'booking_insurer_save', jsonb_build_object('booking', test.b('rnB'), 'bill_to', 'split', 'insurer_id', test.id('ins:rn'), 'claim_number', 'C-1'));
select test.eq('vlf: billed to an insurer with no VLF set: no line', (select count(*) from booking_line_items where booking_id = test.b('rnB') and charge_type = 'vlf' and voided_at is null), 0::bigint);
select test.rn_do('rn_cs', 'booking_insurer_save', jsonb_build_object('booking', test.b('rnB'), 'vlf_daily_cents', 250));
select test.eq('vlf: $2.50 a day times the days, with HST, on the booking',
  (select amount_cents || ':' || hst_cents || ':' || quantity::integer from booking_line_items where booking_id = test.b('rnB') and charge_type = 'vlf' and voided_at is null),
  (select (250 * billable_days) || ':' || public.calc_hst(250 * billable_days, hst_bps) || ':' || billable_days from bookings where id = test.b('rnB')));
select test.eq('vlf: "rental only" (split): the insurer pays the VLF with the rental, not the other fees',
  (select (s.share_cents - s.rental_share_cents - s.fees_share_cents)::text from app.booking_insurer_share(test.b('rnB')) s),
  (select (250 * billable_days)::text from bookings where id = test.b('rnB')));
select test.eq('vlf: the booking''s totals include it and the insurer''s share covers it',
  (select (total_due_at_booking_cents = (select sum(amount_cents + hst_cents) from booking_line_items where booking_id = b.id and stage = 'booking' and voided_at is null and charged_to_renter))::text
          || ':' || (insurer_share_cents >= 250 * billable_days) from bookings b where id = test.b('rnB')), 'true:true');
select app.draft_insurer_invoice(test.b('rnB'), test.id('rn_admin'));
select test.eq('vlf: the insurer invoice has a VLF line, and its lines add up to the invoice',
  (select (exists (select 1 from jsonb_array_elements(lines) l where l ->> 'description' like 'VLF (vehicle licensing fee), % at $2.50 a day'))::text
          || ':' || ((select sum((l ->> 'amount_cents')::bigint) from jsonb_array_elements(lines) l) = amount_cents)
     from insurer_invoices where booking_id = test.b('rnB') and status = 'draft'), 'true:true');
select test.rn_do('rn_cs', 'booking_insurer_save', jsonb_build_object('booking', test.b('rnB'), 'bill_to', 'renter'));
select test.eq('vlf: the renter pays again: the VLF line is voided', (select count(*) from booking_line_items where booking_id = test.b('rnB') and charge_type = 'vlf' and voided_at is null), 0::bigint);
update program_settings set vlf_daily_cents = 0;
