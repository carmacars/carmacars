-- 99: the Admin connector approves an owner's cars and puts a fleet supplier's car on the lease (migration 3730, release 50).
-- approve_owner_car previews the plan, then approves through the door as the application page does (a fleet supplier's cars
-- go on the lease at their tier, the Fleet Supplier Lease Agreement and the forms made); fleet_lease_car_set previews and
-- sets. Admins only, admin:write for the writes. Fixtures "q50".
select test.suite('99 r50 connector owner cars');
select set_config('app.paper_fixture', 'on', false);
select test.mk_user('q50_admin', 'admin');
select test.mk_user('q50_fin', 'va', 'finance');
insert into users (id, email, full_name) values (test.id('q50_web'), 'q50-north@example.test', 'Nia Example');
create function test.q50owner() returns uuid language sql stable as $$ select id from owners where email = 'q50-north@example.test' $$;
create function test.q50call(p_key text, p_tool text, p jsonb) returns jsonb language sql as $$ select app.api_call(encode(sha256(p_key::bytea), 'hex'), p_tool, p) $$;
create temp table q50_app as select app.submit_owner_application(jsonb_build_object('source', 'web', 'owner', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation',
    'legal_name', 'Nia Example', 'first_name', 'Nia', 'last_name', 'Example', 'corporation_name', 'Q50 Holdings Ltd.', 'corporation_number', '1000050', 'signing_officer_name', 'Nia Example',
    'signing_officer_title', 'Director', 'address_line1', '5 Example Way', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5V 1A1', 'country', 'CA', 'email', 'q50-north@example.test', 'phone', '+16475550150'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', '1HGCM82633A150001', 'plate', 'Q50A', 'year', 2021, 'make', 'Toyota', 'model', 'Camry', 'colour', 'Grey', 'lease_tier', 'troubled',
    'onboarding_method', 'transfer', 'title_status', 'owned', 'fleet_transfer', '{"registered_to": "corporation"}'::jsonb))), test.id('q50_web')) as r;
grant select on q50_app to public;
select app.api_key_create(test.id('q50_admin'), test.id('q50_admin'), 'q50 write', array['admin:read', 'admin:write'], encode(sha256('q50-w'::bytea), 'hex'), 'cc_live_q5w_');
select app.api_key_create(test.id('q50_admin'), test.id('q50_admin'), 'q50 read', array['admin:read'], encode(sha256('q50-r'::bytea), 'hex'), 'cc_live_q5r_');

-- ================================================================ 1. approve_owner_car
select test.eq('a read-only key cannot approve', test.q50call('q50-r', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app))) ->> 'status', '403');
select test.eq('the application is required', test.q50call('q50-w', 'approve_owner_car', '{}') ->> 'error', 'application: the owner''s application id (the page /admin/applications/<id>)');
create temp table q50_pv as select test.q50call('q50-w', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app))) -> 'result' as r;
select test.eq('previewed: the plan with the supplier''s tier, nothing changed',
  (select (r ->> 'preview') || '/' || (r #>> '{plan,cars,0,lease_tier}') || '/' || (r ->> 'will_do' like '%Fleet Supplier Lease Agreement%')::text from q50_pv), 'true/troubled/true');
select test.eq('nothing approved by the preview', (select count(*) from vehicle_owner_arrangements a where a.owner_id = test.q50owner()), 0::bigint);
select test.eq('a confirm with other arguments is refused',
  test.q50call('q50-w', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app), 'cars', '[]'::jsonb, 'confirm', true, 'preview_id', (select r ->> 'preview_id' from q50_pv))) ->> 'error',
  'The arguments differ from the preview: preview again with these');
select test.eq('confirmed: approved, the set-up email is left to the web layer',
  test.q50call('q50-w', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app), 'confirm', true, 'preview_id', (select r ->> 'preview_id' from q50_pv))) #>> '{result,run}', 'owner_setup');
-- sign first (3800): the approval waits for the owner's signatures, then goes through by itself
select test.eq('sign first: nothing on the lease before the owner signs', (select count(*) from vehicle_owner_arrangements a where a.owner_id = test.q50owner() and a.cancelled_at is null), 0::bigint);
update owner_agreements set status = 'signed', agreement_date = app.today() where owner_id = test.q50owner() and status in ('draft', 'sent');
update vehicle_schedules s set signed_at = now() from vehicles v where v.id = s.vehicle_id and v.owner_id = test.q50owner() and s.signed_at is null and s.superseded_by is null;
select test.eq('the car is on the lease at the supplier''s tier', (select string_agg(a.lease_tier, ',') from vehicle_owner_arrangements a where a.owner_id = test.q50owner() and a.cancelled_at is null), 'troubled');
select test.ok('the Fleet Supplier Lease Agreement is made for signing', exists (select 1 from owner_agreements g where g.owner_id = test.q50owner() and g.variant = 'fleet_lease' and g.status <> 'void'));
select test.eq('approved once only', test.q50call('q50-w', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app))) ->> 'error', 'This application is approved already');

-- ================================================================ 2. fleet_lease_car_set
select test.eq('a car already on the lease is refused with the reason',
  test.q50call('q50-w', 'fleet_lease_car_set', '{"vehicle": "Q50A", "tier": "regular"}') ->> 'error', 'This car is on the lease already and its tier is fixed. An Admin corrects a tier entered by mistake');
select test.eq('an unknown car', test.q50call('q50-w', 'fleet_lease_car_set', '{"vehicle": "NOPE50", "tier": "regular"}') ->> 'status', '404');

-- ================================================================ 3. add_car (3740): the Add a car path, from the VIN
select test.mk_owner('q50_p');
insert into vin_decodes (vin, provider, ok, raw, year, make, model, trim) values ('5YJ3E1EA0PF500001', 'fake', true, '{}', 2023, 'Tesla', 'Model 3', 'Long Range'),
  ('5YJ3E1EA2PF500002', 'fake', true, '{}', 2023, 'Tesla', 'Model 3', null);
select test.eq('a wrong check digit is refused', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5YJ3E1EA9PF500001')) ->> 'error',
  'The VIN''s check digit (the 9th character) does not match: check the VIN for a typo');
select test.eq('a VIN that is not one', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', 'ABC')) ->> 'error', 'vin: 17 letters and digits, never I, O or Q');
select test.eq('an undecoded VIN needs the year, make and model', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5YJ3E1EA4PF500003')) ->> 'error',
  'The year, make and model could not be read from this VIN: give year, make and model');
select test.eq('a fleet supplier''s car needs its tier', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.q50owner(), 'vin', '5YJ3E1EA2PF500002')) ->> 'error',
  'tier: a fleet supplier''s car needs its tier, regular or troubled');
create temp table q50_ac as select test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5yj3e1ea0pf500001', 'plate', 'q50car', 'colour', 'White', 'odometer_km', 12000)) -> 'result' as r;
grant select on q50_ac to public;
select test.eq('previewed from the decode, the given details kept, nothing made',
  (select (r ->> 'preview') || '/' || (r #>> '{car,year}') || ' ' || (r #>> '{car,make}') || ' ' || (r #>> '{car,model}') || ' ' || (r #>> '{car,trim}') || '/' || (r #>> '{car,plate}') || '/' || (r ->> 'decoded_from_vin') from q50_ac)
  || '/' || (select count(*) from vehicles where vin = '5YJ3E1EA0PF500001'), 'true/2023 Tesla Model 3 Long Range/Q50CAR/true/0');
select test.eq('confirmed: added through the Add a car path',
  test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5yj3e1ea0pf500001', 'plate', 'q50car', 'colour', 'White', 'odometer_km', 12000,
    'confirm', true, 'preview_id', (select r ->> 'preview_id' from q50_ac))) #>> '{result,run}', 'car_added');
select test.eq('the car is the owner''s, in onboarding, with its plate',
  (select (v.owner_id = test.id('owner:q50_p'))::text || '/' || v.plate || '/' || (exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = v.id))::text from vehicles v where v.vin = '5YJ3E1EA0PF500001'), 'true/Q50CAR/true');
select test.eq('a duplicate is refused', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5YJ3E1EA0PF500001')) ->> 'status', '409');
select test.eq('the company fleet: previewed for its owner', test.q50call('q50-w', 'add_car', jsonb_build_object('owner', (select id from owners where kind = 'company'), 'vin', '5YJ3E1EA2PF500002')) #>> '{result,preview}', 'true');
select test.eq('a read-only key cannot add', test.q50call('q50-r', 'add_car', jsonb_build_object('owner', test.id('owner:q50_p'), 'vin', '5YJ3E1EA2PF500002')) ->> 'status', '403');

select test.ok('every call is logged', (select count(*) from api_calls c where c.tool like 'approve_owner_car%' and c.user_id = test.id('q50_admin')) >= 3);
select test.eq('the other tools still go through', test.q50call('q50-r', 'helcim_account', '{}') #>> '{result,run}', 'helcim_account');
