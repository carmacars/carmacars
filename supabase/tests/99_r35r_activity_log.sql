-- 99: migration 0850 (release 35, part R): the renter's Activity log. One read (renter_activity) unions the emails, texts,
-- live chat, calls with their summaries, notes, booking events, payments, documents and website visits of a renter (or one
-- booking), newest first, 50 a page with a cursor, with a type filter and a search. Fixtures start with "zal"; every
-- address is example.test.
select test.suite('99 r35r activity log (0850)');
grant usage on schema test to service_role;

select test.mk_user('zal_admin', 'admin');
select test.mk_user('zal_cs', 'va', 'cs');
select test.mk_user('zal_fleet', 'va', 'fleet');
select test.mk_owner('zal_o');
select test.mk_vehicle('ZALA', 'zal_o');
select test.mk_renter('zal_r');
select test.mk_renter('zal_old');
create function test.zald(p_days integer) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' 10:00' $$;
select test.mk_booking('ZAL-1', 'ZALA', 'zal_r', test.zald(-1), test.zald(3), 'on_rent');
select test.mk_booking('ZAL-OLD', 'ZALA', 'zal_old', '2025-01-05 10:00', '2025-01-07 10:00', 'closed');
update bookings set checked_in_at = return_at where booking_number = 'ZAL-OLD';

-- one of each, a minute apart (newest last)
insert into messages (direction, channel, subject, body, renter_id, booking_id, occurred_at, status)
values ('inbound', 'email', 'Fuel question', 'Do I return it full?', test.id('renter:zal_r'), test.id('booking:ZAL-1'), now() - interval '20 minutes', 'received');
insert into notification_outbox (code, category, priority, audience, dedupe_key, renter_id, booking_id, to_address, status, sent_at, created_at, payload)
values ('renter_booking_confirmed', 'transactional', 1, 'renter', 'zal-outbox-1', test.id('renter:zal_r'), test.id('booking:ZAL-1'), 'zal.r@example.test', 'sent', now() - interval '19 minutes', now() - interval '19 minutes', '{}'::jsonb);
insert into phone_threads (id, number, match_kind, renter_id) values ('00000000-0000-4000-8000-00000000a101', '+12895550891', 'renter', test.id('renter:zal_r'));
insert into phone_activity (thread_id, kind, direction, body, started_at, renter_id)
values ('00000000-0000-4000-8000-00000000a101', 'text', 'in', 'Running ten minutes late', now() - interval '18 minutes', test.id('renter:zal_r'));
insert into phone_activity (thread_id, kind, direction, started_at, ended_at, duration_seconds, ai_summary, next_steps, renter_id)
values ('00000000-0000-4000-8000-00000000a101', 'call', 'in', now() - interval '17 minutes', now() - interval '16 minutes', 60, 'Asked about the toll road', '["Send the toll rules"]'::jsonb, test.id('renter:zal_r'));
insert into chat_conversations (id, renter_id, status, created_at) values ('00000000-0000-4000-8000-00000000a102', test.id('renter:zal_r'), 'human', now() - interval '15 minutes');
insert into chat_messages (conversation_id, sender, body, at) values ('00000000-0000-4000-8000-00000000a102', 'visitor', 'Is the car ready?', now() - interval '15 minutes');
insert into renter_notes (renter_id, body, author_name, author_role, created_at) values (test.id('renter:zal_r'), 'Prefers texts over calls', 'Zal Cs', 'cs', now() - interval '14 minutes');
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_at)
values (test.id('booking:ZAL-1'), test.id('renter:zal_r'), 'booking_total', 'charge', 'card', 45000, 'succeeded', now() - interval '13 minutes', now() - interval '13 minutes');
insert into documents (kind, title, storage_bucket, storage_path, renter_id, booking_id, created_at)
values ('id_front', 'Licence front', 'private', 'zal/front.jpg', test.id('renter:zal_r'), test.id('booking:ZAL-1'), now() - interval '12 minutes');
insert into visitor_sessions (id, visitor_id, renter_id, started_at, last_seen_at, landing_path, page_views, device)
values ('00000000-0000-4000-8000-00000000a103', '00000000-0000-4000-8000-00000000a104', test.id('renter:zal_r'), now() - interval '11 minutes', now() - interval '10 minutes', '/cars', 4, 'phone');
insert into visitor_events (session_id, at, kind, path) values ('00000000-0000-4000-8000-00000000a103', now() - interval '10 minutes', 'search', '/cars');
insert into visitor_events (session_id, at, kind, path) values ('00000000-0000-4000-8000-00000000a103', now() - interval '10 minutes', 'page_view', '/cars');
insert into booking_events (booking_id, kind, note, actor_type, created_at) values (test.id('booking:ZAL-1'), 'added_by_staff', 'Keys handed over', 'staff', now() - interval '9 minutes');

create function test.zal(p_user text, p jsonb, p_call text default 'va_read') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'renter_activity', p) $$;
create table test.zal_all as select test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r')), 'admin_read') as j;

-- ================================================================ 1. one log
select test.ok('log: every type is in the one log by default', (select bool_and(t in (select x ->> 'type' from jsonb_array_elements(j -> 'items') x)) from test.zal_all,
  unnest(array['email', 'text', 'chat', 'call', 'note', 'booking', 'payment', 'document', 'visit']) t));
select test.ok('log: newest first', (select bool_and(a >= b) from (select (x ->> 'at')::timestamptz a, lead((x ->> 'at')::timestamptz) over (order by o) b
  from test.zal_all, jsonb_array_elements(j -> 'items') with ordinality y(x, o)) z where b is not null));
select test.eq('log: the newest is the booking event, with its note', (select (j #>> '{items,0,type}') || '/' || (j #>> '{items,0,body}') from test.zal_all), 'booking/Keys handed over');
select test.eq('log: the email from the renter, with its subject and the booking', (select (x ->> 'title') || '/' || (x ->> 'dir') || '/' || (x ->> 'booking_number')
  from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'k' like 'email:%'), 'Email from the renter/in/ZAL-1');
select test.ok('log: the email the platform sent, by its subject', (select (x ->> 'title') like 'Email sent: %' from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'k' like 'outbox:%'));
select test.eq('log: the call with its summary and next steps', (select (x ->> 'body') || '/' || (x #>> '{extra,next_steps,0}') from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'type' = 'call'),
  'Asked about the toll road/Send the toll rules');
select test.eq('log: the chat line opens its conversation', (select x ->> 'ref' from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'type' = 'chat'), '00000000-0000-4000-8000-00000000a102');
select test.ok('log: the payment, with its amount', (select bool_or(x ->> 'body' = '$450.00, succeeded') from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'type' = 'payment'));
select test.eq('log: the visit and what they did there, not each page view', (select string_agg(x ->> 'title', '|' order by x ->> 'k') from test.zal_all, jsonb_array_elements(j -> 'items') x where x ->> 'type' = 'visit'),
  'Search|Visit to the site');
select test.eq('log: no email address or phone number is in the log', (select count(*) from test.zal_all, jsonb_array_elements(j -> 'items') x where x::text ~ '@example\.test|2895550891'), 0::bigint);

-- ================================================================ 2. filters, search, pages
select test.eq('filter: one type', (select string_agg(distinct x ->> 'type', ',') from jsonb_array_elements(test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r'), 'types', 'call,text'), 'admin_read') -> 'items') x), 'call,text');
select test.eq('filter: an unknown type means all', (select jsonb_array_length(test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r'), 'types', 'nonsense'), 'admin_read') -> 'items'))
  = (select jsonb_array_length(j -> 'items') from test.zal_all), true);
select test.eq('search: words in the text, any case', (select string_agg(x ->> 'type', ',') from jsonb_array_elements(test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r'), 'q', 'TOLL road'), 'admin_read') -> 'items') x), 'call');
create table test.zal_p1 as select test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r'), 'limit', 3), 'admin_read') as j;
select test.eq('pages: a page of the limit, with Older', (select jsonb_array_length(j -> 'items') || '/' || (j ->> 'more') from test.zal_p1), '3/true');
create table test.zal_p2 as select test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r'), 'limit', 3, 'before', j #>> '{next,before}', 'before_k', j #>> '{next,before_k}'), 'admin_read') as j from test.zal_p1;
select test.eq('pages: Older starts right after the last one, with no repeat', (select count(*) from test.zal_p1 a, test.zal_p2 b, jsonb_array_elements(a.j -> 'items') x, jsonb_array_elements(b.j -> 'items') y where x ->> 'k' = y ->> 'k'), 0::bigint);
select test.eq('pages: page two follows page one in the full log', (select b.j #>> '{items,0,k}' from test.zal_p2 b), (select j #>> '{items,3,k}' from test.zal_all));
select test.eq('pages: 50 by default', (select (test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_r')), 'admin_read') ->> 'more')), 'false');

-- ================================================================ 3. who
select test.eq('who: customer service in the renter''s window reads it, payments included', (select count(*) from jsonb_array_elements(test.zal('zal_cs', jsonb_build_object('renter_id', test.id('renter:zal_r'), '_va', 'cs')) -> 'items') x where x ->> 'type' = 'payment') > 0, true);
select test.eq('who: Fleet reads it without payments', (select (j -> 'types') ? 'payment' or exists (select 1 from jsonb_array_elements(j -> 'items') x where x ->> 'type' = 'payment')
  from (select test.zal('zal_fleet', jsonb_build_object('renter_id', test.id('renter:zal_r'))) as j) z), false);
select test.throws('who: staff outside the renter''s window do not', format($$ select test.zal('zal_cs', jsonb_build_object('renter_id', %L)) $$, test.id('renter:zal_old')), '%Open this renter%');
select test.eq('who: an Admin reads any renter', (select jsonb_typeof(test.zal('zal_admin', jsonb_build_object('renter_id', test.id('renter:zal_old')), 'admin_read') -> 'items')), 'array');
select test.throws('who: a renter does not', format($$ select test.zal('zal_r', jsonb_build_object('renter_id', %L)) $$, test.id('renter:zal_r')), '%');

-- ================================================================ 4. a booking's log
select test.eq('booking: the booking''s log on the booking page (ops_read), the same items', (select jsonb_array_length(j -> 'items') from (select test.zal('zal_cs', jsonb_build_object('booking', 'ZAL-1', '_va', 'cs'), 'ops_read') as j) z),
  (select jsonb_array_length(j -> 'items') from test.zal_all));
select test.eq('booking: by its number in any case', (select test.zal('zal_admin', jsonb_build_object('booking', 'zal-1'), 'ops_read') ->> 'booking'), 'ZAL-1');
select test.throws('booking: staff outside the renter''s window do not', $$ select test.zal('zal_cs', jsonb_build_object('booking', 'ZAL-OLD', '_va', 'cs'), 'ops_read') $$, '%not open to you%');
select test.throws('booking: an unknown booking', $$ select test.zal('zal_admin', jsonb_build_object('booking', 'NOPE-1'), 'ops_read') $$, '%not found%');
select test.eq('the door still answers what it did before', (select jsonb_typeof(app.door(test.id('zal_cs'), 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', test.id('renter:zal_r'))) -> 'notes')), 'array');

select app.process_events(1000) >= 0 as processed;
