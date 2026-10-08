-- 10: tolls, tickets and damages after a rental; owner statements and CarmaCars' own monthly
-- statements (migration 0021). Intake with duplicates and bad rows, every matching case, charging
-- from a held Deposit, the Card on File and on a closed booking, the Owner and staff paths,
-- damage routing, the worked owner month, a second month with every kind of car and its company
-- statement to the cent with the reconciliation, and row-level security for each role.
--
-- Part A uses vehicles of Owner "tz_paul" from March to May 2026 (before any other test's data);
-- part B uses Owner "tz_olga" and three others in June 2026, so the company statement for June
-- holds only what this file creates.
select test.suite('10 tolls statements');

-- ------------------------------------------------------------------ fixture
create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;

create function test.tz_doc(p_label text, p_kind document_kind default 'toll_ticket_notice') returns uuid language plpgsql as $$
declare
  v uuid := test.id('doc:' || p_label);
begin
  insert into documents (id, kind, title, storage_bucket, storage_path) values (v, p_kind, p_label, 'claims', 'tz/' || p_label || '.pdf')
  on conflict (id) do nothing;
  return v;
end $$;

-- log one notice through the single-entry function, as Finance
create function test.tz_log(p_label text, p_vehicle text, p_at text, p_amount bigint, p_kind text default 'toll_invoice',
                            p_extra jsonb default '{}'::jsonb) returns uuid language sql as $$
  select app.log_toll_ticket(jsonb_build_object('kind', p_kind, 'authority', 'Toll operator', 'notice_number', 'N-' || p_label,
           'plate', (select plate from vehicles where id = test.id('vehicle:' || p_vehicle)), 'occurred_at', p_at,
           'amount_cents', p_amount, 'document_id', test.tz_doc(p_label)) || p_extra, test.id('tz_fin'))
$$;
create function test.tz_t(p_label text) returns toll_tickets language sql as $$
  select * from toll_tickets where notice_number = 'N-' || p_label
$$;

select test.mk_user('tz_admin', 'admin');
select test.mk_user('tz_fin', 'va', 'finance');
select test.mk_user('tz_fleet', 'va', 'fleet');
select test.mk_user('tz_cs', 'va', 'cs');
select test.mk_user('tz_field', 'field', null, 'driver');
select test.mk_user('tz_driver', 'field', null, 'driver');
select test.mk_owner('tz_paul');
select test.mk_owner('tz_oscar');
select test.mk_vehicle(n, 'tz_paul', 'managed', 45000, 2500, 3500, date '2026-02-01') from unnest(array['TA', 'TB', 'TC', 'TD']) n;
select test.mk_vehicle('TO', 'tz_oscar', 'managed', 45000, 2500, 3500, date '2026-02-01');
select test.mk_owner('tz_tom');
select test.mk_vehicle('TT', 'tz_tom', 'turo_only', 0, 0, 3500, date '2026-02-01');
select test.mk_owner('tz_sam');
select test.mk_vehicle('TS', 'tz_sam', 'self_managed', 45000, 2500, 0, date '2026-02-01');
select test.mk_renter(n) from unnest(array['tz_r1', 'tz_r2', 'tz_r3', 'tz_r4', 'tz_r5']) n;
select test.mk_renter('tz_paul_as_renter', false);
update renters set user_id = test.id('tz_paul'), is_owner_account = true where id = test.id('renter:tz_paul_as_renter');
select test.mk_renter('tz_oscar_as_renter', false);
update renters set user_id = test.id('tz_oscar'), is_owner_account = true where id = test.id('renter:tz_oscar_as_renter');

-- TA: TA1 closed (Mar 2 to 6); TA2 returned three hours late on Mar 12 at 15:00; an Owner Booking
-- in April; staff moves on Mar 8 and around TA2's handover; an owner-use block in May; a booking
-- confirmed for May 10 to 12 but never handed over.
select test.mk_booking('TA1', 'TA', 'tz_r1', '2026-03-02 10:00', '2026-03-06 10:00', 'closed', 40000, 'standard', null, '2026-02-20 10:00');
select test.mk_booking('TA2', 'TA', 'tz_r2', '2026-03-10 10:00', '2026-03-12 10:00', 'returned', 20000, 'standard', null, '2026-02-25 10:00', '2026-03-12 15:00');
insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, ended_at, created_by) values
  (test.id('vehicle:TA'), test.id('tz_driver'), 'detail', test.at('2026-03-08 14:00'), test.at('2026-03-08 15:00'), test.id('tz_fleet')),
  (test.id('vehicle:TA'), test.id('tz_driver'), 'delivery', test.at('2026-03-10 09:00'), test.at('2026-03-10 10:10'), test.id('tz_fleet'));
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at)
values (test.id('vehicle:TA'), 'owner_unavailable', test.at('2026-05-01 00:00'), test.at('2026-05-03 00:00'));
select test.mk_booking('TA9', 'TA', 'tz_r3', '2026-05-10 10:00', '2026-05-12 10:00', 'confirmed', 20000, 'standard', null, '2026-04-20 10:00');
-- TB1 (Apr 1 to 5) moved to TC on Apr 3 at 10:00
select test.mk_booking('TB1', 'TB', 'tz_r4', '2026-04-01 10:00', '2026-04-05 10:00', 'closed', 40000, 'standard', null, '2026-03-20 10:00');
insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason, approved_by)
values (test.id('booking:TB1'), test.id('vehicle:TB'), test.id('vehicle:TC'), test.at('2026-04-03 10:00'), 'breakdown', test.id('tz_admin'));
update bookings set vehicle_id = test.id('vehicle:TC') where id = test.id('booking:TB1');
-- Owner Booking on TC in April; another Owner's Owner Booking on TO in April
select test.mk_booking('TOB', 'TC', 'tz_paul_as_renter', '2026-04-10 10:00', '2026-04-12 10:00', 'closed', null, 'owner', null, '2026-04-01 10:00');
select test.mk_booking('TOB2', 'TO', 'tz_oscar_as_renter', '2026-04-15 10:00', '2026-04-18 10:00', 'closed', null, 'owner', null, '2026-04-01 10:00');
-- TD1 on rent now, booked on Sep 25 (after the fee change below)
select test.mk_booking('TD1', 'TD', 'tz_r5', to_char(now() - interval '5 days', 'YYYY-MM-DD HH24:00'), to_char(now() + interval '10 days', 'YYYY-MM-DD HH24:00'),
                       'on_rent', 150000, 'standard', null, '2026-09-25 10:00');
-- plate history and a transponder
insert into vehicle_plate_history (vehicle_id, plate, from_date, to_date) values (test.id('vehicle:TA'), 'OLD-TA1', date '2026-02-01', date '2026-02-28');
insert into vehicle_transponders (vehicle_id, transponder_number, from_date) values (test.id('vehicle:TB'), 'TX-777', date '2026-02-01');

-- ------------------------------------------------------------------ matching, case by case
create temp view mc as select 1;
select test.eq('M renter on rent, clearly inside: one candidate, high, automatic',
  (select m ->> 'decision' || '/' || (m ->> 'confidence') || '/' || (m -> 'suggested' ->> 'booking_number') || '/' || (m -> 'suggested' ->> 'renter_first_name')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-04 12:00')) m), 'auto/high/TA1/Tz');
select test.eq('M evidence: window, position and the margin',
  (select (m -> 'suggested' ->> 'minutes_from_start') || '/' || (m -> 'suggested' ->> 'minutes_to_end') || '/' || (m -> 'suggested' ->> 'position_pct') || '/' || (m ->> 'margin_minutes')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-04 12:00')) m), '3000/2760/52/30');
select test.eq('M 20 minutes after the handover: flagged within the margin, medium, for review',
  (select m ->> 'decision' || '/' || (m ->> 'confidence') || '/' || (m -> 'suggested' ->> 'near_boundary')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-02 10:20')) m), 'review/medium/true');
select test.eq('M a late return: after the return time, before Check-in, still the renter (flagged late)',
  (select m ->> 'decision' || '/' || (m -> 'suggested' ->> 'booking_number') || '/' || (m -> 'suggested' ->> 'late_return')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-12 13:00')) m), 'auto/TA2/true');
select test.eq('M between bookings: no one, with the reason',
  (select m ->> 'decision' || '/' || (m ->> 'confidence') || '/' || (m ->> 'reason')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-08 12:00')) m),
  'unmatched/none/The car was in the program and not on a booking, a staff move or an owner block at that time');
select test.eq('M a staff move (0020 vehicle_moves): the staff member, automatic',
  (select m ->> 'decision' || '/' || (m -> 'suggested' ->> 'kind') || '/' || (m -> 'suggested' ->> 'staff_name') || '/' || (m -> 'suggested' ->> 'purpose')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-08 14:30')) m), 'auto/staff/Tz Driver/detail');
select test.eq('M a delivery leg touching the handover: renter and staff, medium, for review',
  (select m ->> 'decision' || '/' || (m ->> 'confidence') || '/' || jsonb_array_length(m -> 'candidates')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-10 10:05')) m), 'review/medium/2');
select test.eq('M swap: before the swap the booking is on the first car',
  (select m -> 'suggested' ->> 'booking_number' || '/' || (m -> 'suggested' ->> 'swapped') from app.match_toll_candidates(test.id('vehicle:TB'), test.at('2026-04-02 12:00')) m), 'TB1/false');
select test.eq('M swap: after the swap the booking is on the replacement car',
  (select m -> 'suggested' ->> 'booking_number' || '/' || (m -> 'suggested' ->> 'swapped') from app.match_toll_candidates(test.id('vehicle:TC'), test.at('2026-04-04 12:00')) m), 'TB1/true');
select test.eq('M swap: the first car after the swap is no longer the renter''s',
  (select m ->> 'decision' from app.match_toll_candidates(test.id('vehicle:TB'), test.at('2026-04-04 12:00')) m), 'unmatched');
select test.eq('M an Owner Booking',
  (select m ->> 'decision' || '/' || (m -> 'suggested' ->> 'kind') from app.match_toll_candidates(test.id('vehicle:TC'), test.at('2026-04-11 12:00')) m), 'auto/owner_booking');
select test.eq('M before the Enrollment Date: the Owner, outside the program',
  (select m -> 'suggested' ->> 'kind' || '/' || (m -> 'suggested' ->> 'reason') from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-01-15 12:00')) m),
  'owner_outside_program/Before the Enrollment Date');
select test.eq('M an owner-use block',
  (select m -> 'suggested' ->> 'kind' from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-05-02 12:00')) m), 'owner_outside_program');
select test.eq('M a Turo-Only car',
  (select m ->> 'decision' || '/' || (m -> 'suggested' ->> 'kind') from app.match_toll_candidates(test.id('vehicle:TT'), test.at('2026-05-02 12:00')) m), 'auto/turo_only');
select test.eq('M a Self-Managed car outside a CarmaCars rental',
  (select m -> 'suggested' ->> 'reason' from app.match_toll_candidates(test.id('vehicle:TS'), test.at('2026-05-20 12:00')) m),
  'Self-Managed car outside a CarmaCars rental');
select test.eq('M a booking confirmed but never handed over: low, never automatic',
  (select m ->> 'decision' || '/' || (m ->> 'confidence') || '/' || (m -> 'suggested' ->> 'not_handed_over')
     from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-05-11 12:00')) m), 'review/low/true');
select test.eq('M time not stated, one party all day: medium',
  (select m ->> 'confidence' from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-04 00:00'), true) m), 'medium');
select test.eq('M time not stated, several parties that day: low',
  (select m ->> 'confidence' || '/' || jsonb_array_length(m -> 'candidates') from app.match_toll_candidates(test.id('vehicle:TA'), test.at('2026-03-10 00:00'), true) m), 'low/2');
select test.eq('M an active booking (on rent now) is matched up to now',
  (select m -> 'suggested' ->> 'booking_number' || '/' || (m -> 'suggested' ->> 'still_on_rent') from app.match_toll_candidates(test.id('vehicle:TD'), now() - interval '1 day') m), 'TD1/true');
select test.eq('M the old single-answer function still answers (renter, booking)',
  (select matched_to || '/' || (booking_id = test.id('booking:TA1')) from app.match_toll_ticket(test.id('vehicle:TA'), test.at('2026-03-04 12:00'))), 'renter/true');
select test.eq('M plate history and transponder find the car on the date',
  (select string_agg(r.found_by || ':' || (r.vehicle_id = test.id(v)), ' ' order by v) from (
     select 'vehicle:TA' as v, x.* from app.resolve_toll_vehicle('old ta1', null, date '2026-02-15') x
     union all select 'vehicle:TB', x.* from app.resolve_toll_vehicle(null, 'tx-777', date '2026-04-02') x) r),
  'plate_history:true transponder:true');
select test.eq('M the old plate after its last day finds nothing', (select count(*) from app.resolve_toll_vehicle('OLD-TA1', null, date '2026-03-15')), 0::bigint);

-- ------------------------------------------------------------------ bulk import
select test.tz_doc('stmt-1');
select app.save_toll_import_profile(jsonb_build_object('operator', 'Toll operator', 'name', 'Trips export', 'header_signature', 'plate|date|amount|trip',
         'mapping', jsonb_build_object('plate', 'Plate', 'occurred_at', 'Date', 'amount_cents', 'Amount', 'notice_number', 'Trip')), test.id('tz_fin'));
select test.eq('I a saved mapping is found again by its header row',
  (select (app.find_toll_import_profile('Toll operator', 'plate|date|amount|trip')).mapping ->> 'plate'), 'Plate');
create temp table imp as select app.import_toll_batch(jsonb_build_object(
  'operator', 'Toll operator', 'statement_number', 'S-2026-03', 'statement_date', '2026-03-20', 'due_on', '2026-04-15', 'total_cents', 3000,
  'document_id', test.id('doc:stmt-1'), 'profile_id', (select id from toll_import_profiles where header_signature = 'plate|date|amount|trip'),
  'rows', jsonb_build_array(
    jsonb_build_object('row_no', 1, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-04 12:00', 'amount_cents', 450, 'notice_number', 'T-1'),
    jsonb_build_object('row_no', 2, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-04 15:30', 'amount_cents', 325, 'notice_number', 'T-2'),
    jsonb_build_object('row_no', 3, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-04 12:00', 'amount_cents', 450, 'notice_number', 'T-1'),
    jsonb_build_object('row_no', 4, 'plate', (select lower(plate) from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-04T20:30:00Z', 'amount_cents', 325, 'notice_number', 'T-2b'),
    jsonb_build_object('row_no', 5, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', 'last tuesday', 'amount_cents', 100, 'notice_number', 'T-5'),
    jsonb_build_object('row_no', 6, 'plate', 'ZZZ999', 'occurred_at', '2026-03-04 12:00', 'amount_cents', 100, 'notice_number', 'T-6'),
    jsonb_build_object('row_no', 7, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-04 13:00', 'amount_cents', -5, 'notice_number', 'T-7'),
    jsonb_build_object('row_no', 8, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2099-01-01 12:00', 'amount_cents', 100, 'notice_number', 'T-8'),
    jsonb_build_object('row_no', 9, 'transponder', 'TX-777', 'occurred_at', '2026-04-02 13:00', 'amount_cents', 600, 'notice_number', 'T-9'),
    jsonb_build_object('row_no', 10, 'plate', (select plate from vehicles where id = test.id('vehicle:TA')), 'occurred_at', '2026-03-08 12:00', 'amount_cents', 250, 'notice_number', 'T-10'))),
  test.id('tz_fin')) as r;
select test.eq('I counts: 10 rows, 4 imported, 2 duplicates, 4 invalid',
  (select (r ->> 'rows') || '/' || (r ->> 'imported') || '/' || (r ->> 'duplicates') || '/' || (r ->> 'invalid') from imp), '10/4/2/4');
select test.eq('I per row: imported, duplicate (same notice; same plate, time and amount), invalid with the reason',
  (select string_agg((x ->> 'row_no') || ':' || (x ->> 'result') || coalesce(':' || (x ->> 'reason'), ''), ' | ' order by (x ->> 'row_no')::integer)
     from imp, jsonb_array_elements(r -> 'results') x),
  '1:imported | 2:imported | 3:duplicate:Already logged | 4:duplicate:Already logged | 5:invalid:Unreadable date and time'
  || ' | 6:invalid:Plate or transponder not in the fleet (not ours) | 7:invalid:Unreadable amount | 8:invalid:The date and time are in the future | 9:imported | 10:imported');
select test.eq('I the difference with the statement total is shown (rows given $26.95 less the $30.00 total), and the total imported',
  (select (r ->> 'difference_cents') || '/' || (r ->> 'imported_total_cents') from imp), '-305/1625');
select test.eq('I the batch keeps its counts and the statement number on each row',
  (select imported_count || '/' || duplicate_count || '/' || invalid_count || '/' || (select count(*) from toll_tickets t where t.import_batch_id = b.id and t.statement_number = 'S-2026-03')
     from toll_import_batches b where statement_number = 'S-2026-03'), '4/2/4/4');
select test.eq('I matched on import: two trips to TA1, the transponder trip to TB1, one unmatched',
  (select string_agg(notice_number || '=' || matched_to || coalesce(':' || bk.booking_number, ''), ' ' order by notice_number)
     from toll_tickets t left join bookings bk on bk.id = t.booking_id where t.statement_number = 'S-2026-03'),
  'T-1=renter:TA1 T-10=unmatched T-2=renter:TA1 T-9=renter:TB1');
select test.eq('I the transponder row found the car by its transponder', (select vehicle_found_by from toll_tickets where notice_number = 'T-9'), 'transponder');
select test.eq('I each logged notice is in the finance digest once (staff_toll_ticket_logged)',
  (select count(*) from app_events e join toll_tickets t on t.id = e.entity_id where e.code = 'staff_toll_ticket_logged' and t.statement_number = 'S-2026-03'), 4::bigint);
select test.eq('I the unmatched row raised a Finance task due the day after its charge-by date',
  (select count(*) || '/' || min(queue) || '/' || (min(due_at) = app.local_midnight(min(t.charge_by) + 1))
     from tasks k join toll_tickets t on t.id = k.related_id where k.task_type = 'match_toll' and t.notice_number = 'T-10'), '1/finance/true');
select test.eq('I charge-by is the set number of business days after receipt',
  (select charge_by = app.add_business_days(received_on, 3) from toll_tickets where notice_number = 'T-1'), true);

-- ------------------------------------------------------------------ single entry and confirmation
select test.tz_log('near', 'TA', '2026-03-02 10:20', 800);
select test.tz_log('late', 'TA', '2026-03-12 13:00', 1000);
select test.tz_log('staff', 'TA', '2026-03-08 14:30', 900);
select test.tz_log('own', 'TC', '2026-04-11 12:00', 1250);
select test.tz_log('turo', 'TT', '2026-05-02 12:00', 700);
select test.tz_log('never', 'TA', '2026-05-11 12:00', 300);
select test.tz_log('ticket', 'TD', to_char(now() - interval '1 day', 'YYYY-MM-DD HH24:MI'), 6000, 'ticket');
select test.throws('E the same notice cannot be logged twice', $$select test.tz_log('near', 'TA', '2026-03-02 10:20', 800)$$, 'already logged');
select test.throws('E a ticket needs its notice number',
  format($$select app.log_toll_ticket('{"kind":"ticket","authority":"City","plate":"X1","occurred_at":"2026-03-01 10:00","amount_cents":5}', %L)$$, test.id('tz_fin')),
  'notice number');
select test.throws('E only Finance or an Admin logs a notice', format($$select app.log_toll_ticket('{}', %L)$$, test.id('tz_fleet')), 'Finance or an Admin');
select test.eq('E statuses after intake: near and never wait for review; late, staff, own, turo and ticket matched',
  (select string_agg(replace(notice_number, 'N-', '') || '=' || status || '/' || coalesce(match_confidence, '-'), ' ' order by notice_number)
     from toll_tickets where notice_number in ('N-near', 'N-late', 'N-staff', 'N-own', 'N-turo', 'N-never', 'N-ticket')),
  'late=matched/high near=logged/medium never=logged/low own=matched/high staff=matched/high ticket=matched/high turo=matched/high');
select test.eq('E review tasks for the medium and low rows',
  (select count(*) from tasks k join toll_tickets t on t.id = k.related_id where k.task_type = 'review_toll_match' and t.notice_number in ('N-near', 'N-never')), 2::bigint);
select test.throws('E a medium renter match needs the tracker proof',
  format('select app.confirm_toll_match(%L, %L)', (test.tz_t('near')).id, test.id('tz_fin')), 'tracker proof');
select test.throws('E a booking never handed over cannot be confirmed',
  format('select app.confirm_toll_match(%L, %L)', (test.tz_t('never')).id, test.id('tz_fin')), 'never handed over');
select app.confirm_toll_match((test.tz_t('near')).id, test.id('tz_fin'), jsonb_build_object('index', 0, 'tracker_proof_document_id', test.tz_doc('gps-near', 'other')));
select test.eq('E with the tracker proof the match is confirmed and its task closed',
  (select t.status || '/' || t.matched_how || '/' || (t.tracker_proof_document_id is not null) || '/'
          || (select string_agg(status, ',') from tasks where related_id = t.id and task_type = 'review_toll_match')
     from toll_tickets t where notice_number = 'N-near'), 'matched/confirmed/true/done');
select test.throws('E a manual booking must have been on the vehicle',
  format($$select app.confirm_toll_match(%L, %L, '{"kind":"renter","booking_id":"%s"}')$$, (test.tz_t('never')).id, test.id('tz_fin'), test.id('booking:TO1')),
  'not on this vehicle');
select test.eq('E bulk confirm: clear rows confirmed, others skipped with the reason',
  (select string_agg(x ->> 'result' || coalesce(':' || (x ->> 'reason'), ''), ' | ' order by x ->> 'result')
     from jsonb_array_elements(app.bulk_confirm_toll_matches(array[(test.tz_t('late')).id, (test.tz_t('never')).id], test.id('tz_fin'))) x),
  'confirmed | skipped:not a clear match: confirm it on its own');

-- ------------------------------------------------------------------ charging the renter
-- TA1 is closed: its Check-in statement was issued and the Deposit fully released, so the toll
-- statement is a supplementary one and the money comes from the Card on File.
insert into booking_statements (booking_id, statement_number, kind, issued_at) values (test.id('booking:TA1'), 'RS-TZ1', 'check_in', test.at('2026-03-06 12:00'));
insert into deposits (booking_id, amount_cents, method, status, captured_cents, applied_cents, released_cents, release_approved_by)
values (test.id('booking:TA1'), 100000, 'card_hold', 'settled', 0, 0, 100000, test.id('tz_admin'));
create temp table ch1 as select app.charge_toll_ticket(array(select id from toll_tickets where notice_number in ('T-1', 'T-2')), test.id('tz_fin'), test.at('2026-03-25 10:00')) as r;
select test.eq('C closed booking: one group, charged to the card',
  (select string_agg(x ->> 'result' || '/' || (x ->> 'charged_from') || '/' || (x ->> 'admin_fee_cents'), ' ') from ch1, jsonb_array_elements(r) x), 'charged/card_on_file/1500');
select test.eq('C two trips of one statement and booking: two pass-through lines and one $15 fee, HST on the fee only',
  (select string_agg(charge_type || ':' || amount_cents || ':' || hst_cents, ' ' order by charge_type, amount_cents) from booking_line_items
    where booking_id = test.id('booking:TA1') and toll_ticket_id is not null), 'toll_admin_fee:1500:195 toll_amount:325:0 toll_amount:450:0');
select test.eq('C a later-charge statement (the issued Check-in statement is untouched)',
  (select string_agg(kind || ':' || charges_cents || ':' || hst_cents, ' ' order by issued_at) from booking_statements where booking_id = test.id('booking:TA1')),
  'check_in:0:0 later_charge:2275:195');
select test.eq('C a pending card charge for $24.70 is left for the server',
  (select string_agg(purpose || '/' || kind || '/' || amount_cents || '/' || status, ' ') from payments where booking_id = test.id('booking:TA1') and purpose = 'post_rental'),
  'post_rental/charge/2470/pending');
select test.eq('C the fee sits on the first row only; both rows charged and notified, one group',
  (select string_agg(admin_fee_cents || '/' || status || '/' || (notified_at is not null) || '/' || (toll_group_id is not null), ' ' order by occurred_at)
     from toll_tickets where notice_number in ('T-1', 'T-2')), '1500/charged/true/true 0/charged/true/true');
select test.eq('C the renter is told once, with the notices and the statement (renter_extra_charge)',
  (select count(*) || '/' || min(payload ->> 'charged_from') || '/' || min(jsonb_array_length(payload -> 'document_ids'))
     from app_events where code = 'renter_extra_charge' and entity_id = (select booking_statement_id from toll_tickets where notice_number = 'T-1')), '1/card_on_file/2');
select test.eq('C charging again is refused per group, and nothing changes',
  (select string_agg(x ->> 'result', ',') from jsonb_array_elements(app.charge_toll_ticket(array[(select id from toll_tickets where notice_number = 'T-1')], test.id('tz_fin'))) x)
  || '/' || (select count(*) from booking_line_items where booking_id = test.id('booking:TA1') and toll_ticket_id is not null), 'failed/3');

-- TA2 is returned with part of the Deposit held back for an expected toll: the toll comes from it.
insert into booking_statements (booking_id, statement_number, kind, issued_at) values (test.id('booking:TA2'), 'RS-TZ2', 'check_in', test.at('2026-03-12 18:00'));
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:TA2-dep'), test.id('booking:TA2'), test.id('renter:tz_r2'), 'deposit', 'capture', 'card', 20000, 'succeeded', test.at('2026-03-12 18:00'));
insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, captured_cents, applied_cents, held_back_cents, held_back_reason, held_back_until, released_cents, release_approved_by)
values (test.id('booking:TA2'), 100000, 'card_hold', 'captured', test.id('pay:TA2-dep'), 20000, 0, 20000, 'toll expected', date '2026-04-10', 80000, test.id('tz_admin'));
select app.charge_toll_ticket(array[(test.tz_t('late')).id], test.id('tz_fin'), test.at('2026-03-20 10:00'));
select test.eq('C held Deposit: the toll and fee ($10 + $15 + $1.95) come from the held-back amount; the rest stays held',
  (select t.charged_from || '/' || d.applied_cents || '/' || d.held_back_cents || '/' || d.released_cents
     from toll_tickets t, deposits d where t.notice_number = 'N-late' and d.booking_id = test.id('booking:TA2')), 'deposit/2695/17305/80000');
select test.eq('C no card charge on TA2', (select count(*) from payments where booking_id = test.id('booking:TA2') and purpose = 'post_rental'), 0::bigint);

-- TD1 is on rent: the lines wait for its Check-in statement; changing a fee default changes the fee
insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, note, effective_from, effective_to)
values ('ticket_admin_fee', 'premium', 5500, 'test: premium class from Sep 21 to 30', date '2026-09-21', date '2026-09-30');
select test.eq('C the ticket fee follows the fee defaults: $55 for a premium car booked in the window, $40 otherwise',
  app.toll_ticket_admin_fee('ticket', 'renter', test.id('booking:TD1')) || '/' || app.toll_ticket_admin_fee('ticket', 'renter', test.id('booking:TA1')), '5500/4000');
select app.charge_toll_ticket(array[(test.tz_t('ticket')).id], test.id('tz_fin'));
select test.eq('C active booking: the ticket and its $55 fee are on the booking, waiting for the Check-in statement',
  (select string_agg(charge_type || ':' || amount_cents || ':' || (statement_id is null), ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:TD1') and toll_ticket_id is not null) || '/' || (test.tz_t('ticket')).status || '/' || coalesce((test.tz_t('ticket')).notified_at::text, 'not yet'),
  'ticket_admin_fee:5500:true ticket_amount:6000:true/charged/not yet');
select test.throws('C a notice not matched to a renter is not charged',
  format($$select case when (select r ->> 'result' from jsonb_array_elements(app.charge_toll_ticket(array[%L]::uuid[], %L)) r) = 'failed' then 1/0 end$$,
         (test.tz_t('own')).id, test.id('tz_fin')), 'division by zero');
select test.throws('C a VA in customer service cannot charge', format('select app.charge_toll_ticket(array[%L]::uuid[], %L)', (test.tz_t('near')).id, test.id('tz_cs')), 'Finance or an Admin');

-- ------------------------------------------------------------------ the Owner, staff, disputes
select app.bill_toll_to_owner((test.tz_t('own')).id, test.id('tz_fin'));
select test.eq('O Owner Booking: a deduction at cost, no fee, on the Owner''s next statement',
  (select d.kind || '/' || d.amount_cents || '/' || (d.receipt_document_id = t.document_id) || '/' || t.status || '/' || t.admin_fee_cents
     from toll_tickets t join owner_deductions d on d.id = t.owner_deduction_id where t.notice_number = 'N-own'), 'owner_booking_toll/1250/true/billed_to_owner/0');
select app.bill_toll_to_owner((test.tz_t('turo')).id, test.id('tz_fin'));
select test.eq('O Turo-Only: forwarded; the Owner is told both times (owner_toll_ticket)',
  (select string_agg((payload ->> 'is_forwarded'), ',' order by payload ->> 'is_forwarded') from app_events
    where code = 'owner_toll_ticket' and entity_id in ((test.tz_t('own')).id, (test.tz_t('turo')).id)) || '/' || (test.tz_t('turo')).status,
  'false,true/forwarded_to_owner');
select test.throws('O a renter match is not billed to the Owner', format('select app.bill_toll_to_owner(%L, %L)', (test.tz_t('near')).id, test.id('tz_fin')), 'not to the Owner');
select app.mark_toll_company_paid((test.tz_t('staff')).id, test.id('tz_fin'), 'BANK-9', test.at('2026-06-03 10:00'));
select test.eq('O staff: CarmaCars pays, noted against the staff member',
  (select status || '/' || (staff_user_id = test.id('tz_driver')) || '/' || payment_reference from toll_tickets where notice_number = 'N-staff'), 'company_paid/true/BANK-9');
select app.dispute_toll_ticket((test.tz_t('near')).id, test.id('tz_fin'), 'Renter shows a receipt for the trip');
select test.eq('O dispute', (test.tz_t('near')).status || '/' || (test.tz_t('near')).dispute_reason, 'disputed/Renter shows a receipt for the trip');
select test.throws('O only an Admin names a renter to the authority', format('select app.name_renter_to_authority(%L, %L)', (test.tz_t('near')).id, test.id('tz_fin')), 'Only an Admin');
select app.name_renter_to_authority((test.tz_t('near')).id, test.id('tz_admin'));
select test.eq('O named to the authority, with the event', (test.tz_t('near')).status || '/' ||
  (select count(*) from app_events where code = 'renter_named_to_authority' and entity_id = (test.tz_t('near')).id), 'named_to_authority/1');

-- ------------------------------------------------------------------ work queue and the unmatched watch
select test.login(test.id('tz_fin'));
select test.eq('Q buckets: unmatched, needs review, matched not charged, charged not notified',
  (select string_agg(distinct bucket, ',' order by bucket) from toll_work_queue
    where notice_number in ('T-10', 'N-never', 'T-9', 'N-ticket')), 'charged_not_notified,matched_not_charged,needs_review,unmatched');
select test.eq('Q by age: every open row has an age band', (select count(*) from toll_work_queue where age_band is null), 0::bigint);
select test.ok('Q the summary counts by bucket and age', (select sum(notices) from toll_work_queue_summary) = (select count(*) from toll_work_queue));
select test.logout();
update toll_tickets set received_on = date '2026-03-20' where notice_number = 'T-10';
select test.eq('Q the watch runs from 06:00', app.job_toll_watch(test.at('2026-03-25 07:00')), 'succeeded');
select test.eq('Q the watch raises the Admin task and the staff event after the set business days',
  'succeeded/' ||
  (select count(*) || ':' || min(queue) || ':' || bool_and(escalated) from tasks k join toll_tickets t on t.id = k.related_id where k.task_type = 'toll_unmatched' and t.notice_number = 'T-10')
  || '/' || (select count(*) from app_events e join toll_tickets t on t.id = e.entity_id where e.code = 'staff_toll_ticket_unmatched' and t.notice_number = 'T-10'),
  'succeeded/1:admin:true/1');
select test.eq('Q the watch does not run twice for a day', app.job_toll_watch(test.at('2026-03-25 09:00')), 'already_run');
select app.close_toll_ticket((select id from toll_tickets where notice_number = 'T-10'), test.id('tz_fin'), 'Not our vehicle: the plate was misread');
select test.eq('Q closing with a reason cancels its tasks',
  (select t.status || '/' || (select string_agg(distinct k.status, ',') from tasks k where k.related_id = t.id) from toll_tickets t where notice_number = 'T-10'), 'closed/cancelled');

-- ------------------------------------------------------------------ damage after the rental
-- reports either side of TA1, and a damage found the next day, with a repair estimate
insert into condition_reports (id, vehicle_id, booking_id, kind, performed_at, completed_at) values
  (test.id('cr:TA1-pickup'), test.id('vehicle:TA'), test.id('booking:TA1'), 'pickup', test.at('2026-03-02 10:00'), test.at('2026-03-02 10:00')),
  (test.id('cr:TA1-return'), test.id('vehicle:TA'), test.id('booking:TA1'), 'return', test.at('2026-03-06 10:00'), test.at('2026-03-06 10:00'));
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TA'), 'found_at', test.at('2026-03-07 09:00'), 'location', 'rear bumper',
         'description', 'scrape 10 cm', 'before_report_id', test.id('cr:TA1-pickup'), 'after_report_id', test.id('cr:TA1-return'),
         'cost_kind', 'repair_estimate', 'cost_cents', 80000, 'cost_document_id', test.tz_doc('est-1', 'repair_estimate'), 'shop_name', 'Approved shop'),
       test.id('tz_fleet'));
select test.eq('D the pickup and return reports of one booking bracket the damage: matched automatically',
  (select matched_to || '/' || match_confidence || '/' || (booking_id = test.id('booking:TA1')) from damage_intakes where description = 'scrape 10 cm'), 'renter/high/true');
select test.throws('D only an Admin bills damage', format('select app.bill_damage(%L, %L)', (select id from damage_intakes where description = 'scrape 10 cm'), test.id('tz_fin')), 'An Admin');
create temp table dm1 as select app.bill_damage((select id from damage_intakes where description = 'scrape 10 cm'), test.id('tz_admin'), test.at('2026-03-07 10:00')) as r;
select test.eq('D under the deductible: at cost plus the administration fee, through 0020''s assessment, on a later-charge statement',
  (select r ->> 'route' from dm1) || '/' ||
  (select string_agg(charge_type || ':' || amount_cents, ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:TA1') and incident_id = (select (r ->> 'incident_id')::uuid from dm1) and voided_at is null),
  'at_cost/admin_fee_other:5000 damage_at_cost:80000');
select test.eq('D the damage was recorded on the return report (record_late_damage) and the renter told',
  (select count(*) from condition_report_damages where condition_report_id = test.id('cr:TA1-return') and found_later) || '/' ||
  (select count(*) from app_events where code = 'renter_damage_found' and entity_id = (select (r ->> 'incident_id')::uuid from dm1)), '1/1');
select test.eq('D the renter is charged with the estimate (renter_extra_charge, damage)',
  (select count(*) from app_events where code = 'renter_extra_charge' and dedupe_key = 'renter_extra_charge:' || (select r ->> 'statement_id' from dm1) || ':damage'), 1::bigint);
-- over the deductible on TB1 (time known): a claim
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TB'), 'found_at', test.at('2026-04-06 09:00'), 'occurred_at', '2026-04-02T16:00:00Z',
         'location', 'front', 'description', 'collision', 'cost_kind', 'repair_estimate', 'cost_cents', 300000,
         'cost_document_id', test.tz_doc('est-2', 'repair_estimate')), test.id('tz_fleet'));
create temp table dm2 as select app.bill_damage((select id from damage_intakes where description = 'collision'), test.id('tz_admin'), test.at('2026-04-06 10:00')) as r;
select test.eq('D at or over the deductible: a claim with the $2,500 deductible and the $75 fee (waiting for the Check-in statement)',
  (select r ->> 'route' from dm2) || '/' || (select path from claims where id = (select (r ->> 'claim_id')::uuid from dm2)) || '/' ||
  (select string_agg(charge_type || ':' || amount_cents || ':' || (statement_id is null), ' ' order by charge_type) from booking_line_items
    where booking_id = test.id('booking:TB1') and incident_id = (select (r ->> 'incident_id')::uuid from dm2) and voided_at is null),
  'claim/fleet_policy/admin_fee_claim:7500:true deductible:250000:true');
-- an Owner Booking: under the deductible nothing; with a claim, the Owner is billed the deductible
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TO'), 'occurred_at', '2026-04-16T16:00:00Z', 'location', 'door', 'description', 'dent',
         'cost_kind', 'repair_estimate', 'cost_cents', 50000, 'cost_document_id', test.tz_doc('est-3', 'repair_estimate')), test.id('tz_fleet'));
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TO'), 'occurred_at', '2026-04-17T16:00:00Z', 'location', 'roof', 'description', 'hail',
         'cost_kind', 'repair_estimate', 'cost_cents', 300000, 'cost_document_id', test.tz_doc('est-4', 'repair_estimate')), test.id('tz_fleet'));
select app.bill_damage((select id from damage_intakes where description = 'dent'), test.id('tz_admin'), test.at('2026-04-19 10:00'));
select app.bill_damage((select id from damage_intakes where description = 'hail'), test.id('tz_admin'), test.at('2026-04-19 11:00'));
select test.eq('D Owner Booking under the deductible: the Owner repairs, nothing billed',
  (select route from damage_intakes where description = 'dent'), 'owner_repairs');
select test.eq('D Owner Booking with a claim: the deductible is an owner deduction',
  (select route from damage_intakes where description = 'hail')
  || '/' || (select string_agg(kind || ':' || amount_cents, ' ') from owner_deductions where booking_id = test.id('booking:TOB2')),
  'owner_deductible/owner_booking_deductible:250000');
-- staff had the car: CarmaCars bears it, noted against the staff member (an expense in June)
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TA'), 'occurred_at', '2026-03-08T18:30:00Z', 'location', 'mirror', 'description', 'mirror cracked',
         'cost_kind', 'repair_invoice', 'cost_cents', 30000, 'cost_document_id', test.tz_doc('inv-5', 'repair_invoice')), test.id('tz_fleet'));
select app.bill_damage((select id from damage_intakes where description = 'mirror cracked'), test.id('tz_admin'), test.at('2026-06-20 12:00'));
select test.eq('D staff: CarmaCars bears the repair as an expense noted against the staff member',
  (select route from damage_intakes where description = 'mirror cracked')
  || '/' || (select category || ':' || amount_cents || ':' || (staff_user_id = test.id('tz_driver')) from company_expenses where description like '%mirror cracked'),
  'company/repair_absorbed:30000:true');
-- nobody in the window: reviewed and confirmed by hand
select app.log_damage(jsonb_build_object('vehicle_id', test.id('vehicle:TB'), 'window_from', '2026-02-10T12:00:00Z', 'window_to', '2026-02-12T12:00:00Z',
         'location', 'wheel', 'description', 'curb rash'), test.id('tz_fleet'));
select test.eq('D no candidate: review task in the finance queue',
  (select d.matched_to || '/' || d.match_confidence || '/' || (select count(*) from tasks k where k.related_id = d.id and k.task_type = 'review_damage_match')
     from damage_intakes d where description = 'curb rash'), 'unmatched/none/1');
select app.confirm_damage_match((select id from damage_intakes where description = 'curb rash'), test.id('tz_fin'),
                                jsonb_build_object('kind', 'staff', 'staff_user_id', test.id('tz_driver')));
select test.eq('D confirmed by hand', (select matched_to || '/' || status || '/' || match_confidence from damage_intakes where description = 'curb rash'), 'staff/matched/low');
select test.login(test.id('tz_fleet'));
select test.eq('D work queue: the confirmed damage needs its estimate', (select bucket from damage_work_queue where description = 'curb rash'), 'needs_estimate');
select test.logout();

-- ------------------------------------------------------------------ owner statements: the worked month still pays $1,922.25
select test.eq('S the owner specification''s worked month still pays $1,922.25 (statement of 02)',
  (select payout_cents from owner_statements where owner_id = test.id('owner:olivia') and statement_month = date '2026-11-01' and status <> 'void'), test.money('1,922.25'));

-- ------------------------------------------------------------------ June 2026: every kind of car
select test.mk_owner('tz_olga');
select test.mk_vehicle(n, 'tz_olga', 'managed', 45000, 2500, 3500, date '2026-02-01') from unnest(array['TJA', 'TJB', 'TJC']) n;
select test.mk_owner('tz_hold', null, null, true);
select test.mk_vehicle('TH', 'tz_hold', 'managed', 0, 0, 1000, date '2026-02-01', true);
select test.mk_renter(n, false) from unnest(array['tz_j1', 'tz_j2', 'tz_j3', 'tz_j4', 'tz_j5']) n;
select test.mk_renter('tz_olga_as_renter', false);
update renters set user_id = test.id('tz_olga'), is_owner_account = true where id = test.id('renter:tz_olga_as_renter');
-- J1: $500 with a $50 promo code discount and $75 delivery
select test.mk_booking('J1', 'TJA', 'tz_j1', '2026-06-01 10:00', '2026-06-06 10:00', 'closed', 50000, 'standard', null, '2026-06-01 09:00');
select test.mk_line('J1', 'promo_discount', -5000);
select test.mk_line('J1', 'delivery', 7500);
-- J2: $600, 25% refunded ($150 + HST $19.50) in June
select test.mk_booking('J2', 'TJA', 'tz_j2', '2026-06-10 10:00', '2026-06-15 10:00', 'closed', 60000, 'standard', null, '2026-06-02 09:00');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, processed_at)
values (test.id('pay:J2-refund'), test.id('booking:J2'), test.id('renter:tz_j2'), 'booking_total', 'refund', 'card', 16950, 'succeeded', test.id('payment:J2'), test.at('2026-06-16 10:00'));
insert into refunds (id, booking_id, payment_id, refund_payment_id, reason, refund_bps, amount_cents, status, requested_by, approved_by, approved_at, paid_at)
values (test.id('refund:J2'), test.id('booking:J2'), test.id('payment:J2'), test.id('pay:J2-refund'), 'goodwill', 2500, 16950, 'paid',
        test.id('tz_admin'), test.id('tz_admin'), test.at('2026-06-16 09:00'), test.at('2026-06-16 10:00'));
select app.allocate_refund(test.id('refund:J2'));
-- J3: $700, billed to an insurer, invoice paid
select test.mk_booking('J3', 'TJB', 'tz_j3', '2026-06-08 10:00', '2026-06-15 10:00', 'closed', 70000, 'standard', null, '2026-06-03 09:00');
insert into insurers (id, name) values (test.id('insurer:tz'), 'Insurer A');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:tz') where id = test.id('booking:J3');
insert into insurer_invoices (booking_id, insurer_id, period_start, period_end, amount_cents, hst_cents, status, sent_at, paid_cents, paid_at)
values (test.id('booking:J3'), test.id('insurer:tz'), date '2026-06-08', date '2026-06-15', 70000, 9100, 'paid', test.at('2026-06-15 12:00'), 79100, test.at('2026-06-25 12:00'));
-- an Owner Booking on TJC with a toll billed to the Owner at cost
select test.mk_booking('OBJ', 'TJC', 'tz_olga_as_renter', '2026-06-20 10:00', '2026-06-22 10:00', 'closed', null, 'owner', null, '2026-06-05 09:00');
select test.tz_log('olga-own', 'TJC', '2026-06-21 12:00', 1250);
select app.bill_toll_to_owner((test.tz_t('olga-own')).id, test.id('tz_fin'));
-- shareholder car at 90/10, a Self-Managed car with delivery, a Turo-Only trip
select test.mk_booking('J4', 'TH', 'tz_j4', '2026-06-05 10:00', '2026-06-08 10:00', 'closed', 30000, 'standard', null, '2026-06-04 09:00');
select test.mk_booking('J5', 'TS', 'tz_j5', '2026-06-12 10:00', '2026-06-14 10:00', 'closed', 20000, 'standard', null, '2026-06-05 09:00');
select test.mk_line('J5', 'delivery', 7500);
insert into turo_trips (vehicle_id, turo_trip_ref, starts_at, ends_at, gross_cents, turo_fees_cents, company_extras_cents, revenue_share_bps, revenue_share_cents, statement_month, received_at)
values (test.id('vehicle:TT'), 'TZ-TURO-1', test.at('2026-06-10 10:00'), test.at('2026-06-13 10:00'), 40000, 10000, 5000, 3500, public.calc_bps(30000, 3500), date '2026-06-01', test.at('2026-06-16 10:00'));
-- June fees, all paid; a fleet insurance premium entered by hand
select app.generate_owner_invoice(test.id('vehicle:' || n), date '2026-06-01') from unnest(array['TJA', 'TJB', 'TJC', 'TS']) n;
update owner_invoices set status = 'issued' where period_month = date '2026-06-01' and vehicle_id in (select test.id('vehicle:' || n) from unnest(array['TJA', 'TJB', 'TJC', 'TS']) n);
update owner_invoices set status = 'paid' where period_month = date '2026-06-01' and vehicle_id in (select test.id('vehicle:' || n) from unnest(array['TJA', 'TJB', 'TJC', 'TS']) n);
insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, created_by)
values (date '2026-06-30', 'fleet_insurance', 'Fleet policy premium, June', 100000, 0, test.id('tz_fin'));

-- owner statements for June
select app.build_owner_statement(test.id('owner:' || n), date '2026-06-01') from unnest(array['tz_olga', 'tz_hold', 'tz_sam', 'tz_tom']) n;
create temp view jst as select o.legal_name, s.* from owner_statements s join owners o on o.id = s.owner_id
  where s.statement_month = date '2026-06-01' and s.status <> 'void' and o.id in (select test.id('owner:' || n) from unnest(array['tz_olga', 'tz_hold', 'tz_sam', 'tz_tom']) n);
select test.eq('S every Owner has a June statement, one block per car in the program (TJC with only an Owner Booking included)',
  (select string_agg(legal_name || ':' || (select count(*) from owner_statement_vehicles v where v.owner_statement_id = jst.id), ' ' order by legal_name) from jst),
  'Tz Hold:1 Tz Olga:3 Tz Sam:1 Tz Tom:1');
select test.eq('S Olga: TJA $500 less the $50 promo, plus $600 less the 25% refund = $900 Owner Revenue, 35% kept, $585.00 net',
  (select owner_revenue_cents || '/' || revenue_share_cents || '/' || net_earnings_cents || '/' || payable_cents from owner_statement_vehicles
    where owner_statement_id = (select id from jst where legal_name = 'Tz Olga') and vehicle_id = test.id('vehicle:TJA')), '90000/31500/58500/58500');
select test.eq('S Olga: the insurer-billed booking pays like any other once collected ($700, $455 net)',
  (select owner_revenue_cents || '/' || net_earnings_cents from owner_statement_vehicles
    where owner_statement_id = (select id from jst where legal_name = 'Tz Olga') and vehicle_id = test.id('vehicle:TJB')), '70000/45500');
select test.eq('S Olga: TJC block holds the toll deduction at cost ($12.50)',
  (select owner_costs_deducted_cents || '/' || payable_cents from owner_statement_vehicles
    where owner_statement_id = (select id from jst where legal_name = 'Tz Olga') and vehicle_id = test.id('vehicle:TJC')), '1250/-1250');
select test.eq('S payouts: Olga $1,027.50, shareholder $270.00 (90/10), Self-Managed $200.00, Turo-Only $195.00',
  (select string_agg(legal_name || ':' || payout_cents, ' ' order by legal_name) from jst), 'Tz Hold:27000 Tz Olga:102750 Tz Sam:20000 Tz Tom:19500');
select test.eq('S the per-vehicle breakdown names the booking behind each number',
  (select string_agg(x ->> 'booking_number' || ':' || (x ->> 'owner_revenue_cents'), ' ' order by x ->> 'booking_number')
     from jsonb_array_elements(app.owner_statement_breakdown((select id from jst where legal_name = 'Tz Olga'), test.id('tz_fin')) -> 'vehicles') v,
          jsonb_array_elements(v -> 'lines') x where x ->> 'line_type' = 'rental'), 'J1:45000 J2:45000 J3:70000');
select test.eq('S the toll deduction is on the TJC block with its description',
  (select x ->> 'line_type' || ':' || (x ->> 'amount_cents')
     from jsonb_array_elements(app.owner_statement_breakdown((select id from jst where legal_name = 'Tz Olga'), test.id('tz_fin')) -> 'vehicles') v,
          jsonb_array_elements(v -> 'lines') x where v ->> 'fleet_number' = 'F-TJC'), 'owner_cost:-1250');
select test.throws('S the Owner cannot see a draft statement', format('select app.owner_statement_breakdown(%L, %L)', (select id from jst where legal_name = 'Tz Olga'), test.id('tz_olga')), 'not available');
-- approve, issue, record the payout
select app.approve_owner_statement((select id from jst where legal_name = 'Tz Olga'), test.id('tz_admin'));
select test.eq('S approved: the Owner now sees the breakdown',
  jsonb_array_length(app.owner_statement_breakdown((select id from jst where legal_name = 'Tz Olga'), test.id('tz_olga')) -> 'vehicles'), 3);
-- a later mileage charge on J1 after it was paid out becomes an Owner credit on the next statement
select test.mk_line('J1', 'mileage_overage', 3500);
select app.build_owner_statement(test.id('owner:tz_olga'), date '2026-10-01');
select test.eq('S Owner Revenue billed after the payout becomes an Owner credit (65% of $35 = $22.75) on the next statement',
  (select string_agg(kind || ':' || amount_cents || ':' || status, ' ') from owner_credits where booking_id = test.id('booking:J1'))
  || '/' || (select credits_cents || ':' || payout_cents from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-10-01'),
  'later_rental_revenue:2275:open/2275:2275');
-- the October draft is withdrawn so the June correction below can take the mileage itself
delete from owner_statement_lines where owner_statement_id = (select id from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-10-01');
delete from owner_statement_vehicles where owner_statement_id = (select id from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-10-01');
delete from tasks where related_table = 'owner_statements' and related_id = (select id from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-10-01');
delete from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-10-01';
-- reissue June as a corrected version before the payout is sent
select app.reissue_owner_statement((select id from jst where legal_name = 'Tz Olga'), test.id('tz_admin'), 'promo was entered twice');
select test.eq('S reissue: version 1 voided, version 2 drafted from the sources, payout cancelled, deduction open again',
  (select string_agg(version || ':' || status, ' ' order by version) from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-06-01')
  || '/' || (select string_agg(status, ',') from payouts where owner_statement_id = (select id from owner_statements where owner_id = test.id('owner:tz_olga') and statement_month = date '2026-06-01' and version = 1))
  || '/' || (select status from owner_deductions where id = (test.tz_t('olga-own')).owner_deduction_id),
  '1:void 2:draft/cancelled/open');
select test.eq('S the open credit is waived: the rebuilt split carries the mileage itself',
  (select string_agg(status, ',') from owner_credits where booking_id = test.id('booking:J1')), 'waived');
select test.eq('S the corrected version supersedes the first and now includes the later mileage on J1',
  (select (supersedes_statement_id is not null) || '/' || payout_cents from jst where legal_name = 'Tz Olga'), 'true/105025');
select app.approve_owner_statement((select id from jst where legal_name = 'Tz Olga'), test.id('tz_admin'));
select app.issue_owner_statement((select id from jst where legal_name = 'Tz Olga'), test.id('tz_fin'), test.tz_doc('st-olga-06', 'owner_statement'));
select test.eq('S issued: sent, with the owner_statement_ready event for version 2',
  (select (sent_at is not null) || '/' || (select count(*) from app_events where code = 'owner_statement_ready' and dedupe_key = 'owner_statement_ready:' || jst.id || ':v2')
     from jst where legal_name = 'Tz Olga'), 'true/1');
select test.throws('S a VA cannot record a payout', format('select app.record_owner_payout(%L, %L, ''EFT-9'')', (select id from jst where legal_name = 'Tz Olga'), test.id('tz_fin')), 'Only an Admin');
select app.record_owner_payout((select id from jst where legal_name = 'Tz Olga'), test.id('tz_admin'), 'EFT-OLGA-06', test.at('2026-07-10 10:00'));
select test.eq('S payout recorded: paid with the reference; the statement is paid',
  (select p.status || '/' || p.reference || '/' || s.status from payouts p join jst s on s.id = p.owner_statement_id where s.legal_name = 'Tz Olga'), 'paid/EFT-OLGA-06/paid');
select test.throws('S a paid statement is corrected on the next one, not reissued',
  format('select app.reissue_owner_statement(%L, %L, ''x'')', (select id from jst where legal_name = 'Tz Olga'), test.id('tz_admin')), 'next statement');
select test.eq('S CSV of the owner statement: header and one row per line',
  (select split_part(app.owner_statement_csv(id), chr(10), 1) || '/' || (array_length(string_to_array(app.owner_statement_csv(id), chr(10)), 1) - 1)
     from jst where legal_name = 'Tz Olga'),
  'statement_number,statement_month,version,vehicle,plate,line_type,description,booking_number,starts_on,ends_on,rental_charge_cents,mileage_overage_cents,refunds_cents,chargebacks_cents,kickback_cents,owner_revenue_cents,revenue_share_cents,fee_cents,late_fee_cents,amount_cents/4');

-- ------------------------------------------------------------------ the company statement for June
select test.eq('B the monthly job drafts last month''s company statement on the owner statements'' day (July 5 from 06:00)',
  app.job_company_statement_draft(test.at('2026-07-04 09:00')) || '/' || app.job_company_statement_draft(test.at('2026-07-05 06:00'))
  || '/' || app.job_company_statement_draft(test.at('2026-07-05 08:00')), 'not_due/succeeded/already_run');
select test.eq('B an Admin is asked to review it', (select count(*) || '/' || min(queue) from tasks where task_type = 'review_company_statement'), '1/admin');
select app.build_company_statement(date '2026-06-01', test.id('tz_fin'));
create temp view cv as select l.* from company_statement_lines l join company_statements s on s.id = l.statement_id where s.statement_month = date '2026-06-01';
create function test.cv(p_vehicle text, p_col text) returns text language plpgsql as $$
declare v text;
begin
  execute format('select (%I)::text from cv where level = ''vehicle'' and vehicle_id = %L', p_col, test.id('vehicle:' || p_vehicle)) into v;
  return v;
end $$;
create function test.ct(p_col text) returns text language plpgsql as $$
declare v text;
begin
  execute format('select (%I)::text from cv where level = ''total''', p_col) into v;
  return v;
end $$;
select test.eq('B TJA rental revenue $900, Revenue Share $327.25 (with the $35 mileage), owners'' share $607.75',
  test.cv('TJA', 'rental_revenue_cents') || '/' || test.cv('TJA', 'mileage_cents') || '/' || test.cv('TJA', 'revenue_share_cents') || '/' || test.cv('TJA', 'owner_share_out_cents'),
  '90000/3500/32725/60775');
select test.eq('B TJA the $50 promo: the Owner bore $32.50 (65%), CarmaCars $17.50',
  test.cv('TJA', 'discounts_cents') || '/' || test.cv('TJA', 'discounts_owner_cents') || '/' || test.cv('TJA', 'discounts_company_cents'), '5000/3250/1750');
select test.eq('B TJA company fees by type: delivery $75', test.cv('TJA', 'company_fees_cents') || '/' || test.cv('TJA', 'company_fees_by_type'), '7500/{"delivery": 7500}');
select test.eq('B TJA refunds paid $169.50 (cash); HST collected $150.80 on renter lines + $61.75 on fees; $19.50 refunded',
  test.cv('TJA', 'refunds_cents') || '/' || test.cv('TJA', 'hst_collected_cents') || '/' || test.cv('TJA', 'hst_refunded_cents'), '16950/21255/1950');
select test.eq('B TJA owner fees billed $450 + $25 with HST $61.75, collected $536.75',
  test.cv('TJA', 'insurance_fees_cents') || '/' || test.cv('TJA', 'tracker_fees_cents') || '/' || test.cv('TJA', 'owner_fees_hst_cents') || '/' || test.cv('TJA', 'owner_fees_collected_cents'),
  '45000/2500/6175/53675');
select test.eq('B TJA days: 30 in the program, 10 rented, utilization 33.33%, ADR $90, RevPAD $30',
  test.cv('TJA', 'days_available') || '/' || test.cv('TJA', 'days_rented') || '/' || test.cv('TJA', 'utilization_bps') || '/'
  || test.cv('TJA', 'avg_daily_rate_cents') || '/' || test.cv('TJA', 'revpad_cents'), '30.00/10.00/3333/9000/3000');
select test.eq('B TJA cash: $632.80 (J1 with the later mileage) + $678.00 collected, $169.50 refunded',
  test.cv('TJA', 'cash_collected_cents') || '/' || test.cv('TJA', 'cash_refunded_cents'), '131080/16950');
select test.eq('B TJA net to CarmaCars: $327.25 share + $75 fees + $475 owner fees = $877.25', test.cv('TJA', 'company_net_cents'), '87725');
select test.eq('B TJB insurer billed $791.00 and collected', test.cv('TJB', 'insurer_billed_cents') || '/' || test.cv('TJB', 'insurer_collected_cents'), '79100/79100');
select test.eq('B TJC: two days with the Owner, nothing rented', test.cv('TJC', 'owner_days') || '/' || test.cv('TJC', 'days_rented'), '2.00/0.00');
select test.eq('B shareholder car: $300 rental, 10% kept', test.cv('TH', 'revenue_share_cents') || '/' || test.cv('TH', 'owner_share_out_cents') || '/' || test.cv('TH', 'billing_case'), '3000/27000/shareholder');
select test.eq('B Self-Managed: no share; CarmaCars keeps the $75 delivery', test.cv('TS', 'revenue_share_cents') || '/' || test.cv('TS', 'company_fees_cents'), '0/7500');
select test.eq('B Turo-Only: gross $400, fees $100, share $105, extras $50, owner $195, 3 days rented',
  test.cv('TT', 'turo_gross_cents') || '/' || test.cv('TT', 'turo_fees_cents') || '/' || test.cv('TT', 'turo_revenue_share_cents') || '/'
  || test.cv('TT', 'turo_extras_cents') || '/' || test.cv('TT', 'turo_owner_cents') || '/' || test.cv('TT', 'days_rented'), '40000/10000/10500/5000/19500/3.00');
select test.eq('B TA: the staff toll paid by CarmaCars and the absorbed repair',
  test.cv('TA', 'pass_through_out_cents') || '/' || test.cv('TA', 'company_paid_tolls_cents') || '/' || test.cv('TA', 'expenses_cents'), '900/900/30000');
select test.eq('B owner level: Olga''s three cars summed with her statement payout',
  (select rental_revenue_cents || '/' || revenue_share_cents || '/' || owner_payout_cents || '/' || owner_deductions_cents from cv where level = 'owner' and owner_id = test.id('owner:tz_olga')),
  '160000/57225/105025/1250');
select test.eq('B total: rental $2,100, Revenue Share $602.25, Turo share $105, company fees $150, owner fees $1,900',
  test.ct('rental_revenue_cents') || '/' || test.ct('revenue_share_cents') || '/' || test.ct('turo_revenue_share_cents') || '/' || test.ct('company_fees_cents')
  || '/' || (test.ct('insurance_fees_cents')::bigint + test.ct('tracker_fees_cents')::bigint), '210000/60225/10500/15000/190000');
select test.eq('B total: refunds $169.50, insurer $791, HST collected $563.55, expenses $1,300, CarmaCars-paid tolls $9',
  test.ct('refunds_cents') || '/' || test.ct('insurer_billed_cents') || '/' || test.ct('hst_collected_cents') || '/' || test.ct('expenses_cents') || '/' || test.ct('company_paid_tolls_cents'),
  '16950/79100/56355/130000/900');
select test.eq('B total net: $602.25 + $105 + $50 + $150 + $1,900 - $9 - $1,300 = $1,498.25', test.ct('company_net_cents'), '149825');
select test.eq('B the reconciliation ties: vehicles = owners = total; sources; payments; refunds; payouts',
  (select ties_ok || '/' || jsonb_array_length(checks) || '/' || coalesce(tie_problems, 'none') from company_statements where statement_month = date '2026-06-01'), 'true/15/none');
-- a payment tied to nothing breaks the cash tie and blocks finalization, naming the difference
insert into payments (id, owner_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:stray'), test.id('owner:tz_olga'), 'other', 'charge', 'e_transfer', 4321, 'succeeded', test.at('2026-06-28 12:00'));
select app.build_company_statement(date '2026-06-01', test.id('tz_fin'));
select test.eq('B the rebuilt draft records the failed tie, names it, and raises an urgent Admin task',
  (select ties_ok || '/' || (tie_problems like '%4321 not tied to a booking or an owner invoice%') || '/'
          || (select count(*) || ':' || min(priority) from tasks where task_type = 'company_statement_tie' and status = 'open')
     from company_statements where statement_month = date '2026-06-01'), 'false/true/1:urgent');
select test.throws('B a failed tie blocks finalization and names the difference',
  format($$select app.finalize_company_statement(date '2026-06-01', %L)$$, test.id('tz_admin')), '4321 not tied to a booking or an owner invoice');
update payments set status = 'cancelled' where id = test.id('pay:stray');
select test.throws('B only an Admin finalizes', format($$select app.finalize_company_statement(date '2026-06-01', %L)$$, test.id('tz_fin')), 'Only an Admin');
select app.finalize_company_statement(date '2026-06-01', test.id('tz_admin'));
select test.eq('B the tie task is closed once the rebuild reconciles', (select string_agg(status, ',') from tasks where task_type = 'company_statement_tie'), 'done');
select test.eq('B finalized: frozen, with the staff event',
  (select status || '/' || (select count(*) from app_events where code = 'staff_monthly_statements_ready' and entity_id = s.id) from company_statements s where statement_month = date '2026-06-01'),
  'final/1');
select test.throws('B a final month is never rebuilt', $$select app.build_company_statement(date '2026-06-01')$$, 'is final');
select test.throws('B nor takes a new expense', format($$insert into company_expenses (expense_on, category, description, amount_cents) values (date '2026-06-15', 'other', 'late', 100)$$), 'is final');
-- July: month over month and year to date
select app.build_company_statement(date '2026-07-01');
select test.login(test.id('tz_fin'));
select test.eq('B July carries June beside it and the year to date',
  (select prev_company_net_cents || '/' || ytd_rental_revenue_cents from company_statement_totals where statement_month = date '2026-07-01'),
  '149825/210000');
select test.logout();
select test.eq('B the chart of accounts is on every charge type',
  (select count(*) from fee_types where gl_account is null) || '/' || (select gl_account from fee_types where code = 'toll_admin_fee') || '/' || (select gl_account from fee_types where code = 'toll_amount'),
  '0/4120/2150');
select test.eq('B CSV per vehicle: one row per vehicle line plus the header',
  (select array_length(string_to_array(app.company_statement_csv(date '2026-06-01', 'vehicle'), chr(10)), 1) - 1)::bigint,
  (select count(*) from cv where level = 'vehicle'));
select test.eq('B ledger CSV: accounts with names; Revenue Share 4000 for TJA is $332.50',
  (select split_part(app.company_ledger_csv(date '2026-06-01'), chr(10), 1)) || '/' ||
  (select count(*) from unnest(string_to_array(app.company_ledger_csv(date '2026-06-01'), chr(10))) x where x like '2026-06,4000,Revenue Share,F-TJA,%,32725'),
  'month,account,account_name,vehicle,owner,item,amount_cents/1');

-- ------------------------------------------------------------------ row-level security on every new table and view
select test.eq('R every new table has row-level security, the admin policy and an audit trigger',
  (select count(*) from unnest(array['gl_accounts', 'gl_account_map', 'vehicle_transponders', 'vehicle_plate_history', 'toll_import_profiles',
      'toll_import_batches', 'damage_intakes', 'company_expense_categories', 'company_expenses', 'owner_credits', 'company_statements', 'company_statement_lines']) t
    where exists (select 1 from pg_class c where c.relname = t and c.relrowsecurity)
      and exists (select 1 from pg_policies p where p.tablename = t and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid where c.relname = t and g.tgname = 'audit_' || t)), 12::bigint);
select test.eq('R no function of 0021 that moves money or reads records runs from a browser',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('import_toll_batch', 'charge_toll_ticket', 'bill_toll_to_owner', 'bill_damage', 'build_company_statement',
                                               'finalize_company_statement', 'company_ledger_csv', 'match_toll_candidates', 'reissue_owner_statement', 'record_owner_payout')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), null::text);

create function test.tz_counts() returns text language sql as $$
  select concat_ws('/', test.visible('select * from toll_import_batches'), test.visible('select * from toll_import_profiles'),
    test.visible('select * from vehicle_transponders'), test.visible('select * from damage_intakes'), test.visible('select * from company_statements'),
    test.visible('select * from company_statement_lines'), test.visible('select * from company_expenses'), test.visible('select * from owner_credits'),
    test.visible('select * from toll_work_queue'), test.visible('select * from damage_work_queue'), test.visible('select * from company_statement_report'),
    test.visible('select * from owner_statement_vehicle_lines'))
$$;
select test.login(test.id('tz_admin'));
select test.ok('R admin: sees all of it', (select bool_and(x::bigint > 0) from unnest(string_to_array(test.tz_counts(), '/')) x), test.tz_counts());
select test.logout();
select test.login(test.id('tz_fin'));
select test.eq('R finance: batches, profiles, transponders, damage, statements, expenses, credits, queues, owner lines (all > 0)',
  (select string_agg((x::bigint > 0)::text, ',') from unnest(string_to_array(test.tz_counts(), '/')) x), 'true,true,true,true,true,true,true,true,true,true,true,true');
select test.lives('finance: enters an expense for the current month', $$insert into company_expenses (expense_on, category, description, amount_cents) values (date '2026-10-01', 'software', 'Mapping service', 2500)$$);
select test.throws('finance: cannot change a statement directly', $$update company_statements set ties_ok = true$$, 'permission denied');
select test.logout();
select test.login(test.id('tz_fleet'));
select test.eq('R fleet: transponders, damage and the toll queue; no company money, no import profiles',
  (select concat_ws('/', test.visible('select * from vehicle_transponders') > 0, test.visible('select * from damage_intakes') > 0, test.visible('select * from toll_work_queue') > 0,
     test.visible('select * from company_statements') + test.visible('select * from company_statement_lines') + test.visible('select * from company_expenses')
     + test.visible('select * from company_statement_report') + test.visible('select * from toll_import_profiles') + test.visible('select * from owner_credits'))),
  't/t/t/0');
select test.eq('R fleet: records a transponder', test.affected(format($$insert into vehicle_transponders (vehicle_id, transponder_number, from_date) values (%L, 'TX-888', date '2026-06-01')$$, test.id('vehicle:TC'))), 1::bigint);
select test.logout();
select test.login(test.id('tz_cs'));
select test.eq('R customer service: the chart of accounts only',
  (select test.visible('select * from gl_accounts') > 0) || '/' || (select sum(x::bigint) from unnest(string_to_array(test.tz_counts(), '/')) x), 'true/0');
select test.logout();
select test.login(test.id('tz_olga'));
select test.eq('R owner: own approved statement lines and own credits; nothing else',
  (select (select bool_and(owner_id = test.id('owner:tz_olga') and status in ('approved', 'paid')) from owner_statement_vehicle_lines) || '/'
     || (test.visible('select * from owner_statement_vehicle_lines') > 0) || '/' || (test.visible('select * from owner_credits') > 0) || '/'
     || (test.visible('select * from company_statements') + test.visible('select * from company_statement_lines') + test.visible('select * from toll_work_queue')
         + test.visible('select * from damage_intakes') + test.visible('select * from company_statement_report') + test.visible('select * from toll_import_batches'))),
  'true/true/true/0');
select test.logout();
select test.login(test.id('tz_paul'));
select test.eq('R another owner: none of Olga''s lines', test.visible(format('select * from owner_statement_vehicle_lines where owner_id = %L', test.id('owner:tz_olga'))), 0::bigint);
select test.logout();
select test.login(test.id('tz_r1'));
select test.eq('R renter: nothing new', (select sum(x::bigint) from unnest(string_to_array(test.tz_counts(), '/')) x), 0::numeric);
select test.logout();
select test.login(test.id('tz_field'));
select test.eq('R field staff: nothing new', (select sum(x::bigint) from unnest(string_to_array(test.tz_counts(), '/')) x), 0::numeric);
select test.logout();
set role anon;
select test.eq('R anonymous: no privilege on any new table or view',
  (select string_agg(x, ',') from unnest(string_to_array(test.tz_counts(), '/')) x), '-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1');
reset role;
