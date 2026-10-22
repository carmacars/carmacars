-- 55: Turo emails matched to cars by themselves (migration 0088). Every active real car is a candidate with no setup
-- (samples only when linked or taught); every match teaches the car its Turo car id and Turo name; a Turo car id is one
-- car's (staff moves it, an automatic match never takes it); "Which car is this?" (pick) applies the trip, closes the
-- task and teaches; emails still waiting with the same id resolve by themselves; a change without the car finds it by
-- its trip; the backfill (rematch due, the cron gate, the Worker's answer); the guest on the trip, on the block and on
-- one contact record (no marketing, never a renter account), found by phone and in Live chat; To do; the door.
-- Fixtures start with "t88".
select test.suite('55 Turo smart matching');

select test.mk_user('t88_admin', 'admin');
select test.mk_user('t88_fleet', 'va', 'fleet');
select test.mk_user('t88_cs', 'va', 'cs');
select test.mk_owner('t88_owner');
select test.mk_vehicle('t88a', 't88_owner');
select test.mk_vehicle('t88b', 't88_owner');
select test.mk_vehicle('t88sample', 't88_owner');
select test.mk_vehicle('t88gone', 't88_owner');
select test.mk_renter('t88_rita');
update vehicles set make = 'Volkswagen', model = 'Jetta', year = 2021, colour = 'BLACK', trim = 'SEL' where id = test.id('vehicle:t88a');
update vehicles set make = 'Volkswagen', model = 'Jetta', year = 2021, colour = 'BLACK', trim = 'S' where id = test.id('vehicle:t88b');
update vehicles set is_sample = true where id = test.id('vehicle:t88sample');
update vehicles set retired_at = now() where id = test.id('vehicle:t88gone');
update program_settings set turo_email_enabled = true, turo_email_forwarders = 'rent@carmacars.ca', turnaround_buffer_minutes = 120, turnaround_block_enabled = true;

create or replace function test.v88(p text) returns uuid language sql immutable as $$ select test.id('vehicle:' || p) $$;
create or replace function test.at88(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;
create or replace function test.do88(p_name text, p jsonb, p_user text default 't88_fleet') returns jsonb language sql as $$
  select app.door(test.id(p_user), '', case when p_user like '%admin' then 'admin_do' else 'va_do' end, p_name, p) $$;
create or replace function test.rd88(p_user text default 't88_fleet') returns jsonb language sql as $$
  select app.door(test.id(p_user), '', case when p_user like '%admin' then 'admin_read' else 'va_read' end, 'calendar_sync', '{}') $$;
-- one email as the Worker hands it over
create or replace function test.mail88(p_mid text, p_kind text, p_extra jsonb default '{}', p_at text default '2031-03-01 09:05') returns jsonb language sql as $$
  select app.turo_email_receive(jsonb_build_object('message_id', p_mid, 'envelope_from', 'rent@carmacars.ca', 'from_turo', true, 'kind', p_kind,
           'guest_first_name', 'Omar', 'method', 'rules', 'subject', 'Omar ' || p_kind || ' your Volkswagen Jetta 2021',
           'sent_at', test.at88(p_at), 'missing', '[]'::jsonb) || p_extra, test.at88(p_at)) $$;
create or replace function test.ids88(p text) returns text language sql as $$
  select coalesce(string_agg(kind || ':' || value || ':' || source || ':' || hits, ' ' order by kind desc, value), 'none') from turo_identities where vehicle_id = test.v88(p) $$;
create or replace function test.note88(p text) returns text language sql as $$
  select coalesce(string_agg(k.note, ' | ' order by k.starts_at), 'none') from vehicle_calendar_blocks k
   where k.vehicle_id = test.v88(p) and k.source = 'external' and k.removed_at is null $$;
create temp table s55 (k text primary key, v jsonb);
grant all on s55 to public;
create or replace function test.s55(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s55 where k = p_k $$;

-- ================================================================ 1. candidates: no setup per car
select test.eq('every active real car is a candidate with no name on Turo; a sample or a retired car is not',
  (select string_agg(x, ' ' order by x) from (select case c ->> 'vehicle_id' when test.v88('t88a')::text then 'a' when test.v88('t88b')::text then 'b'
     when test.v88('t88sample')::text then 'sample' when test.v88('t88gone')::text then 'gone' end x from jsonb_array_elements(public.turo_match_keys() -> 'cars') c) y where x is not null),
  'a b');
select test.eq('the keys carry trim, colour, what was learned and when the car is busy', (select format('%s %s %s %s', c ->> 'trim', c ->> 'colour', c -> 'identities', c -> 'busy')
  from jsonb_array_elements(public.turo_match_keys() -> 'cars') c where c ->> 'vehicle_id' = test.v88('t88a')::text), 'SEL Black [] []');  -- 0104: a colour in capitals is stored in proper case
-- a sample car linked by hand (an override) is a candidate again
select test.do88('turo_link_save', jsonb_build_object('vehicle', test.v88('t88sample'), 'listing_name', 'Sample Corolla 2023'));
select test.eq('a sample car someone linked by hand is a candidate', (select count(*) from jsonb_array_elements(public.turo_match_keys() -> 'cars') c
  where c ->> 'vehicle_id' = test.v88('t88sample')::text), 1::bigint);
select test.do88('turo_link_remove', jsonb_build_object('vehicle', test.v88('t88sample')));

-- ================================================================ 2. an automatic match teaches the car; the guest is kept
insert into s55 values ('b1', test.mail88('t88-b1', 'booked', jsonb_build_object('trip_id', '61000001', 'vehicle_id', test.v88('t88a'),
  'starts_at', test.at88('2031-03-10 10:00'), 'ends_at', test.at88('2031-03-12 10:00'), 'turo_car_ids', '["3355101"]'::jsonb, 'car_name', 'Volkswagen Jetta 2021',
  'guest_name', 'Omar R.', 'guest_phone', '+1 (416) 555-0101', 'guest_email', 'Omar.R@Example.test', 'match_why', '+100 Turo car 3355101')));
select test.eq('applied', test.s55('b1') ->> 'status', 'applied');
select test.eq('learned on the car: its Turo car id and the exact Turo name (automatic)', test.ids88('t88a'), 'turo_car_id:3355101:auto:1 name:Volkswagen Jetta 2021:auto:1');
select test.eq('the trip keeps the guest as shown: name, phone, email', (select format('%s %s %s', guest_name, guest_phone, guest_email) from turo_calendar_trips where trip_id = '61000001'),
  'Omar R. +14165550101 omar.r@example.test');
select test.eq('the block shows the guest and their phone (staff only)', test.note88('t88a'), 'Turo: Turo trip 61000001 · Omar R. · 416-555-0101');
select test.eq('the email row does not keep the guest''s phone or email once the trip has them', (select coalesce(guest_phone, 'none') || ' ' || coalesce(guest_email, 'none') || ' ' || guest_name
  from turo_inbound_emails where message_id = 't88-b1'), 'none none Omar R.');
select test.eq('one contact record: a Turo guest, source turo, no marketing consent, the note on it',
  (select format('%s %s %s %s %s %s', l.kind, l.source, l.consent_marketing, l.name, l.phone, l.payload -> 'trips') from leads l join turo_calendar_trips t on t.lead_id = l.id where t.trip_id = '61000001'),
  'turo_guest turo f Omar R. +14165550101 ["61000001"]');
select test.ok('the note says transactional contact only, no marketing', (select l.message from leads l join turo_calendar_trips t on t.lead_id = l.id where t.trip_id = '61000001') like '%Never add them to a marketing list%CASL%');
select test.eq('never a renter account for a Turo guest', (select count(*) from renters where legal_name = 'Omar R.' or lower(email) = 'omar.r@example.test'), 0::bigint);  -- (not by the phone: suite 55 quo phone has a renter at 416-555-0101)
select test.throws('a Turo guest can never be given marketing consent', $$ update leads set consent_marketing = true, consent_text = 'x', consent_at = now()
  where kind = 'turo_guest' and phone = '+14165550101' $$, '%leads_turo_guest_no_marketing%');
-- the same Turo car id again: hits go up; the same guest on another trip: the same contact record
select test.mail88('t88-b2', 'booked', jsonb_build_object('trip_id', '61000002', 'vehicle_id', test.v88('t88a'),
  'starts_at', test.at88('2031-04-10 10:00'), 'ends_at', test.at88('2031-04-12 10:00'), 'turo_car_ids', '["3355101"]'::jsonb, 'car_name', 'Volkswagen Jetta 2021',
  'guest_name', 'Omar', 'guest_phone', '416-555-0101'), '2031-03-02 09:05');
select test.eq('seen again: the identities count it', test.ids88('t88a'), 'turo_car_id:3355101:auto:2 name:Volkswagen Jetta 2021:auto:2');
select test.eq('the guest matched by phone: one record, both trips, the fuller name kept', (select format('%s %s %s', count(*), max(l.name), max((l.payload -> 'trips')::text))
  from leads l where l.kind = 'turo_guest' and l.phone = '+14165550101'), '1 Omar R. ["61000001", "61000002"]');
select test.eq('found by phone (for the phone line)', (select (app.turo_guest_by_phone('(416) 555-0101') ->> 'name') || ' ' || (app.turo_guest_by_phone('4165550101') ->> 'trip_id')),
  'Omar R. 61000002');
-- a guest with a name only: a contact record without phone or email (matched by name on the same trip)
select test.mail88('t88-b3', 'booked', jsonb_build_object('trip_id', '61000003', 'vehicle_id', test.v88('t88b'), 'guest_first_name', 'Liam', 'guest_name', 'Liam T.',
  'starts_at', test.at88('2031-05-10 10:00'), 'ends_at', test.at88('2031-05-12 10:00')), '2031-03-03 09:05');
select test.eq('a name only: a contact record all the same, nothing invented', (select format('%s %s %s', l.name, coalesce(l.phone, 'no phone'), coalesce(l.email, 'no email'))
  from leads l join turo_calendar_trips t on t.lead_id = l.id where t.trip_id = '61000003'), 'Liam T. no phone no email');

-- ================================================================ 3. a Turo car id is one car's
select app.turo_learn(test.v88('t88b'), array['3355101'], null, 'auto');
select test.eq('an automatic match never takes a Turo car id from another car', (select vehicle_id from turo_identities where kind = 'turo_car_id' and value = '3355101'), test.v88('t88a'));
select app.turo_learn(test.v88('t88b'), array['abc', '12'], 'x', 'auto');
select test.eq('ids that are not digits, and names under 3 letters, are not learned', test.ids88('t88b'), 'none');

-- ================================================================ 4. still unclear: "Which car is this?"
insert into s55 values ('r1', test.mail88('t88-r1', 'booked', jsonb_build_object('trip_id', '61000010', 'vehicle_id', null, 'missing', '["car"]'::jsonb,
  'starts_at', test.at88('2031-06-10 10:00'), 'ends_at', test.at88('2031-06-12 10:00'), 'turo_car_ids', '["3355999"]'::jsonb, 'car_name', 'Volkswagen Jetta 2021',
  'guest_name', 'Noor H.', 'guest_phone', '647-555-0199', 'vehicle_hint', 'Volkswagen Jetta 2021', 'match_why', 'matches 2 cars (2021 Volkswagen Jetta, 2021 Volkswagen Jetta)',
  'candidates', jsonb_build_array(jsonb_build_object('vehicle_id', test.v88('t88b'), 'score', 50, 'why', '["+10 Volkswagen"]'::jsonb),
                                  jsonb_build_object('vehicle_id', test.v88('t88a'), 'score', 10, 'why', '["-40 another Turo car"]'::jsonb),
                                  jsonb_build_object('vehicle_id', '00000000-0000-0000-0000-000000000000', 'score', 5)),
  'excerpt', 'Noor booked your Volkswagen Jetta 2021.')));
insert into s55 values ('r2', test.mail88('t88-r2', 'changed', jsonb_build_object('trip_id', '61000011', 'vehicle_id', null, 'missing', '["car"]'::jsonb,
  'starts_at', test.at88('2031-07-10 10:00'), 'ends_at', test.at88('2031-07-12 10:00'), 'turo_car_ids', '["3355999"]'::jsonb), '2031-03-04 09:05'));
select test.eq('only the car is unclear: waits with the best guesses (unknown cars dropped) and a "Which car is this?" task',
  (test.s55('r1') ->> 'status') || ' | ' || (test.s55('r1') ->> 'reason') || ' | ' || (select jsonb_array_length(candidates) from turo_inbound_emails where message_id = 't88-r1')
  || ' | ' || (select title from tasks where task_type = 'turo_email_review' and related_id = (test.s55('r1') ->> 'id')::uuid),
  'review | Which car: matches 2 cars (2021 Volkswagen Jetta, 2021 Volkswagen Jetta) | 2 | Which car is this? Turo email: Omar booked your Volkswagen Jetta 2021');
select test.eq('Calendar sync: the pop-up''s guesses, best first, with colour and the plate''s last 3', (select format('%s %s %s %s', r ->> 'pick', jsonb_array_length(r -> 'guesses'),
    (r -> 'guesses' -> 0 ->> 'vehicle_id') = test.v88('t88b')::text, (r -> 'guesses' -> 0 ->> 'colour') || '/' || length(r -> 'guesses' -> 0 ->> 'plate_end'))
  from jsonb_array_elements(test.rd88() -> 'turo' -> 'review') r where r ->> 'id' = test.s55('r1') ->> 'id'), 'true 2 t Black/3');
select test.eq('every candidate car is offered for "another car", and the no-marketing note is on the page', (select count(*) from jsonb_array_elements(test.rd88() -> 'turo' -> 'candidates') c
  where c ->> 'id' in (test.v88('t88a')::text, test.v88('t88b')::text)) || ' ' || (test.rd88() -> 'turo' ->> 'guest_note' like 'Turo guest:%'), '2 true');
select test.eq('To do: "which car is this?" opens the pop-up', (select format('%s | %s | %s', i ->> 'label', i ->> 'button', i ->> 'href') from jsonb_array_elements(app.admin_todo(test.id('t88_admin')) -> 'items') i where i ->> 'key' = 'turo_emails'),
  format('Turo emails: which car is this? | Choose the car | /admin/calendar-sync?pick=%s#turo-review', test.s55('r1') ->> 'id'));
select test.throws('customer service may not answer it', $$ select test.do88('turo_review_pick', jsonb_build_object('id', test.s55('r1') ->> 'id', 'vehicle', test.v88('t88b')), 't88_cs') $$, 'Calendar sync is for Admins and Fleet');
insert into s55 values ('pick', test.do88('turo_review_pick', jsonb_build_object('id', test.s55('r1') ->> 'id', 'vehicle', test.v88('t88b'))));
select test.eq('one click: the trip is applied, the email checked by staff, its task done', (test.s55('pick') ->> 'status') || ' ' ||
  (select format('%s %s %s', e.status, e.method, coalesce(e.excerpt, 'no excerpt')) from turo_inbound_emails e where e.message_id = 't88-r1') || ' ' ||
  (select t.status from tasks t where t.task_type = 'turo_email_review' and t.related_id = (test.s55('r1') ->> 'id')::uuid) || ' ' ||
  (select (vehicle_id = test.v88('t88b'))::text from turo_calendar_trips where trip_id = '61000010'),
  'resolved resolved staff no excerpt done true');
select test.eq('the answer teaches the car forever (staff)', test.ids88('t88b'), 'turo_car_id:3355999:staff:2 name:Volkswagen Jetta 2021:staff:1');
select test.eq('the other email waiting with the same Turo car id resolved by itself (learned)', (select format('%s %s %s', e.status, e.method, e.vehicle_id = test.v88('t88b'))
  from turo_inbound_emails e where e.message_id = 't88-r2'), 'applied learned t');
select test.eq('the guest of the chosen email is on its trip and block', (select guest_name || ' ' || guest_phone from turo_calendar_trips where trip_id = '61000010')
  || ' | ' || test.note88('t88b'), 'Noor H. +16475550199 | Turo: Turo trip 61000003 · Liam T. | Turo: Turo trip 61000010 · Noor H. · 647-555-0199 | Turo: Turo trip 61000011 · Omar');
select test.eq('To do is back to plain once nothing waits for a car', (select i ->> 'label' from jsonb_array_elements(app.admin_todo(test.id('t88_admin')) -> 'items') i where i ->> 'key' = 'turo_emails'),
  'Turo emails to check');
select test.throws('an email no longer waiting cannot be picked again', $$ select test.do88('turo_review_pick', jsonb_build_object('id', test.s55('r1') ->> 'id', 'vehicle', test.v88('t88a'))) $$, 'That email is no longer waiting');
-- staff moves a Turo car id that was learned on the wrong car
select app.turo_learn(test.v88('t88a'), array['3355999'], null, 'staff', test.id('t88_admin'));
select test.eq('staff moves a Turo car id to the car they chose, in the audit log', (select vehicle_id = test.v88('t88a') from turo_identities where value = '3355999')::text
  || ' ' || (select count(*) from audit_log where entity_table = 'turo_identities' and after ->> 'turo_car_id' = '3355999'), 'true 1');
select test.eq('Calendar sync lists what each car learned', (select string_agg(i ->> 'value', ', ' order by i ->> 'value') from jsonb_array_elements(
  (select c -> 'turo' -> 'identities' from jsonb_array_elements(test.rd88() -> 'cars') c where c ->> 'id' = test.v88('t88a')::text)) i), '3355101, 3355999, Volkswagen Jetta 2021');
select test.do88('turo_identity_remove', jsonb_build_object('id', (select id from turo_identities where value = '3355999')));
select test.eq('a wrong identity can be removed', (select count(*) from turo_identities where value = '3355999'), 0::bigint);

-- ================================================================ 5. a change without the car: its trip's car
insert into s55 values ('c1', test.mail88('t88-c1', 'changed', jsonb_build_object('trip_id', '61000001', 'vehicle_id', null, 'missing', '["car"]'::jsonb,
  'starts_at', test.at88('2031-03-11 10:00'), 'ends_at', test.at88('2031-03-13 10:00')), '2031-03-05 09:05'));
select test.eq('a change email that does not name the car moves its trip on the trip''s car', (test.s55('c1') ->> 'status') || ' ' || test.note88('t88a'),
  'applied Turo: Turo trip 61000001 · Omar R. · 416-555-0101 | Turo: Turo trip 61000002 · Omar · 416-555-0101');

-- ================================================================ 6. the backfill: matched again by the Worker
insert into s55 values ('w1', test.mail88('t88-w1', 'booked', jsonb_build_object('trip_id', '61000020', 'vehicle_id', null, 'missing', '["car"]'::jsonb,
  'starts_at', test.at88('2031-08-10 10:00'), 'ends_at', test.at88('2031-08-12 10:00'), 'car_name', 'Volkswagen Jetta 2021', 'guest_name', 'Ana'), '2031-03-06 09:05'));
select test.eq('the cron gate sees an email to match again', (public.server_jobs_due() ->> 'turo'), 'true');
insert into s55 values ('due', app.turo_rematch_due(10, test.at88('2031-03-06 10:00')));
select test.eq('it is handed to the Worker once, with what was kept (first time: the model may help)', (select format('%s %s %s', count(*), bool_and((d ->> 'first')::boolean), max(d ->> 'car_name'))
  from jsonb_array_elements(test.s55('due')) d where d ->> 'id' = test.s55('w1') ->> 'id'), '1 t Volkswagen Jetta 2021');
select test.eq('not again until the fleet or what was learned changes', (select count(*) from jsonb_array_elements(app.turo_rematch_due(10, test.at88('2031-03-06 10:05'))) d where d ->> 'id' = test.s55('w1') ->> 'id')
  || ' ' || (public.server_jobs_due() ->> 'turo'), '0 false');
select public.turo_rematch_result(jsonb_build_object('id', test.s55('w1') ->> 'id', 'why', 'matches 2 cars (a, b)',
  'candidates', jsonb_build_array(jsonb_build_object('vehicle_id', test.v88('t88a'), 'score', 50), jsonb_build_object('vehicle_id', test.v88('t88b'), 'score', 50))));
select test.eq('still unclear: the new guesses are kept, it still waits', (select format('%s %s %s', status, jsonb_array_length(candidates), reason) from turo_inbound_emails where message_id = 't88-w1'),
  'review 2 Which car: matches 2 cars (a, b)');
select app.turo_learn(test.v88('t88b'), null, 'VW Jetta black', 'staff', null, false, test.at88('2031-03-06 11:00'));
select test.eq('something learned since: due again (not the first time)', (select string_agg((d ->> 'first'), ',') from jsonb_array_elements(app.turo_rematch_due(10, test.at88('2031-03-06 12:00'))) d where d ->> 'id' = test.s55('w1') ->> 'id'), 'false');
insert into s55 values ('w1r', public.turo_rematch_result(jsonb_build_object('id', test.s55('w1') ->> 'id', 'vehicle_id', test.v88('t88a'), 'method', 'ai', 'why', 'picked by the assistant', 'neurons', 40)));
select test.eq('the Worker found the car: applied, by the assistant, its neurons counted', (test.s55('w1r') ->> 'status') || ' ' ||
  (select format('%s %s', method, left(audit, 28)) from turo_inbound_emails where message_id = 't88-w1') || ' ' ||
  (select count(*) from provider_calls where purpose = 'turo_email' and units = 40), 'applied ai Car picked by the assistant. 1');
select test.eq('an answer for an email no longer waiting changes nothing', public.turo_rematch_result(jsonb_build_object('id', test.s55('w1') ->> 'id', 'vehicle_id', test.v88('t88b'))) ->> 'status', 'gone');
select test.eq('the Worker''s calls are for the server only', has_function_privilege('authenticated', 'public.turo_rematch_due(integer)', 'execute')
  or has_function_privilege('anon', 'public.turo_rematch_result(jsonb)', 'execute') or has_function_privilege('authenticated', 'app.turo_learn(uuid, text[], text, text, uuid, boolean, timestamptz)', 'execute'), false);

-- ================================================================ 7. the old way still works: Add as a Turo trip teaches too
insert into s55 values ('m1', test.mail88('t88-m1', 'booked', jsonb_build_object('trip_id', '61000030', 'vehicle_id', null, 'missing', '["car", "end"]'::jsonb,
  'starts_at', test.at88('2031-09-10 10:00'), 'turo_car_ids', '["4400100"]'::jsonb, 'car_name', 'Volkswagen Jetta 2021', 'guest_name', 'Zara K.'), '2031-03-07 09:05'));
select test.eq('more than the car is missing: no one-click pick', (select (r ->> 'pick') from jsonb_array_elements(test.rd88() -> 'turo' -> 'review') r where r ->> 'id' = test.s55('m1') ->> 'id'), 'false');
select test.do88('turo_trip_add', jsonb_build_object('vehicle', test.v88('t88b'), 'trip_id', '61000030', 'starts_at', test.at88('2031-09-10 10:00'), 'ends_at', test.at88('2031-09-12 10:00'),
  'email', test.s55('m1') ->> 'id'));
select test.eq('added by hand from the email: the car learns its Turo car id (staff), the guest is on the trip', (select source from turo_identities where value = '4400100' and vehicle_id = test.v88('t88b'))
  || ' ' || (select guest_name from turo_calendar_trips where trip_id = '61000030'), 'staff Zara K.');

-- ================================================================ 8. Live chat: a Turo guest who writes
insert into chat_conversations (number, phone) values ('LC-T88', '416 555 0101');
select test.eq('Live chat names a Turo guest by their phone', (select app.visitor_chat_name(c) from chat_conversations c where c.number = 'LC-T88'), 'Omar R. (Turo guest)');
