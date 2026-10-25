-- 86: long rentals, part 2 (migration 0148): drafts of a rental or an offer saved as typed, the car held while one is
-- entered, Quick start at pickup (a task to finish it, the readings kept), and the draft closed when the rental is added.
-- Fixtures start with "dr".
select test.suite('86 long rentals 2');

select test.mk_user('dr_admin', 'admin');
select test.mk_user('dr_cs', 'va', 'cs');
select test.mk_renter('dr_renter');

create table test.dr (k text primary key, v jsonb);
grant select on test.dr to authenticated, service_role;
create function test.drv(p text) returns jsonb language sql stable as $$ select v from test.dr where k = p $$;
insert into test.dr select 'car', app.vehicle_add(test.id('dr_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXDR0000000001',
  'plate', 'DRC001', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.drcar() returns uuid language sql stable as $$ select (test.drv('car') ->> 'vehicle_id')::uuid $$;

-- ================================================================ 1. a draft: nothing required
insert into test.dr select 'd0', app.door(test.id('dr_cs'), 'aal2', 'ops_do', 'draft_save', jsonb_build_object('kind', 'rental', 'data', '{}'::jsonb));
select test.ok('an empty draft saves', (test.drv('d0') ->> 'id') is not null);
select test.ok('an empty draft lists what is missing', (test.drv('d0') -> 'missing') ? 'the car');
select test.ok('an empty draft lists the renter missing', (test.drv('d0') -> 'missing') ? 'the renter');
select test.eq('an empty draft holds nothing', (test.drv('d0') ->> 'held')::boolean, false);
select test.throws('a renter cannot save a draft', $$ select app.draft_save(test.id('dr_renter'), '{"data":{}}'::jsonb) $$, '%Staff%');
select test.throws('a draft is a rental or an offer', $$ select app.draft_save(test.id('dr_cs'), '{"kind":"lease","data":{}}'::jsonb) $$, '%rental or an offer%');

-- typed more: the car and the renter; held
insert into test.dr select 'd1', app.door(test.id('dr_cs'), 'aal2', 'ops_do', 'draft_save', jsonb_build_object('id', test.drv('d0') ->> 'id', 'kind', 'rental', 'hold', true,
  'title', 'Dana Draft, Kia K5', 'data', jsonb_build_object('f', jsonb_build_object('vehicle_id', test.drcar(), 'full_name', 'Dana Draft', 'pickup_at', '2026-11-01T10:00', 'return_at', '2026-11-05T10:00'), 'paid_by', 'card')));
select test.eq('the same draft is updated', test.drv('d1') ->> 'id', test.drv('d0') ->> 'id');
select test.eq('the car is held', (test.drv('d1') ->> 'held')::boolean, true);
select test.ok('the hold is about two hours', (test.drv('d1') ->> 'hold_until')::timestamptz between now() + interval '119 minutes' and now() + interval '121 minutes');
select test.eq('the hold is one calendar block on the car', (select count(*) from vehicle_calendar_blocks k where k.vehicle_id = test.drcar() and k.removed_at is null), 1::bigint);
select test.ok('missing: the car is no longer missing', not ((test.drv('d1') -> 'missing') ? 'the car'));
select test.ok('missing: the email still is', (test.drv('d1') -> 'missing') ? 'the renter''s email');
-- saved again: still one block
select app.draft_save(test.id('dr_cs'), jsonb_build_object('id', test.drv('d0') ->> 'id', 'hold', true, 'data', jsonb_build_object('f', jsonb_build_object('vehicle_id', test.drcar()))));
select test.eq('saved again: still one block', (select count(*) from vehicle_calendar_blocks k where k.vehicle_id = test.drcar() and k.removed_at is null), 1::bigint);
-- untick Hold the car: the block goes
select app.draft_save(test.id('dr_cs'), jsonb_build_object('id', test.drv('d0') ->> 'id', 'hold', false, 'data', jsonb_build_object('f', jsonb_build_object('vehicle_id', test.drcar()))));
select test.eq('unticked: the block is removed', (select count(*) from vehicle_calendar_blocks k where k.vehicle_id = test.drcar() and k.removed_at is null), 0::bigint);

-- the list: everyone's, and one's own
select test.eq('the list shows the draft to its author', (select count(*) from jsonb_array_elements(app.door(test.id('dr_cs'), 'aal2', 'ops_read', 'drafts', '{"kind":"rental"}'::jsonb)) e where e ->> 'id' = test.drv('d0') ->> 'id'), 1::bigint);
select test.eq('the list shows it to the admin too', (select count(*) from jsonb_array_elements(app.door(test.id('dr_admin'), 'aal2', 'ops_read', 'drafts', '{}'::jsonb)) e where e ->> 'id' = test.drv('d0') ->> 'id'), 1::bigint);
select test.eq('mine only: not the admin''s list', (select count(*) from jsonb_array_elements(app.door(test.id('dr_admin'), 'aal2', 'ops_read', 'drafts', '{"mine":true}'::jsonb)) e where e ->> 'id' = test.drv('d0') ->> 'id'), 0::bigint);
select test.eq('the list says who', (select e ->> 'mine' from jsonb_array_elements(app.door(test.id('dr_cs'), 'aal2', 'ops_read', 'drafts', '{}'::jsonb)) e where e ->> 'id' = test.drv('d0') ->> 'id'), 'true');
select test.eq('resume: the draft comes back as typed', app.door(test.id('dr_admin'), 'aal2', 'ops_read', 'draft_get', jsonb_build_object('id', test.drv('d0') ->> 'id')) #>> '{data,f,vehicle_id}', test.drcar()::text);
select test.eq('a renter sees no drafts', jsonb_array_length(app.drafts_list(test.id('dr_renter'), '{}'::jsonb)), 0);

-- discarded: gone from the list; saving it again is refused
select app.door(test.id('dr_cs'), 'aal2', 'ops_do', 'draft_close', jsonb_build_object('id', test.drv('d0') ->> 'id', 'status', 'discarded'));
select test.eq('discarded: off the list', (select count(*) from jsonb_array_elements(app.drafts_list(test.id('dr_cs'), '{}'::jsonb)) e where e ->> 'id' = test.drv('d0') ->> 'id'), 0::bigint);
select test.throws('discarded: saving it again is refused', format($$ select app.draft_save(test.id('dr_cs'), '{"id":"%s","data":{}}'::jsonb) $$, test.drv('d0') ->> 'id'), '%discarded%');

-- ================================================================ 2. Quick start at pickup
insert into test.dr select 'q', app.draft_save(test.id('dr_cs'), jsonb_build_object('kind', 'rental', 'quick', true, 'hold', true, 'title', 'Quinn Quick',
  'data', jsonb_build_object('f', jsonb_build_object('vehicle_id', test.drcar(), 'full_name', 'Quinn Quick', 'mobile', '4165550186', 'odometer_out', '12345', 'fuel_out', '75'))));
select test.eq('quick start: the car is held', (test.drv('q') ->> 'held')::boolean, true);
select test.eq('quick start: a task to finish it', (select count(*) from tasks t where t.dedupe_key = 'finish_rental_draft:' || (test.drv('q') ->> 'id') and t.status = 'open'), 1::bigint);
select test.eq('quick start: the task is high priority', (select t.priority::text from tasks t where t.dedupe_key = 'finish_rental_draft:' || (test.drv('q') ->> 'id')), 'high');
select app.draft_save(test.id('dr_cs'), jsonb_build_object('id', test.drv('q') ->> 'id', 'hold', true, 'data', jsonb_build_object('f', jsonb_build_object('vehicle_id', test.drcar(), 'full_name', 'Quinn Quick'))));
select test.eq('saved again: still one task', (select count(*) from tasks t where t.dedupe_key = 'finish_rental_draft:' || (test.drv('q') ->> 'id')), 1::bigint);
select test.eq('saved again: still quick', (select quick from rental_drafts where id = (test.drv('q') ->> 'id')::uuid), true);

-- finished: the rental is added with the readings; the draft, its hold and its task are closed
insert into test.dr select 'qb', app.door(test.id('dr_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object(
  'vehicle_id', test.drcar(), 'pickup_at', date_trunc('hour', now()) - interval '1 hour', 'return_at', date_trunc('hour', now()) + interval '3 days',
  'coverage_option', 3, 'source', 'walk_in', 'sales_choice', 'for_carmacars', 'agreement', 'paper',
  'renter', jsonb_build_object('full_name', 'Quinn Quick', 'email', 'quinn.quick@example.test', 'mobile', '4165550186', 'date_of_birth', '1990-01-01', 'licence_number', 'Q1234-12345-12345'),
  'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'received_on', app.today()),
  'deposit', jsonb_build_object('method', 'cash'),
  'draft_id', test.drv('q') ->> 'id', 'odometer_out_km', 12345, 'fuel_out_pct', 75));
select test.ok('finished: a booking', (test.drv('qb') ->> 'booking_id') is not null);
select test.eq('finished: the odometer at pickup', (select odometer_out_km from bookings where id = (test.drv('qb') ->> 'booking_id')::uuid), 12345);
select test.eq('finished: the fuel at pickup', (select fuel_out_pct::integer from bookings where id = (test.drv('qb') ->> 'booking_id')::uuid), 75);
select test.eq('finished: the draft is done', (select status from rental_drafts where id = (test.drv('q') ->> 'id')::uuid), 'done');
select test.eq('finished: the draft knows its booking', (select booking_id::text from rental_drafts where id = (test.drv('q') ->> 'id')::uuid), test.drv('qb') ->> 'booking_id');
select test.eq('finished: the hold is removed', (select count(*) from vehicle_calendar_blocks k join rental_drafts d on d.hold_block_id = k.id where d.id = (test.drv('q') ->> 'id')::uuid and k.removed_at is null), 0::bigint);
select test.eq('finished: the task is done', (select status::text from tasks t where t.dedupe_key = 'finish_rental_draft:' || (test.drv('q') ->> 'id')), 'done');

-- offers draft too
select test.eq('an offer draft', app.draft_save(test.id('dr_cs'), '{"kind":"offer","data":{"renter_id":"x"}}'::jsonb) ->> 'kind', 'offer');
select test.ok('an offer draft does not ask how it is paid', not ((select e -> 'missing' from jsonb_array_elements(app.drafts_list(test.id('dr_cs'), '{"kind":"offer"}'::jsonb)) e limit 1) ? 'how it is paid'));

-- ================================================================ 3. a long rental's periods, each with its agreement
insert into test.dr select 'car2', app.vehicle_add(test.id('dr_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXDR0000000002',
  'plate', 'DRC002', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
-- picked up 28 days ago, 70 days in all: three periods (30, 30, 10)
insert into test.dr select 'long', app.door(test.id('dr_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object(
  'vehicle_id', (test.drv('car2') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) - interval '28 days', 'return_at', date_trunc('hour', now()) + interval '42 days',
  'coverage_option', 3, 'source', 'walk_in', 'sales_choice', 'for_carmacars', 'agreement', 'send',
  'renter', jsonb_build_object('full_name', 'Lee Period', 'email', 'lee.period@example.test', 'mobile', '4165550187', 'date_of_birth', '1985-01-01', 'licence_number', 'P1234-12345-12345'),
  'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'received_on', app.today()),
  'deposit', jsonb_build_object('method', 'cash')));
create function test.drlong() returns uuid language sql stable as $$ select (test.drv('long') ->> 'booking_id')::uuid $$;
select test.eq('three periods', (select count(*) from booking_periods where booking_id = test.drlong()), 3::bigint);
select test.eq('the first is covered by the booking''s agreement', (select status from booking_periods where booking_id = test.drlong() and seq = 1), 'issued');
select test.eq('the next is upcoming', (select status from booking_periods where booking_id = test.drlong() and seq = 2), 'upcoming');
select test.eq('the periods add up to what is due', (select sum(amount_cents) from booking_periods where booking_id = test.drlong()), (select renter_due_at_booking_cents from bookings where id = test.drlong()));
select test.eq('the last period is the days left', (select days from booking_periods where booking_id = test.drlong() and seq = 3), 10);
select test.eq('staff see the periods', jsonb_array_length(app.door(test.id('dr_cs'), 'aal2', 'ops_read', 'booking_periods', jsonb_build_object('booking', test.drlong()))), 3);

-- the first agreement, signed (as the site makes it); the period starts in two days: due (three days ahead)
select public.renter_open_agreement(test.drlong(), (select r.user_id from renters r join bookings b on b.renter_id = r.id where b.id = test.drlong()), 'v-test', repeat('a', 64), 'bookings/test/p1.pdf');
update rental_agreements set status = 'completed', renter_signed_at = now(), completed_at = now() where booking_id = test.drlong() and status = 'open';
select test.ok('period 2 is due', exists (select 1 from jsonb_array_elements(public.server_periods_due(50)) x where x ->> 'booking_id' = test.drlong()::text and (x ->> 'seq')::integer = 2));
select test.ok('period 3 waits for period 2', not exists (select 1 from jsonb_array_elements(public.server_periods_due(50)) x where x ->> 'booking_id' = test.drlong()::text and (x ->> 'seq')::integer = 3));
select test.ok('the jobs flag says there is work', (app.server_jobs_due() ->> 'agreements')::boolean);

-- the site: begin, open as the renter, done
select public.server_period_begin(test.drlong(), 2);
select test.eq('the first period''s agreement is kept as superseded', (select count(*) from rental_agreements where booking_id = test.drlong() and status = 'superseded'), 1::bigint);
select test.ok('the number says the period', (select agreement_number from bookings where id = test.drlong()) like '%-P2');
select test.ok('the agreement facts say the period', (public.server_agreement_facts(test.drlong(), test.id('dr_admin')) #>> '{period,seq}') = '2');
select test.eq('the facts say of how many', (public.server_agreement_facts(test.drlong(), test.id('dr_admin')) #>> '{period,of}'), '3');
select test.lives('the next agreement opens for a booking on its way', format($$ select public.renter_open_agreement(%L, (select r.user_id from renters r join bookings b on b.renter_id = r.id where b.id = %L), 'v-test', %L, 'bookings/test/p2.pdf') $$,
  test.drlong(), test.drlong(), repeat('b', 64)));
select public.server_period_done(test.drlong(), 2, true);
select test.eq('period 2 is issued', (select status from booking_periods where booking_id = test.drlong() and seq = 2), 'issued');
select test.eq('its agreement is open for the renter', (select a.status from booking_periods bp join rental_agreements a on a.id = bp.agreement_id where bp.booking_id = test.drlong() and bp.seq = 2), 'open');
select test.eq('the agreement knows its period', (select a.period_seq from booking_periods bp join rental_agreements a on a.id = bp.agreement_id where bp.booking_id = test.drlong() and bp.seq = 2), 2);
select test.ok('the renter is asked to sign it', exists (select 1 from agreement_auto_runs x where x.booking_id = test.drlong() and x.source = 'period' and x.ok));
select test.ok('period 2 is no longer due', not exists (select 1 from jsonb_array_elements(public.server_periods_due(50)) x where x ->> 'booking_id' = test.drlong()::text and (x ->> 'seq')::integer = 2));
select test.ok('the booking signs like one added by staff', (select app.booking_added_live(b) from bookings b where b.id = test.drlong()));

-- staff send the next one now; three misses make a task
select test.eq('send now: period 3', (app.door(test.id('dr_cs'), 'aal2', 'ops_do', 'period_send_now', jsonb_build_object('booking', test.drlong())) ->> 'seq'), '3');
select test.ok('period 3 is due now', exists (select 1 from jsonb_array_elements(public.server_periods_due(50)) x where x ->> 'booking_id' = test.drlong()::text and (x ->> 'seq')::integer = 3));
select public.server_period_done(test.drlong(), 3, false, 'render failed'), public.server_period_done(test.drlong(), 3, false, 'render failed'), public.server_period_done(test.drlong(), 3, false, 'render failed');
select test.ok('three misses: not due any more', not exists (select 1 from jsonb_array_elements(public.server_periods_due(50)) x where x ->> 'booking_id' = test.drlong()::text and (x ->> 'seq')::integer = 3));
select test.ok('three misses: a task for staff', exists (select 1 from tasks t where t.dedupe_key like 'period_agreement_failed:%' and t.booking_id = test.drlong()));

-- shortened to fit one period: the periods not sent go
update bookings set return_at = pickup_at + interval '40 days', billable_days = 40, km_allowance_total = km_allowance_per_day * 40 where id = test.drlong();
select test.eq('shortened: the period sent stays, the ones not sent go', (select string_agg(seq || ':' || status, ',' order by seq) from booking_periods where booking_id = test.drlong()), '1:issued,2:issued');
select test.eq('a short rental has no periods', (select count(*) from booking_periods bp join bookings b on b.id = bp.booking_id where b.return_at - b.pickup_at < interval '20 days'), 0::bigint);

-- ================================================================ 4. an insurance replacement added by hand (sim item 3)
insert into test.dr select 'car3', app.vehicle_add(test.id('dr_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXDR0000000003',
  'plate', 'DRC003', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.drins(p jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', (test.drv('car3') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + interval '1 day', 'return_at', date_trunc('hour', now()) + interval '11 days',
    'coverage_option', 3, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper',
    'renter', jsonb_build_object('full_name', 'Ira Insured', 'email', 'ira.insured.' || md5(p::text) || '@example.test', 'mobile', '4165550188', 'date_of_birth', '1980-01-01', 'licence_number', 'I1234-12345-12345'),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
select test.eq('the insurers come with the check', jsonb_typeof(app.door(test.id('dr_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.drins('{}'::jsonb)) -> 'insurers'), 'array');
select test.throws('paid by the insurer with none chosen: a sentence, not the constraint', $$ select app.door(test.id('dr_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.drins('{"insurance": {"claim_number": "C-1"}}'::jsonb)) $$, '%choose the insurer%');
insert into test.dr select 'ins', app.door(test.id('dr_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.drins(jsonb_build_object('insurance', jsonb_build_object(
  'insurer_name', 'Dr Test Mutual', 'claim_number', 'CLM-77', 'adjuster_name', 'Ada Adjuster', 'adjuster_email', 'ADA@example.test', 'adjuster_phone', '4165550199',
  'authorized_days', 10, 'authorized_daily_rate_cents', 6000, 'authorized_until', (current_date + 11)::text, 'dates_provisional', true, 'pays', 'insurer'))));
create function test.drinsb() returns bookings language sql stable security definer as $$ select * from bookings where id = (test.drv('ins') ->> 'booking_id')::uuid $$;
select test.eq('billed to the insurer', (test.drinsb()).bill_to, 'insurer');
select test.eq('the insurer typed is added to the list', (select name from insurers where id = (test.drinsb()).insurer_id), 'Dr Test Mutual');
select test.eq('the claim', (test.drinsb()).insurer_claim_number, 'CLM-77');
select test.eq('the adjuster''s email', (test.drinsb()).insurer_adjuster_email, 'ada@example.test');
select test.eq('the days authorized', (test.drinsb()).insurer_authorized_days, 10);
select test.eq('provisional', (test.drinsb()).dates_provisional, true);
select test.ok('the insurer pays its share', (test.drinsb()).insurer_share_cents > 0);
select test.ok('the renter owes only the rest', (test.drinsb()).renter_due_at_booking_cents < (test.drinsb()).total_due_at_booking_cents);

-- ================================================================ 5. no false tasks; a price typed by hand kept for new dates (sim items 11, 13)
select test.eq('a rental added underway with its deposit taken keeps no "Deposit not taken"',
  (select count(*) from tasks t where t.booking_id = (test.drv('qb') ->> 'booking_id')::uuid and t.task_type = 'live_rental_deposit' and t.status = 'open'), 0::bigint);
select test.eq('nor the long one (cash deposit)', (select count(*) from tasks t where t.booking_id = test.drlong() and t.task_type = 'live_rental_deposit' and t.status = 'open'), 0::bigint);
select test.ok('the offer screen''s cars carry their type', (select bool_and(c ? 'body_type') from jsonb_array_elements(app.staff_offer_form(test.id('dr_admin'), '{}'::jsonb) -> 'cars') c));
update bookings set custom_price_at = now() where id = (test.drinsb()).id;
select test.eq('new dates keep the typed price in proportion', (app.booking_price_spec((test.drinsb()).id, jsonb_build_object('pickup_at', (test.drinsb()).pickup_at, 'return_at', (test.drinsb()).pickup_at + interval '5 days')) ->> 'rental_charge_cents')::bigint,
  round((test.drinsb()).rental_charge_cents::numeric * 5 / (test.drinsb()).billable_days)::bigint);
select test.ok('recompute still goes back to the rate sheet', (app.booking_price_spec((test.drinsb()).id, jsonb_build_object('pickup_at', (test.drinsb()).pickup_at, 'return_at', (test.drinsb()).pickup_at + interval '5 days', 'recompute_rental', true)) ->> 'rental_charge_cents') is null);

-- ================================================================ 6. two records of one renter, merged
insert into renters (legal_name, email, mobile, date_of_birth) values ('Mia Merge', 'mia.merge@example.test', '416-555-0190', '1991-02-03');
insert into renters (legal_name, email, mobile) values ('Mia Merge', null, '(416) 555 0190');
create function test.mia(p_n integer) returns uuid language sql stable security definer as $$ select id from renters where legal_name = 'Mia Merge' order by email nulls last, created_at limit 1 offset p_n - 1 $$;
update bookings set renter_id = test.mia(2) where id = (test.drinsb()).id;
select test.eq('the duplicate is found by the phone', (select x ->> 'why' from jsonb_array_elements(app.door(test.id('dr_cs'), 'aal2', 'ops_read', 'renter_duplicates', jsonb_build_object('renter', test.mia(1)))) x where (x ->> 'id')::uuid = test.mia(2)), 'same phone');
select test.throws('a renter cannot merge', format($$ select app.renter_merge(test.id('dr_renter'), '{"keep":"%s","merge":"%s"}'::jsonb) $$, test.mia(1), test.mia(2)), '%merge renters%');
insert into test.dr select 'merge', app.door(test.id('dr_cs'), 'aal2', 'ops_do', 'renter_merge', jsonb_build_object('keep', test.mia(1), 'merge', test.mia(2), 'reason', 'Phone booking, then the website'));
select test.eq('the booking moved to the kept record', (test.drinsb()).renter_id, test.mia(1));
select test.eq('the other record points at the kept one', (select merged_into from renters where id = test.mia(2)), test.mia(1));
select test.eq('and is blocked', (select is_blocked from renters where id = test.mia(2)), true);
select test.eq('the merge is in the change history', (select count(*) from renter_edits where renter_id = test.mia(1) and after ? 'merged_from'), 1::bigint);
select test.throws('merged twice: refused', format($$ select app.renter_merge(test.id('dr_cs'), '{"keep":"%s","merge":"%s"}'::jsonb) $$, test.mia(1), test.mia(2)), '%already merged%');
