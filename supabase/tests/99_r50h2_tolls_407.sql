-- R50 hotfix 2 (5140): a 407 ETR statement as the reader now reads it (each line's date and minute, plate, entry and exit,
-- the toll with its camera and trip charges in the amount, the fees apart) is matched to whoever had the car at that minute
-- with the boundary margin of Program settings, and the renter is charged per the rules: the statement lines and one
-- administration fee per booking and statement, never a line near a rental's edge without a person's check. A ticket on
-- the same file goes the same way. Fixtures start with "rt7".
select test.suite('99 r50h2 tolls 407');
create table test.rt7 (k text primary key, v uuid);
create or replace function test.rt7(p text) returns uuid language sql stable as $$ select v from test.rt7 where k = p $$;
create or replace function test.rt7_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;

select test.mk_user('rt7_fin', 'va', 'finance');
select test.mk_owner('rt7_olive');
select test.mk_vehicle('RT7A', 'rt7_olive');
select test.mk_renter('rt7_rana');
select test.mk_renter('rt7_raj');
select test.mk_booking('RT7-1', 'RT7A', 'rt7_rana', '2026-11-02 10:00', '2026-11-04 10:00', 'closed');
select test.mk_booking('RT7-2', 'RT7A', 'rt7_raj', '2026-11-04 12:00', '2026-11-06 10:00', 'closed');
-- the margin this test runs at (30 minutes), the setting before it kept and put back at the end (99_ tests stay independent)
-- every dated row (an earlier file may have saved a newer one: the date of the trip picks the row)
create table test.rt7_margin as select id, toll_boundary_margin_minutes as m from program_settings;
update program_settings set toll_boundary_margin_minutes = 30;

insert into test.rt7 select 'doc', (app.toll_read_document(test.id('rt7_fin'), jsonb_build_object('storage_path', 'tolls/2026/rt7-statement.pdf', 'mime_type', 'application/pdf', 'title', '2026-11-18 Statement.pdf')) ->> 'id')::uuid;
-- the lines as web/src/features/tolls/parse.ts reads the 407 PDF (parse.test.ts, "407 PDF"): amount = toll + camera + trip charge
insert into test.rt7 select 'r', (app.toll_read_save(test.id('rt7_fin'), jsonb_build_object(
  'method', 'pdf_text', 'document_id', test.rt7('doc'), 'file_name', '2026-11-18 Statement.pdf', 'mime_type', 'application/pdf', 'authority', '407 ETR', 'kind', 'toll_invoice',
  'statement_number', 'ST-0000000001', 'statement_date', '2026-11-18', 'due_on', '2026-12-08',
  'lines', jsonb_build_array(
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-03T08:15:00', 'amount_cents', 2658, 'fees_cents', 525, 'entry', 'Hwy 427', 'exit', 'Brock Rd', 'confidence', 95),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-04T09:50:00', 'amount_cents', 1000, 'fees_cents', 525, 'entry', 'Hwy 401', 'exit', 'Hwy 403', 'confidence', 95),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-04T11:00:00', 'amount_cents', 845, 'fees_cents', 525, 'confidence', 95),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-04T12:45:00', 'amount_cents', 1225, 'fees_cents', 525, 'confidence', 95),
     jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-05T09:05:00', 'amount_cents', 900, 'fees_cents', 100, 'confidence', 95)))) ->> 'id')::uuid;
select test.eq('read: every line has its car and no problem (read with confidence, our plate, a date, an amount)',
  (select string_agg(l.line_no || ':' || coalesce(array_to_string(l.problems, ','), '') || ':' || (l.vehicle_id = test.id('vehicle:RT7A')), ' ' order by l.line_no) from toll_notice_read_lines l where l.read_id = test.rt7('r')),
  '1::true 2::true 3::true 4::true 5::true');

-- the margin moves the answer (a minute inside it is checked by a person)
update program_settings set toll_boundary_margin_minutes = 60;
select test.eq('margin 60: 45 minutes after the pickup is near the edge (medium, a person checks)',
  (select x ->> 'confidence' from app.match_toll_candidates(test.id('vehicle:RT7A'), test.rt7_at('2026-11-04 12:45'), false) x), 'medium');
update program_settings set toll_boundary_margin_minutes = 30;

select app.toll_read_confirm(test.id('rt7_fin'), jsonb_build_object('read', test.rt7('r'), 'charge', true));
select test.eq('match: each trip to whoever had the car at that minute (inside RT7-1; 10 minutes before its return; between rentals; 45 minutes into RT7-2; inside RT7-2)',
  (select string_agg(l.line_no || ':' || t.matched_to || ':' || coalesce(t.match_confidence, '') || ':' || coalesce((select booking_number from bookings b where b.id = t.booking_id), '-'), ' ' order by l.line_no)
     from toll_notice_read_lines l join toll_tickets t on t.id = l.toll_ticket_id where l.read_id = test.rt7('r')),
  '1:renter:high:RT7-1 2:unmatched:medium:- 3:unmatched:none:- 4:renter:high:RT7-2 5:renter:high:RT7-2');
select test.eq('charge: the high matches only (lines 1, 4, 5), never the line near the return',
  (select string_agg(l.line_no::text, ',' order by l.line_no) from toll_notice_read_lines l join toll_tickets t on t.id = l.toll_ticket_id where l.read_id = test.rt7('r') and t.amount_line_item_id is not null),
  '1,4,5');
select test.eq('charge: each booking pays its lines at the statement''s amounts (fees in) and one administration fee for the statement',
  (select string_agg(b.booking_number || ':' || (select sum(li.amount_cents) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'toll_amount' and li.voided_at is null)
                     || '+' || (select count(*) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'toll_admin_fee' and li.voided_at is null), ' ' order by b.booking_number)
     from bookings b where b.booking_number in ('RT7-1', 'RT7-2')),
  'RT7-1:2658+1 RT7-2:2125+1');
select test.eq('charge: the administration fee is the fee schedule''s toll fee', (select li.amount_cents from booking_line_items li where li.booking_id = test.id('booking:RT7-1') and li.charge_type = 'toll_admin_fee'),
  app.toll_ticket_admin_fee('toll_invoice', 'renter', test.id('booking:RT7-1')));
select test.eq('review: the near-edge line waits for a person: RT7-1 suggested, a Confirm task open, nothing charged',
  (select t.status || '/' || (t.match_evidence -> 'suggested' ->> 'booking_number') || '/' || (t.amount_line_item_id is null) || '/' ||
          (select count(*) from tasks k where k.dedupe_key = 'review_toll_match:' || t.id and k.status = 'open')
     from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.rt7('r') and l.line_no = 2), 'logged/RT7-1/true/1');

-- a ticket read from the same kind of file: one line, its notice number, matched and charged with the ticket fee
insert into test.rt7 select 'doc2', (app.toll_read_document(test.id('rt7_fin'), jsonb_build_object('storage_path', 'tolls/2026/rt7-ticket.pdf', 'mime_type', 'application/pdf', 'title', 'Penalty notice')) ->> 'id')::uuid;
insert into test.rt7 select 't', (app.toll_read_save(test.id('rt7_fin'), jsonb_build_object(
  'method', 'pdf_text', 'document_id', test.rt7('doc2'), 'file_name', 'penalty.pdf', 'authority', 'City of Toronto', 'kind', 'parking',
  'lines', jsonb_build_array(jsonb_build_object('notice_number', 'PN 0000-0001', 'plate', (select plate from vehicles where id = test.id('vehicle:RT7A')),
                                                'occurred_at', '2026-11-05T14:32:00', 'amount_cents', 5000, 'place', '100 Queen St W', 'confidence', 90)))) ->> 'id')::uuid;
select app.toll_read_confirm(test.id('rt7_fin'), jsonb_build_object('read', test.rt7('t'), 'charge', true));
select test.eq('ticket: matched to the renter who had the car and charged with the ticket fee',
  (select t.matched_to || '/' || (select booking_number from bookings b where b.id = t.booking_id) || '/' || (t.amount_line_item_id is not null) || '/' ||
          (select count(*) from booking_line_items li where li.booking_id = t.booking_id and li.charge_type = 'ticket_admin_fee' and li.voided_at is null)
     from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.rt7('t')), 'renter/RT7-2/true/1');

-- 5147 (review fix): a statement with a credit left out, or lines that do not add up, charges nothing by itself
insert into test.rt7 select 'doc3', (app.toll_read_document(test.id('rt7_fin'), jsonb_build_object('storage_path', 'tolls/2026/rt7-held.pdf', 'mime_type', 'application/pdf', 'title', 'Held statement.pdf')) ->> 'id')::uuid;
insert into test.rt7 select 'h', (app.toll_read_save(test.id('rt7_fin'), jsonb_build_object(
  'method', 'pdf_text', 'document_id', test.rt7('doc3'), 'file_name', 'Held statement.pdf', 'authority', '407 ETR', 'kind', 'toll_invoice', 'statement_number', 'ST-0000000002',
  'hold', jsonb_build_array('A credit or reversal was left out: 2026-11-07 Reversal -$7.00', 'The lines add up to 26.58, the statement says 19.58'),
  'lines', jsonb_build_array(jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-03T13:15:00', 'amount_cents', 2658, 'fees_cents', 525, 'confidence', 95)))) ->> 'id')::uuid;
select test.eq('hold: saved with the read', (select cardinality(charge_hold) from toll_notice_reads where id = test.rt7('h')), 2);
select app.toll_read_confirm(test.id('rt7_fin'), jsonb_build_object('read', test.rt7('h'), 'charge', true));
select test.eq('hold: the line is matched and imported, nothing charged, a Finance To do lists both items',
  (select t.matched_to || '/' || (t.amount_line_item_id is null) from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.rt7('h')) || '/' ||
  (select queue || ':' || array_length(string_to_array(detail, E'\n'), 1) from tasks where dedupe_key = 'toll_read_hold:' || test.rt7('h') and status = 'open'), 'renter/true/finance:2');
insert into test.rt7 select 'h2', (app.toll_read_save(test.id('rt7_fin'), jsonb_build_object(
  'method', 'pdf_text', 'document_id', test.rt7('doc3'), 'file_name', 'Held statement.pdf', 'authority', '407 ETR', 'kind', 'toll_invoice', 'statement_number', 'ST-0000000003',
  'hold', jsonb_build_array('The lines add up to 12.25, the statement says 20.00'),
  'lines', jsonb_build_array(jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:RT7A')), 'occurred_at', '2026-11-03T14:15:00', 'amount_cents', 1225, 'fees_cents', 525, 'confidence', 95)))) ->> 'id')::uuid;
select app.toll_read_confirm(test.id('rt7_fin'), jsonb_build_object('read', test.rt7('h2'), 'charge', true, 'release_hold', true));
select test.eq('release: a person who checked the items confirms with release_hold; it charges, the release is in the audit log',
  (select (t.amount_line_item_id is not null)::text from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id where l.read_id = test.rt7('h2')) || '/' ||
  (select count(*) from audit_log a where a.action = 'toll_read_hold_release' and a.entity_id = test.rt7('h2')::text), 'true/1');

update program_settings p set toll_boundary_margin_minutes = r.m from test.rt7_margin r where r.id = p.id;
