-- 26: tolls, plates and forms (migration 0042): reading toll notices and statements into lines that staff check
-- before import, the reading profiles, the vision model's budget, licence plates on listing photos and the publish
-- gate, the official ServiceOntario PDFs and their mapping, and one turnaround between trips. Fixtures start with "tp".
select test.suite('26 tolls plates forms');
create table test.tp (k text primary key, v uuid);
create or replace function test.tp(p text) returns uuid language sql stable as $$ select v from test.tp where k = p $$;
create or replace function test.tp_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;

select test.mk_user('tp_admin', 'admin');
select test.mk_user('tp_fin', 'va', 'finance');
select test.mk_user('tp_cs', 'va', 'cs');
select test.mk_user('tp_fleet', 'va', 'fleet');
select test.mk_owner('tp_olga');
select test.mk_owner('tp_omar');
select test.mk_vehicle('TPA', 'tp_olga');
select test.mk_vehicle('TPB', 'tp_olga');
select test.mk_vehicle('TPC', 'tp_omar');
select test.mk_renter('tp_rosa');
select test.mk_renter('tp_reza');

-- ================================================================ 1. settings
-- helpers.sql switched the plate check off for the earlier suites; it is on by default and on here
alter table program_settings alter column listing_plate_check_required set default true;
insert into program_settings (effective_from) values (date '2099-01-01');
select test.eq('settings: the plate check before publishing is on in a new settings row', (select listing_plate_check_required from program_settings where effective_from = date '2099-01-01'), true);
delete from program_settings where effective_from = date '2099-01-01';
update program_settings set listing_plate_check_required = true;
select test.eq('settings: lines at 80% or more import without a check, renters matched with high confidence are charged, 6 pages, the vision model on with its daily cap, plates checked before publishing, a CarmaCars plate cover by default',
  (select toll_read_min_confidence || '/' || toll_read_auto_charge || '/' || toll_read_max_pages || '/' || ai_vision_enabled || '/' || ai_vision_model || '/'
          || ai_vision_daily_neurons || '/' || listing_plate_check_required || '/' || plate_cover_style || '/' || plate_detect_enabled from app.settings()),
  '80/true/6/true/@cf/meta/llama-4-scout-17b-16e-instruct/3000/true/cover/true');

-- ================================================================ 2. one turnaround between trips (the owner's 2 hours, held once)
select test.eq('turnaround: one setting, 120 minutes; the cleaning block''s length follows it',
  (select turnaround_buffer_minutes || '/' || turnaround_block_minutes from app.settings()), '120/120');
select test.mk_booking('TP-1', 'TPA', 'tp_rosa', '2027-05-03 10:00', '2027-05-05 10:00', 'confirmed');
select test.eq('turnaround: the trip''s cleaning block is the turnaround (2 hours from the return)',
  (select (starts_at = test.tp_at('2027-05-05 10:00')) || '/' || (ends_at - starts_at)::text from vehicle_calendar_blocks where booking_id = test.id('booking:TP-1') and source = 'turnaround'),
  'true/02:00:00');
select test.eq('turnaround: the next trip may start 2 hours after the return, not a minute sooner (not 4 hours: block and buffer do not add up)',
  app.vehicle_is_available(test.id('vehicle:TPA'), test.tp_at('2027-05-05 11:59'), test.tp_at('2027-05-06 10:00')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPA'), test.tp_at('2027-05-05 12:00'), test.tp_at('2027-05-06 10:00')), 'false/true');
select test.eq('turnaround: a trip before must end 2 hours before the pickup',
  app.vehicle_is_available(test.id('vehicle:TPA'), test.tp_at('2027-05-01 10:00'), test.tp_at('2027-05-03 08:01')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPA'), test.tp_at('2027-05-01 10:00'), test.tp_at('2027-05-03 08:00')), 'false/true');
select app.remove_turnaround_block(test.id('tp_fleet'), (select id from vehicle_calendar_blocks where booking_id = test.id('booking:TP-1') and source = 'turnaround'), 'Cleaned at the return');
select test.eq('turnaround: removing the cleaning block frees the time after the return (no second buffer behind it)',
  app.vehicle_is_available(test.id('vehicle:TPA'), test.tp_at('2027-05-05 10:30'), test.tp_at('2027-05-06 10:00')), true);
select app.set_vehicle_turnaround(test.id('tp_fleet'), test.id('vehicle:TPB'), 60);
select test.mk_booking('TP-2', 'TPB', 'tp_reza', '2027-05-03 10:00', '2027-05-05 10:00', 'confirmed');
select test.eq('turnaround: a car''s own turnaround (60 minutes) sets its block and its availability, before and after',
  (select (ends_at - starts_at)::text from vehicle_calendar_blocks where booking_id = test.id('booking:TP-2') and source = 'turnaround') || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-05 10:59'), test.tp_at('2027-05-06 10:00')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-05 11:00'), test.tp_at('2027-05-06 10:00')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-01 10:00'), test.tp_at('2027-05-03 09:00')), '01:00:00/false/true/true');
select app.set_vehicle_turnaround(test.id('tp_admin'), test.id('vehicle:TPB'), null);
update program_settings set turnaround_buffer_minutes = 90 where id = (select id from app.settings());
select test.eq('turnaround: a new turnaround in Program settings moves the blocks ahead and the availability (90 minutes)',
  (select turnaround_block_minutes::text from app.settings()) || '/' ||
  (select (ends_at - starts_at)::text from vehicle_calendar_blocks where booking_id = test.id('booking:TP-2') and source = 'turnaround') || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-05 11:30'), test.tp_at('2027-05-06 10:00')), '90/01:30:00/true');
update program_settings set turnaround_block_enabled = false where id = (select id from app.settings());
select test.eq('turnaround: with the block switched off the same time is still held after the return, without a block',
  (select count(*) from vehicle_calendar_blocks where booking_id = test.id('booking:TP-2') and source = 'turnaround')::text || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-05 11:29'), test.tp_at('2027-05-06 10:00')) || '/' ||
  app.vehicle_is_available(test.id('vehicle:TPB'), test.tp_at('2027-05-05 11:30'), test.tp_at('2027-05-06 10:00')), '0/false/true');
update program_settings set turnaround_buffer_minutes = 120, turnaround_block_enabled = true where id = (select id from app.settings());
select test.eq('turnaround: back to 120 with the block', (select (ends_at - starts_at)::text from vehicle_calendar_blocks where booking_id = test.id('booking:TP-2') and source = 'turnaround'), '02:00:00');
update program_settings set turnaround_block_minutes = 30 where id = (select id from app.settings());
select test.eq('turnaround: the old block minutes cannot drift from the turnaround (set to 30, kept at 120)', (select turnaround_block_minutes::integer from app.settings()), 120);

-- ================================================================ 3. reading a notice: who, context, save
select test.throws('read: customer service does not read notices', format('select app.toll_read_context(%L)', test.id('tp_cs')), 'Finance or an Admin');
select test.eq('read: Finance gets the profiles (407 ETR first), the fleet''s plates and the settings',
  (select (v -> 'profiles' -> 0 ->> 'name') || '/' || ((v -> 'plates') ? app.norm_plate((select plate from vehicles where id = test.id('vehicle:TPA'))))::text || '/' || (v -> 'settings' ->> 'min_confidence')
     from app.toll_read_context(test.id('tp_fin')) v), '407 ETR statement/true/80');
select test.mk_booking('TP-9', 'TPA', 'tp_rosa', '2026-09-20 10:00', '2026-09-25 10:00', 'closed');
insert into test.tp select 'doc', (app.toll_read_document(test.id('tp_fin'), jsonb_build_object('storage_path', 'tolls/2026/statement.pdf', 'mime_type', 'application/pdf', 'title', '407 ETR statement')) ->> 'id')::uuid;
select test.throws('read: a notice file must be stored under tolls/', format('select app.toll_read_document(%L, %L)', test.id('tp_fin'), '{"storage_path": "x/y.pdf"}'), 'Unknown file');
insert into test.tp select 'r1', (app.toll_read_save(test.id('tp_fin'), jsonb_build_object(
  'method', 'pdf_text', 'document_id', test.tp('doc'), 'file_name', 'statement.pdf', 'mime_type', 'application/pdf', 'authority', '407 ETR', 'kind', 'toll_invoice',
  'statement_number', 'ST-2026-09', 'due_on', '2026-10-30', 'total_cents', 4000,
  'lines', jsonb_build_array(
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPA')), 'occurred_at', '2026-09-22T12:15:00', 'amount_cents', 1234, 'fees_cents', 420,
                        'entry', 'Highway 400', 'exit', 'Dufferin St', 'confidence', 95, 'source_text', '2026-09-22 12:15 PM Highway 400 Dufferin St $8.14 $4.20 $12.34', 'page', 2),
     jsonb_build_object('plate', 'ZZZZ999', 'occurred_at', '2026-09-23T08:00:00', 'amount_cents', 500, 'confidence', 92),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPA')), 'occurred_at', '2026-09-23T09:30:00', 'amount_cents', 777, 'confidence', 50),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPA')), 'occurred_at', '2026-09-24T18:05:00', 'confidence', 90)))) ->> 'id')::uuid;
select test.eq('read: saved in review with its number, its four lines and a Finance task',
  (select status || '/' || (read_number like 'TR-%') || '/' || (select count(*) from toll_notice_read_lines l where l.read_id = r.id) || '/' ||
          (select count(*) from tasks t where t.dedupe_key = 'toll_read_review:' || r.id and t.queue = 'finance' and t.status = 'open')
     from toll_notice_reads r where r.id = test.tp('r1')), 'in_review/true/4/1');
select test.eq('read: each line''s problems in words (a good line has none; a plate not ours; low confidence; amount missing)',
  (select string_agg(l.line_no || ':' || coalesce(array_to_string(l.problems, ','), ''), ' | ' order by l.line_no) from toll_notice_read_lines l where l.read_id = test.tp('r1')),
  '1: | 2:Plate not in the fleet | 3:Read with 50% confidence | 4:Amount missing');
select test.eq('read: the car is found for each line of our plate', (select count(*) from toll_notice_read_lines l where l.read_id = test.tp('r1') and l.vehicle_id = test.id('vehicle:TPA')), 3::bigint);
select test.eq('read: a time without a zone is Toronto time', (select occurred_at = test.tp_at('2026-09-22 12:15') from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 1), true);
select test.throws('read: customer service does not correct lines',
  format('select app.toll_read_line_save(%L, %L)', test.id('tp_cs'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 4))), 'Finance or an Admin');
select app.toll_read_line_save(test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 4), 'values', jsonb_build_object('amount_cents', 655)));
select test.eq('read: a corrected line has no problem left and is marked edited',
  (select coalesce(array_to_string(problems, ','), '') || '/' || edited from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 4), '/true');
select test.throws('read: an amount must be a number of cents',
  format('select app.toll_read_line_save(%L, %L)', test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 4), 'values', jsonb_build_object('amount_cents', '12.5'))), 'Unreadable amount');
select app.toll_read_line_save(test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 3), 'status', 'checked'));
select test.eq('read: a person''s check clears the low confidence', (select status || '/' || coalesce(array_to_string(problems, ','), '') from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 3), 'checked/');
select test.throws('read: leaving a line out needs a reason',
  format('select app.toll_read_line_save(%L, %L)', test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 2), 'status', 'excluded')), 'Say why');

-- ================================================================ 4. confirm: import, match, charge, exceptions
select app.toll_read_confirm(test.id('tp_fin'), jsonb_build_object('read', test.tp('r1'), 'charge', true));
select test.eq('confirm: three lines imported, the plate not ours is an exception with its reason',
  (select string_agg(l.line_no || ':' || l.status, ' ' order by l.line_no) from toll_notice_read_lines l where l.read_id = test.tp('r1')),
  '1:imported 2:exception 3:imported 4:imported');
select test.eq('confirm: the exception says why', (select result_reason from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 2), 'Plate not in the fleet');
select test.eq('confirm: the read is confirmed, with one batch for 407 ETR, the statement number and the notice attached to every toll',
  (select r.status || '/' || cardinality(r.batch_ids) || '/' ||
          (select count(*) from toll_tickets t where t.import_batch_id = r.batch_ids[1] and t.statement_number = 'ST-2026-09' and t.document_id = test.tp('doc') and t.authority = '407 ETR')
     from toll_notice_reads r where r.id = test.tp('r1')), 'confirmed/1/3');
select test.eq('confirm: the trip inside the rental is matched to the renter with high confidence',
  (select t.matched_to || '/' || t.match_confidence || '/' || (t.booking_id = test.id('booking:TP-9')) from toll_tickets t
     join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.tp('r1') and l.line_no = 1), 'renter/high/true');
select test.eq('confirm: the toll keeps where it was read from (read number, line, confidence, fees, the text on the notice) and the fees in its note',
  (select (t.ocr_raw ->> 'read' like 'TR-%') || '/' || (t.ocr_raw ->> 'line_no') || '/' || (t.ocr_raw ->> 'confidence') || '/' || (t.ocr_raw ->> 'fees_cents') || '/' || t.note || '/' || t.place
     from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.tp('r1') and l.line_no = 1),
  'true/1/95/420/Includes $4.20 in fees on the notice/Highway 400 to Dufferin St');
select test.eq('confirm: the renter matched with high confidence was charged (the existing toll charge: notice and administration fee)',
  (select (r.result ->> 'charged') from toll_notice_reads r where r.id = test.tp('r1')), '3');
select test.ok('confirm: each charged notice went through 0021''s charge (charged, or the reason it could not be)',
  (select bool_and(t.charged_at is not null or (r.result -> 'charge_result') is not null) from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id
     join toll_notice_reads r on r.id = l.read_id where l.read_id = test.tp('r1') and t.matched_to = 'renter'));
select test.eq('confirm: the staff notice of 0021 went for each imported toll', (select count(*) from app_events e where e.code = 'staff_toll_ticket_logged'
   and e.entity_id in (select toll_ticket_id from toll_notice_read_lines where read_id = test.tp('r1'))), 3::bigint);
select test.eq('confirm: the review task is done; an exceptions task names the line',
  (select string_agg(t.task_type || ':' || t.status, ' ' order by t.task_type) from tasks t where t.related_id = test.tp('r1')) || '/' ||
  (select position('Line 2: Plate not in the fleet' in detail) > 0 from tasks where dedupe_key = 'toll_read_exceptions:' || test.tp('r1')),
  'toll_read_exceptions:open toll_read_review:done/true');
select test.throws('confirm: a confirmed read is not confirmed again', format('select app.toll_read_confirm(%L, %L)', test.id('tp_fin'), jsonb_build_object('read', test.tp('r1'))), 'already confirmed');
select test.eq('queue: the exception is listed for Finance', (select count(*) from jsonb_array_elements(app.toll_read_queue(test.id('tp_fin')) -> 'exceptions') x where (x ->> 'read_id')::uuid = test.tp('r1')), 1::bigint);
select app.toll_read_line_save(test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 2),
  'values', jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPC')))));
select app.toll_read_line_import(test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 2), 'charge', false));
select test.eq('exception: fixed and imported on its own; nothing left, so the exceptions task is done',
  (select status from toll_notice_read_lines where read_id = test.tp('r1') and line_no = 2) || '/' ||
  (select status from tasks where dedupe_key = 'toll_read_exceptions:' || test.tp('r1')), 'imported/done');

-- a second read of the same statement: every line is already logged
insert into test.tp select 'r2', (app.toll_read_save(test.id('tp_admin'), jsonb_build_object('method', 'vision', 'authority', '407 ETR', 'model', '@cf/test', 'neurons', 12,
  'lines', jsonb_build_array(jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPA')), 'occurred_at', '2026-09-22T12:15:00', 'amount_cents', 1234, 'confidence', 99)))) ->> 'id')::uuid;
select test.eq('duplicate: a line already logged says so before anyone confirms', (select array_to_string(problems, ',') from toll_notice_read_lines where read_id = test.tp('r2')), 'Already logged');
select test.throws('discard: needs a reason', format('select app.toll_read_discard(%L, %L)', test.id('tp_fin'), jsonb_build_object('read', test.tp('r2'))), 'Say why');
select app.toll_read_discard(test.id('tp_fin'), jsonb_build_object('read', test.tp('r2'), 'reason', 'Read twice'));
select test.eq('discard: the read and its task are closed', (select r.status || '/' || (select status from tasks where dedupe_key = 'toll_read_review:' || r.id) from toll_notice_reads r where r.id = test.tp('r2')), 'discarded/cancelled');
select test.throws('discard: a confirmed read stays', format('select app.toll_read_discard(%L, %L)', test.id('tp_fin'), jsonb_build_object('read', test.tp('r1'), 'reason', 'x')), 'waiting for review');

-- a single notice (parking): the notice number is needed
insert into test.tp select 'r3', (app.toll_read_save(test.id('tp_fin'), jsonb_build_object('method', 'pdf_text', 'authority', 'City of Toronto', 'kind', 'parking',
  'lines', jsonb_build_array(jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:TPB')), 'occurred_at', '2026-09-23T14:32:00', 'amount_cents', 3000, 'confidence', 85)))) ->> 'id')::uuid;
select test.eq('single notice: a ticket without its number cannot be imported yet', (select array_to_string(problems, ',') from toll_notice_read_lines where read_id = test.tp('r3')), 'Notice number missing');
select app.toll_read_line_save(test.id('tp_fin'), jsonb_build_object('line', (select id from toll_notice_read_lines where read_id = test.tp('r3')), 'values', jsonb_build_object('notice_number', 'PN 123456')));
select app.toll_read_confirm(test.id('tp_fin'), jsonb_build_object('read', test.tp('r3'), 'charge', false));
select test.eq('single notice: imported as parking, unmatched (nobody had the car), into the existing work queue',
  (select t.kind || '/' || t.matched_to || '/' || t.notice_number from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.tp('r3')), 'parking/unmatched/PN 123456');

-- ================================================================ 5. reading profiles (Admin, no code)
select test.throws('profiles: customer service does not change them', format('select app.toll_profile_upsert(%L, %L)', test.id('tp_cs'), '{"operator": "x", "name": "y"}'), 'Finance or an Admin');
select test.throws('profiles: an unknown field is refused', format('select app.toll_profile_upsert(%L, %L)', test.id('tp_admin'),
  '{"operator": "Highway 412", "name": "412 statement", "rules": {"layout": "statement", "fields": {"colour": ["Colour"]}}}'), 'Unknown field "colour"');
insert into test.tp select 'p1', (app.toll_profile_upsert(test.id('tp_admin'), '{"operator": "Highway 412", "name": "412 statement", "notice_kind": "toll_invoice",
  "rules": {"layout": "statement", "detect": ["Highway 412"], "fields": {"total": ["Amount Due"]}}}') ->> 'id')::uuid;
select app.toll_profile_upsert(test.id('tp_fin'), jsonb_build_object('id', test.tp('p1'), 'operator', 'Highway 412', 'name', '412 statement', 'rules',
  '{"layout": "statement", "detect": ["Highway 412", "412"], "fields": {"total": ["Amount Due", "Total"]}}'::jsonb, 'sample_text', 'Highway 412 Amount Due $3.00'));
select test.eq('profiles: added by an Admin, adjusted by Finance, listed with the others',
  (select (rules -> 'detect' ->> 1) || '/' || source || '/' || (header_signature like 'text:%') from toll_import_profiles where id = test.tp('p1')) || '/' ||
  (select count(*) from jsonb_array_elements(app.toll_profiles(test.id('tp_fin'))) x where x ->> 'source' = 'pdf_text')::text, '412/pdf_text/true/6');

-- ================================================================ 6. the vision model: who, budget, record
select test.throws('vision: customer service does not read notices with it', format('select app.ai_vision_gate(%L, %L)', test.id('tp_cs'), 'toll_read'), 'Finance or an Admin');
select test.eq('vision: Finance may, with the model and the day''s budget', (select (v ->> 'allowed') || '/' || (v ->> 'model') || '/' || (v ->> 'limit') from app.ai_vision_gate(test.id('tp_fin'), 'toll_read') v),
  'true/@cf/meta/llama-4-scout-17b-16e-instruct/3000');
select test.eq('vision: customer service may ask for a plate box', (select v ->> 'allowed' from app.ai_vision_gate(test.id('tp_cs'), 'plate_detect') v), 'true');
select app.ai_call_record(test.id('tp_fin'), '{"purpose": "toll_read", "model": "@cf/meta/llama-4-scout-17b-16e-instruct", "ok": true, "neurons": 2990, "duration_ms": 4100}');
select test.eq('vision: each call is recorded with its neurons', (select (v ->> 'used') from app.ai_vision_budget() v), '2990');
select app.ai_call_record(test.id('tp_cs'), '{"purpose": "plate_detect", "ok": false, "error": "model busy", "neurons": 15}');
select test.eq('vision: past the day''s cap the model is not asked (staff read the notice by hand)',
  (select (v ->> 'allowed') || '/' || (v ->> 'reason') from app.ai_vision_gate(test.id('tp_fin'), 'toll_read') v), 'false/Today''s allowance for the vision model is used up; it starts again at midnight, Toronto time');
delete from provider_calls where purpose in ('toll_read', 'plate_detect');
update program_settings set plate_detect_enabled = false where id = (select id from app.settings());
select test.eq('vision: plate suggestions can be switched off', (select v ->> 'allowed' from app.ai_vision_gate(test.id('tp_cs'), 'plate_detect') v), 'false');
update program_settings set plate_detect_enabled = true where id = (select id from app.settings());
select test.throws('vision: an unknown purpose is refused', format('select app.ai_call_record(%L, %L)', test.id('tp_fin'), '{"purpose": "chat"}'), 'Unknown purpose');

-- ================================================================ 7. the door
select test.eq('door: Finance reads the queue through the staff door', (select jsonb_typeof(app.door(test.id('tp_fin'), 'aal2', 'ops_read', 'toll_read_queue', '{}') -> 'reads')), 'array');
select test.throws('door: a change is never a read', format('select app.door(%L, %L, %L, %L, %L)', test.id('tp_fin'), 'aal2', 'ops_read', 'toll_read_save', '{}'), 'Unknown read');
select test.throws('door: an owner is refused', format('select app.door(%L, %L, %L, %L, %L)', test.id('tp_olga'), 'aal1', 'ops_read', 'toll_read_queue', '{}'), 'Finance or an Admin');

-- ================================================================ 8. licence plates on listing photos
insert into test.tp values ('ph1', gen_random_uuid()), ('ph2', gen_random_uuid()), ('ph3', gen_random_uuid());
insert into vehicle_photos (id, vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, sort_order, approved_at)
values (test.tp('ph1'), test.id('vehicle:TPC'), 'front_left', 'front_left', 'vehicles/x/original/a.jpg', 'vehicles/' || test.id('vehicle:TPC') || '/front-left.jpg', 'approved', true, 1, now()),
       (test.tp('ph2'), test.id('vehicle:TPC'), 'rear', 'rear', 'vehicles/x/original/b.jpg', 'vehicles/' || test.id('vehicle:TPC') || '/rear.jpg', 'approved', true, 2, now()),
       (test.tp('ph3'), test.id('vehicle:TPC'), 'odometer', 'odometer', 'vehicles/x/original/c.jpg', 'vehicles/' || test.id('vehicle:TPC') || '/odometer.jpg', 'approved', false, 3, now());
select test.eq('plates: every photo starts unchecked; the public shots are listed (the odometer never goes public)',
  array_to_string(app.listing_plate_problems(test.id('vehicle:TPC')), ', '),
  (select string_agg(label, ', ' order by seq) from listing_shot_types where code in ('front_left', 'rear')));
select test.throws('plates: Finance does not edit listing photos', format('select app.photo_plate_context(%L, %L)', test.id('tp_fin'), test.tp('ph1')), 'Fleet, customer service or an Admin');
select test.eq('plates: the editor gets the photo, the brand on the cover and the default style',
  (select (v ->> 'cover_text') || '/' || (v ->> 'default_style') || '/' || (v ->> 'is_public_shot') || '/' || (v ->> 'plate_status') from app.photo_plate_context(test.id('tp_cs'), test.tp('ph1')) v),
  (select coalesce(brand_name, 'CarmaCars') from site_settings limit 1) || '/cover/true/unchecked');
select test.throws('plates: a cover needs a box', format('select app.photo_plate_record(%L, %L)', test.id('tp_fleet'),
  jsonb_build_object('photo', test.tp('ph1'), 'status', 'covered', 'style', 'cover', 'boxes', '[]'::jsonb, 'processed_path', 'vehicles/' || test.id('vehicle:TPC') || '/front-left-c1.jpg')), 'Draw at least one box');
select test.throws('plates: a box must be inside the photo', format('select app.photo_plate_record(%L, %L)', test.id('tp_fleet'),
  jsonb_build_object('photo', test.tp('ph1'), 'status', 'covered', 'style', 'cover', 'boxes', '[{"x": 0.9, "y": 0.5, "w": 0.2, "h": 0.1}]'::jsonb, 'processed_path', 'vehicles/' || test.id('vehicle:TPC') || '/front-left-c1.jpg')), 'outside the photo');
select test.throws('plates: the covered file must be this car''s', format('select app.photo_plate_record(%L, %L)', test.id('tp_fleet'),
  jsonb_build_object('photo', test.tp('ph1'), 'status', 'covered', 'style', 'pixelate', 'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb, 'processed_path', 'vehicles/other/front.jpg')), 'not this car');
select app.photo_plate_record(test.id('tp_fleet'), jsonb_build_object('photo', test.tp('ph1'), 'status', 'covered', 'style', 'cover', 'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb,
  'processed_path', 'vehicles/' || test.id('vehicle:TPC') || '/front-left-c1.jpg', 'variants', '[]'::jsonb, 'uncovered_path', 'vehicles/' || test.id('vehicle:TPC') || '/uncovered/front-left.jpg', 'width', 1800, 'height', 1200));
select test.eq('plates: the covered file replaces the public one; the uncovered copy is kept privately; who and when',
  (select plate_status || '/' || plate_style || '/' || (processed_path like '%-c1.jpg') || '/' || (uncovered_path like '%/uncovered/%') || '/' || (plate_checked_by = test.id('tp_fleet')) || '/' || jsonb_array_length(plate_boxes)
     from vehicle_photos where id = test.tp('ph1')), 'covered/cover/true/true/true/1');
select app.photo_plate_record(test.id('tp_cs'), jsonb_build_object('photo', test.tp('ph2'), 'status', 'not_visible'));
select test.eq('plates: nothing left to check', cardinality(app.listing_plate_problems(test.id('vehicle:TPC'))), 0);

-- the publish gate, on the car test 11 listed (every check of 0022 and 0040 passes; its photos have no plate decision)
select app.unlist_listing(test.id('vehicle:oflC'), test.id('tp_admin'), 'Plate check test', null);
select test.throws('plates: publishing waits for the plates, after every other check, naming the photos',
  format('select app.publish_listing(%L, %L)', test.id('vehicle:oflC'), test.id('tp_admin')), 'Cover the licence plate or mark it not visible on every public photo first: Front left, Front');
select test.eq('plates: the refused publish changed nothing', (select status from vehicle_listings where vehicle_id = test.id('vehicle:oflC')), 'unpublished');
select app.photo_plate_record(test.id('tp_fleet'), jsonb_build_object('photo', ph.id, 'status', 'not_visible'))
  from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
 where ph.vehicle_id = test.id('vehicle:oflC') and ph.replaced_at is null and ph.status = 'approved' and st.is_public;
select test.eq('plates: once every public photo is checked the listing publishes', (select (app.publish_listing(test.id('vehicle:oflC'), test.id('tp_admin')) ->> 'status')), 'published');
select app.unlist_listing(test.id('vehicle:oflC'), test.id('tp_admin'), 'Plate check test', null);
select app.photo_plate_record(test.id('tp_cs'), jsonb_build_object('photo', (select id from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and shot_type = 'rear' and replaced_at is null), 'status', 'unchecked'));
update program_settings set listing_plate_check_required = false where id = (select id from app.settings());
select test.eq('plates: with the setting off the plate check is skipped', (select (app.publish_listing(test.id('vehicle:oflC'), test.id('tp_admin')) ->> 'status')), 'published');
update program_settings set listing_plate_check_required = true where id = (select id from app.settings());
select app.photo_plate_suggestion(test.id('tp_cs'), jsonb_build_object('photo', test.tp('ph2'), 'suggestion', '{"boxes": [{"x": 0.42, "y": 0.66, "w": 0.16, "h": 0.06}], "model": "@cf/test"}'::jsonb));
select test.eq('plates: a suggested box is kept with the photo until someone decides', (select plate_suggestion ->> 'model' from vehicle_photos where id = test.tp('ph2')), '@cf/test');

-- ================================================================ 9. official ServiceOntario PDFs
select test.throws('forms: only an Admin maps the official forms', format('select app.form_templates(%L)', test.id('tp_fin')), null);
select test.eq('forms: the five registry forms, the data each can take, the formats',
  (select jsonb_array_length(v -> 'forms') || '/' || ((v -> 'sources') @> '[{"path": "vehicle.vin"}]') || '/' || ((v -> 'transforms') ? 'postal') from app.form_templates(test.id('tp_admin')) v), '5/true/true');
select app.fill_government_form(test.id('vehicle:TPA'), 'SR-LV-012', test.id('tp_admin'));
select test.eq('forms: before a mapping is checked the owner gets the data sheet', (select mode from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null), 'data_sheet');
select test.throws('forms: a PDF with no fillable field is refused, saying why', format('select app.form_template_upload(%L, %L)', test.id('tp_admin'),
  '{"form_code": "SR-LV-012", "file_key": "forms/templates/SR-LV-012/a.pdf", "fields": []}'), 'no fillable fields');
insert into test.tp select 't1', (app.form_template_upload(test.id('tp_admin'), '{"form_code": "SR-LV-012", "file_key": "forms/templates/SR-LV-012/a.pdf", "sha256": "ab", "page_count": 2, "file_name": "sr-lv-012.pdf",
  "fields": [{"name": "owner_name", "type": "text"}, {"name": "vin", "type": "text"}, {"name": "postal", "type": "text"}, {"name": "is_lease", "type": "checkbox"}, {"name": "sig_owner", "type": "signature"}]}') ->> 'id')::uuid;
select test.eq('forms: the uploaded PDF is the current version, not checked yet, with its fields',
  (select is_current || '/' || verified || '/' || jsonb_array_length(field_names) || '/' || (version like 'official-%') from pdf_templates where id = test.tp('t1')), 'true/false/5/true');
select test.throws('forms: a field the PDF does not have', format('select app.form_template_map(%L, %L)', test.id('tp_admin'),
  jsonb_build_object('template', test.tp('t1'), 'field_map', '{"colour": {"source": "vehicle.colour"}}'::jsonb)), 'no field "colour"');
select test.throws('forms: a field needs something to put in it', format('select app.form_template_map(%L, %L)', test.id('tp_admin'),
  jsonb_build_object('template', test.tp('t1'), 'field_map', '{"vin": {"source": "vehicle.serial"}}'::jsonb)), 'choose what goes in it');
select test.throws('forms: a signature alone is not a mapping', format('select app.form_template_map(%L, %L)', test.id('tp_admin'),
  jsonb_build_object('template', test.tp('t1'), 'verify', true, 'field_map', '{"sig_owner": {"type": "signature"}}'::jsonb)), 'Map at least one field');
update owners set postal_code = 'm5v1a1', address_line1 = '1 King St W', city = 'Toronto', province = 'ON' where id = test.id('owner:tp_olga');
-- what the data sheet asks for, so the form is complete (ready to sign)
update vehicles set body_type = 'sedan', colour = 'Black', odometer_km = 12000 where id = test.id('vehicle:TPA');
insert into owner_private_details (owner_id, licence_number, date_of_birth) values (test.id('owner:tp_olga'), 'O1234-56789-01234', date '1985-02-03')
  on conflict (owner_id) do update set licence_number = excluded.licence_number, date_of_birth = excluded.date_of_birth;
update program_settings set company_rin = coalesce(company_rin, 'RIN-TEST'), company_address = coalesce(company_address, '100 Test St, Toronto ON') where id = (select id from app.settings());
select test.eq('forms: the mapping is saved, checked, and the owner''s form is filled again from it',
  (select (v ->> 'verified') || '/' || ((v ->> 'refilled')::integer >= 1) from app.form_template_map(test.id('tp_admin'), jsonb_build_object('template', test.tp('t1'), 'verify', true,
     'field_map', '{"owner_name": {"source": "owner.legal_name", "transform": "upper", "required": true}, "vin": {"source": "vehicle.vin"}, "postal": {"source": "owner.postal_code", "transform": "postal"},
                    "is_lease": {"source": "method.is_lease", "type": "checkbox"}, "sig_owner": {"type": "signature"}}'::jsonb)) v), 'true/true');
select test.eq('forms: the official PDF replaces the data sheet, with each value in its field',
  (select mode || '/' || (field_values ->> 'owner_name') || '/' || (field_values ->> 'vin' = (select upper(vin) from vehicles where id = test.id('vehicle:TPA'))) || '/' || (field_values ->> 'postal') || '/' || (field_values ->> 'is_lease')
     from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null), 'pdf/TP OLGA/true/M5V 1A1/Off');
select test.eq('forms: the Admin''s preview gives the same values without storing a fill',
  (select (v -> 'values' ->> 'postal') || '/' || (v ->> 'file_key') from app.form_template_preview(test.id('tp_admin'), jsonb_build_object('template', test.tp('t1'), 'vehicle', test.id('vehicle:TPA'))) v),
  'M5V 1A1/forms/templates/SR-LV-012/a.pdf');
select test.eq('forms: the owner gets the official form with its values; another owner gets nothing',
  (select (v ->> 'form_code') || '/' || (v ->> 'file_key') || '/' || (v -> 'field_values' ->> 'postal') from public.owner_form_official(test.id('tp_olga'), (select id from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null)) v)
  || '/' || coalesce(public.owner_form_official(test.id('tp_omar'), (select id from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null))::text, 'none'),
  'SR-LV-012/forms/templates/SR-LV-012/a.pdf/M5V 1A1/none');
select test.eq('forms: the owner''s list says the official form is ready', (select x ->> 'official' from jsonb_array_elements(app.owner_portal_forms(test.id('tp_olga'))) x where x ->> 'form_code' = 'SR-LV-012'), 'true');
select test.throws('forms: the signed copy must be in the owner''s own folder', format('select public.owner_form_signed(%L, %L, %L)', test.id('tp_olga'),
  (select id from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null), '{"storage_path": "owners/someone/x.pdf"}'), 'Unknown file');
select public.owner_form_signed(test.id('tp_olga'), (select id from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null),
  jsonb_build_object('storage_path', 'owners/' || test.id('owner:tp_olga') || '/vehicles/x/forms/SR-LV-012-signed.pdf', 'sha256', 'cd'));
select test.eq('forms: signed on screen: the form is signed and the copy is filed as a registry form for the owner and the car',
  (select g.status || '/' || d.kind || '/' || (d.owner_id = test.id('owner:tp_olga')) || '/' || (d.vehicle_id = test.id('vehicle:TPA')) || '/' || d.storage_bucket
     from government_form_fills g join documents d on d.id = g.document_id where g.vehicle_id = test.id('vehicle:TPA') and g.form_code = 'SR-LV-012' and g.superseded_at is null),
  'signed/registry_form/true/true/agreements');
select test.throws('forms: another owner cannot sign it', format('select public.owner_form_signed(%L, %L, %L)', test.id('tp_omar'),
  (select id from government_form_fills where vehicle_id = test.id('vehicle:TPA') and form_code = 'SR-LV-012' and superseded_at is null), '{}'), 'not yours');
insert into test.tp select 't2', (app.form_template_upload(test.id('tp_admin'), '{"form_code": "SR-LV-012", "file_key": "forms/templates/SR-LV-012/b.pdf", "fields": [{"name": "vin", "type": "text"}, {"name": "new_box", "type": "text"}]}') ->> 'id')::uuid;
select test.eq('forms: a newer PDF keeps the mapping of the fields it still has, and waits for a check',
  (select (field_map ? 'vin') || '/' || (field_map ? 'owner_name') || '/' || verified from pdf_templates where id = test.tp('t2')) || '/' ||
  (select is_current::text from pdf_templates where id = test.tp('t1')), 'true/false/false/false');

-- ================================================================ 10. privileges
select test.eq('privileges: the new functions are for the server only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('toll_read_save', 'toll_read_confirm', 'photo_plate_record', 'form_template_map', 'ai_call_record', 'ops42')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
select test.eq('privileges: the reads and their lines have row-level security', (select count(*) from pg_class where relname in ('toll_notice_reads', 'toll_notice_read_lines') and relrowsecurity), 2::bigint);
