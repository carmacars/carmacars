-- 0187: email the renter and the adjuster from the portal, the insurance emails as Blind Spot Car Rental, and the reminders
-- to release deposits. Fixtures start with "pq" (bookings PQ-...).
select test.suite('99 portal emails and deposit reminders');

select test.mk_user('pq_admin', 'admin');
select test.mk_user('pq_cs', 'va', 'cs');
select test.mk_user('pq_fleet', 'va', 'fleet');
select test.mk_user('pq_fin', 'va', 'finance');
select test.mk_user('pq_sales', 'va', 'sales');
select test.mk_owner('pq_owner');
select test.mk_vehicle('PQ1', 'pq_owner');
select test.mk_renter('pq_r1');
select test.mk_renter('pq_r2');
select test.mk_booking('PQ-1', 'PQ1', 'pq_r1', '2033-01-10 10:00', '2033-01-12 10:00', 'confirmed');
select test.mk_booking('PQ-2', 'PQ1', 'pq_r2', '2033-01-20 10:00', '2033-01-25 10:00', 'confirmed');
insert into insurers (id, name, billing_email) values (test.id('ins:pq'), 'PQ Mutual', 'billing.pq@example.test');
update bookings set bill_to = 'insurer', insurer_id = test.id('ins:pq'), insurer_claim_number = 'CL-PQ-77',
       insurer_adjuster_name = 'Alex Adjuster', insurer_adjuster_email = 'Alex.Adjuster@example.test'
 where id = test.id('booking:PQ-2');
insert into quick_replies (title, body, audience) values ('PQ pickup reminder', 'See you at the pickup.', 'renter');

create table test.pq (k text primary key, v jsonb);
create function test.pqv(p text) returns jsonb language sql stable as $$ select v from test.pq where k = p $$;
create function test.pq_send(p_key text, p_user text, p_va text, p jsonb) returns void language sql as $$
  insert into test.pq select p_key, app.door(test.id(p_user), 'aal2', 'ops_do', 'booking_email', p || case when p_va is null then '{}'::jsonb else jsonb_build_object('_va', p_va) end)
$$;
create function test.pq_out(p_key text) returns notification_outbox language sql stable as $$
  select o.* from notification_outbox o where o.entity = 'message' and o.entity_id = (test.pqv(p_key) ->> 'id')::uuid order by o.created_at limit 1
$$;
-- what app.outbox_claim hands the sender for a row (0018: the catalogue's sender and reply-to)
create function test.pq_sender(p_key text) returns text language sql stable as $$
  select c.from_address || ' / ' || c.reply_to from notification_catalogue c where c.code = (test.pq_out(p_key)).code
$$;

-- ================================================================ 1. Email the renter, as CarmaCars
-- the renter wrote first: customer service has a "renter replied" task
select public.renter_send_message(test.id('booking:PQ-1'), test.id('pq_r1'), 'Can I pick up an hour early?');
select test.eq('the renter''s reply opened a customer service task', (select count(*) from tasks where booking_id = test.id('booking:PQ-1') and task_type = 'renter_message' and status = 'open'), 1::bigint);

select test.pq_send('m1', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-1', 'to', 'renter', 'sender', 'carmacars',
  'subject', 'Earlier pickup on PQ-1', 'body', 'Yes, 9:00 works. See you then.'));
select test.eq('sent: the staff message email, to the renter''s address', (test.pqv('m1') ->> 'code') || '/' || (test.pqv('m1') ->> 'address'), 'renter_staff_message/pq_r1@example.test');
select test.eq('kept on the booking''s messages with who sent it, the subject and the sender address',
  (select m.channel || '/' || m.direction || '/' || (m.sent_by = test.id('pq_cs')) || '/' || m.subject || '/' || m.from_address from messages m where m.id = (test.pqv('m1') ->> 'id')::uuid),
  'portal/outbound/true/Earlier pickup on PQ-1/CarmaCars <bookings@carmacars.ca>');
select test.eq('and in the booking''s history, as the staff member',
  (select e.kind || '/' || e.actor_type || '/' || (e.actor_user_id = test.id('pq_cs')) || '/' || e.note from booking_events e where e.booking_id = test.id('booking:PQ-1') and e.kind = 'staff_email'),
  'staff_email/staff/true/Email to the renter, from CarmaCars: Earlier pickup on PQ-1');
select test.eq('the renter''s task is done', (select count(*) from tasks where booking_id = test.id('booking:PQ-1') and task_type = 'renter_message' and status = 'open'), 0::bigint);
select test.eq('the renter sees it in their account', (select count(*) from jsonb_array_elements(app.booking_thread(test.id('booking:PQ-1'))) x where x ->> 'subject' = 'Earlier pickup on PQ-1'), 1::bigint);
select app.process_events();
select test.eq('queued in the outbox at the customer priority (class 1), every value filled',
  (select o.status || '/' || o.priority || '/' || o.audience || '/' || o.to_address || '/' || cardinality(o.missing_variables) from test.pq_out('m1') o),
  'queued/1/renter/pq_r1@example.test/0');
select test.eq('from CarmaCars, replies to the shared bookings inbox', test.pq_sender('m1'), 'CarmaCars <bookings@carmacars.ca> / bookings@carmacars.ca');
select test.eq('the email''s subject is the one typed', (select app.render_text(c.subject, o.payload) from test.pq_out('m1') o join notification_catalogue c on c.code = o.code), 'Earlier pickup on PQ-1');
select test.eq('it counts against the daily limit (class 1 limit and the cap)', (select o.code from notification_outbox o where o.id = (test.pq_out('m1')).id and o.status in ('queued', 'delayed', 'sending', 'sent')), 'renter_staff_message');

-- every assistant function may write (Fleet included); Sales only on a request or an offer
select test.lives('Fleet may email the renter', $$select test.pq_send('m2', 'pq_fleet', 'fleet', jsonb_build_object('booking', 'PQ-1', 'subject', 'Delivery time', 'body', 'Our driver arrives at 9:00.'))$$);
select test.lives('Finance may email the renter', $$select test.pq_send('m3', 'pq_fin', 'finance', jsonb_build_object('booking', 'PQ-1', 'subject', 'Your receipt', 'body', 'The receipt is in your account.'))$$);
select test.lives('an Admin may email the renter', $$select test.pq_send('m4', 'pq_admin', null, jsonb_build_object('booking', 'PQ-1', 'subject', 'Thank you', 'body', 'Thank you for booking with us.'))$$);
select test.throws('Sales: requests and offers only', $$select test.pq_send('x1', 'pq_sales', 'sales', jsonb_build_object('booking', 'PQ-1', 'subject', 'Hi', 'body', 'Hello'))$$, 'requests and offers only');
select test.throws('a renter cannot use it', $$select test.pq_send('x2', 'pq_r1', null, jsonb_build_object('booking', 'PQ-1', 'subject', 'Hi', 'body', 'Hello'))$$, 'Only an Admin or an assistant');
select test.throws('a subject is needed', $$select test.pq_send('x3', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-1', 'subject', ' ', 'body', 'Hello'))$$, 'Write the subject');
select test.throws('a message is needed', $$select test.pq_send('x4', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-1', 'subject', 'Hi', 'body', ''))$$, 'Write the message first');
select test.throws('Blind Spot Car Rental writes only on an insurer-billed booking', $$select test.pq_send('x5', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-1', 'sender', 'blindspot', 'subject', 'Hi', 'body', 'Hello'))$$, 'billed to an insurer');
select test.throws('no adjuster on a renter-billed booking', $$select test.pq_send('x6', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-1', 'to', 'adjuster', 'subject', 'Hi', 'body', 'Hello'))$$, 'not billed to an insurer');

-- the conversation on the screen
insert into test.pq select 'c1', app.door(test.id('pq_cs'), 'aal2', 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'PQ-1', '_va', 'cs'));
select test.eq('the conversation: both ways, newest first, with who wrote; the emails of the booking; the quick replies; not insurer-billed',
  (select count(*) from jsonb_array_elements(test.pqv('c1') -> 'messages') x where x ->> 'by' = 'Pq Cs' and x ->> 'subject' = 'Earlier pickup on PQ-1') || '/'
  || (select count(*) from jsonb_array_elements(test.pqv('c1') -> 'messages') x where x ->> 'direction' = 'inbound') || '/'
  || (select count(*) from jsonb_array_elements(test.pqv('c1') -> 'emails') x where x ->> 'code' = 'renter_staff_message' and x ->> 'subject' = 'Earlier pickup on PQ-1') || '/'
  || (select count(*) from jsonb_array_elements(test.pqv('c1') -> 'quick_replies') x where x ->> 'title' = 'PQ pickup reminder') || '/'
  || (test.pqv('c1') ->> 'insurer_billed') || '/' || (test.pqv('c1') #>> '{renter,email}') || '/' || ((test.pqv('c1') #>> '{usage,cap}')::integer > 0),
  '1/1/1/1/false/pq_r1@example.test/true');
insert into test.pq select 'c2', app.door(test.id('pq_fleet'), 'aal2', 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'PQ-1', '_va', 'fleet'));
select test.eq('Fleet sees the renter''s first name, never the address', (test.pqv('c2') #>> '{renter,name}') || '/' || coalesce(test.pqv('c2') #>> '{renter,email}', 'none')
  || '/' || (select count(*) from jsonb_array_elements(test.pqv('c2') -> 'emails') x where x ->> 'to' is not null and x ->> 'audience' = 'renter'), 'Pq/none/0');
select test.throws('Sales cannot read the conversation of a confirmed booking', $$select app.door(test.id('pq_sales'), 'aal2', 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'PQ-1', '_va', 'sales'))$$, 'requests and offers only');

-- ================================================================ 2. the insurance emails: Blind Spot Car Rental
select test.eq('every email to an insurer, and the insurance message, go as Blind Spot Car Rental and reply to it',
  (select string_agg(code || '=' || from_address || ' / ' || reply_to, '; ' order by code) from notification_catalogue where has_email and (audience = 'insurer' or code = 'insurance_staff_message')),
  'insurance_staff_message=Blind Spot Car Rental <blindspotcarrental@carmacars.ca> / blindspotcarrental@carmacars.ca; insurer_invoice=Blind Spot Car Rental <blindspotcarrental@carmacars.ca> / blindspotcarrental@carmacars.ca');
select test.eq('the address is an active receiving alias; the outbox reply-to agrees', (select is_active from email_aliases where address = 'blindspotcarrental@carmacars.ca')
  || '/' || app.email_reply_to_for('insurer_invoice', 'insurer') || '/' || app.email_reply_to_for('insurance_staff_message', 'renter'),
  'true/blindspotcarrental@carmacars.ca/blindspotcarrental@carmacars.ca');
select test.eq('the other emails still go as CarmaCars', (select count(*) from notification_catalogue where has_email and from_address like 'Blind Spot%'), 2::bigint);

insert into test.pq select 'c3', app.door(test.id('pq_cs'), 'aal2', 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'PQ-2', '_va', 'cs'));
select test.eq('an insurer-billed booking offers the adjuster', (test.pqv('c3') ->> 'insurer_billed') || '/' || (test.pqv('c3') #>> '{adjuster,email}') || '/' || (test.pqv('c3') ->> 'insurer_name'),
  'true/Alex.Adjuster@example.test/PQ Mutual');

-- Email the adjuster: always Blind Spot Car Rental, even if CarmaCars is asked for
select test.pq_send('a1', 'pq_fin', 'finance', jsonb_build_object('booking', 'PQ-2', 'to', 'adjuster', 'sender', 'carmacars',
  'subject', 'Extension for claim CL-PQ-77', 'body', 'The repairs take two more days. Please confirm the extension.'));
select test.eq('to the adjuster: the insurance message, from Blind Spot Car Rental', (test.pqv('a1') ->> 'code') || '/' || (test.pqv('a1') ->> 'sender') || '/' || (test.pqv('a1') ->> 'address'),
  'insurance_staff_message/blindspot/alex.adjuster@example.test');
select test.eq('kept on the booking as an email (out of the renter''s account)',
  (select m.channel || '/' || m.to_address || '/' || m.from_address || '/' || (m.sent_by = test.id('pq_fin')) from messages m where m.id = (test.pqv('a1') ->> 'id')::uuid),
  'email/alex.adjuster@example.test/Blind Spot Car Rental <blindspotcarrental@carmacars.ca>/true');
select test.eq('the renter does not see the adjuster''s email', (select count(*) from jsonb_array_elements(app.booking_thread(test.id('booking:PQ-2'))) x where x ->> 'subject' like 'Extension%'), 0::bigint);
select app.process_events();
select test.eq('queued to the adjuster as the insurer, class 1, every value filled (the claim in the text)',
  (select o.status || '/' || o.audience || '/' || o.priority || '/' || o.to_address || '/' || cardinality(o.missing_variables) || '/' || (o.payload ->> 'about_line') || '/' || (o.payload ->> 'first_name') from test.pq_out('a1') o),
  'queued/insurer/1/alex.adjuster@example.test/0/booking PQ-2, the ' || app.vehicle_name(test.id('vehicle:PQ1')) || ', claim CL-PQ-77/Alex');
select test.eq('from Blind Spot Car Rental, replies to its own address', test.pq_sender('a1'), 'Blind Spot Car Rental <blindspotcarrental@carmacars.ca> / blindspotcarrental@carmacars.ca');
select test.eq('the history names the adjuster and the sender', (select note from booking_events where booking_id = test.id('booking:PQ-2') and kind = 'staff_email' order by id limit 1),
  'Email to the adjuster, from Blind Spot Car Rental: Extension for claim CL-PQ-77');

-- Email the renter of the insurer-billed booking, as Blind Spot Car Rental (chosen)
select test.pq_send('r2', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-2', 'to', 'renter', 'sender', 'blindspot', 'subject', 'Your replacement car', 'body', 'Your insurer approved five days.'));
select app.process_events();
select test.eq('to the renter as Blind Spot Car Rental: the insurance message to the renter''s address, with the in-app notice',
  (select o.code || '/' || o.audience || '/' || o.to_address || '/' || o.priority from test.pq_out('r2') o) || '/' || test.pq_sender('r2')
  || '/' || (select count(*) from notifications n where n.user_id = test.id('pq_r2') and n.code = 'insurance_staff_message'),
  'insurance_staff_message/renter/pq_r2@example.test/1/Blind Spot Car Rental <blindspotcarrental@carmacars.ca> / blindspotcarrental@carmacars.ca/1');
select test.eq('and in the renter''s account', (select count(*) from jsonb_array_elements(app.booking_thread(test.id('booking:PQ-2'))) x where x ->> 'subject' = 'Your replacement car'), 1::bigint);
-- the same booking as CarmaCars still goes from bookings@
select test.pq_send('r3', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-2', 'subject', 'Pickup place', 'body', 'We meet you at the body shop.'));
select app.process_events();
select test.eq('CarmaCars on an insurer-billed booking: the staff message from bookings@', (test.pq_out('r3')).code || '/' || test.pq_sender('r3'),
  'renter_staff_message/CarmaCars <bookings@carmacars.ca> / bookings@carmacars.ca');
update bookings set insurer_adjuster_email = null where id = test.id('booking:PQ-2');
select test.throws('the adjuster''s email is needed', $$select test.pq_send('x7', 'pq_cs', 'cs', jsonb_build_object('booking', 'PQ-2', 'to', 'adjuster', 'subject', 'Hi', 'body', 'Hello'))$$, 'adjuster''s email');

-- ================================================================ 3. reminders to release deposits
-- PQ-3 returned on Tuesday March 1, 2033, no check-in date on the deposit: due 7 business days later, Thursday March 10.
select test.mk_booking('PQ-3', 'PQ1', 'pq_r1', '2033-02-25 10:00', '2033-03-01 10:00', 'returned');
select test.mk_booking('PQ-4', 'PQ1', 'pq_r2', '2033-02-10 10:00', '2033-02-12 10:00', 'returned');
select test.mk_booking('PQ-5', 'PQ1', 'pq_r2', '2033-02-14 10:00', '2033-02-16 10:00', 'returned');
insert into deposits (id, booking_id, amount_cents, method, status, release_due_on, taken_at) values
  (test.id('dep:PQ-3'), test.id('booking:PQ-3'), 100000, 'card_hold', 'held', null, test.at('2033-02-25 10:00')),
  (test.id('dep:PQ-4'), test.id('booking:PQ-4'), 50000, 'charged', 'captured', date '2033-04-29', test.at('2033-02-10 10:00')),
  (test.id('dep:PQ-5'), test.id('booking:PQ-5'), 70000, 'charged', 'captured', date '2033-03-09', test.at('2033-02-14 10:00'));
update deposits set release_due_on = null where id = test.id('dep:PQ-3');
select test.eq('a deposit with no release date is due back 7 business days after the return (program setting)',
  (select due_on || '/' || from_return || '/' || balance_cents from app.deposit_release_reminders(test.at('2033-03-10 06:00')) where deposit_id = test.id('dep:PQ-3')), '2033-03-10/true/100000');
select test.eq('the setting is 7 by default', (app.settings()).deposit_release_reminder_days, 7);

select test.eq('the daily job runs on the due day', app.job_deposits_due(test.at('2033-03-10 06:30')), 'succeeded');
select test.eq('one open task in the Finance queue: release the deposit for PQ-3, the amount and the day, urgent',
  (select count(*) || '/' || min(t.queue) || '/' || min(t.title) || '/' || min(t.priority) from tasks t where t.related_id = test.id('dep:PQ-3') and t.task_type = 'release_deposit' and t.status = 'open'),
  '1/finance/Release the deposit for PQ-3: $1,000, due ' || app.fmt_day(date '2033-03-10') || '/urgent');
select test.eq('overdue (PQ-5, due yesterday) too; a deposit due in April is not yet',
  (select count(*) filter (where t.related_id = test.id('dep:PQ-5')) || '/' || count(*) filter (where t.related_id = test.id('dep:PQ-4'))
     from tasks t where t.task_type = 'release_deposit' and t.status = 'open'), '1/0');
select test.eq('an in-app notice to Finance and to the Admin (no email)',
  (select count(*) filter (where n.user_id = test.id('pq_fin')) || '/' || count(*) filter (where n.user_id = test.id('pq_admin')) || '/' || count(*) filter (where n.user_id = test.id('pq_cs'))
     from notifications n where n.code = 'staff_deposit_release_due' and n.entity_id = test.id('dep:PQ-3')), '1/1/0');
select test.eq('the notice opens the booking''s money, in the reader''s portal',
  (select string_agg(n.url, ' ' order by n.url) from notifications n where n.code = 'staff_deposit_release_due' and n.entity_id = test.id('dep:PQ-3') and n.user_id in (test.id('pq_admin'), test.id('pq_fin'))),
  (app.settings()).notify_base_url || '/admin/bookings/PQ-3?tab=money ' || (app.settings()).notify_base_url || '/staff/bookings/PQ-3?tab=money');
select test.eq('no email about it', (select count(*) from notification_outbox where code = 'staff_deposit_release_due'), 0::bigint);

select test.eq('the next day: still one task, no second notice', app.job_deposits_due(test.at('2033-03-11 06:30')) || '/'
  || (select count(*) from tasks t where t.related_id = test.id('dep:PQ-3') and t.task_type = 'release_deposit' and t.status = 'open') || '/'
  || (select count(*) from notifications n where n.code = 'staff_deposit_release_due' and n.entity_id = test.id('dep:PQ-3') and n.user_id = test.id('pq_fin')), 'succeeded/1/1');

-- settled: the task closes by itself
update deposits set released_cents = 100000, released_at = now(), status = 'settled', release_approved_by = test.id('pq_admin') where id = test.id('dep:PQ-3');
select test.eq('released: the task is done by itself', (select string_agg(t.status || ':' || t.completion_note, ',') from tasks t where t.related_id = test.id('dep:PQ-3') and t.task_type = 'release_deposit'), 'done:Deposit settled');
-- kept whole against the charges (nothing left to give back): also done
update deposits set applied_cents = 70000 where id = test.id('dep:PQ-5');
select test.eq('kept against the charges: the task is done', (select string_agg(t.status, ',') from tasks t where t.related_id = test.id('dep:PQ-5') and t.task_type = 'release_deposit'), 'done');
select test.eq('settled deposits raise nothing more', app.job_deposits_due(test.at('2033-03-14 06:30')) || '/'
  || (select count(*) from tasks t where t.related_id in (test.id('dep:PQ-3'), test.id('dep:PQ-5')) and t.task_type = 'release_deposit' and t.status = 'open'), 'succeeded/0');

-- Admin > To do counts the deposits due today or overdue
select test.mk_booking('PQ-6', 'PQ1', 'pq_r1', '2033-05-01 10:00', '2033-05-03 10:00', 'returned');
insert into deposits (id, booking_id, amount_cents, method, status, release_due_on, taken_at)
values (test.id('dep:PQ-6'), test.id('booking:PQ-6'), 30000, 'charged', 'captured', app.today() - 1, now());
select test.ok('Admin > To do: deposits due back today or overdue',
  coalesce((select (x ->> 'count')::integer >= 1 and x ->> 'href' = '/admin/tasks?queue=finance' from jsonb_array_elements(app.admin_todo(test.id('pq_admin')) -> 'items') x where x ->> 'key' = 'deposits_overdue'), false));
