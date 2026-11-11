-- 99: lead intent (1506). The rules read budget, car class, length, dates, urgency, delivery and coverage from what a
-- renter or lead said; the website behaviour and a booking request add to the score; hot, warm, cold or unknown; staff
-- read it (computed at once), a renter cannot; the AI's reading only fills gaps and only well-formed values; the live map
-- carries it. Fixtures start with "inx"; every address is example.test.
select test.suite('99 r35c lead intent');

select test.eq('budget a week, SUV, two weeks, a date, urgency, delivery, own insurance',
  app.intent_extract('Hi, I need an SUV ASAP for 2 weeks starting Nov 20, budget $600 a week, can you deliver to my house? I will use my own insurance.'),
  '{"budget": {"per": "week", "amount_cents": 60000}, "car_class": "suv", "duration_days": 14, "dates": "nov 20", "urgency": "high", "delivery": true, "coverage": "own_insurance"}'::jsonb);
select test.eq('an insurance claim, a month, tomorrow', app.intent_extract('My car was in an accident, the adjuster says a replacement for a month, from tomorrow') - 'car_class',
  '{"coverage": "insurer_claim", "duration_days": 30, "dates": "tomorrow", "urgency": "medium"}'::jsonb);
select test.eq('a Mercedes for the weekend at 120/day', app.intent_extract('looking for a mercedes this weekend, around $120/day'),
  '{"budget": {"per": "day", "amount_cents": 12000}, "car_class": "luxury", "duration_days": 2, "dates": "this weekend", "urgency": "medium"}'::jsonb);
select test.eq('nothing to read', app.intent_extract('ok thanks'), '{}'::jsonb);

select test.mk_user('inx_admin', 'admin');
select test.mk_user('inx_cs', 'va', 'cs');
select test.mk_renter('inx_rita');
select test.mk_renter('inx_quiet');
insert into phone_threads (id, number, renter_id) values (test.id('thread:inx'), '+16475550911', test.id('renter:inx_rita'));
insert into phone_activity (thread_id, kind, direction, started_at, body, renter_id)
values (test.id('thread:inx'), 'text', 'in', now() - interval '1 hour', 'Need an SUV today for 2 weeks, $600 a week, can you deliver?', test.id('renter:inx_rita'));
insert into visitor_sessions (id, visitor_id, renter_id, page_views, cars_viewed, started_at, last_seen_at, score)
select gen_random_uuid(), gen_random_uuid(), test.id('renter:inx_rita'), 12, array[gen_random_uuid(), gen_random_uuid()], now() - interval '2 hours', now() - interval '1 hour', 70
;

create temp table inx_r as select app.door(test.id('inx_cs'), 'aal2', 'ops_read', 'intent', jsonb_build_object('renter', test.id('renter:inx_rita'))) as v;
select test.eq('hot: what she said and what she did on the site', (select v ->> 'label' from inx_r), 'hot');
select test.eq('the signals are on the renter', (select format('%s|%s|%s|%s', v #>> '{signals,car_class}', v #>> '{signals,duration_days}', v #>> '{signals,urgency}', v #>> '{signals,delivery}') from inx_r), 'suv|14|high|true');
select test.ok('the reasons say why', (select jsonb_array_length(v -> 'reasons') >= 4 from inx_r));
select test.eq('nothing said or done: unknown', app.door(test.id('inx_cs'), 'aal2', 'ops_read', 'intent', jsonb_build_object('renter', test.id('renter:inx_quiet'))) ->> 'label', 'unknown');
select test.throws('a renter cannot read it', format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('inx_rita'), 'aal2', 'ops_read', 'intent', jsonb_build_object('renter', test.id('renter:inx_rita'))), 'Staff only');

-- the AI's reading: only gaps, only well-formed values
select public.server_intent_ai_result(jsonb_build_object('kind', 'renter', 'id', test.id('renter:inx_rita'), 'sha', 'x', 'neurons', 50,
  'signals', jsonb_build_object('car_class', 'spaceship', 'coverage', 'card', 'duration_days', 3, 'dates', 'Nov 21')));
select test.eq('the AI fills coverage (empty), not the rules'' values; a bad class is dropped',
  (select format('%s|%s|%s', signals ->> 'coverage', signals ->> 'duration_days', signals ->> 'car_class') from intent_scores where subject_kind = 'renter' and subject_id = test.id('renter:inx_rita')), 'card|14|suv');
select test.ok('the AI''s neurons count in the day''s budget', exists (select 1 from provider_calls where purpose = 'intent_enrich' and units = 50));
update program_settings set intent_ai_enabled = false;
select test.eq('switched off: nothing is due for the AI', public.server_intent_ai_due(1) ->> 'ok', 'false');
update program_settings set intent_ai_enabled = true;

select test.ok('the job refreshes whoever was active', app.job_intent() like '%intents');
