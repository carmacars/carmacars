-- 55: the maintenance and service tracker (migration 0089). Defaults and settings by class and car, km a day from the
-- readings, due soon and overdue by km and by date, the readings the system already gets, recording a service (timers
-- reset, tasks close), the bill both ways (company expense, owner cost on the statement, claim, renter; an expense under
-- a service category records the service), the assistant's limit, voiding, tires and the seasonal swap, the handover
-- and booking blocks, the winter tire add-on, the To do lines and the digest, and who may do what. Fixtures start with "mt".
select test.suite('55 maintenance tracker');

select test.mk_user('mt_admin', 'admin');
select test.mk_user('mt_fleet', 'va', 'fleet');
select test.mk_user('mt_fin', 'va', 'finance');
select test.mk_user('mt_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 20000 where user_id = test.id('mt_fleet');
select test.mk_owner('mt_olga');
select test.mk_owner('mt_other');
select test.mk_vehicle('mt_car', 'mt_olga');
select test.mk_vehicle('mt_class', 'mt_olga');
select test.mk_vehicle('mt_tires', 'mt_olga');
select test.mk_vehicle('mt_block', 'mt_olga');
select test.mk_vehicle('mt_ev', 'mt_olga');
select test.mk_vehicle('mt_sample', 'mt_olga');
select test.mk_renter('mt_rita');
select test.mk_vehicle('mt_co', 'mt_olga');
update vehicles set supply_type = 'company', owner_id = null where id = test.id('vehicle:mt_co');
update vehicles set fuel = 'electric' where id = test.id('vehicle:mt_ev');
update vehicles set is_sample = true where id = test.id('vehicle:mt_sample');
update vehicles set class = 'economy' where id = test.id('vehicle:mt_class');

create or replace function test.mtv(p text) returns uuid language sql stable as $$ select test.id('vehicle:' || p) $$;
create or replace function test.mti(p_car text, p_item text) returns vehicle_service_items language sql stable as $$
  select * from vehicle_service_items where vehicle_id = test.mtv(p_car) and item_code = p_item $$;
-- an item's status on a day (each call sees the refresh before it)
create or replace function test.mtst(p_car text, p_item text, p_day date default null) returns text language plpgsql as $$
begin
  perform app.maint_refresh(test.mtv(p_car), p_day);
  return (select status from vehicle_service_items where vehicle_id = test.mtv(p_car) and item_code = p_item);
end $$;
create or replace function test.mtdo(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create or replace function test.mtread(p_user text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;
-- a reading n days ago
create or replace function test.mtkm(p_car text, p_km integer, p_days_ago integer) returns void language sql as $$
  insert into vehicle_odometer_readings (vehicle_id, read_at, km, source) values (test.mtv(p_car), now() - make_interval(days => p_days_ago), p_km, 'manual') $$;

-- ================================================================ 1. defaults
select test.eq('defaults: oil and filter 8,000 km or 6 months; tire rotation 10,000 km; brake inspection 20,000 km or 12 months',
  (select string_agg(code || '=' || coalesce(interval_km::text, '-') || '/' || coalesce(interval_months::text, '-'), ',' order by sort_order) from service_items
    where code in ('oil_filter', 'tire_rotation', 'brake_inspection')), 'oil_filter=8000/6,tire_rotation=10000/-,brake_inspection=20000/12');
select test.eq('defaults: every item of the list', (select string_agg(code, ',' order by sort_order) from service_items),
  'oil_filter,tire_rotation,brake_inspection,brake_pads_rotors,tires,seasonal_swap,safety_certificate,registration,battery,wipers,cabin_filter,engine_air_filter,alignment,fluids,annual_inspection');
select test.eq('defaults: handover is blocked when the safety inspection or the registration has expired, nothing blocks bookings',
  (select string_agg(code, ',' order by sort_order) filter (where block_handover_when_expired) || '/' || count(*) filter (where block_bookings_when_overdue) from service_items),
  'safety_certificate,registration/0');
select test.eq('defaults: Ontario winter dates and the thresholds',
  (select maint_winter_on_reminder || ' ' || maint_winter_on_by || ' ' || maint_winter_off_from || ' ' || maint_winter_off_by || ' ' || maint_due_soon_km || ' ' || maint_due_soon_days
     from app.settings()), '11-01 12-01 04-01 05-01 1000 14');

-- ================================================================ 2. backfill: every real car, unknown until recorded
select test.eq('backfill: a real car gets every item, unknown until its last service is recorded',
  (select count(*) || '/' || count(*) filter (where status = 'unknown') || '/' || count(*) filter (where status = 'none') from vehicle_service_items where vehicle_id = test.mtv('mt_car')), '15/14/1');
select test.eq('backfill: oil and the engine air filter are off for an electric car', (select string_agg(item_code, ',' order by item_code) from vehicle_service_items where vehicle_id = test.mtv('mt_ev') and status = 'off'),
  'engine_air_filter,oil_filter');
select test.eq('backfill: a sample car has none', (select count(*) from vehicle_service_items where vehicle_id = test.mtv('mt_sample')), 0::bigint);
select app.job_maintenance_watch(date_trunc('day', now()) + interval '14 hours');
select test.eq('backfill: one task per car to record its last service, in Fleet', (select count(*) || '/' || min(queue) || '/' || min(priority) from tasks
  where task_type = 'maintenance_backfill' and vehicle_id in (test.mtv('mt_car'), test.mtv('mt_class'), test.mtv('mt_tires'))), '3/fleet/low');
update tasks set status = 'done', completed_at = now() where task_type = 'maintenance_backfill' and vehicle_id = test.mtv('mt_class');
select app.maint_tasks(test.mtv('mt_class'));
select test.eq('backfill: asked once per car (done is not asked again)', (select count(*) from tasks where task_type = 'maintenance_backfill' and vehicle_id = test.mtv('mt_class')), 1::bigint);

-- ================================================================ 3. km a day from the readings
select test.mtkm('mt_car', 10000, 60);
select test.mtkm('mt_car', 13000, 0);
select test.eq('km a day: from the readings (3,000 km in 60 days)', app.maint_km_per_day(test.mtv('mt_car')) ->> 'rate' || '/' || (app.maint_km_per_day(test.mtv('mt_car')) ->> 'source'), '50.0/readings');
select test.eq('km a day: Program settings when nothing is known', app.maint_km_per_day(test.mtv('mt_block')) ->> 'source', 'default');
select test.eq('current odometer: the highest reading', app.maint_current_km(test.mtv('mt_car')), 13000);

-- ================================================================ 4. due soon and overdue, by km and by date
select test.lives('record: the last oil change, 7,500 km ago (at 5,500 km, a month ago)',
  format($$select test.mtdo('mt_admin', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', app.today() - 30, 'odometer_km', 5500,
    'items', jsonb_build_array('oil_filter'), 'payer', 'none')));
select test.eq('due soon: within 1,000 km of the next oil change (13,000 of 13,500)', (test.mti('mt_car', 'oil_filter')).status || '/' || (test.mti('mt_car', 'oil_filter')).next_due_km, 'due_soon/13500');
select test.eq('projection: the date the km a day gives (500 km at 50 a day: 10 days)', (test.mti('mt_car', 'oil_filter')).projected_due_on - app.today(), 10);
select test.mtkm('mt_car', 13600, 0);
select app.maint_refresh(test.mtv('mt_car'));
select test.eq('overdue: past the km', (test.mti('mt_car', 'oil_filter')).status, 'overdue');
select test.ok('overdue: the detail says by how much', (test.mti('mt_car', 'oil_filter')).detail like '%(100 km over)%');
-- by date: the battery, 4 years ago less 20 days (due soon within 30 days), the wipers 13 months ago (overdue)
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', app.today() - interval '4 years' + interval '20 days', 'items', jsonb_build_array('battery'), 'payer', 'none'));
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', app.today() - interval '13 months', 'items', jsonb_build_array('wipers'), 'payer', 'none'));
select test.eq('by date: the battery is due soon (its own 30 days), the wipers are overdue',
  (test.mti('mt_car', 'battery')).status || '/' || (test.mti('mt_car', 'wipers')).status, 'due_soon/overdue');
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', app.today() - 20, 'items', jsonb_build_array('cabin_filter'), 'payer', 'none'));
select test.ok('a service without an odometer takes the reading of that day, marked estimated',
  exists (select 1 from vehicle_service_records where vehicle_id = test.mtv('mt_car') and odometer_estimated and odometer_km = 5500));

-- the task: one per car, with what is due, priority from the worst
select app.maint_tasks(test.mtv('mt_car'));
select test.eq('task: one Fleet task for the car, high when something is overdue',
  (select count(*) || '/' || min(priority) || '/' || min(queue) from tasks where task_type = 'maintenance_due' and vehicle_id = test.mtv('mt_car') and status = 'open'), '1/high/fleet');
select test.ok('task: lists the items, overdue first', (select detail like '%Oil and filter: overdue%' and position('Battery: due soon' in detail) > position('Oil and filter' in detail) from tasks
  where task_type = 'maintenance_due' and vehicle_id = test.mtv('mt_car') and status = 'open'));

-- ================================================================ 5. recorded: the timers reset
select test.lives('record: oil and wipers done today at 13,700 km',
  format($$select test.mtdo('mt_fleet', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'odometer_km', 13700, 'shop', 'Quick Lube',
    'items', jsonb_build_array('oil_filter', 'wipers'), 'cost_cents', 8000, 'hst_cents', 1040, 'payer', 'company')));
select test.eq('reset: oil is ok, next at 21,700 km or in 6 months', (test.mti('mt_car', 'oil_filter')).status || '/' || (test.mti('mt_car', 'oil_filter')).next_due_km
  || '/' || ((test.mti('mt_car', 'oil_filter')).next_due_on = (app.today() + interval '6 months')::date), 'ok/21700/true');
select test.eq('reset: the wipers too', (test.mti('mt_car', 'wipers')).status, 'ok');
select test.eq('reset: the odometer of the service is a reading', app.maint_current_km(test.mtv('mt_car')), 13700);
select test.ok('reset: the task now lists only the battery (due soon, normal)', (select detail not like '%Oil%' and priority = 'normal' from tasks
  where task_type = 'maintenance_due' and vehicle_id = test.mtv('mt_car') and status = 'open'));

-- ================================================================ 6. the bill: company expense, both ways
select test.eq('company: the expense is entered under the service''s category, with the car, amount and HST',
  (select e.category || '/' || e.amount_cents || '/' || e.hst_cents || '/' || (e.vehicle_id = test.mtv('mt_car')) || '/' || r.billing_status
     from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where r.shop = 'Quick Lube'), 'maint_service/8000/1040/true/billed');
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('oil_filter'), 'cost_cents', 6000, 'hst_cents', 780,
  'payer', 'company', 'shop', 'Oil only'));
select test.eq('company: an oil change alone goes under "Car service: oil change"',
  (select e.category from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where r.shop = 'Oil only'), 'maint_oil');
select test.eq('company: recording does not make a second record from the expense', (select count(*) from vehicle_service_records where vehicle_id = test.mtv('mt_car') and source = 'expense'), 0::bigint);
-- the other way: an expense entered under a service category records the service
insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, created_by)
values (app.today() - 2, 'maint_brakes', 'Front pads and rotors', 45000, 5850, test.mtv('mt_car'), test.id('mt_admin'));
select test.eq('expense: a service record with the category''s items, billed, linked to the expense',
  (select r.source || '/' || r.billing_status || '/' || r.payer || '/' || (select string_agg(item_code, ',' order by item_code) from vehicle_service_record_items where record_id = r.id)
     from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where e.description = 'Front pads and rotors'),
  'expense/billed/company/brake_inspection,brake_pads_rotors');
select test.eq('expense: the brake inspection timer reset to the expense date', (test.mti('mt_car', 'brake_inspection')).last_done_on || '/' || (test.mti('mt_car', 'brake_inspection')).status,
  (app.today() - 2)::text || '/ok');
insert into company_expenses (expense_on, category, description, amount_cents, vehicle_id, created_by) values (app.today(), 'marketing', 'Flyers', 1000, test.mtv('mt_car'), test.id('mt_admin'));
select test.eq('expense: marketing with a car is not a service', (select count(*) from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where e.description = 'Flyers'), 0::bigint);
update company_expenses set voided_at = now(), void_reason = 'Entered twice' where description = 'Front pads and rotors';
select test.eq('expense voided: the record goes, the brake timer is back to unknown',
  (select (r.voided_at is not null)::text from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where e.description = 'Front pads and rotors')
  || '/' || (test.mti('mt_car', 'brake_inspection')).status, 'true/unknown');
-- a record voided: its expense is voided
select test.lives('void: an Admin voids the "Oil only" record',
  format($$select test.mtdo('mt_admin', 'maint_void', %L)$$, jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Oil only'), 'reason', 'Wrong car')));
select test.ok('void: its expense is voided too', (select e.voided_at is not null from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where r.shop = 'Oil only'));
select test.eq('void: the oil timer goes back to the service before (13,700 km)', (test.mti('mt_car', 'oil_filter')).last_done_km, 13700);

-- ================================================================ 7. the owner pays (owner agreement 11.1): on the owner's statement
select test.eq('owner: the default payer of a program owner''s car is the owner; a company car''s is CarmaCars',
  app.maint_default_payer(test.mtv('mt_car')) || '/' || app.maint_default_payer(test.mtv('mt_co')), 'owner/company');
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', date '2026-10-05', 'items', jsonb_build_array('tire_rotation', 'alignment'),
  'cost_cents', 12000, 'hst_cents', 1560, 'shop', 'Owner Tire Shop', 'payer', 'owner'));
select test.eq('owner: an open owner cost of the total with HST, kind maintenance, for this car',
  (select d.kind || '/' || d.amount_cents || '/' || d.hst_cents || '/' || d.status || '/' || (d.owner_id = test.id('owner:mt_olga'))
     from vehicle_service_records r join owner_deductions d on d.id = r.owner_deduction_id where r.shop = 'Owner Tire Shop'), 'maintenance/13560/1560/open/true');
select test.ok('owner: the description names the work, the shop and the date',
  (select d.description from vehicle_service_records r join owner_deductions d on d.id = r.owner_deduction_id where r.shop = 'Owner Tire Shop')
   = 'Service: Tire rotation, Wheel alignment at Owner Tire Shop, Oct 5, 2026');
select app.build_owner_statement(test.id('owner:mt_olga'), date '2026-10-01');
select test.eq('owner: deducted on the owner''s statement as an owner cost',
  (select l.line_type || '/' || l.amount_cents from owner_statement_lines l join vehicle_service_records r on r.owner_deduction_id = l.owner_deduction_id where r.shop = 'Owner Tire Shop'),
  'owner_cost/-13560');
select test.throws('owner: a company car has no owner to bill', format($$select test.mtdo('mt_admin', 'maint_record', %L)$$,
  jsonb_build_object('vehicle_id', test.mtv('mt_co'), 'items', jsonb_build_array('fluids'), 'cost_cents', 100, 'payer', 'owner')), 'no owner to bill');
select test.eq('company car: the payers offered leave out the owner', (select string_agg(x ->> 0, ',') from jsonb_array_elements(app.maint_payers(test.mtv('mt_co'))) x), 'company,claim,renter,none');
select test.eq('owner: not billed yet is recorded, billing waits',
  test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('fluids'), 'cost_cents', 3000, 'payer', 'owner', 'billed', false, 'shop', 'Later bill')) ->> 'billing_status',
  'not_billed');
select test.eq('owner: not billed yet, the timers reset anyway', (test.mti('mt_car', 'fluids')).status, 'ok');
select test.eq('owner: To do counts it under services to bill', (select (i ->> 'count')::integer from jsonb_array_elements(app.admin_todo(test.id('mt_admin')) -> 'items') i where i ->> 'key' = 'maintenance_bill') >= 1, true);
select test.eq('bill now: billed', test.mtdo('mt_fleet', 'maint_bill', jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Later bill'), 'hst_cents', 390)) ->> 'billing_status', 'billed');
select test.eq('bill now: the owner cost with the HST added', (select d.amount_cents from vehicle_service_records r join owner_deductions d on d.id = r.owner_deduction_id where r.shop = 'Later bill'), 3390::bigint);

-- the assistant's single limit ($200 here): above it the record is kept and an Admin bills it
select test.eq('limit: above the assistant''s limit the bill waits for an Admin',
  test.mtdo('mt_fleet', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('annual_inspection'), 'cost_cents', 25000, 'hst_cents', 3250,
    'payer', 'company', 'shop', 'Big Garage')) ->> 'billing_status', 'needs_admin');
select test.ok('limit: an Admin task, and the timer reset anyway', exists (select 1 from tasks where task_type = 'maintenance_bill' and status = 'open' and queue = 'admin'
  and related_id = (select id from vehicle_service_records where shop = 'Big Garage')) and (test.mti('mt_car', 'annual_inspection')).status = 'ok');
select test.throws('limit: the assistant cannot bill it', format($$select test.mtdo('mt_fleet', 'maint_bill', %L)$$, jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Big Garage'))),
  'An Admin bills this service');
select test.eq('limit: the Admin bills it', test.mtdo('mt_admin', 'maint_bill', jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Big Garage'))) ->> 'billing_status', 'billed');
select test.eq('limit: the task closes', (select status from tasks where task_type = 'maintenance_bill' and related_id = (select id from vehicle_service_records where shop = 'Big Garage')), 'done');

-- a claim pays
insert into incidents (id, kind, vehicle_id, occurred_at) values (test.id('inc:mt'), 'accident', test.mtv('mt_car'), now() - interval '5 days');
insert into claims (id, incident_id, vehicle_id, owner_id, path) values (test.id('claim:mt'), test.id('inc:mt'), test.mtv('mt_car'), test.id('owner:mt_olga'), 'fleet_policy');
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('alignment'), 'cost_cents', 20000, 'hst_cents', 2600,
  'payer', 'claim', 'claim_id', test.id('claim:mt'), 'shop', 'Claim Shop'));
select test.eq('claim: a repair cost on the claim''s ledger', (select e.kind || '/' || e.amount_cents || '/' || e.direction from vehicle_service_records r join claim_ledger_entries e on e.id = r.claim_entry_id
  where r.shop = 'Claim Shop'), 'repair/22600/out');
select test.throws('claim: voiding is refused (the ledger cannot change)', format($$select test.mtdo('mt_admin', 'maint_void', %L)$$,
  jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Claim Shop'), 'reason', 'x')), 'correcting entry on the claim');
-- the renter pays (tire damage): a post-rental charge at cost
select test.mk_booking('MT-1', 'mt_car', 'mt_rita', '2026-10-01 10:00', '2026-10-04 10:00', 'closed');
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('tire_rotation'), 'cost_cents', 15000,
  'payer', 'renter', 'booking_id', test.id('booking:MT-1'), 'shop', 'Renter Tire', 'notes', 'Curb damage'));
select test.eq('renter: a damage-at-cost line on the booking', (select l.charge_type || '/' || l.amount_cents || '/' || (l.booking_id = test.id('booking:MT-1'))
  from vehicle_service_records r join booking_line_items l on l.id = r.booking_line_item_id where r.shop = 'Renter Tire'), 'damage_at_cost/15000/true');
select test.throws('renter: needs the rental', format($$select test.mtdo('mt_admin', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'),
  'items', jsonb_build_array('fluids'), 'cost_cents', 100, 'payer', 'renter')), 'Choose the rental');
select test.mtdo('mt_admin', 'maint_void', jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Renter Tire'), 'reason', 'Not the renter'));
select test.ok('renter: voiding the record voids the line not yet on a statement',
  (select l.voided_at is not null from vehicle_service_records r join booking_line_items l on l.id = r.booking_line_item_id where r.shop = 'Renter Tire'));
select test.mtdo('mt_admin', 'maint_void', jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Later bill'), 'reason', 'Duplicate'));
select test.ok('owner void: an open owner cost is waived', (select d.status from vehicle_service_records r join owner_deductions d on d.id = r.owner_deduction_id where r.shop = 'Later bill') = 'waived');
update owner_deductions set status = 'deducted' where id = (select owner_deduction_id from vehicle_service_records where shop = 'Owner Tire Shop');
select test.throws('owner void: refused once the cost is on a statement', format($$select test.mtdo('mt_admin', 'maint_void', %L)$$,
  jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Owner Tire Shop'), 'reason', 'x')), 'already on a statement');
select test.throws('validation: at least one item', format($$select test.mtdo('mt_admin', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', '[]'::jsonb)), 'Tick what was done');
select test.throws('validation: not in the future', format($$select test.mtdo('mt_admin', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'done_on', app.today() + 3,
  'items', jsonb_build_array('fluids'))), 'cannot be in the future');

-- ================================================================ 8. settings by class and by car
select test.mtdo('mt_admin', 'maint_rule_save', jsonb_build_object('item_code', 'oil_filter', 'vehicle_class', 'economy', 'interval_km', 5000));
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_class'), 'odometer_km', 20000, 'items', jsonb_build_array('oil_filter'), 'payer', 'none'));
select test.eq('class: an economy car changes its oil every 5,000 km (months from the default)', (test.mti('mt_class', 'oil_filter')).next_due_km || '/'
  || ((test.mti('mt_class', 'oil_filter')).next_due_on = (app.today() + interval '6 months')::date), '25000/true');
select test.mtdo('mt_admin', 'maint_rule_save', jsonb_build_object('item_code', 'oil_filter', 'vehicle_id', test.mtv('mt_class'), 'interval_km', 12000, 'interval_months', 0));
select test.eq('car: the car''s own rule wins; 0 months means by km only', (test.mti('mt_class', 'oil_filter')).next_due_km || '/' || coalesce((test.mti('mt_class', 'oil_filter')).next_due_on::text, 'none'), '32000/none');
select test.eq('car: the rule source shows', (select rule_source from app.maint_rules(test.mtv('mt_class')) where code = 'oil_filter'), 'car');
select test.mtdo('mt_admin', 'maint_rule_save', jsonb_build_object('item_code', 'wipers', 'vehicle_id', test.mtv('mt_class'), 'active', false));
select test.eq('car: an item turned off for one car', (test.mti('mt_class', 'wipers')).status, 'off');
select test.throws('settings: only an Admin', format($$select test.mtdo('mt_fleet', 'maint_rule_save', %L)$$, jsonb_build_object('item_code', 'oil_filter', 'vehicle_class', 'suv', 'interval_km', 1)),
  'Only an Admin changes the maintenance settings');
select test.mtdo('mt_admin', 'maint_item_save', jsonb_build_object('code', 'tire_rotation', 'interval_km', 12000));
select test.eq('default: an Admin changes the default interval', (select interval_km from service_items where code = 'tire_rotation'), 12000);
select test.mtdo('mt_admin', 'maint_item_save', jsonb_build_object('code', 'tire_rotation', 'interval_km', 10000));

-- ================================================================ 9. readings the system already gets
insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, odometer_start, created_by)
values (test.mtv('mt_block'), test.id('mt_fleet'), 'service', now() - interval '1 hour', 40100, test.id('mt_fleet'));
select test.eq('readings: a field staff move', (select source || '/' || km from vehicle_odometer_readings where vehicle_id = test.mtv('mt_block') order by read_at desc limit 1), 'move/40100');
select test.mk_booking('MT-2', 'mt_block', 'mt_rita', '2026-10-10 10:00', '2026-10-12 10:00', 'closed');
update bookings set odometer_out_km = 40200, odometer_in_km = 40650 where id = test.id('booking:MT-2');
select test.eq('readings: the rental''s odometer out and in', (select string_agg(km::text, ',' order by km) from vehicle_odometer_readings where vehicle_id = test.mtv('mt_block') and source = 'rental'), '40200,40650');
insert into condition_reports (vehicle_id, booking_id, kind, performed_by, performed_by_role, odometer_km, fuel_pct)
values (test.mtv('mt_block'), test.id('booking:MT-2'), 'return', test.id('mt_fleet'), 'staff', 40700, 80);
select test.eq('readings: a return condition report', (select source || '/' || km from vehicle_odometer_readings where vehicle_id = test.mtv('mt_block') and source = 'return'), 'return/40700');
select test.eq('readings: the car record follows the highest reading', (select odometer_km from vehicles where id = test.mtv('mt_block')), 40700);
select test.throws('readings: a manual reading lower than the last one needs the tick',
  format($$select test.mtdo('mt_fleet', 'maint_reading_add', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'km', 4070)), 'lower than the last one on file');
select test.lives('readings: a manual reading', format($$select test.mtdo('mt_fleet', 'maint_reading_add', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'km', 99000)));
select test.lives('readings: an Admin voids a wrong reading', format($$select test.mtdo('mt_admin', 'maint_reading_void', %L)$$,
  jsonb_build_object('id', (select id from vehicle_odometer_readings where vehicle_id = test.mtv('mt_block') and km = 99000), 'reason', 'Typo')));
select test.eq('readings: the current odometer is back to the highest left', app.maint_current_km(test.mtv('mt_block')), 40700);

-- ================================================================ 10. tires and the seasonal swap
select test.ok('tires: unknown with no set on file', (test.mti('mt_tires', 'tires')).status = 'unknown' and (test.mti('mt_tires', 'seasonal_swap')).status = 'unknown');
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('vehicle_id', test.mtv('mt_tires'), 'season', 'all_season', 'size', '225/45R17', 'brand', 'Michelin',
  'tread_mm', 6.5, 'made_on', app.today() - 400, 'on_car', true));
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('vehicle_id', test.mtv('mt_tires'), 'season', 'winter', 'size', '225/45R17', 'brand', 'Bridgestone Blizzak',
  'tread_mm', 8, 'storage_location', 'Rack B3', 'on_car', false));
select test.eq('tires: ok at 6.5 mm', (test.mti('mt_tires', 'tires')).status, 'ok');
select test.eq('seasonal: all-season on Oct 20 is ok; Nov 5 due soon; Dec 5 and Feb 1 overdue',
  test.mtst('mt_tires', 'seasonal_swap', date '2026-10-20') || ',' || test.mtst('mt_tires', 'seasonal_swap', date '2026-11-05') || ','
  || test.mtst('mt_tires', 'seasonal_swap', date '2026-12-05') || ',' || test.mtst('mt_tires', 'seasonal_swap', date '2027-02-01'), 'ok,due_soon,overdue,overdue');
select app.maint_refresh(test.mtv('mt_tires'), date '2026-12-05');
select test.mtdo('mt_fleet', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_tires'), 'items', jsonb_build_array(jsonb_build_object('code', 'seasonal_swap',
  'tire_set_id', (select id from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and season = 'winter'), 'store_removed_at', 'Rack B4')), 'payer', 'none'));
select test.eq('swap: recorded, the winter set is on, the other stored where said, the swap in the history',
  (select season from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and on_car) || '/' || (select storage_location from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and season = 'all_season')
  || '/' || (select count(*) from vehicle_tire_swaps where vehicle_id = test.mtv('mt_tires')), 'winter/Rack B4/1');
select test.eq('seasonal: winter on Dec 5 ok; Apr 10 due soon; May 10 overdue',
  test.mtst('mt_tires', 'seasonal_swap', date '2026-12-05') || ',' || test.mtst('mt_tires', 'seasonal_swap', date '2027-04-10') || ','
  || test.mtst('mt_tires', 'seasonal_swap', date '2027-05-10'), 'ok,due_soon,overdue');
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('id', (select id from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and on_car), 'tread_mm', 3.6));
select test.eq('tires: due soon at 3.6 mm (4 mm)', test.mtst('mt_tires', 'tires'), 'due_soon');
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('id', (select id from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and on_car), 'tread_mm', 2.9));
select test.eq('tires: overdue at 2.9 mm (3 mm)', test.mtst('mt_tires', 'tires'), 'overdue');
select test.mtdo('mt_fleet', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_tires'), 'items', jsonb_build_array(jsonb_build_object('code', 'tires',
  'new_set', jsonb_build_object('season', 'winter', 'size', '225/45R17', 'brand', 'Nokian', 'tread_mm', 9, 'made_on', app.today() - 60))), 'payer', 'none'));
select test.eq('new tires: a new set on the car, the worn one retired as replaced, the tires ok',
  (select brand from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and on_car) || '/' || (select count(*) from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and retired_reason = 'Replaced')
  || '/' || (test.mti('mt_tires', 'tires')).status, 'Nokian/1/ok');
select app.maint_refresh(test.mtv('mt_tires'));
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('vehicle_id', test.mtv('mt_tires'), 'season', 'summer', 'made_on', app.today() - interval '6 years 1 day', 'tread_mm', 7, 'on_car', true));
select test.eq('tires: six years old is overdue whatever the tread', (test.mti('mt_tires', 'tires')).status, 'overdue');
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('id', (select id from vehicle_tire_sets where vehicle_id = test.mtv('mt_tires') and on_car), 'season', 'all_weather'));
select test.eq('all-weather: no seasonal swap, even in January', test.mtst('mt_tires', 'seasonal_swap', date '2027-01-15'), 'ok');

-- the winter tire add-on follows the tires
select test.ok('winter add-on: a car with no tire record keeps it (as set)', app.addon_applies((select a from addons a where code = 'winter_tire'), (select v from vehicles v where id = test.mtv('mt_class')), null));
select test.ok('winter add-on: a car with a winter set offers it', app.addon_applies((select a from addons a where code = 'winter_tire'), (select v from vehicles v where id = test.mtv('mt_tires')), null));
select test.mtdo('mt_fleet', 'maint_tire_save', jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'season', 'all_season', 'on_car', true));
select test.ok('winter add-on: a car with tires on file and no winter set does not', not app.addon_applies((select a from addons a where code = 'winter_tire'), (select v from vehicles v where id = test.mtv('mt_block')), null));
update vehicle_tire_sets set on_car = false where vehicle_id = test.mtv('mt_tires') and on_car;
update vehicle_tire_sets set on_car = true where vehicle_id = test.mtv('mt_tires') and brand = 'Nokian';
select test.ok('winter add-on: a car on winter tires says so', (select x ->> 'description' from jsonb_array_elements(app.addons_for_car(test.mtv('mt_tires'))) x where x ->> 'code' = 'winter_tire')
  like '%This car is on winter tires now.');
update program_settings set maint_winter_addon_link = false where id = (app.settings()).id;
select test.ok('winter add-on: the link can be turned off', app.addon_applies((select a from addons a where code = 'winter_tire'), (select v from vehicles v where id = test.mtv('mt_block')), null));
update program_settings set maint_winter_addon_link = true where id = (app.settings()).id;

-- ================================================================ 11. blocking
select test.mk_booking('MT-3', 'mt_block', 'mt_rita', to_char(now() + interval '2 days', 'YYYY-MM-DD HH24:00'), to_char(now() + interval '4 days', 'YYYY-MM-DD HH24:00'), 'confirmed');
-- the registration from the plate renewal month never blocks (it moves to the next one)
insert into vehicle_registrations (vehicle_id, registered_as, registered_on, plate_renewal_month) values (test.mtv('mt_block'), 'owner', date '2025-01-10', extract(month from app.today())::smallint);
select app.maint_refresh(test.mtv('mt_block'));
select test.eq('registration: from the renewal month, the end of this month, due soon', (test.mti('mt_block', 'registration')).expires_source || '/' || (test.mti('mt_block', 'registration')).status
  || '/' || ((test.mti('mt_block', 'registration')).expires_on = (date_trunc('month', app.today()) + interval '1 month - 1 day')::date), 'renewal_month/due_soon/true');
select test.eq('registration: a renewal month alone never blocks the handover', app.maint_handover_block(test.mtv('mt_block')), null::text);
-- a recorded safety inspection that has expired blocks the handover
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'done_on', app.today() - 400, 'items',
  jsonb_build_array(jsonb_build_object('code', 'safety_certificate', 'expires_on', app.today() - 35)), 'payer', 'none'));
select test.eq('block: the safety inspection expired', (test.mti('mt_block', 'safety_certificate')).status, 'overdue');
select test.throws('block: handover refused while it has expired, with what to do',
  format('update bookings set status = ''on_rent'', handed_over_at = now() where id = %L', test.id('booking:MT-3')),
  'Do not release the car: Safety inspection or certificate expired on');
select app.maint_tasks(test.mtv('mt_block'));
select test.eq('block: the car''s task is urgent', (select priority from tasks where task_type = 'maintenance_due' and vehicle_id = test.mtv('mt_block') and status = 'open'), 'urgent');
select test.mtdo('mt_fleet', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'items', jsonb_build_array('safety_certificate'), 'payer', 'none'));
select test.eq('block: the new inspection is valid 12 months; the block is gone', (test.mti('mt_block', 'safety_certificate')).expires_on || '/' || coalesce(app.maint_handover_block(test.mtv('mt_block')), 'free'),
  (app.today() + interval '12 months')::date::text || '/free');
-- new bookings: off by default; an Admin turns it on for an item
select test.mtdo('mt_admin', 'maint_record', jsonb_build_object('vehicle_id', test.mtv('mt_block'), 'done_on', app.today() - interval '2 years', 'items', jsonb_build_array('annual_inspection'), 'payer', 'none'));
select test.lives('booking block: off by default, an overdue item does not stop a booking',
  $$select test.mk_booking('MT-4', 'mt_block', 'mt_rita', to_char(now() + interval '20 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '22 days', 'YYYY-MM-DD 10:00'), 'requested')$$);
select test.mtdo('mt_admin', 'maint_item_save', jsonb_build_object('code', 'annual_inspection', 'block_bookings_when_overdue', true));
select test.throws('booking block: on, a new booking on the car is refused, with what to do',
  $$select test.mk_booking('MT-5', 'mt_block', 'mt_rita', to_char(now() + interval '30 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '32 days', 'YYYY-MM-DD 10:00'), 'requested')$$,
  'This car takes no new bookings until its overdue service is done and recorded (Annual inspection');
select test.lives('booking block: a past rental recorded by hand is not stopped',
  $$select test.mk_booking('MT-6', 'mt_block', 'mt_rita', '2026-09-01 10:00', '2026-09-03 10:00', 'closed')$$);
select test.mtdo('mt_admin', 'maint_item_save', jsonb_build_object('code', 'annual_inspection', 'block_bookings_when_overdue', false));

-- ================================================================ 12. who may do what
select test.ok('read: Fleet and Finance read the overview', (test.mtread('mt_fleet', 'maint_overview') -> 'cars') is not null and (test.mtread('mt_fin', 'maint_overview') -> 'cars') is not null);
select test.throws('read: customer service does not', $$select test.mtread('mt_cs', 'maint_overview')$$, 'Only an Admin, Fleet or Finance');
select test.throws('record: customer service does not', format($$select test.mtdo('mt_cs', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('fluids'))),
  'Only an Admin, Fleet or Finance');
select test.ok('owner: reads the history of their car', jsonb_array_length(test.mtread('mt_olga', 'maint_owner', jsonb_build_object('vehicle_id', test.mtv('mt_car'))) -> 'records') > 0);
select test.ok('owner: sees what was billed to them, not CarmaCars'' costs',
  (select bool_and((r ->> 'paid_by') <> 'Deducted on your statement' or (r ->> 'billed_to_you_cents') is not null) and bool_and((r ->> 'paid_by') <> 'CarmaCars' or (r ->> 'billed_to_you_cents') is null)
     from jsonb_array_elements(test.mtread('mt_olga', 'maint_owner', jsonb_build_object('vehicle_id', test.mtv('mt_car'))) -> 'records') r));
select test.throws('owner: not another owner''s car', format($$select test.mtread('mt_other', 'maint_owner', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'))), 'Not permitted');
select test.throws('owner: cannot record', format($$select test.mtdo('mt_olga', 'maint_record', %L)$$, jsonb_build_object('vehicle_id', test.mtv('mt_car'), 'items', jsonb_build_array('fluids'))),
  'Only an Admin, Fleet or Finance');
select test.throws('void: an assistant cannot void a billed service', format($$select test.mtdo('mt_fleet', 'maint_void', %L)$$,
  jsonb_build_object('id', (select id from vehicle_service_records where shop = 'Quick Lube'), 'reason', 'x')), 'Only an Admin voids a service that is billed');
select test.throws('tables: closed to the API roles', 'set local role authenticated; select count(*) from vehicle_service_records', 'permission denied');
reset role;
select test.ok('functions: the maintenance functions are the server''s only', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname like 'maint\_%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))));

-- ================================================================ 13. the screens' reads, To do and the digest
select test.ok('overview: most urgent first', (select (test.mtread('mt_admin', 'maint_overview') -> 'cars' -> 0 ->> 'rank')::integer = 0));
select test.ok('overview: each car with its chips, odometer and km a day',
  (select c ? 'chips' and c ? 'current_km' and c ? 'km_per_day' from jsonb_array_elements(test.mtread('mt_admin', 'maint_overview') -> 'cars') c where c ->> 'vehicle_id' = test.mtv('mt_car')::text));
select test.ok('car: items, tire sets, history, readings, who may pay',
  (select x ? 'items' and x ? 'tire_sets' and x ? 'records' and x ? 'readings' and jsonb_array_length(x -> 'payers') = 5 from (select test.mtread('mt_fleet', 'maint_vehicle', jsonb_build_object('vehicle_id', test.mtv('mt_car'))) x) z));
select test.eq('To do: the three maintenance lines', (select string_agg(i ->> 'key', ',' order by i ->> 'key') from jsonb_array_elements(app.admin_todo(test.id('mt_admin')) -> 'items') i where i ->> 'key' like 'maintenance%'),
  'maintenance_bill,maintenance_due,maintenance_unknown');
select test.ok('digest: one line for the morning (no other email)', app.maint_digest_line() ->> 'line' like 'Maintenance: % overdue, % due soon');
select app.notify_digests('morning', gen_random_uuid(), now());
select test.eq('digest: in the Admin''s and Fleet''s morning digest, once a day', (select count(*) from staff_digest_items where dedupe_key like 'maint_day:%:' || app.today()), 2::bigint);
select test.ok('digest: no email of its own', not exists (select 1 from app_events where code like '%maint%'));
