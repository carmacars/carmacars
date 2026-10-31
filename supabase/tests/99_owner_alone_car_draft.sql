-- 99: an owner added on their own, and a car before its VIN or plate (migration 0264). Fixtures start with "oa".
select test.suite('99 owner alone, car draft');
select test.mk_user('oal_admin', 'admin');
select test.mk_user('oal_cs', 'va', 'cs');
select test.mk_user('oal_sales', 'va', 'sales');
create table test.oa (k text primary key, v jsonb);
create function test.oav(p text) returns jsonb language sql stable as $$ select v from test.oa where k = p $$;
create function test.oal_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;

-- ================================================================ 1. the owner on their own
select test.throws('sales do not add owners', $$select test.oal_do('oal_sales', 'owner_add', '{"legal_name": "Ann Alone", "email": "ann.alone@example.test"}')$$, 'Only an Admin');
select test.throws('the name is needed', $$select test.oal_do('oal_cs', 'owner_add', '{"email": "x@example.test"}')$$, 'legal name');
select test.throws('a corporation needs its name', $$select test.oal_do('oal_cs', 'owner_add', '{"legal_name": "Ann Alone", "email": "ann.corp@example.test", "owner_type": "corporation"}')$$, 'corporation');
select test.throws('customer service sets no terms', $$select test.oal_do('oal_cs', 'owner_add', '{"legal_name": "Ann Alone", "email": "ann.terms@example.test", "terms": {"revenue_share_bps": 7000}}')$$, 'Only an Admin');
insert into test.oa select 'o1', test.oal_do('oal_admin', 'owner_add', '{"legal_name": "Ann Alone", "email": "Ann.Alone@example.test", "phone": "416 555 0177", "owner_type": "individual",
  "terms": {"insurance_fee_cents": 45000, "tracker_fee_cents": 2500, "revenue_share_bps": 7000}}');
select test.ok('the owner is on file, without a car', exists (select 1 from owners o where o.id = (test.oav('o1') ->> 'owner_id')::uuid and o.email = 'ann.alone@example.test'
  and o.added_alone_at is not null and not exists (select 1 from vehicles v where v.owner_id = o.id)));
select test.ok('the owner''s default terms are kept', exists (select 1 from owner_terms t where t.owner_id = (test.oav('o1') ->> 'owner_id')::uuid and t.vehicle_id is null));
select test.eq('nothing emailed: no event for the owner', (select count(*) from app_events where entity_id = (test.oav('o1') ->> 'owner_id')::uuid or payload ->> 'owner_id' = test.oav('o1') ->> 'owner_id'), 0::bigint);
select test.ok('listed on Owners', exists (select 1 from jsonb_array_elements(app.admin_owner_applications(test.id('oal_admin'))) x where x ->> 'owner_id' = test.oav('o1') ->> 'owner_id'));
select test.throws('the same email twice is refused', $$select test.oal_do('oal_cs', 'owner_add', '{"legal_name": "Ann Again", "email": "ann.alone@example.test"}')$$, 'on file');
select test.ok('audited', exists (select 1 from audit_log where action = 'owner_add' and entity_id = test.oav('o1') ->> 'owner_id'));

-- ================================================================ 2. a car with only its year, make and model
insert into test.oa select 'c1', app.add_owner_vehicle((test.oav('o1') ->> 'owner_id')::uuid,
  '{"year": 2022, "make": "Toyota", "model": "Corolla", "trim": "LE", "colour": "White", "notes": "Owner sends the permit next week"}'::jsonb, test.id('oal_cs'), null);
select test.ok('saved as an onboarding draft with a fleet number and the notes', exists (select 1 from vehicles v where v.id = (test.oav('c1') ->> 'vehicle_id')::uuid
  and v.id_pending and v.status = 'onboarding' and v.fleet_number is not null and v.vin is null and v.plate is null and v.notes like 'Owner sends%'));
select test.ok('To do: VIN or plate needed', exists (select 1 from tasks t where t.vehicle_id = (test.oav('c1') ->> 'vehicle_id')::uuid and t.task_type = 'vehicle_id_needed' and t.status = 'open'));
select test.throws('the owner''s own application still needs the VIN', format($s$select app.add_owner_vehicle(%L, '{"year": 2021, "make": "Honda", "model": "Civic"}'::jsonb, null, null)$s$, test.oav('o1') ->> 'owner_id'), 'VIN');
select test.throws('staff with nothing to go on: refused', format($s$select app.add_owner_vehicle(%L, '{"make": "Honda"}'::jsonb, %L, null)$s$, test.oav('o1') ->> 'owner_id', test.id('oal_cs')), 'year, make and model');
select test.eq('never listed', app.listing_auto_publish((test.oav('c1') ->> 'vehicle_id')::uuid) ->> 'reason', 'VIN or plate needed');
select test.throws('never available', format($s$update vehicles set status = 'available' where id = %L$s$, test.oav('c1') ->> 'vehicle_id'), 'VIN or plate needed');
select test.throws('not put on the fleet policy', format($s$update vehicles set on_fleet_policy = true where id = %L$s$, test.oav('c1') ->> 'vehicle_id'), 'VIN or plate needed');
update vehicles set status = 'ready_to_list' where id = (test.oav('c1') ->> 'vehicle_id')::uuid;
select test.eq('moved on by itself: waits in onboarding', (select status::text from vehicles where id = (test.oav('c1') ->> 'vehicle_id')::uuid), 'onboarding');
select test.mk_renter('oal_r');
select test.throws('never bookable', format($s$insert into bookings (booking_number, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
    deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
  values ('CC-OA1', 'requested', %L, %L, now(), now() + interval '5 days', now() + interval '7 days', now() + interval '7 days', 2, 10000, 10000, 50000, 150000, 'daily', 20000, 200, 400, 35, 50000, 20000, 2600, 22600)$s$,
  test.oav('c1') ->> 'vehicle_id', test.id('renter:oal_r')), 'VIN or plate needed');

-- the notes on the car page; the plate added: a car like any other
select test.eq('notes changed on the car page', test.oal_do('oal_cs', 'vehicle_notes_set', jsonb_build_object('vehicle_id', test.oav('c1') ->> 'vehicle_id', 'notes', 'Permit received')) ->> 'notes', 'Permit received');
select test.throws('a VIN must be 17 characters', format($s$select test.oal_do('oal_cs', 'vehicle_id_set', jsonb_build_object('vehicle_id', %L, 'vin', 'ABC'))$s$, test.oav('c1') ->> 'vehicle_id'), '17 characters');
select test.eq('the plate added: no longer a draft', test.oal_do('oal_cs', 'vehicle_id_set', jsonb_build_object('vehicle_id', test.oav('c1') ->> 'vehicle_id', 'plate', 'oa 1234')) ->> 'id_pending', 'false');
select test.ok('the task closed by itself', not exists (select 1 from tasks t where t.vehicle_id = (test.oav('c1') ->> 'vehicle_id')::uuid and t.task_type = 'vehicle_id_needed' and t.status = 'open'));
select test.throws('the plate cannot be taken away again', format($s$update vehicles set plate = null where id = %L$s$, test.oav('c1') ->> 'vehicle_id'), null);
