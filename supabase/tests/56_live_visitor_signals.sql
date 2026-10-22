-- 56: live visitor signals (migration 0086). The new events and their consent, every signal rule, the booking
-- likelihood score and its reasons, the hot band, the rules and settings Admins change, the one-click actions
-- (invite, discount code, assign to Sales, a similar free car), interest per car (prices shown, cars compared), the
-- 5-minute job, the doors and who may use them. Fixtures start with "sg".
select test.suite('56 live visitor signals');

select test.mk_user('sg_admin', 'admin');
select test.mk_user('sg_cs', 'va', 'cs');
select test.mk_user('sg_sales', 'va', 'sales');
select test.mk_user('sg_fin', 'va', 'finance');
select test.mk_renter('sg_rita');
select test.mk_owner('sg_owner');
select test.mk_vehicle('SG' || i, 'sg_owner') from generate_series(1, 4) i;
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at)
select test.id('vehicle:SG' || i), 'sg-car-' || i, 'Signal car ' || i, 'published', now() from generate_series(1, 4) i
on conflict (vehicle_id) do update set slug = excluded.slug, status = 'published';
-- car 1 is premium; the other three are sedans
delete from vehicle_class_links where vehicle_id in (select test.id('vehicle:SG' || i) from generate_series(2, 4) i);
insert into vehicle_class_links (vehicle_id, class_code, source) select test.id('vehicle:SG' || i), 'sedan', 'staff' from generate_series(2, 4) i;
update chat_staff_prefs set last_seen_at = null;

create or replace function test.sgcar(i integer) returns uuid language sql stable as $$ select test.id('vehicle:SG' || i) $$;
create or replace function test.sgname(i integer) returns text language sql stable as $$ select app.vehicle_name(test.id('vehicle:SG' || i)) $$;
create or replace function test.sgsid(p text) returns uuid language sql immutable as $$ select md5('sg-sid:' || p)::uuid $$;
create or replace function test.sgb(p_sid text, p_events jsonb, p_consent text default 'analytics', p_extra jsonb default '{}') returns jsonb
language sql as $$ select public.track_ingest(jsonb_build_object('sid', test.sgsid(p_sid), 'vid', md5('sg-vid:' || p_sid)::uuid, 'consent', p_consent, 'device', 'desktop',
  'landing', '/', 'events', p_events) || p_extra, '{"city": "Toronto", "region": "ON", "country": "CA"}') $$;
-- the signals of a visit, as "kind" list, and one signal's why
create or replace function test.sgk(p_sid text) returns text language sql stable as $$
  select coalesce(string_agg(kind, ',' order by kind), '') from visitor_live_signals where session_id = test.sgsid(p_sid) and active $$;
create or replace function test.sgwhy(p_sid text, p_kind text) returns text language sql stable as $$
  select why from visitor_live_signals where session_id = test.sgsid(p_sid) and kind = p_kind and active $$;
create or replace function test.sgscore(p_sid text) returns integer language sql stable as $$ select score from visitor_sessions where id = test.sgsid(p_sid) $$;
create or replace function test.ev(k text, slug integer default null, d jsonb default null, path text default null) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('k', k, 'path', coalesce(path, case when slug is not null then '/cars/sg-car-' || slug else '/' end),
    'slug', case when slug is not null then 'sg-car-' || slug end, 'd', d)) $$;

-- ================================================================ 1. rules, settings, consent
select test.eq('rules: 35 signals in five groups, the six of 0060 among them',
  (select count(*) || ' ' || count(distinct grp) || ' ' || count(*) filter (where legacy) from visitor_signal_rules), '35 5 6');
select test.eq('settings: hot from 60, warm from 30, strong from 15 points, a 10% code for 3 days, 10 a day, Admins and Sales only',
  (select format('%s %s %s %s %s %s %s', hot_score, warm_score, strong_weight, discount_percent, discount_valid_days, discount_daily_cap, discount_cs) from visitor_signal_config), '60 30 15 10 3 10 f');
select test.eq('without consent: the new events are never kept (no visit recorded at all)',
  test.sgb('anon', jsonb_build_array(test.ev('quote_seen', 1, '{"days": "3", "total": "320", "avail": "1"}'), test.ev('contact_click', null, '{"via": "call"}')), 'essential') ->> 'kept', 'false');
select test.eq('without consent: nothing stored', (select count(*) from visitor_sessions where id = test.sgsid('anon')), 0::bigint);
-- a known renter on her own booking page without consent: still none of the new events
select test.login(test.id('sg_rita'));
select test.sgb('rita-ess', jsonb_build_array(test.ev('page_view', null, null, '/account'), test.ev('help_open', null, '{"topic": "deposit"}'), test.ev('photos', 1, '{"n": "9"}')), 'essential');
select test.logout();
select test.eq('a known renter without consent: none of the 0086 events', (select count(*) from visitor_events e where e.session_id = test.sgsid('rita-ess')
  and e.kind in ('quote_seen', 'request_step', 'help_open', 'contact_click', 'photos', 'browse', 'friction')), 0::bigint);
select test.sgb('det', jsonb_build_array(
  test.ev('help_open', null, '{"topic": "deposit", "question": "my secret text"}'), test.ev('help_open', null, '{"topic": "anything"}'),
  test.ev('contact_click', null, '{"via": "fax"}'), test.ev('contact_click', null, '{"via": "whatsapp", "number": "4165550000"}'),
  test.ev('friction', null, '{"type": "keystrokes"}'), test.ev('quote_seen', 1, '{"days": "x"}')), 'analytics', '{"ad": "1"}');
select test.eq('details: only the listed values are kept; anything else in an event is dropped',
  (select string_agg(kind || ':' || data::text, ' ' order by id) from visitor_events where session_id = test.sgsid('det')), 'help_open:{"topic": "deposit"} contact_click:{"via": "whatsapp"}');
select test.eq('ad click: only the flag is kept', (select from_ad::text from visitor_sessions where id = test.sgsid('det')), 'true');
select test.eq('ad click without consent: nothing', test.sgb('ad-ess', '[]', 'essential', '{"ad": "1"}') ->> 'kept', 'false');

-- ================================================================ 2. intent
select test.sgb('dates', (select jsonb_agg(test.ev('search', 2, jsonb_build_object('pickup', (current_date + 40 + i)::text, 'return', (current_date + 43 + i)::text))) from generate_series(1, 3) i));
select test.eq('dates searched 3 times', test.sgwhy('dates', 'dates_repeat'), 'Searched dates 3 times this visit');
select test.sgb('dates2', (select jsonb_agg(test.ev('search', 2, jsonb_build_object('pickup', (current_date + 40)::text, 'return', (current_date + 43)::text))) from generate_series(1, 2) i));
select test.eq('twice is below the threshold', test.sgk('dates2'), '');
select test.sgb('price', jsonb_build_array(test.ev('page_view', 1), test.ev('quote_seen', 1, '{"days": "3", "total": "1320", "avail": "1"}')));
select test.eq('saw the full price', test.sgwhy('price', 'price_seen'), format('Saw $1,320 for 3 days, %s', test.sgname(1)));
select test.sgb('price', jsonb_build_array(test.ev('quote_seen', 1, '{"days": "4", "total": "1700", "avail": "1"}')));
select test.eq('prices shown count once a visit per car', (select quotes from vehicle_interest_daily where vehicle_id = test.sgcar(1) and day = app.local_date(now())), 1);
select test.sgb('form', jsonb_build_array(test.ev('page_view', null, null, '/book/sg-car-2'), test.ev('request_started', null, null, '/book/sg-car-2'),
  jsonb_build_object('k', 'request_step', 'path', '/book/sg-car-2', 'slug', 'sg-car-2', 'd', '{"step": "3"}'::jsonb)));
select test.eq('reached the booking form, with the step', test.sgwhy('form', 'form_reached'), 'Reached step 3 of the request form');
-- the same car on another day
select test.sgb('ret1', jsonb_build_array(test.ev('page_view', 3)));
update visitor_events set at = at - interval '2 days' where session_id = test.sgsid('ret1');
select app.track_ingest(jsonb_build_object('sid', test.sgsid('ret2'), 'vid', md5('sg-vid:ret1')::uuid, 'consent', 'analytics', 'events', jsonb_build_array(test.ev('page_view', 3))));
select test.eq('came back for the same car on another day', test.sgwhy('ret2', 'same_car_return'), format('Looked at the %s again, first seen on an earlier day', test.sgname(3)));
select test.eq('the first visit of that day does not count', test.sgk('ret1'), '');
select test.sgb('cmp', jsonb_build_array(test.ev('page_view', 2), test.ev('page_view', 3), test.ev('page_view', 2), test.ev('page_view', 3), test.ev('page_view', 2)));
select test.eq('comparing two cars back and forth', test.sgwhy('cmp', 'comparing'), format('Went back and forth between the %s and the %s', test.sgname(2), test.sgname(3)));
select test.eq('cars compared: counted per day, without a person', (app.vehicle_compared(test.sgcar(2)) -> 0 ->> 'car'), test.sgname(3));
update visitor_signal_rules set t2 = 3 where code = 'comparing';
select test.sgb('cmp5', (select jsonb_agg(test.ev('page_view', 1 + (i % 4))) from generate_series(0, 9) i));
select test.eq('more cars than the limit is browsing, not comparing', position('comparing' in test.sgk('cmp5')), 0);
update visitor_signal_rules set t2 = 4 where code = 'comparing';
select test.sgb('policy', jsonb_build_array(test.ev('page_view', null, null, '/cancellation-policy')));
select test.eq('read the cancellation policy', test.sgwhy('policy', 'policy_check'), 'Read about cancelling');
select test.sgb('help', jsonb_build_array(test.ev('help_open', null, '{"topic": "insurance"}'), test.ev('page_view', null, null, '/requirements')));
select test.eq('read the rules: the topics in words', test.sgwhy('help', 'help_read'), 'Read about insurance, the requirements');
select test.eq('the message names the topics', (select app.visitor_fill(r.message, l.data) from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind
  where l.session_id = test.sgsid('help') and l.kind = 'help_read'), 'Hi! Any question about insurance, the requirements? I can answer here.');
select test.sgb('tap', jsonb_build_array(test.ev('contact_click', null, '{"via": "call"}'), test.ev('contact_click', null, '{"via": "copy"}')));
select test.eq('tapped to call or copied the number', test.sgwhy('tap', 'contact_tap'), 'Tapped to call, copy our number');
select test.sgb('deliv', jsonb_build_array(test.ev('quote_seen', 1, '{"days": "2", "total": "400", "avail": "1", "deliv": "1"}')));
select test.eq('priced delivery', test.sgwhy('deliv', 'delivery_check'), 'Priced delivery to an address');
select test.sgb('photos', jsonb_build_array(test.ev('page_view', 4), test.ev('photos', 4, '{"n": "8"}')));
select test.eq('looked through 8 photos', test.sgwhy('photos', 'photo_dwell'), format('Looked through 8 photos of the %s', test.sgname(4)));
select test.sgb('dwell', jsonb_build_array(test.ev('page_view', 4), jsonb_build_object('k', 'page_leave', 'path', '/cars/sg-car-4', 'slug', 'sg-car-4', 'ms', 200000)));
select test.eq('or stayed long on one car', test.sgwhy('dwell', 'photo_dwell'), format('Stayed 3 minutes on the %s', test.sgname(4)));

-- ================================================================ 3. urgency
select test.sgb('soon', jsonb_build_array(test.ev('search', 2, jsonb_build_object('pickup', (app.local_date(now()) + 1)::text, 'return', (app.local_date(now()) + 3)::text))));
select test.eq('pickup tomorrow', test.sgwhy('soon', 'soon_pickup'), 'Pickup tomorrow');
select test.sgb('far', jsonb_build_array(test.ev('search', 2, jsonb_build_object('pickup', (app.local_date(now()) + 20)::text, 'return', (app.local_date(now()) + 30)::text))));
select test.eq('in 20 days is not soon', position('soon_pickup' in test.sgk('far')), 0);
-- a Friday to Sunday trip, the first Friday at least 10 days away
select test.sgb('wknd', jsonb_build_array(test.ev('search', 2, jsonb_build_object(
  'pickup', (select d::date from generate_series(current_date + 10, current_date + 17, interval '1 day') d where extract(isodow from d) = 5 limit 1)::text,
  'return', (select d::date + 2 from generate_series(current_date + 10, current_date + 17, interval '1 day') d where extract(isodow from d) = 5 limit 1)::text))));
select test.ok('weekend dates', test.sgwhy('wknd', 'weekend_trip') = 'Friday to Sunday' or test.sgwhy('wknd', 'weekend_trip') like 'Dates over %', test.sgwhy('wknd', 'weekend_trip'));
insert into holidays (holiday_on, name) values (current_date + 50, 'Signal Day') on conflict do nothing;
select test.sgb('hol', jsonb_build_array(test.ev('search', 2, jsonb_build_object('pickup', (current_date + 49)::text, 'return', (current_date + 56)::text))));
select test.ok('dates over a holiday', test.sgwhy('hol', 'weekend_trip') like 'Dates over %', test.sgwhy('hol', 'weekend_trip'));
-- late at night on a phone, looking at a car
select public.track_ingest(jsonb_build_object('sid', test.sgsid('night'), 'vid', md5('sg-vid:night')::uuid, 'consent', 'analytics', 'device', 'phone', 'events', jsonb_build_array(test.ev('page_view', 1))), '{}');
update visitor_sessions set last_seen_at = app.local_midnight(app.local_date(now())) + interval '23 hours 30 minutes' where id = test.sgsid('night');
select app.visitor_live_eval(test.sgsid('night'));
select test.eq('on a phone late at night', test.sgwhy('night', 'late_night'), 'On a phone at 11:30 pm');
update visitor_sessions set last_seen_at = app.local_midnight(app.local_date(now())) + interval '14 hours' where id = test.sgsid('night');
select app.visitor_live_eval(test.sgsid('night'));
select test.eq('not in the afternoon', position('late_night' in test.sgk('night')), 0);
-- the visit back in the past: just after local midnight, 2 pm today is still ahead and the job test below would count it
update visitor_sessions set last_seen_at = least(last_seen_at, now() - interval '2 minutes') where id = test.sgsid('night');
select public.track_ingest(jsonb_build_object('sid', test.sgsid('local'), 'vid', md5('sg-vid:local')::uuid, 'consent', 'analytics', 'landing', '/car-rental/mississauga',
  'events', jsonb_build_array(test.ev('page_view', null, null, '/car-rental/mississauga'))), '{}');
select test.eq('came from a local page', test.sgwhy('local', 'local_search'), 'Landed on Car Rental (/car-rental/mississauga)');

-- ================================================================ 4. value
select test.sgb('long', jsonb_build_array(test.ev('search', 2, jsonb_build_object('pickup', (current_date + 30)::text, 'return', (current_date + 60)::text))));
select test.eq('a long rental: 30 days, monthly', test.sgwhy('long', 'long_rental'), '30 days (monthly)');
select test.sgb('prem', jsonb_build_array(test.ev('page_view', 1)));
select test.eq('a premium car', test.sgwhy('prem', 'premium_class'), format('Looked at the %s (Premium)', test.sgname(1)));
select test.sgb('sedan', jsonb_build_array(test.ev('page_view', 2)));
select test.eq('a sedan is not premium', test.sgk('sedan'), '');
select test.sgb('xdrv', jsonb_build_array(test.ev('quote_seen', 2, '{"days": "2", "total": "300", "avail": "1", "xdrv": "1"}')));
select test.eq('priced an additional driver', test.sgwhy('xdrv', 'extra_driver'), 'Priced an additional driver');
select test.sgb('young', jsonb_build_array(test.ev('help_open', null, '{"topic": "young"}')));
select test.eq('asked about young drivers (worth no points by default)', test.sgwhy('young', 'young_driver') || ' ' || test.sgscore('young'), 'Read about drivers under 25 0');
-- an email given in the chat
select test.sgb('biz', jsonb_build_array(test.ev('page_view', 2)));
insert into chat_conversations (session_id, visitor_id, email, status) values (test.sgsid('biz'), md5('sg-vid:biz')::uuid, 'pat@acme-logistics.example', 'ai');
select app.visitor_live_eval(test.sgsid('biz'));
select test.eq('a business email', test.sgwhy('biz', 'business_email'), 'Email at acme-logistics.example');
update chat_conversations set email = 'pat@gmail.com' where visitor_id = md5('sg-vid:biz')::uuid;
select app.visitor_live_eval(test.sgsid('biz'));
select test.eq('a personal email is not', position('business_email' in test.sgk('biz')), 0);
-- the chat's words count as questions too (key words only)
insert into chat_messages (conversation_id, sender, body) select id, 'visitor', 'Can my wife be an additional driver? And how much is the deposit hold?' from chat_conversations where visitor_id = md5('sg-vid:biz')::uuid;
select app.visitor_live_eval(test.sgsid('biz'));
select test.eq('questions in the chat: an additional driver and the deposit', test.sgk('biz'), 'deposit_worry,extra_driver,help_read');

-- ================================================================ 5. hesitation
select test.sgb('cheap', jsonb_build_array(jsonb_build_object('k', 'browse', 'path', '/cars', 'd', '{"sort": "price-asc"}'::jsonb), jsonb_build_object('k', 'browse', 'path', '/cars', 'd', '{"maxp": "1", "filter": "1"}'::jsonb)));
select test.eq('watching the price', test.sgwhy('cheap', 'price_sensitive'), 'Sorted by lowest price, lowered the price limit');
select test.eq('its action is a discount code', (select r.action from visitor_signal_rules r where r.code = 'price_sensitive'), 'discount');
select test.sgb('left', jsonb_build_array(test.ev('page_view', 2), test.ev('quote_seen', 2, '{"days": "3", "total": "330", "avail": "1"}')));
select test.eq('just after the price: not yet "left"', position('left_at_price' in test.sgk('left')), 0);
select test.eq('the 5-minute job looks again later', app.job_visitor_signals(now() + interval '11 minutes') like 'evaluated %', true);
select test.eq('10 minutes without a request: left after seeing the price', test.sgwhy('left', 'left_at_price'), format('Saw $330 for the %s and did not start a request', test.sgname(2)));
select test.sgb('left', jsonb_build_array(test.ev('request_started', null, null, '/book/sg-car-2')));
select test.eq('a request started: the reason passed', position('left_at_price' in test.sgk('left')), 0);
select test.sgb('err', jsonb_build_array(test.ev('friction', null, '{"type": "error"}'), test.ev('friction', null, '{"type": "error"}'), test.ev('friction', null, '{"type": "rage"}')));
select test.eq('trouble with a form', test.sgwhy('err', 'friction'), '2 form errors, tapped again and again on something');
select test.sgb('busy', jsonb_build_array(test.ev('search', 3, jsonb_build_object('pickup', (current_date + 70)::text, 'return', (current_date + 72)::text)),
  test.ev('quote_seen', 3, '{"days": "2", "total": "250", "avail": "0"}')));
select test.eq('the car is not free for their dates', test.sgwhy('busy', 'unavailable'),
  format('The %s is not free from %s to %s', test.sgname(3), app.visitor_date_words(current_date + 70), app.visitor_date_words(current_date + 72)));

-- ================================================================ 6. context
select test.eq('from an ad', test.sgwhy('det', 'from_ad'), 'Clicked one of our ads');
select public.track_ingest(jsonb_build_object('sid', test.sgsid('paid'), 'vid', md5('sg-vid:paid')::uuid, 'consent', 'analytics', 'utm', '{"source": "google", "medium": "cpc", "campaign": "fall"}'::jsonb,
  'events', jsonb_build_array(test.ev('page_view'))), '{}');
select test.eq('a paid campaign', test.sgwhy('paid', 'from_ad'), 'Paid campaign google/fall');
-- a past renter with a finished trip, signed in
select test.mk_booking('SG-0001', 'SG4', 'sg_rita', (now() - interval '40 days')::text, (now() - interval '37 days')::text, 'closed');
select test.login(test.id('sg_rita'));
select test.sgb('rita', jsonb_build_array(test.ev('page_view', 2)));
select test.logout();
select test.eq('a past renter', test.sgwhy('rita', 'known_renter'), '1 finished trip with us');
select test.eq('her name in the message', (select app.visitor_fill(r.message, l.data) from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind
  where l.session_id = test.sgsid('rita') and l.kind = 'known_renter'), 'Welcome back Sg! Want me to set up your next trip?');
-- a popular car: 5 people today
select test.sgb('pop' || i, jsonb_build_array(test.ev('page_view', 4))) from generate_series(1, 5) i;
select test.eq('a popular car', test.sgwhy('pop5', 'popular_car'), format('%s people looked at the %s today', (select viewers from vehicle_interest_daily where vehicle_id = test.sgcar(4) and day = app.local_date(now())), test.sgname(4)));
update visitor_signal_rules set t1 = 500 where code = 'popular_car';
select app.visitor_live_eval(test.sgsid('pop5'));
select test.eq('not below the number of people set', (select count(*) from visitor_live_signals where session_id = test.sgsid('pop5') and kind = 'popular_car' and active), 0::bigint);
update visitor_signal_rules set t1 = 5 where code = 'popular_car';
-- owners on their portal are not scored
select test.sgb('own', jsonb_build_array(test.ev('page_view', null, null, '/owner/vehicles'), test.ev('page_view', 1)));
select test.eq('an owner on their portal: no score, no signals', coalesce(test.sgscore('own')::text, 'none') || ' ' || (select audience from visitor_sessions where id = test.sgsid('own')) || ' ' || test.sgk('own'), 'none owner ');

-- ================================================================ 7. the score
-- the form (15) + the price (10) + a premium car (6) + a tap to call (20) + pickup tomorrow (12) = 63
select test.sgb('hot', jsonb_build_array(test.ev('page_view', 1), test.ev('search', 1, jsonb_build_object('pickup', (app.local_date(now()) + 1)::text, 'return', (app.local_date(now()) + 2)::text)),
  test.ev('quote_seen', 1, '{"days": "1", "total": "130", "avail": "1"}'), test.ev('contact_click', 1, '{"via": "call"}'),
  test.ev('page_view', null, null, '/book/sg-car-1'), test.ev('request_started', null, null, '/book/sg-car-1')));
select test.eq('the score is the sum of the points of its signals', test.sgscore('hot'), (select sum(r.weight)::integer from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind where l.session_id = test.sgsid('hot') and l.active));
select test.eq('the signals of a hot visit', (select count(*) from visitor_live_signals where session_id = test.sgsid('hot') and active and kind in ('form_reached', 'price_seen', 'premium_class', 'contact_tap', 'soon_pickup')), 5::bigint);
select test.ok('63 points or more', test.sgscore('hot') >= 63);
select test.eq('its three strongest reasons', (select string_agg(x ->> 'kind', ',') from visitor_sessions s, jsonb_array_elements(s.score_reasons) x where s.id = test.sgsid('hot')), 'contact_tap,form_reached,soon_pickup');
select test.eq('hot from 60: marked once', (select (hot_at is not null)::text || ' ' || app.visitor_band(score) from visitor_sessions where id = test.sgsid('hot')), 'true hot');
select test.eq('warm and cold bands', app.visitor_band(35) || ' ' || app.visitor_band(10), 'warm cold');
select test.eq('strength: strong, medium, weak by points', app.visitor_strength(20)::text || app.visitor_strength(10) || app.visitor_strength(3) || app.visitor_strength(0), '3210');
-- the 0060 signals count too: a viewing spree adds its points
update program_settings set visitor_spree_cars = 3;
select test.sgb('spree', jsonb_build_array(test.ev('page_view', 2), test.ev('page_view', 3), test.ev('page_view', 4)));
update program_settings set visitor_spree_cars = 6;
select test.eq('a 0060 signal adds its points', test.sgscore('spree') - coalesce((select sum(r.weight)::integer from visitor_live_signals l join visitor_signal_rules r on r.code = l.kind where l.session_id = test.sgsid('spree') and l.active), 0), 5);
select test.eq('capped at 100', (select least(100, sum(weight))::integer from visitor_signal_rules where weight > 0) >= 100 and test.sgscore('hot') <= 100, true);
-- an Admin changes a weight; the next look uses it
select app.live_action(test.id('sg_admin'), 'live_rules_save', '{"rules": [{"code": "contact_tap", "weight": 30}]}');
create temp table sg_before as select test.sgscore('hot') as v;
grant all on sg_before to public;
select app.visitor_live_eval(test.sgsid('hot'));
select test.eq('a weight changed by an Admin counts at once', test.sgscore('hot') - (select v from sg_before), 10);
select app.live_action(test.id('sg_admin'), 'live_rules_save', '{"rules": [{"code": "contact_tap", "weight": 20, "enabled": false}]}');
select test.sgb('tap2', jsonb_build_array(test.ev('contact_click', null, '{"via": "sms"}')));
select test.eq('a rule turned off raises nothing', test.sgk('tap2'), '');
select app.live_action(test.id('sg_admin'), 'live_rules_save', '{"rules": [{"code": "contact_tap", "enabled": true}]}');
select app.live_action(test.id('sg_admin'), 'live_rules_save', '{"rules": [{"code": "dates_repeat", "t1": 2}]}');
select test.sgb('dates2', '[]');
select app.visitor_live_eval(test.sgsid('dates2'));
select test.eq('a threshold changed by an Admin (2 searches)', test.sgwhy('dates2', 'dates_repeat'), 'Searched dates 2 times this visit');
select app.live_action(test.id('sg_admin'), 'live_rules_save', '{"rules": [{"code": "dates_repeat", "t1": 3}]}');

-- ================================================================ 8. the Live page
select test.eq('live: sorted by the score, hot first', (select x ->> 'id' from jsonb_array_elements(app.live_visitors(test.id('sg_cs')) -> 'now') with ordinality t(x, n) order by n limit 1), test.sgsid('hot')::text);
select test.eq('live: the row has the score, band, reasons and the suggested action with its message',
  (select format('%s %s %s %s', x ->> 'score' = test.sgscore('hot')::text, x ->> 'band', jsonb_array_length(x -> 'reasons'), x -> 'suggested' ->> 'kind')
     from jsonb_array_elements(app.live_visitors(test.id('sg_cs')) -> 'now') x where x ->> 'id' = test.sgsid('hot')::text), 't hot 3 contact_tap');
select test.eq('live: each signal has a label, why, strength, action and message',
  (select x -> 'signals' -> 0 ?& array['label', 'why', 'strength', 'action', 'message', 'grp'] from jsonb_array_elements(app.live_visitors(test.id('sg_cs')) -> 'now') x where x ->> 'id' = test.sgsid('hot')::text), true);
select test.eq('live: the day''s hot visitors', (select count(*) from jsonb_array_elements(app.live_visitors(test.id('sg_admin')) -> 'hot') x where x ->> 'id' = test.sgsid('hot')::text), 1::bigint);
select test.eq('live: others looking at the same car now', (select (x ->> 'others_on_car')::integer from jsonb_array_elements(app.live_visitors(test.id('sg_cs')) -> 'now') x where x ->> 'id' = test.sgsid('pop1')::text),
  (select count(*)::integer - 1 from visitor_sessions where current_vehicle_id = test.sgcar(4) and last_seen_at > now() - interval '3 minutes'));
select test.eq('live: the settings it needs (customer service may not send codes by default)',
  (select format('%s %s %s', x ->> 'hot', x -> 'discount' ->> 'can', x ->> 'is_admin') from (select app.live_visitors(test.id('sg_cs')) -> 'cfg' x) y), '60 false false');
select test.eq('menu: chats waiting and hot visitors now', (app.door(test.id('sg_cs'), '', 'va_read', 'chat_counts', '{}') ->> 'hot')::integer >= 1, true);
select test.eq('per car: prices shown and the car most compared', (select format('%s %s', x ->> 'quotes_30d', x -> 'compared' -> 0 ->> 'car')
  from (select app.vehicle_interest(test.id('sg_admin'), jsonb_build_object('vehicle_id', test.sgcar(2))) x) y), format('2 %s', test.sgname(3)));
select test.eq('most viewed: prices shown in 7 days', (select (x ->> 'quotes_7d')::integer from jsonb_array_elements(app.most_viewed_cars(7, 8)) x where x ->> 'vehicle_id' = test.sgcar(1)::text), 3);

-- ================================================================ 9. actions
select test.eq('invite: a chat with the message', app.door(test.id('sg_cs'), '', 'va_do', 'live_invite', jsonb_build_object('session_id', test.sgsid('hot'), 'kind', 'contact_tap', 'body', 'Hi, {staff} here. Easier to chat?')) ->> 'ok', 'true');
select test.eq('invite: logged on the visit', (select action || ':' || signal from visitor_actions where session_id = test.sgsid('hot') order by at desc limit 1), 'chat:contact_tap');
select test.eq('invite: the visitor reads it with the staff member''s first name', (select m.body from chat_messages m join chat_conversations c on c.id = m.conversation_id
  where c.session_id = test.sgsid('hot') and m.sender = 'staff' order by m.id desc limit 1), 'Hi, Sg here. Easier to chat?');
select test.throws('discount: customer service may not send codes by default', $$ select app.live_action(test.id('sg_cs'), 'live_discount', jsonb_build_object('session_id', test.sgsid('cheap'))) $$, 'Only Admins and Sales send discount codes');
create temp table sg_d as select app.door(test.id('sg_sales'), '', 'va_do', 'live_discount', jsonb_build_object('session_id', test.sgsid('cheap'), 'kind', 'price_sensitive')) as r;
grant all on sg_d to public;
select test.eq('discount: Sales sends a single-use code in the chat (10% for 3 days, capped at $75)',
  (select format('%s %s %s %s %s', p.percent_bps, p.max_uses, p.max_discount_cents, p.source, (p.valid_until::date - p.valid_from::date))
     from promo_codes p where p.code = (select r ->> 'code' from sg_d)), '1000 1 7500 live_visitors 3');
select test.eq('discount: the message carries the code', (select position((select r ->> 'code' from sg_d) in m.body) > 0 from chat_messages m join chat_conversations c on c.id = m.conversation_id
  where c.session_id = test.sgsid('cheap') and m.sender = 'staff' order by m.id desc limit 1), true);
select test.throws('discount: one a week per visitor', $$ select app.live_action(test.id('sg_sales'), 'live_discount', jsonb_build_object('session_id', test.sgsid('cheap'))) $$, 'already got a discount code');
update visitor_signal_config set discount_daily_cap = 1;
select test.throws('discount: the daily limit per person', $$ select app.live_action(test.id('sg_sales'), 'live_discount', jsonb_build_object('session_id', test.sgsid('left'))) $$, 'today''s limit of 1');
update visitor_signal_config set discount_daily_cap = 10, discount_cs = true;
select test.eq('discount: customer service once an Admin allows it', (app.live_action(test.id('sg_cs'), 'live_discount', jsonb_build_object('session_id', test.sgsid('left'))) ->> 'percent'), '10');
update visitor_signal_config set discount_cs = false;
create temp table sg_a as select app.live_action(test.id('sg_cs'), 'live_assign', jsonb_build_object('session_id', test.sgsid('long'), 'kind', 'long_rental')) as r;
grant all on sg_a to public;
select test.eq('assign: from customer service, to the Sales person on shift (a task in the Sales queue, theirs)',
  (select format('%s %s', r ->> 'to' = test.id('sg_sales')::text, (select queue || ' ' || (assigned_to = test.id('sg_sales'))::text from tasks where id = (r ->> 'task_id')::uuid)) from sg_a), 't sales true');
select test.eq('assign: the visit shows who has it', (select assigned_to from visitor_sessions where id = test.sgsid('long')), test.id('sg_sales'));
create temp table sg_a2 as select app.live_action(test.id('sg_admin'), 'live_assign', jsonb_build_object('session_id', test.sgsid('rita'), 'to', test.id('sg_sales'))) as r;
grant all on sg_a2 to public;
select test.eq('assign: a known renter''s task has the contact', (select detail like '%Contact:%' from tasks where id = (select (r ->> 'task_id')::uuid from sg_a2)), true);
select test.throws('assign: only to Sales or an Admin', $$ select app.live_action(test.id('sg_admin'), 'live_assign', jsonb_build_object('session_id', test.sgsid('long'), 'to', test.id('sg_fin'))) $$, 'Assign to Sales or an Admin');
create temp table sg_sim as select app.door(test.id('sg_cs'), '', 'va_read', 'live_similar', jsonb_build_object('session_id', test.sgsid('busy'))) as x;
grant all on sg_sim to public;
select test.eq('similar: up to 3 cars, each sharing a class with theirs, never their own',
  (select format('%s %s %s', jsonb_array_length(x -> 'cars') between 1 and 3,
     bool_and(app.vehicle_in_classes((c ->> 'vehicle_id')::uuid, array['sedan'])), bool_and((c ->> 'vehicle_id')::uuid <> test.sgcar(3)))
     from sg_sim, jsonb_array_elements(x -> 'cars') c group by x), 't t t');
select test.eq('similar: the message lists them with their address', (select position((x -> 'cars' -> 0 ->> 'url') in (x ->> 'message')) > 0 from sg_sim), true);

-- ================================================================ 10. settings and access
select test.throws('rules: only Admins change them', $$ select app.door(test.id('sg_sales'), '', 'va_do', 'live_rules_save', '{"rules": [{"code": "price_seen", "weight": 50}]}') $$, null);
select test.throws('settings: only Admins change them', $$ select app.live_action(test.id('sg_cs'), 'live_config_save', '{"hot_score": 90}') $$, null);
select test.eq('settings: an Admin changes the bands', app.door(test.id('sg_admin'), '', 'admin_do', 'live_config_save', '{"hot_score": 70, "warm_score": 35}') ->> 'ok', 'true');
select test.eq('settings: saved', (select hot_score || '/' || warm_score from visitor_signal_config), '70/35');
select test.throws('settings: warm must stay below hot', $$ select app.live_action(test.id('sg_admin'), 'live_config_save', '{"warm_score": 80}') $$, null);
update visitor_signal_config set hot_score = 60, warm_score = 30;
select test.eq('rules: every live staff member may read them; only an Admin can edit',
  (app.live_signal_rules(test.id('sg_cs')) ->> 'can_edit') || ' ' || (app.live_signal_rules(test.id('sg_admin')) ->> 'can_edit') || ' ' || jsonb_array_length(app.live_signal_rules(test.id('sg_cs')) -> 'rules'), 'false true 35');
select test.throws('Finance: no rules', $$ select app.live_signal_rules(test.id('sg_fin')) $$, 'Live visitors and Live chat are for Admins, customer service and Sales');
select test.throws('Finance: no actions', $$ select app.live_action(test.id('sg_fin'), 'live_invite', jsonb_build_object('session_id', test.sgsid('hot'))) $$, 'Live visitors and Live chat are for Admins, customer service and Sales');
select test.throws('Finance: no similar cars', $$ select app.door(test.id('sg_fin'), '', 'va_read', 'live_similar', jsonb_build_object('session_id', test.sgsid('busy'))) $$, null);
select test.eq('privileges: the browser roles execute none of the 0086 functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app'
     and p.proname in ('visitor_live_eval', 'live_action', 'live_signal_rules', 'live_similar', 'job_visitor_signals', 'visitor_signals_all', 'ops86')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.eq('rls: a browser session reads none of the new tables', (select count(*) from information_schema.role_table_grants
  where table_name in ('visitor_signal_rules', 'visitor_signal_config', 'visitor_live_signals', 'visitor_actions', 'vehicle_pairs_daily') and grantee in ('anon', 'authenticated')), 0::bigint);
select test.eq('the beacon is still open to the browser', has_function_privilege('anon', 'public.track_ingest(jsonb, jsonb)', 'execute'), true);
select test.eq('privacy policy: the new events are listed (where our text is in place)',
  (select count(*) from site_content_blocks where block_key = 'legal.privacy' and body like '%We do not store your network address for this.%' and body not like '%With the same consent we also note a few actions%'), 0::bigint);

-- ================================================================ 11. housekeeping
insert into visitor_actions (visitor_id, action, by_user, at) values (md5('sg-vid:old')::uuid, 'chat', test.id('sg_cs'), now() - interval '200 days');
select test.eq('housekeeping: actions follow the visits'' retention', app.job_visitor_signals_housekeeping(), 'actions 1');
select test.eq('job: visits active in the last hour only', app.job_visitor_signals(now() + interval '3 hours'), 'evaluated 0');
