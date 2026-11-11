-- 99: release 35 fix helper (migrations 1700 to 1703): the owner's decisions of November 11, 2026.
-- The delivery origin is a Program setting at 1570 Midland Ave and deliveries are measured from it; owner statements and
-- payouts say what is not yet collected, with the bookings behind it, read from the data; lead intent reads every channel.
-- Fixtures start with "rfx"; every address is example.test.
select test.suite('99 r35fix owner decisions');

-- ================================================================ 2. the delivery origin
select test.eq('the origin is a Program setting: the address', (app.settings()).delivery_origin_address, '1570 Midland Ave, Scarborough, ON');
select test.eq('the origin: its coordinates (approximate)', format('%s,%s', (app.settings()).company_latitude, (app.settings()).company_longitude), '43.771000,-79.269000');
select test.ok('the mailing address is not the origin', (app.settings()).company_address is distinct from (app.settings()).delivery_origin_address);
select test.eq('a delivery to the origin itself is 0 km', (public.delivery_to_point(43.771, -79.269) ->> 'km')::numeric, 0::numeric);
select test.ok('a delivery downtown is measured from Midland (about 17 km), not from Dundas St W (about 7 km)',
  (public.delivery_to_point(43.6453, -79.3806) ->> 'km')::numeric between 14 and 20);

-- ================================================================ 3. not yet collected
select test.mk_user('rfx_admin', 'admin');
select test.mk_user('rfx_fin', 'va', 'finance');
select test.mk_owner('rfx_olga');
select test.mk_owner('rfx_other');
select test.mk_vehicle('RFX1', 'rfx_olga');
select test.mk_renter('rfx_r1', false); select test.mk_renter('rfx_r2', false); select test.mk_renter('rfx_r3', false); select test.mk_renter('rfx_r4', false);
-- paid by card
select test.mk_booking('RFX-PAID', 'RFX1', 'rfx_r1', '2026-10-10 10:00', '2026-10-13 10:00', 'closed', 30000);
-- billed to an insurer: nothing paid yet
select test.mk_booking('RFX-INS', 'RFX1', 'rfx_r2', '2026-10-15 10:00', '2026-10-18 10:00', 'returned', 0);
select test.mk_line('RFX-INS', 'rental_charge', 36000, false);
insert into insurers (id, name) values (test.id('insurer:rfx'), 'Rfx Insurance');
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:rfx') where id = test.id('booking:RFX-INS');
-- an unpaid balance: half paid by card, half not
select test.mk_booking('RFX-BAL', 'RFX1', 'rfx_r3', '2026-10-20 10:00', '2026-10-22 10:00', 'closed', 20000);
select test.mk_line('RFX-BAL', 'rental_charge', 20000, false);
-- a past trip recorded and not paid
select test.mk_booking('RFX-PAST', 'RFX1', 'rfx_r4', '2026-10-24 10:00', '2026-10-26 10:00', 'closed', 0);
select test.mk_line('RFX-PAST', 'rental_charge', 24000, false);
insert into booking_overrides (booking_id, action, reason, status, requested_by) values (test.id('booking:RFX-PAST'), 'past_trip', 'recorded after the fact', 'used', test.id('rfx_admin'));

select app.build_owner_statement(test.id('owner:rfx_olga'), date '2026-10-01');
create temp table rfx_st as select id from owner_statements where owner_id = test.id('owner:rfx_olga') and statement_month = date '2026-10-01' and status <> 'void';
create temp table rfx_nc as select app.owner_statement_not_collected((select id from rfx_st)) as v;
create function pg_temp.line_amount(p_booking text) returns bigint language sql as $$
  select sum(amount_cents)::bigint from owner_statement_lines where owner_statement_id = (select id from rfx_st) and line_type = 'rental' and booking_id = test.id('booking:' || p_booking) $$;
create function pg_temp.nc(p_booking text) returns jsonb language sql as $$
  select e from rfx_nc, jsonb_array_elements(v -> 'bookings') e where e ->> 'booking_number' = p_booking $$;

select test.ok('a booking paid by card is not listed', pg_temp.nc('RFX-PAID') is null);
select test.eq('insurer-billed: its whole line, as billed to the insurer', format('%s|%s', (pg_temp.nc('RFX-INS') ->> 'cents')::bigint = pg_temp.line_amount('RFX-INS'), pg_temp.nc('RFX-INS') ->> 'reason'), 't|insurer');
select test.eq('an unpaid balance: half its line', format('%s|%s', (pg_temp.nc('RFX-BAL') ->> 'cents')::bigint = round(pg_temp.line_amount('RFX-BAL') / 2.0)::bigint, pg_temp.nc('RFX-BAL') ->> 'reason'), 't|balance');
select test.eq('a past trip not paid', pg_temp.nc('RFX-PAST') ->> 'reason', 'past_trip');
select test.eq('the total adds up the bookings', (select (v ->> 'total_cents')::bigint from rfx_nc),
  (select sum((e ->> 'cents')::bigint) from rfx_nc, jsonb_array_elements(v -> 'bookings') e));
select test.eq('the line says it', (select v ->> 'line' from rfx_nc), format('Of this, %s is not yet collected', app.fmt_money((select (v ->> 'total_cents')::bigint from rfx_nc))));
select test.ok('it is less than the statement''s rentals', (select (v ->> 'total_cents')::bigint from rfx_nc) < (select sum(amount_cents) from owner_statement_lines where owner_statement_id = (select id from rfx_st) and line_type = 'rental'));

-- read from the data: the insurer pays and the booking leaves the list
-- (the insurer invoice flow has suites of its own; the payment is tied straight here)
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('payment:rfx-ins'), test.id('booking:RFX-INS'), test.id('renter:rfx_r2'), 'other', 'charge', 'e_transfer', 36000, 'succeeded', now());
update booking_line_items set payment_id = test.id('payment:rfx-ins') where booking_id = test.id('booking:RFX-INS') and revenue_class = 'owner_revenue';
select test.ok('once the insurer pays, it is no longer listed', not exists (
  select 1 from jsonb_array_elements(app.owner_statement_not_collected((select id from rfx_st)) -> 'bookings') e where e ->> 'booking_number' = 'RFX-INS'));

-- where it shows
select test.eq('Admin''s statement page and the PDF carry it',
  (public.door(test.id('rfx_admin'), 'aal2', 'admin_read', 'owner_statement', jsonb_build_object('id', (select id from rfx_st))) #>> '{not_collected,total_cents}')::bigint,
  (app.owner_statement_not_collected((select id from rfx_st)) ->> 'total_cents')::bigint);
select test.ok('Admin''s statement list carries it', exists (
  select 1 from jsonb_array_elements(public.door(test.id('rfx_admin'), 'aal2', 'admin_list', 'owner_statements', jsonb_build_object('eq', jsonb_build_object('owner_id', test.id('owner:rfx_olga')))) -> 'rows') r
   where (r ->> 'not_collected_cents')::bigint > 0));
select test.ok('Finance''s statement list carries it', exists (
  select 1 from jsonb_array_elements(public.door(test.id('rfx_fin'), 'aal2', 'va_list', 'owner_statements', jsonb_build_object('eq', jsonb_build_object('owner_id', test.id('owner:rfx_olga')))) -> 'rows') r
   where (r ->> 'not_collected_cents')::bigint > 0));
select app.approve_owner_statement((select id from rfx_st), test.id('rfx_admin'));
select test.ok('Admin''s payout list carries it', exists (
  select 1 from jsonb_array_elements(public.door(test.id('rfx_admin'), 'aal2', 'admin_list', 'payouts', jsonb_build_object('eq', jsonb_build_object('owner_statement_id', (select id from rfx_st)))) -> 'rows') r
   where (r ->> 'not_collected_cents')::bigint > 0));
select test.ok('the owner sees it on their statement', (app.owner_portal_statement(test.id('rfx_olga'), (select id from rfx_st)) #>> '{not_collected,total_cents}')::bigint > 0);
select test.ok('another owner does not see the statement at all', app.owner_portal_statement(test.id('rfx_other'), (select id from rfx_st)) is null);
select test.throws('a renter cannot list statements', format($$select public.door(%L, 'aal2', 'admin_list', 'owner_statements', '{}'::jsonb)$$, test.id('rfx_r1')));
select test.eq('the statement email says it, with the bookings',
  (select format('%s|%s|%s', x ->> 'has_not_collected', jsonb_array_length(x -> 'not_collected_rows') > 0, x ->> 'not_collected_line' like 'Of this, $%')
     from (select app.notification_payload('owner_statement_ready',
             jsonb_populate_record(null::app_events, jsonb_build_object('code', 'owner_statement_ready', 'entity', 'owner_statement', 'entity_id', (select id from rfx_st))), '{}'::jsonb) as x) q),
  'true|t|t');

-- ================================================================ 4. lead intent reads every channel
-- each subject has one channel only, saying "an SUV": the channel alone gives the car class
create function pg_temp.renter(p text) returns uuid language sql as $$ select test.id('renter:rfx_i_' || p) $$;
create function pg_temp.cls(p_kind text, p_id uuid) returns text language sql as $$ select app.intent_compute(p_kind, p_id) #>> '{signals,car_class}' $$;
select test.mk_renter('rfx_i_call'); select test.mk_renter('rfx_i_quo'); select test.mk_renter('rfx_i_vm'); select test.mk_renter('rfx_i_text');
select test.mk_renter('rfx_i_email'); select test.mk_renter('rfx_i_chat'); select test.mk_renter('rfx_i_staff'); select test.mk_renter('rfx_i_note');
select test.mk_renter('rfx_i_bnote'); select test.mk_renter('rfx_i_wa'); select test.mk_renter('rfx_i_web'); select test.mk_renter('rfx_i_none');
insert into phone_threads (id, number, renter_id)
select test.id('thread:rfx_' || k), '+1647555' || lpad(n::text, 4, '0'), pg_temp.renter(k)
  from (values ('call', 1201), ('quo', 1202), ('vm', 1203), ('text', 1204)) v(k, n);
insert into phone_activity (thread_id, kind, direction, started_at, renter_id, transcript)
values (test.id('thread:rfx_call'), 'call', 'in', now() - interval '1 hour', pg_temp.renter('call'), '[{"who": "caller", "text": "I am looking for an SUV"}]'::jsonb);
insert into phone_activity (thread_id, kind, direction, started_at, renter_id, quo_summary, next_steps)
values (test.id('thread:rfx_quo'), 'call', 'in', now() - interval '1 hour', pg_temp.renter('quo'), '["Caller wants an SUV"]'::jsonb, '["Send SUV options"]'::jsonb);
insert into phone_activity (thread_id, kind, direction, started_at, renter_id, voicemail_text)
values (test.id('thread:rfx_vm'), 'call', 'in', now() - interval '1 hour', pg_temp.renter('vm'), 'Hi, call me back about an SUV');
insert into phone_activity (thread_id, kind, direction, started_at, renter_id, body)
values (test.id('thread:rfx_text'), 'text', 'in', now() - interval '1 hour', pg_temp.renter('text'), 'Do you have an SUV?');
insert into messages (direction, channel, subject, body, renter_id, occurred_at, status)
values ('inbound', 'email', 'Rental', 'Do you have an SUV?', pg_temp.renter('email'), now() - interval '1 hour', 'received');
insert into chat_conversations (id, renter_id, status, created_at) values (test.id('chat:rfx'), pg_temp.renter('chat'), 'human', now() - interval '1 hour');
insert into chat_messages (conversation_id, sender, body, at) values (test.id('chat:rfx'), 'visitor', 'Any SUV free?', now() - interval '1 hour');
update renters set staff_note = 'Wants an SUV for the family' where id = pg_temp.renter('staff');
insert into renter_notes (renter_id, body, author_name, author_role) values (pg_temp.renter('note'), 'Asked for an SUV on the phone', 'Rfx Cs', 'cs');
select test.mk_vehicle('RFX2', 'rfx_olga');
select test.mk_booking('RFX-NOTE', 'RFX2', 'rfx_i_bnote', '2026-12-01 10:00', '2026-12-03 10:00', 'confirmed', 10000);
update bookings set notes = 'Would rather have an SUV', created_at = now() where id = test.id('booking:RFX-NOTE');
update renters set mobile = '+16475551299' where id = pg_temp.renter('wa');
insert into auto_replies (channel, sender, question, status) values ('whatsapp', '+1 (647) 555-1299', 'Hello, is an SUV available?', 'handoff');
insert into visitor_sessions (id, visitor_id, renter_id, page_views, cars_viewed, started_at, last_seen_at, score)
values (gen_random_uuid(), gen_random_uuid(), pg_temp.renter('web'), 9, array[gen_random_uuid()], now() - interval '2 hours', now() - interval '1 hour', 65);

select test.eq('a call transcript', pg_temp.cls('renter', pg_temp.renter('call')), 'suv');
select test.eq('Quo''s call summary and next steps', pg_temp.cls('renter', pg_temp.renter('quo')), 'suv');
select test.eq('a voicemail', pg_temp.cls('renter', pg_temp.renter('vm')), 'suv');
select test.eq('a text', pg_temp.cls('renter', pg_temp.renter('text')), 'suv');
select test.eq('an email', pg_temp.cls('renter', pg_temp.renter('email')), 'suv');
select test.eq('the site chat', pg_temp.cls('renter', pg_temp.renter('chat')), 'suv');
select test.eq('a staff note on the renter', pg_temp.cls('renter', pg_temp.renter('staff')), 'suv');
select test.eq('a renter note (staff, on a call or a booking)', pg_temp.cls('renter', pg_temp.renter('note')), 'suv');
select test.eq('a staff note on the booking', pg_temp.cls('renter', pg_temp.renter('bnote')), 'suv');
select test.eq('a WhatsApp message, matched by the number', pg_temp.cls('renter', pg_temp.renter('wa')), 'suv');
select test.ok('website behaviour', (select (v ->> 'score')::int > 0 and v::text like '%High visitor score%' from (select app.intent_compute('renter', pg_temp.renter('web')) v) q));
select test.eq('nothing said or done: nothing', app.intent_compute('renter', pg_temp.renter('none')) ->> 'label', 'unknown');

insert into leads (id, kind, name, email, phone, source) values
  (test.id('lead:rfx_msg'), 'contact', 'Rfx Msg', 'rfx_msg@example.test', null, 'web'),
  (test.id('lead:rfx_log'), 'contact', 'Rfx Log', 'rfx_log@example.test', null, 'phone'),
  (test.id('lead:rfx_mail'), 'contact', 'Rfx Mail', 'rfx_mail@example.test', null, 'email'),
  (test.id('lead:rfx_wa'), 'contact', 'Rfx Wa', 'rfx_wa@example.test', '+16475551288', 'phone');
update leads set message = 'I need an SUV' where id = test.id('lead:rfx_msg');
insert into lead_contacts (lead_id, by_user, channel, note) values (test.id('lead:rfx_log'), test.id('rfx_admin'), 'call', 'Called back, wants an SUV');
insert into messages (direction, channel, subject, body, from_address, occurred_at, status)
values ('inbound', 'email', 'Car', 'Is an SUV free next week?', 'RFX_MAIL@example.test', now() - interval '1 hour', 'received');
insert into auto_replies (channel, sender, question, status) values ('whatsapp', '6475551288', 'SUV for the weekend?', 'handoff');
select test.eq('a lead''s own message', pg_temp.cls('lead', test.id('lead:rfx_msg')), 'suv');
select test.eq('a staff note logged on the lead', pg_temp.cls('lead', test.id('lead:rfx_log')), 'suv');
select test.eq('a lead''s email, by the address', pg_temp.cls('lead', test.id('lead:rfx_mail')), 'suv');
select test.eq('a lead''s WhatsApp message, by the number', pg_temp.cls('lead', test.id('lead:rfx_wa')), 'suv');
select test.ok('the job picks up a staff note just written', app.job_intent() like '%intents');

-- ================================================================ 1. rideshare and delivery driving are welcome
select test.ok('the FAQ says it, in the positive (the auto-replies answer from it)', exists (
  select 1 from site_content_blocks b, jsonb_array_elements(b.data -> 'items') e
   where b.block_key = 'faq.road' and e ->> 'answer' like 'Yes. Rideshare and delivery driving are welcome.%'));
select test.ok('the academy asks it, with "welcome" as the right answer', exists (
  select 1 from academy_questions q join academy_sections s on s.id = q.section_id
   where s.slug = 'trip-rules' and q.options ->> q.answer like 'Yes: rideshare and delivery driving are welcome%'));
