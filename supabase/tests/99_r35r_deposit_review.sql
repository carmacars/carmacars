-- 99: release 35 part RR (migration 1010): the two-step deposit review of a returned booking (Fleet signs each item, then
-- Finance; the ticket places and the toll check; the deposit stays held until both signed, unless an Admin gives the reason),
-- the Finance sweep, the Finance countdowns with their alerts and digest lines, Finance staff opting in to Sales, and the plan
-- policy number on the accident card. Uses the helpers of 97 (test.dg_hold, test.dg_settle, test.dgl). Fixtures start with
-- "rr" and "RR-".
select test.suite('99 r35r deposit review');
alter table program_settings alter column deposit_review_required set default true;   -- off for the older suites (helpers.sql)
update program_settings set deposit_review_required = true;

select test.mk_user('rr_admin', 'admin');
select test.mk_user('rr_fleet', 'va', 'fleet');
select test.mk_user('rr_fin', 'va', 'finance');
select test.mk_user('rr_fin2', 'va', 'finance');
select test.mk_user('rr_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('rr_fin'), test.id('rr_fin2'));
select test.mk_owner('rr_o');
select test.mk_vehicle('RRA', 'rr_o'); select test.mk_vehicle('RRB', 'rr_o'); select test.mk_vehicle('RRC', 'rr_o');
select test.mk_vehicle('RRD', 'rr_o'); select test.mk_vehicle('RRE', 'rr_o');
select test.mk_renter('rr_r');

create function test.rr_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function test.rr_read(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;
create function test.rr_tasks(p text, p_type text) returns text language sql stable as $$
  select count(*) || ':' || coalesce(min(queue), '-') || ':' || coalesce(min(priority), '-') from tasks where booking_id = test.dgb(p) and task_type = p_type $$;
create function test.rr_sign(p_user text, p_booking text, p_side text, p_item text, p_result text default 'ok', p_extra jsonb default '{}') returns jsonb language sql as $$
  select test.rr_do(p_user, 'deposit_review_sign', jsonb_build_object('booking', p_booking, 'side', p_side, 'item', p_item, 'result', p_result) || p_extra) $$;
grant execute on all functions in schema test to authenticated, anon, service_role;

-- ================================================================ 1. settings
select test.eq('settings: on, Monday Wednesday Friday, the toll link and the ticket places with their links',
  (select deposit_review_required || '/' || deposit_review_sweep_days || '/' || (deposit_review_toll_url like 'https://%') || '/' || jsonb_array_length(deposit_review_ticket_places)
          || '/' || (select bool_and(x ->> 'url' like 'https://%' and x ? 'key' and x ? 'name') from jsonb_array_elements(deposit_review_ticket_places) x) from program_settings limit 1),
  'true/mon,wed,fri/true/17/true');
select test.ok('settings: the places include Toronto, the Durham towns and the provincial cameras',
  (select count(*) = 6 from jsonb_array_elements((select deposit_review_ticket_places from program_settings limit 1)) x
    where x ->> 'key' in ('toronto', 'pickering', 'ajax', 'whitby', 'oshawa', 'ontario_cameras')));
select test.throws('settings: the sweep days are checked', $$update program_settings set deposit_review_sweep_days = 'monday'$$, 'check');

-- ================================================================ 2. a returned booking gets its review
select test.mk_booking('RR-1', 'RRA', 'rr_r', test.dgl(-4), test.dgl(-2), 'returned');
select test.dg_hold('RR-1', now() + interval '30 hours');
select test.dg_statement('RR-1');
select test.eq('review: made at the return with the seven items and the places', (select count(*) from deposit_review_items where booking_id = test.dgb('RR-1')) || '/' ||
  (select jsonb_array_length(places) || ':' || coalesce(plate, '-') from deposit_reviews where booking_id = test.dgb('RR-1')),
  '7/17:' || (select coalesce(plate, '-') from vehicles where id = test.id('vehicle:RRA')));
select test.eq('review: Fleet gets the To do', test.rr_tasks('RR-1', 'deposit_review_fleet'), '1:fleet:high');
select test.mk_booking('RR-O', 'RRB', 'rr_r', test.dgl(-6), test.dgl(-5), 'returned', null, 'owner');
select test.ok('review: an Owner Booking gets none', not exists (select 1 from deposit_reviews where booking_id = test.dgb('RR-O')));
select test.eq('review: the deposit is blocked by the review, in plain words',
  (select x ->> 'label' from jsonb_array_elements(app.deposit_blockers(test.dgb('RR-1'))) x where x ->> 'kind' = 'review'),
  'The deposit review is not finished: Fleet checked 0 of 7 items');
select test.throws('review: Finance cannot release any of the deposit before the review', $$select test.dg_settle('rr_fin', 'RR-1', '{"hold_back_cents": 0, "release_now": true}')$$, 'whole deposit stays held');

-- the view: who opens it
select test.throws('view: customer service does not open it', format($$select test.rr_read('rr_cs', 'deposit_review', jsonb_build_object('booking', %L))$$, 'RR-1'), 'Fleet, Finance or an Admin');
select test.eq('view: Fleet opens it: the items in order, the facts, the places with links, the toll link, who may sign',
  (select (v -> 'items' -> 0 ->> 'item') || ':' || (v -> 'items' -> 6 ->> 'item') || ':' || (v -> 'items' -> 0 -> 'facts' ? 'suggest') || ':' || jsonb_array_length(v -> 'places') || ':'
          || ((v ->> 'toll_url') like 'https://%') || ':' || (v #>> '{may,fleet}') || ':' || (v #>> '{may,finance}')
     from (select test.rr_read('rr_fleet', 'deposit_review', jsonb_build_object('booking', 'RR-1')) v) x),
  'fuel:tolls:true:17:true:true:false');

-- ================================================================ 3. Fleet first
select test.throws('fleet: Finance cannot check an item before Fleet', $$select test.rr_sign('rr_fin', 'RR-1', 'finance', 'fuel')$$, 'Fleet checks this item first');
select test.throws('fleet: customer service does not sign', $$select test.rr_sign('rr_cs', 'RR-1', 'fleet', 'fuel')$$, 'Fleet or an Admin');
select test.throws('fleet: an issue says what it is', $$select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'fuel', 'issue')$$, 'Say what the issue is');
select test.throws('fleet: photo numbers must be on the return report', $$select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'damage', 'issue', '{"note": "Scratch rear bumper", "photos": "4"}')$$, 'not on the return report');
insert into condition_reports (vehicle_id, booking_id, kind, performed_by_role) values (test.id('vehicle:RRA'), test.dgb('RR-1'), 'return', 'staff');
insert into condition_report_photos (condition_report_id, seq, shot, storage_path)
select id, 4, 'rear', 'bookings/rr/return/4-rear.jpg' from condition_reports where booking_id = test.dgb('RR-1') and kind = 'return';
select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'fuel', 'issue', '{"note": "Quarter tank short", "amount_cents": 2500}');
select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'damage', 'issue', '{"note": "Scratch rear bumper", "photos": "4", "amount_cents": 30000}');
select test.rr_sign('rr_fleet', 'RR-1', 'fleet', x) from unnest(array['km', 'late', 'cleaning', 'tickets']) x;
select test.eq('fleet: six of seven, still Fleet''s stage', (select (s ->> 'fleet_signed') || ':' || (s ->> 'stage') from (select app.drr_state(test.dgb('RR-1')) s) x), '6:fleet');
select test.eq('fleet: the photo kept with the issue', (select fleet_photos::text || ':' || fleet_amount_cents from deposit_review_items where booking_id = test.dgb('RR-1') and item = 'damage'), '{4}:30000');
create temp table rr_s as select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'tolls') s;
select test.eq('fleet: all seven signed: done, Finance''s stage', (select (s ->> 'fleet_signed') || ':' || (s ->> 'stage') from rr_s), '7:finance');
select test.eq('fleet: the Fleet To do is done, Finance gets one', (select status from tasks where booking_id = test.dgb('RR-1') and task_type = 'deposit_review_fleet') || '/' || test.rr_tasks('RR-1', 'deposit_review_finance'),
  'done/1:finance:high');
select test.ok('fleet: in the booking history, with the issues', exists (select 1 from booking_events where booking_id = test.dgb('RR-1') and note like 'Fleet finished the deposit review: Fuel (Quarter tank short); Damage (Scratch rear bumper)%'));
select test.eq('fleet: the blocker now names Finance''s part',
  (select x ->> 'label' from jsonb_array_elements(app.deposit_blockers(test.dgb('RR-1'))) x where x ->> 'kind' = 'review'),
  'The deposit review is not finished: Finance checked 0 of 7 items and 0 of 17 ticket places');

-- ================================================================ 4. then Finance
select test.throws('finance: Fleet does not sign Finance''s check', $$select test.rr_sign('rr_fleet', 'RR-1', 'finance', 'fuel')$$, 'Finance or an Admin');
select test.rr_sign('rr_fin', 'RR-1', 'finance', 'fuel', 'issue', '{"note": "Agreed, two eighths", "amount_cents": 2000}');
select test.throws('finance: Fleet cannot change an item Finance checked', $$select test.rr_sign('rr_fleet', 'RR-1', 'fleet', 'fuel')$$, 'Finance already checked');
select test.throws('finance: tickets wait for every place', $$select test.rr_sign('rr_fin', 'RR-1', 'finance', 'tickets')$$, 'Check every ticket place first (0 of 17)');
select test.throws('finance: a place of the review only', $$select test.rr_do('rr_fin', 'deposit_review_ticket', '{"booking": "RR-1", "place": "nowhere", "result": "none_found"}')$$, 'Choose a place');
select test.throws('finance: Fleet does not check the places', $$select test.rr_do('rr_fleet', 'deposit_review_ticket', '{"booking": "RR-1", "place": "toronto", "result": "none_found"}')$$, 'Finance or an Admin');
select test.rr_do('rr_fin', 'deposit_review_ticket', jsonb_build_object('booking', 'RR-1', 'place', x ->> 'key', 'result', 'none_found'))
  from deposit_reviews r, jsonb_array_elements(r.places) x where r.booking_id = test.dgb('RR-1') and x ->> 'key' <> 'mississauga';
select test.throws('finance: a ticket needs the amount and the time', $$select test.rr_do('rr_fin', 'deposit_review_ticket', '{"booking": "RR-1", "place": "mississauga", "result": "ticket"}')$$, 'Enter the amount');
create temp table rr_t as select test.rr_do('rr_fin', 'deposit_review_ticket', jsonb_build_object('booking', 'RR-1', 'place', 'mississauga', 'result', 'ticket', 'kind', 'parking',
  'amount_cents', 4500, 'occurred_at', (select pickup_at + interval '1 day' from bookings where id = test.dgb('RR-1')), 'notice_number', 'RRM-1')) t;
select test.eq('finance: the ticket is logged in Tolls and tickets, by the place and the plate, and tied to the check',
  (select kind || ':' || authority || ':' || amount_cents || ':' || (plate is not distinct from (select plate from vehicles where id = test.id('vehicle:RRA')))
     from toll_tickets where id = (select (t ->> 'toll_ticket_id')::uuid from rr_t)) || '/' ||
  (select result from deposit_review_ticket_checks where booking_id = test.dgb('RR-1') and place_key = 'mississauga'),
  'parking:Mississauga:4500:true/ticket');
select test.throws('finance: a recorded ticket is changed in Tolls and tickets', $$select test.rr_do('rr_fin', 'deposit_review_ticket', '{"booking": "RR-1", "place": "mississauga", "result": "none_found"}')$$, 'already recorded');
select test.rr_sign('rr_fin', 'RR-1', 'finance', 'tickets', 'issue', '{"note": "Mississauga parking ticket, logged", "amount_cents": 4500}');
select test.rr_sign('rr_fin', 'RR-1', 'finance', x) from unnest(array['km', 'damage', 'late', 'cleaning']) x;
select test.eq('finance: six of seven, the blocker still on', (select (app.drr_state(test.dgb('RR-1')) ->> 'finance_signed')) || ':' ||
  (select count(*) from jsonb_array_elements(app.deposit_blockers(test.dgb('RR-1'))) x where x ->> 'kind' = 'review'), '6:1');
select test.rr_sign('rr_fin', 'RR-1', 'finance', 'tolls', 'ok', '{"note": "Toll operator checked: nothing"}');
select test.eq('finance: done: stage, the Finance To do done, the review no longer blocks',
  (select (s ->> 'stage') || ':' || (s ->> 'tickets_found') || ':' || (s ->> 'issues') from (select app.drr_state(test.dgb('RR-1')) s) x) || '/' ||
  (select status from tasks where booking_id = test.dgb('RR-1') and task_type = 'deposit_review_finance') || '/' ||
  (select count(*) from jsonb_array_elements(app.deposit_blockers(test.dgb('RR-1'))) x where x ->> 'kind' = 'review'),
  'done:1:3/done/0');
select test.eq('finance: the ticket found is on the car, in the Tolls and tickets queue', (select vehicle_id from toll_tickets where id = (select (t ->> 'toll_ticket_id')::uuid from rr_t)), test.id('vehicle:RRA'));

-- someone else double-checks, unless an Admin
select test.mk_booking('RR-2', 'RRB', 'rr_r', test.dgl(-5), test.dgl(-3), 'returned');
select test.dg_hold('RR-2', now() + interval '10 days');
update staff_profiles set functions = array['fleet', 'finance'] where user_id = test.id('rr_fin2');
select test.rr_sign('rr_fin2', 'RR-2', 'fleet', 'fuel');
select test.throws('finance: nobody double-checks their own Fleet check', $$select test.rr_sign('rr_fin2', 'RR-2', 'finance', 'fuel')$$, 'Someone else double-checks');
update staff_profiles set functions = array['finance'] where user_id = test.id('rr_fin2');

-- ================================================================ 5. an Admin releases past the review with the reason
select test.dg_statement('RR-2');
select test.throws('override: an Admin needs the reason', $$select test.dg_settle('rr_admin', 'RR-2', '{"hold_back_cents": 0, "release_now": true}')$$, 'whole deposit stays held');
select test.dg_settle('rr_admin', 'RR-2', '{"hold_back_cents": 0, "release_now": true, "override_reason": "Renter is a long-time client, checked by phone"}');
select test.eq('override: recorded with the review as the blocker (audited, append-only)',
  (select kind || ':' || (blockers -> 0 ->> 'kind') from deposit_overrides where booking_id = test.dgb('RR-2')), 'release_past_blockers:review');

-- ================================================================ 6. the countdowns
select test.mk_booking('RR-3', 'RRC', 'rr_r', test.dgl(-10), test.dgl(11), 'on_rent');
update bookings set pay_every = 'weekly' where id = test.dgb('RR-3');
update payments set amount_cents = (select round(total_due_at_booking_cents / 3.0)::bigint from bookings where id = test.dgb('RR-3')) where id = test.id('payment:RR-3');
select test.throws('countdowns: customer service does not see them', $$select test.rr_read('rr_cs', 'finance_countdowns', '{}')$$, 'Finance or an Admin');
create temp table rr_c as select test.rr_read('rr_fin', 'finance_countdowns', '{}') v;
select test.eq('countdowns: the hold expiring in 30 hours is amber, its re-authorization 24 hours before',
  (select (r ->> 'hold_level') || ':' || ((r ->> 'reauth_at')::timestamptz = (r ->> 'hold_expires_at')::timestamptz - interval '24 hours')
     from rr_c, jsonb_array_elements(v -> 'rows') r where r ->> 'booking_number' = 'RR-1'), 'amber:true');
select test.eq('countdowns: the deposit return promised 7 business days after the return',
  (select (r ->> 'return_due_on') from rr_c, jsonb_array_elements(v -> 'rows') r where r ->> 'booking_number' = 'RR-1'),
  (select coalesce(d.release_due_on, app.add_business_days(app.local_date(b.checked_in_at), 7))::text from deposits d join bookings b on b.id = d.booking_id where b.id = test.dgb('RR-1')));
select test.eq('countdowns: the weekly plan''s payment is overdue and red',
  (select (r ->> 'pay_state') || ':' || (r ->> 'pay_plan') || ':' || (r ->> 'level') from rr_c, jsonb_array_elements(v -> 'rows') r where r ->> 'booking_number' = 'RR-3'), 'overdue:weekly:red');
select test.ok('countdowns: soonest first', (select bool_and(a <= b) from (select (r ->> 'soonest_at')::timestamptz a, lead((r ->> 'soonest_at')::timestamptz) over (order by o) b
  from rr_c, jsonb_array_elements(v -> 'rows') with ordinality t(r, o)) x where b is not null));
select test.eq('countdowns: one booking, sorted by the hold',
  (select jsonb_array_length(v -> 'rows') || ':' || (v ->> 'sort') from (select test.rr_read('rr_admin', 'finance_countdowns', '{"booking": "RR-1", "sort": "hold"}') v) x), '1:hold');

-- the alerts: once at 48 hours, once at 24, never twice; an overdue payment once
select app.drr_alerts(now());
select app.drr_alerts(now());
select test.eq('alerts: the hold (48 hours) and the overdue payment, each once',
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'finance_hold_expiring' and entity_id = test.dgb('RR-1')) || ':' ||
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'finance_payment_due' and entity_id = test.dgb('RR-3')), '1:1');
select test.eq('alerts: normal tier (held through the quiet hours) for Finance on duty and the Admins',
  (select string_agg(tier || ':' || array_to_string(who, ','), ' ' order by rule) from staff_alert_rules where rule like 'finance\_%' and rule in ('finance_hold_expiring', 'finance_deposit_return_due', 'finance_payment_due')),
  'normal:admin,on_duty:finance normal:admin,on_duty:finance normal:admin,on_duty:finance');
update deposits set hold_expires_at = now() + interval '20 hours' where booking_id = test.dgb('RR-1');
select app.drr_alerts(now());
select test.eq('alerts: inside 24 hours, a second alert', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'finance_hold_expiring' and entity_id = test.dgb('RR-1')), 2::bigint);
select test.ok('digest: the Finance morning lines (from 5:00 Toronto)', extract(hour from now() at time zone 'America/Toronto') < 5
  or (select count(*) >= 2 from staff_digest_items where dedupe_key like 'drr:%:va_finance:' || to_char(app.local_date(now()), 'YYYY-MM-DD')));

-- ================================================================ 7. the sweep
create temp table rr_w as select app.drr_sweep(test.base(1)) t;
select test.ok('sweep: Monday from 6:00 makes one Finance To do with the plates', (select status from tasks where id = (select t from rr_w)) = 'open'
  and (select detail like '%' || (select plate from vehicles where id = test.id('vehicle:RRA')) || '%' from tasks where id = (select t from rr_w)));
select test.eq('sweep: once a day', app.drr_sweep(test.base(1) + interval '2 hours'), null::uuid);
select test.eq('sweep: not on Tuesday', app.drr_sweep(test.base(2)), null::uuid);
select test.ok('sweep: Wednesday again', app.drr_sweep(test.base(3)) is not null);
select test.ok('sweep: Wednesday''s counts from Monday''s sweep', (select since is not null from deposit_review_sweeps where run_on = app.local_date(test.base(3))));
select test.eq('sweep: the list for the page groups by plate', (select jsonb_typeof(test.rr_read('rr_fin', 'deposit_reviews', '{"view": "sweep"}') -> 'sweep')), 'array');
delete from deposit_review_sweeps where run_on >= app.local_date(test.base(1));
delete from tasks where task_type = 'deposit_review_sweep';

-- ================================================================ 8. Finance staff opt in to Sales
select test.throws('sales: only Finance here', $$select test.rr_do('rr_fleet', 'finance_sales_optin', '{"on": true}')$$, 'Only Finance');
create temp table rr_so as select test.rr_do('rr_fin', 'finance_sales_optin', '{"on": true}') s;
select test.eq('sales: Finance opts in: the Sales path on their academy, not yet Sales',
  (select (s ->> 'opted_in') || ':' || ((s ->> 'path') in ('sales_remote', 'sales_in_person')) || ':' || (s ->> 'ready') from rr_so) || '/' ||
  (select count(*) from academy_enrollments where user_id = test.id('rr_fin') and path_code in ('sales_remote', 'sales_in_person')), 'true:true:false/1');
select test.eq('sales: the state reads the same', (select (s ->> 'opted_in') from (select test.rr_read('rr_fin', 'finance_sales_state', '{}') s) x), 'true');
create temp table rr_so2 as select test.rr_do('rr_fin', 'finance_sales_optin', '{"on": false}') s;
select test.eq('sales: opting out takes the path off', (select (s ->> 'opted_in') from rr_so2) || '/' ||
  (select count(*) from academy_enrollments where user_id = test.id('rr_fin') and path_code in ('sales_remote', 'sales_in_person')), 'false/0');

-- ================================================================ 9. the accident card: the renter's plan policy and the claim page
select test.mk_booking('RR-5', 'RRD', 'rr_r', test.dgl(3), test.dgl(6), 'confirmed');
update bookings set coverage_option = 3 where id = test.dgb('RR-5');
insert into coverage_proofs (booking_id, coverage_option, status, activation_ref, activated_at, confirmed_at) values (test.dgb('RR-5'), 3, 'confirmed', 'ACT-RR5', now(), now());
select test.eq('card: the plan reference from the purchase and the provider''s claim page, no CarmaCars policy',
  (select (c #>> '{coverage,plan_policy_number}') || ' ' || (c #>> '{coverage,plan_claim_url}') from (select app.accident_card(test.dgb('RR-5')) c) x),
  'ACT-RR5 https://www.rentalcover.com/en-us/claim/start');
select test.throws('card: the renter does not enter it', $$select test.rr_do('rr_r', 'plan_policy_set', '{"booking": "RR-5", "policy_number": "RC-1"}')$$, null);
select test.rr_do('rr_cs', 'plan_policy_set', '{"booking": "RR-5", "policy_number": "RC-778899"}');
select test.eq('card: the number staff entered is printed', (select (c #>> '{coverage,plan_policy_number}') || ':' || (c #>> '{coverage,plan_policy_entered}') from (select app.accident_card(test.dgb('RR-5')) c) x), 'RC-778899:true');
select test.throws('card: only on a booking with the plan', $$select test.rr_do('rr_cs', 'plan_policy_set', '{"booking": "RR-1", "policy_number": "RC-1"}')$$, 'does not have the plan');

-- ================================================================ 10. switched off (as for the suites after this one)
alter table program_settings alter column deposit_review_required set default false;
update program_settings set deposit_review_required = false;
select test.mk_booking('RR-6', 'RRE', 'rr_r', test.dgl(-3), test.dgl(-1), 'returned');
select test.eq('off: no review for a new return, and no review blocker', (select count(*) from deposit_reviews where booking_id = test.dgb('RR-6')) || ':' ||
  (select count(*) from jsonb_array_elements(app.deposit_blockers(test.dgb('RR-2'))) x where x ->> 'kind' = 'review'), '0:0');
