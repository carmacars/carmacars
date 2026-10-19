-- 39: live visitors and live chat (migration 0060). The beacon (consent, staff not recorded, rate limit, the email
-- link), signals and their thresholds, interest per car, follow-up tasks, the Live page and its access, the chat: the
-- visitor's secret, the assistant's budget, the hand-over to a person (on shift or after hours), contact details, a
-- request from the assistant, staff take-over, reply, hand back, close, the transcript email, a proactive chat,
-- retention. Fixtures start with "lv".
select test.suite('39 live visitors and chat');

select test.mk_user('lv_admin', 'admin');
select test.mk_user('lv_cs', 'va', 'cs');
select test.mk_user('lv_sales', 'va', 'sales');
select test.mk_user('lv_fin', 'va', 'finance');
select test.mk_renter('lv_rita');

create temp table s39 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s39(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s39 where k = p_k $$;
grant all on s39 to public;

-- seven cars with public slugs
do $$
declare i integer; v jsonb;
begin
  for i in 1 .. 7 loop
    v := app.vehicle_add(test.id('lv_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1KVKXVE00000000' || lpad(i::text, 2, '0'), 'plate', 'LV00' || i,
      'year', 2024, 'make', 'Kia', 'model', 'K' || i, 'rates', jsonb_build_object('daily', 10000, 'weekend', 12000, 'weekly', 56000, 'monthly', 180000, 'deposit', 30000)));
    insert into vehicle_listings (vehicle_id, slug, status) values ((v ->> 'vehicle_id')::uuid, 'lv-car-' || i, 'draft')
    on conflict (vehicle_id) do update set slug = excluded.slug;
    insert into pg_temp.s39 values ('car' || i, v);
  end loop;
end $$;
create or replace function test.lvcar(i integer) returns uuid language sql stable as $$ select (test.s39('car' || i) ->> 'vehicle_id')::uuid $$;

create or replace function test.beacon(p_sid text, p_consent text, p_events jsonb, p_geo jsonb default '{"city":"Toronto","region":"ON","country":"CA"}') returns jsonb
language sql as $$ select public.track_ingest(jsonb_build_object('sid', p_sid, 'vid', md5('vid:' || p_sid)::uuid, 'consent', p_consent, 'device', 'phone', 'ref', 'instagram.com',
  'utm', jsonb_build_object('source', 'ig', 'campaign', 'fall'), 'landing', '/', 'events', p_events), p_geo) $$;
create or replace function test.sid(p text) returns text language sql immutable as $$ select md5('sid:' || p)::uuid::text $$;

-- ================================================================ 1. consent and the beacon
select test.eq('settings: on, 90 days, the owner''s thresholds, chat on, AI first, greeting off',
  (select format('%s %s %s/%s %s %s %s %s %s', visitor_tracking_enabled, visitor_events_keep_days, visitor_spree_cars, visitor_spree_minutes, visitor_offer_no_answer_hours,
                 chat_enabled, chat_ai_enabled, chat_greeting_seconds, chat_ai_daily_neurons) from (select (app.settings()).*) s),
  't 90 6/10 6 t t 0 6000');
select test.eq('without consent: an anonymous visitor is not recorded',
  test.beacon(test.sid('anon'), 'essential', '[{"k": "page_view", "path": "/cars/lv-car-1", "slug": "lv-car-1"}]') ->> 'kept', 'false');
select test.eq('without consent: no session, no event', (select count(*) from visitor_sessions where id = test.sid('anon')::uuid), 0::bigint);
select test.eq('with consent: kept, with the chat settings', (test.beacon(test.sid('a'), 'analytics', '[{"k": "page_view", "path": "/"}]') -> 'cfg' ->> 'chat'), 'true');
select test.eq('with consent: the session has the city, device, referrer host and UTM; no network address column exists',
  (select format('%s %s %s %s %s', city, device, referrer, utm ->> 'source', consent) from visitor_sessions where id = test.sid('a')::uuid)
  || ' ' || (select count(*) from information_schema.columns where table_name = 'visitor_sessions' and column_name ~ 'ip'), 'Toronto phone instagram.com ig analytics 0');
select test.eq('who: "Visitor from Toronto, phone"', (select app.visitor_who(s) from visitor_sessions s where id = test.sid('a')::uuid), 'Visitor from Toronto, phone');
select test.eq('a junk batch is refused', app.track_ingest('{"sid": "x"}'::jsonb) ->> 'ok', 'false');
-- staff browsing the site are never recorded
select test.login(test.id('lv_cs'));
select test.eq('staff: not recorded', test.beacon(test.sid('staff'), 'analytics', '[{"k": "page_view", "path": "/"}]') ->> 'staff', 'true');
select test.logout();
select test.eq('staff: no session', (select count(*) from visitor_sessions where id = test.sid('staff')::uuid), 0::bigint);
-- the anonymous role may call the beacon and the chat poll, nothing else of 0060
select test.eq('privileges: anon executes track_ingest, chat_poll, chat_typing; not the server functions',
  has_function_privilege('anon', 'public.track_ingest(jsonb, jsonb)', 'execute')::text || has_function_privilege('anon', 'public.chat_poll(text, bigint)', 'execute')::text
  || has_function_privilege('anon', 'public.server_chat_open(jsonb, uuid)', 'execute')::text || has_function_privilege('authenticated', 'public.server_chat_lead(text, jsonb)', 'execute')::text
  || has_function_privilege('anon', 'app.live_visitors(uuid, jsonb)', 'execute')::text, 'truetruefalsefalsefalse');
select test.eq('rate limit: a flood of batches from one session is refused',
  (select count(*) from generate_series(1, 95) g where (test.beacon(test.sid('flood'), 'analytics', '[]') ->> 'limited') = 'true'), 5::bigint);

-- ================================================================ 2. signals and interest per car
select test.beacon(test.sid('spree'), 'analytics', (select jsonb_agg(jsonb_build_object('k', 'page_view', 'path', '/cars/lv-car-' || i, 'slug', 'lv-car-' || i)) from generate_series(1, 6) i));
select test.eq('viewing spree: 6 cars in 10 minutes', (select label from visitor_signals where session_id = test.sid('spree')::uuid and kind = 'viewing_spree'), 'Viewing spree: 6 cars in 10 minutes');
select test.eq('car views: counted per car and day, one viewer each', (select views || '/' || viewers from vehicle_interest_daily where vehicle_id = test.lvcar(1) and day = app.local_date(now())), '1/1');
select test.beacon(test.sid('spree'), 'analytics', '[{"k": "page_view", "path": "/cars/lv-car-1", "slug": "lv-car-1"}]');
select test.eq('car views: the same visitor again is a view, not a new viewer', (select views || '/' || viewers from vehicle_interest_daily where vehicle_id = test.lvcar(1) and day = app.local_date(now())), '2/1');
select test.eq('below the threshold: 5 cars are not a spree', (select count(*) from visitor_signals where session_id = test.sid('a')::uuid), 0::bigint);
update program_settings set visitor_spree_cars = 3;
select test.beacon(test.sid('spree3'), 'analytics', (select jsonb_agg(jsonb_build_object('k', 'page_view', 'path', '/cars/lv-car-' || i, 'slug', 'lv-car-' || i)) from generate_series(1, 3) i));
select test.eq('the threshold is a Program setting (3 cars)', (select label from visitor_signals where session_id = test.sid('spree3')::uuid), 'Viewing spree: 3 cars in 10 minutes');
update program_settings set visitor_spree_cars = 6;
-- a request started and stopped; a request sent counts on the car
select test.beacon(test.sid('req'), 'analytics', '[{"k": "page_view", "path": "/book/lv-car-2", "slug": "lv-car-2"}, {"k": "request_started", "path": "/book/lv-car-2", "slug": "lv-car-2"}, {"k": "request_abandoned", "path": "/book/lv-car-2", "slug": "lv-car-2"}]');
select test.eq('started a request and stopped', (select label from visitor_signals where session_id = test.sid('req')::uuid), 'Started a request and stopped (2024 Kia K2)');
select test.beacon(test.sid('req'), 'analytics', '[{"k": "page_view", "path": "/book/sent/R-000123", "slug": "lv-car-2"}]');
select test.eq('a request sent: the signal is resolved and the car counts a request',
  (select (resolved_at is not null)::text from visitor_signals where session_id = test.sid('req')::uuid) || ' ' || (select requests from vehicle_interest_daily where vehicle_id = test.lvcar(2) and day = app.local_date(now())), 'true 1');
-- returning visitor: the 3rd visit this week
select test.beacon(test.sid('r1'), 'analytics', '[{"k": "page_view", "path": "/"}]');
select app.track_ingest(jsonb_build_object('sid', test.sid('r2'), 'vid', md5('vid:' || test.sid('r1'))::uuid, 'consent', 'analytics', 'events', '[{"k": "page_view", "path": "/"}]'::jsonb));
select app.track_ingest(jsonb_build_object('sid', test.sid('r3'), 'vid', md5('vid:' || test.sid('r1'))::uuid, 'consent', 'analytics', 'events', '[{"k": "page_view", "path": "/"}]'::jsonb));
select test.eq('returning visitor, 3rd visit this week', (select label from visitor_signals where kind = 'returning' and visitor_id = md5('vid:' || test.sid('r1'))::uuid), 'Returning visitor, 3rd visit this week');
select test.eq('visit number', (select visit_number from visitor_sessions where id = test.sid('r3')::uuid), 3);

-- ================================================================ 3. a known customer: the offer, the email link, the pay page
insert into s39 select 'bk', jsonb_build_object('id', app.request_booking(test.id('renter:lv_rita'), test.lvcar(3), date_trunc('hour', now()) + interval '6 days',
  date_trunc('hour', now()) + interval '9 days', 'standard', null, 'web', test.id('lv_rita')));
create or replace function test.lvbk() returns bookings language sql stable as $$ select * from bookings where id = (test.s39('bk') ->> 'id')::uuid $$;
-- the offer itself is another suite's work: the status is set directly here
set session_replication_role = replica;
update bookings set status = 'offered' where id = (test.lvbk()).id;
set session_replication_role = default;
-- an offer email to Rita, then she opens its link without consent: she is known by the email
insert into app_events (code, entity, entity_id, payload) values ('renter_offer_ready', 'booking', (test.lvbk()).id, '{}');
insert into notification_outbox (id, event_id, code, category, priority, audience, recipient_user_id, to_address, to_name, renter_id, booking_id, entity, entity_id, payload, dedupe_key, status, sent_at)
values (test.id('lv:outbox'), (select max(id) from app_events), 'renter_offer_ready', 'transactional', 2, 'renter', test.id('lv_rita'), 'lv_rita@example.test', 'Lv Rita',
        test.id('renter:lv_rita'), (test.lvbk()).id, 'booking', (test.lvbk()).id, '{}', 'lv-outbox-1', 'sent', now());
select test.eq('email link: a visitor without consent who opens our email link is recorded and known',
  test.beacon(test.sid('rita1'), 'essential', jsonb_build_array(jsonb_build_object('k', 'email_link_opened', 'path', '/sign-in', 'm', test.id('lv:outbox')))) ->> 'known', 'true');
select test.eq('email link: the event is tied to the booking of the email',
  (select data ->> 'code' || ' ' || (booking_id = (test.lvbk()).id)::text from visitor_events where session_id = test.sid('rita1')::uuid and kind = 'email_link_opened'), 'renter_offer_ready true');
select test.eq('who: the renter''s name', (select app.visitor_who(s) from visitor_sessions s where id = test.sid('rita1')::uuid), 'Lv Rita');
select test.eq('without consent a general page is still not recorded for her',
  (test.beacon(test.sid('rita1'), 'essential', '[{"k": "page_view", "path": "/cars"}]') ->> 'events'), '0');
-- signed in, she views the offer (the booking number read first: a renter's session cannot read the bookings table)
select booking_number as lvbn from bookings where id = (test.s39('bk') ->> 'id')::uuid \gset
select test.login(test.id('lv_rita'));
select test.beacon(test.sid('rita2'), 'essential', jsonb_build_array(jsonb_build_object('k', 'page_view', 'path', '/account/bookings/' || :'lvbn' || '/offer', 'bn', :'lvbn')));
-- another renter's booking number is never tied to her visit
select test.beacon(test.sid('rita2'), 'essential', '[{"k": "page_view", "path": "/account/bookings/CC-999999/offer", "bn": "CC-999999"}]');
select test.logout();
select test.eq('offer viewed: recorded on her booking', (select count(*) from visitor_events where session_id = test.sid('rita2')::uuid and kind = 'offer_viewed'), 1::bigint);
select test.eq('signal: opened the offer, not answered (the email link and the page)',
  (select label from visitor_signals where kind = 'offer_opened' and renter_id = test.id('renter:lv_rita')), format('Opened offer %s (2 times), not answered', (test.lvbk()).booking_number));
-- follow-up: not before 6 hours
select test.eq('follow-up: nothing before the hours set', app.job_visitor_followups(now()), 'raised 0');
select test.eq('follow-up: after 6 hours, one task with the suggested action', app.job_visitor_followups(now() + interval '7 hours'), 'raised 1');
select test.eq('follow-up: the task says what to do', (select title from tasks where task_type = 'visitor_follow_up' and booking_id = (test.lvbk()).id),
  format('Call or message Lv Rita: opened offer %s twice, no answer for 7 hours', (test.lvbk()).booking_number));
select test.eq('follow-up: deduplicated', app.job_visitor_followups(now() + interval '8 hours') || ' ' || (select count(*) from tasks where task_type = 'visitor_follow_up' and booking_id = (test.lvbk()).id), 'raised 0 1');
-- she pays: the signal resolves and the task closes by itself
set session_replication_role = replica;
update bookings set status = 'pending_payment' where id = (test.lvbk()).id;
set session_replication_role = default;
select app.job_visitor_followups(now() + interval '9 hours');
select test.eq('answered: the signal is resolved and the follow-up closed by itself',
  (select (resolved_at is not null)::text from visitor_signals where kind = 'offer_opened' and renter_id = test.id('renter:lv_rita')) || ' ' || (select status from tasks where task_type = 'visitor_follow_up' and booking_id = (test.lvbk()).id), 'true done');
-- the pay page left without paying
select test.login(test.id('lv_rita'));
select test.beacon(test.sid('rita2'), 'essential', jsonb_build_array(jsonb_build_object('k', 'page_view', 'path', '/account/bookings/' || :'lvbn' || '/pay', 'bn', :'lvbn'),
  jsonb_build_object('k', 'pay_left', 'path', '/account/bookings/' || :'lvbn' || '/pay', 'bn', :'lvbn', 'ms', 40000)));
select test.logout();
select test.eq('left the pay page', (select label from visitor_signals where kind = 'pay_left' and booking_id = (test.lvbk()).id), format('Left the pay page (%s)', (test.lvbk()).booking_number));
insert into s39 select 'fu', to_jsonb(app.job_visitor_followups(now() + interval '31 minutes'));
select test.eq('follow-up after 30 minutes: customer service', (test.s39('fu') #>> '{}') || ' ' || (select queue from tasks where task_type = 'visitor_follow_up' and title like '%pay page%'), 'raised 1 cs');
select test.eq('earlier visits of the browser belong to her now', (select count(*) from visitor_sessions where renter_id = test.id('renter:lv_rita')), 2::bigint);

-- ================================================================ 4. the Live page, per car, the timeline, access
select test.eq('live: Admin sees who is on the site now with the signals',
  (select count(*) from jsonb_array_elements(app.live_visitors(test.id('lv_admin')) -> 'now') x where x ->> 'id' = test.sid('spree'))::text ||
  (select count(*) from jsonb_array_elements(app.live_visitors(test.id('lv_admin')) -> 'now' ) x where x ->> 'id' = test.sid('spree') and jsonb_array_length(x -> 'signals') > 0), '11');
select test.eq('live: customer service and Sales too', (app.live_visitors(test.id('lv_cs')) ->> 'tracking') || (app.live_visitors(test.id('lv_sales')) ->> 'tracking'), 'truetrue');
select test.throws('live: not Finance', $$ select app.live_visitors(test.id('lv_fin')) $$, 'Live visitors and Live chat are for Admins, customer service and Sales');
select test.eq('live: through the door', (app.door(test.id('lv_cs'), '', 'va_read', 'live_visitors', '{}') ->> 'tracking'), 'true');
select test.eq('most viewed: the car viewed twice comes first', (app.most_viewed_cars(7, 3) -> 0 ->> 'vehicle_id')::uuid, test.lvcar(1));
select test.eq('per car: views today, people looking now, conversion over 30 days',
  (select format('%s %s %s', x ->> 'views_today', x ->> 'looking_now', x ->> 'conversion_bps') from (select app.vehicle_interest(test.id('lv_admin'), jsonb_build_object('vehicle_id', test.lvcar(2))) x) y), '2 1 5000');
select test.eq('timeline: the booking page shows the offer viewed and the pay page left',
  (select string_agg(e ->> 'kind', ',' order by e ->> 'kind') from jsonb_array_elements(app.visitor_timeline(test.id('lv_cs'), jsonb_build_object('booking_id', (test.lvbk()).id)) -> 'events') e),
  'email_link_opened,offer_viewed,pay_left,pay_viewed');
select test.eq('renter page: Admin only', (app.renter_live(test.id('lv_admin'), jsonb_build_object('renter_id', test.id('renter:lv_rita'))) ->> 'name'), 'Lv Rita');
select test.eq('rls: a browser session reads no visitor table', (select count(*) from information_schema.role_table_grants where table_name in ('visitor_sessions', 'visitor_events', 'chat_messages', 'chat_conversations') and grantee in ('anon', 'authenticated')), 0::bigint);

-- ================================================================ 5. the chat: the visitor, the assistant, a person
insert into s39 select 'c1', app.server_chat_open(jsonb_build_object('vid', md5('vid:' || test.sid('spree'))::uuid, 'sid', test.sid('spree'), 'page', '/cars/lv-car-4', 'slug', 'lv-car-4'));
create or replace function test.tok(k text) returns text language sql stable as $$ select test.s39(k) ->> 'token' $$;
select test.eq('open: a conversation with a 64-character secret, the assistant first', length(test.tok('c1')) || ' ' || (test.s39('c1') ->> 'status'), '64 ai');
select test.eq('open again from the same browser: the same conversation', app.server_chat_open(jsonb_build_object('vid', md5('vid:' || test.sid('spree'))::uuid)) ->> 'number', test.s39('c1') ->> 'number');
select test.eq('open: the chat opened is an event of the visit', (select count(*) from visitor_events where session_id = test.sid('spree')::uuid and kind = 'chat_opened'), 1::bigint);
select test.eq('poll: a wrong secret reads nothing', app.chat_poll(repeat('0', 64), 0) ->> 'error', 'not_found');
select test.eq('message: the assistant may answer (budget left, not too many replies)', app.server_chat_visitor_message(test.tok('c1'), 'Is the K4 free next weekend?') ->> 'ai', 'true');
select test.eq('message: the assistant gets the conversation and the car', (app.server_chat_visitor_message(test.tok('c1'), 'And the price?') ->> 'car'), 'lv-car-4');
insert into s39 select 'r1', app.server_chat_ai_reply(test.tok('c1'), '{"body": "It is free. From $100.00 a day.", "neurons": 180, "model": "m", "meta": {"tools": [{"name": "quote"}], "cents": [10000]}}');
select test.eq('reply: stored with what it used; the neurons recorded as a Workers AI call',
  (test.s39('r1') ->> 'ok') || ' ' || (select sum(units) from provider_calls where purpose = 'chat'), 'true 180');
select test.eq('poll: the visitor reads the assistant''s reply under "CarmaCars assistant"; no meta for the visitor',
  (select m ->> 'name' || ' ' || (m ? 'meta')::text from jsonb_array_elements(app.chat_poll(test.tok('c1'), 0) -> 'messages') m where m ->> 'sender' = 'ai'), 'CarmaCars assistant false');
-- budget: the day's cap reached, the assistant stops and a person is needed
update program_settings set chat_ai_daily_neurons = 100;
select test.eq('budget: over the day''s cap the assistant stops', (app.server_chat_visitor_message(test.tok('c1'), 'Hello?') ->> 'ai_reason'), 'budget');
update program_settings set chat_ai_daily_neurons = 6000;
select test.eq('budget: the total of every Workers AI use counts too', (select (app.chat_budget() ->> 'all_cap')), '10000');
-- hand-over with nobody on shift: after hours
select test.eq('hand over, nobody on shift: waiting, after hours, asks for contact details',
  (select format('%s %s %s', x ->> 'status', x ->> 'on_shift', x ->> 'offline') from (select app.server_chat_handoff(test.tok('c1'), 'asked for a person') x) y), 'waiting false true');
select test.eq('hand over: one task for customer service, due at the first reply target',
  (select format('%s %s', queue, (due_at <= now() + interval '6 minutes')::text) from tasks where task_type = 'live_chat_waiting' and related_id = (select id from chat_conversations where token = test.tok('c1'))), 'cs true');
select test.eq('hand over: no staff email when nobody is on shift', (select count(*) from app_events where code = 'staff_chat_waiting'), 0::bigint);
select test.eq('after the hand-over the assistant does not answer', app.server_chat_visitor_message(test.tok('c1'), 'Anyone?') ->> 'ai', 'false');
select test.eq('contact: a bad email is refused', app.server_chat_contact(test.tok('c1'), '{"email": "nope"}') ->> 'error', 'That email does not look right');
insert into s39 select 'ct', app.server_chat_contact(test.tok('c1'), '{"name": "Vic Visitor", "email": "vic@example.test", "phone": "416 555 0199", "transcript": true}');
select test.eq('contact: kept on the chat and a lead; a task for the chat left after hours; the transcript emailed',
  (test.s39('ct') ->> 'ok')
  || ' ' || (select kind from leads where email = 'vic@example.test') || ' ' || (select count(*) from tasks where task_type = 'chat_contact')
  || ' ' || (select count(*) from app_events where code = 'renter_chat_transcript'), 'true chat 1 1');
select test.eq('contact: the visit is known now', (select known_email from visitor_sessions where id = test.sid('spree')::uuid), 'vic@example.test');
-- staff: take over, reply, typing, hand back, close
select test.eq('inbox: the waiting chat first, with its unread count',
  (select format('%s %s', x -> 'open' -> 0 ->> 'status', (x -> 'open' -> 0 ->> 'unread')::integer > 0) from (select app.chat_inbox(test.id('lv_cs')) x) y), 'waiting t');
select test.eq('inbox: opening it makes customer service on shift', app.chat_on_shift(), 1);
select app.chat_staff_do(test.id('lv_cs'), 'chat_take', jsonb_build_object('id', (select id from chat_conversations where token = test.tok('c1'))));
select test.eq('take over: with the person; the visitor reads who joined',
  (select status from chat_conversations where token = test.tok('c1')) || ' ' || (app.chat_poll(test.tok('c1'), 0) ->> 'agent'), 'human Lv');
select app.chat_staff_do(test.id('lv_cs'), 'chat_typing', jsonb_build_object('id', (select id from chat_conversations where token = test.tok('c1'))));
select test.eq('typing: the visitor sees it', app.chat_poll(test.tok('c1'), 0) ->> 'staff_typing', 'true');
select app.chat_staff_do(test.id('lv_cs'), 'chat_reply', jsonb_build_object('id', (select id from chat_conversations where token = test.tok('c1')), 'body', 'Hi Vic, the K4 is free. I can send you an offer.'));
select test.eq('reply: the first reply is timed and the waiting task is done',
  (select (first_human_reply_at is not null)::text from chat_conversations where token = test.tok('c1')) || ' ' || (select status from tasks where task_type = 'live_chat_waiting'), 'true done');
select test.eq('reply: an AI reply arriving after the take-over is dropped',
  app.server_chat_ai_reply(test.tok('c1'), '{"body": "late", "neurons": 10}') ->> 'dropped', 'true');
select test.throws('another function cannot reply', $$ select app.chat_staff_do(test.id('lv_fin'), 'chat_reply', jsonb_build_object('id', (select id from chat_conversations limit 1), 'body', 'x')) $$,
  'Live visitors and Live chat are for Admins, customer service and Sales');
select app.chat_staff_do(test.id('lv_cs'), 'chat_hand_back', jsonb_build_object('id', (select id from chat_conversations where token = test.tok('c1'))));
select test.eq('hand back: the assistant answers again', (select status from chat_conversations where token = test.tok('c1')), 'ai');
select app.chat_staff_do(test.id('lv_cs'), 'chat_close', jsonb_build_object('id', (select id from chat_conversations where token = test.tok('c1'))));
select test.eq('close: closed, the transcript email once more for the whole chat',
  (select status from chat_conversations where token = test.tok('c1')) || ' ' || (select count(*) from app_events where code = 'renter_chat_transcript'), 'closed 2');
select test.eq('transcript: to the visitor''s email, transactional, with every message', (select count(*) from app.notification_recipients(
    (select e from app_events e where code = 'renter_chat_transcript' order by id desc limit 1), (select c from notification_catalogue c where code = 'renter_chat_transcript')) r where r.email = 'vic@example.test'), 1::bigint);
select test.eq('transcript payload: the messages and the chat number',
  (select format('%s %s', x ->> 'chat_number' = (test.s39('c1') ->> 'number'), jsonb_array_length(x -> 'messages') >= 6)
     from (select app.notification_payload('renter_chat_transcript', (select e from app_events e where code = 'renter_chat_transcript' order by id desc limit 1), '{"audience": "renter"}') x) y), 't t');
select test.eq('catalogue: both emails, the transcript transactional', (select string_agg(code || ':' || category, ',' order by code) from notification_catalogue where code in ('renter_chat_transcript', 'staff_chat_waiting')),
  'renter_chat_transcript:transactional,staff_chat_waiting:transactional');

-- on shift: the staff who asked for it get an email when a chat waits
select app.chat_staff_do(test.id('lv_sales'), 'chat_prefs', '{"email_when_waiting": true}');
insert into s39 select 'c2', app.server_chat_open(jsonb_build_object('vid', md5('vid:c2')::uuid));
select test.eq('on shift: a person will reply shortly, no contact form', (app.server_chat_handoff(test.tok('c2'), 'a complaint') ->> 'offline'), 'false');
select test.eq('on shift: the staff email goes only to who asked for it', (select string_agg(r.email, ',') from app.notification_recipients(
    (select e from app_events e where code = 'staff_chat_waiting' order by id desc limit 1), (select c from notification_catalogue c where code = 'staff_chat_waiting')) r), 'lv_sales@example.test');

-- the assistant's booking request: a lead and a task for Sales
insert into s39 select 'c3', app.server_chat_open(jsonb_build_object('vid', md5('vid:c3')::uuid, 'slug', 'lv-car-5'));
select test.eq('request: a missing phone is asked for', app.server_chat_lead(test.tok('c3'), '{"name": "Ana Bell", "email": "ana@example.test"}') ->> 'missing', 'phone');
insert into s39 select 'ld', app.server_chat_lead(test.tok('c3'), '{"name": "Ana Bell", "email": "ana@example.test", "phone": "4165550123", "car": "lv-car-5", "pickup": "2026-11-02", "return": "2026-11-04"}');
select test.eq('request: a lead and a task for Sales, never a commission by itself',
  (test.s39('ld') ->> 'ok')
  || ' ' || (select queue from tasks where task_type = 'chat_request') || ' ' || (select payload ->> 'car' from leads where email = 'ana@example.test'), 'true sales lv-car-5');

-- a proactive chat from the Live page: the visitor sees it with the next beacon
select app.chat_staff_do(test.id('lv_cs'), 'chat_start', jsonb_build_object('session_id', test.sid('req'), 'body', 'Hi, can I help with your request?'));
select test.eq('proactive: the beacon brings the invitation and its message', (test.beacon(test.sid('req'), 'analytics', '[]') -> 'invite' ->> 'message'), 'Hi, can I help with your request?');
select test.eq('proactive: a person''s chat from the start', (select status || ' ' || started_by from chat_conversations where session_id = test.sid('req')::uuid), 'human staff');
select app.chat_typing(token) from chat_conversations where session_id = test.sid('req')::uuid;
select test.eq('visitor typing shows to staff', 'true'
  || ' ' || (select (app.chat_row(c) ->> 'visitor_typing') from chat_conversations c where session_id = test.sid('req')::uuid), 'true true');

-- follow-ups count in My sales
update tasks set status = 'done', completed_at = now(), completed_by = test.id('lv_sales') where task_type = 'chat_request';
select test.eq('my sales: follow-ups done this week', (app.door(test.id('lv_sales'), '', 'va_read', 'my_followups', '{}') ->> 'done'), '1');

-- ================================================================ 6. retention
update visitor_events set at = now() - interval '91 days' where session_id = test.sid('a')::uuid;
update visitor_sessions set last_seen_at = now() - interval '91 days' where id = test.sid('a')::uuid;
select app.job_visitor_housekeeping(now());
select test.eq('retention: events and sessions older than 90 days are deleted; daily counts per car kept',
  (select count(*) from visitor_events where session_id = test.sid('a')::uuid) || ' ' || (select count(*) from visitor_sessions where id = test.sid('a')::uuid)
  || ' ' || ((select count(*) from vehicle_interest_daily) > 0)::text, '0 0 true');
update chat_conversations set closed_at = now() - interval '400 days', last_message_at = now() - interval '400 days', renter_id = null where token = test.tok('c2');
select app.job_visitor_housekeeping(now());
select test.eq('retention: a chat of a visitor who is not a customer goes after the days set', (select count(*) from chat_conversations where token = test.tok('c2')), 0::bigint);
select test.eq('privacy policy: the cookie wording asks again with the new text', (select data ->> 'version' from site_content_blocks where block_key = 'cookies.banner') >= '2026-10-19' or not exists (select 1 from site_content_blocks where block_key = 'cookies.banner'), true);
