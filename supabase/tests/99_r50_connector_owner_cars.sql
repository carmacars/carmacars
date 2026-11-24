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
    'onboarding_method', 'transfer', 'title_status', 'owned', 'fleet_transfer', '{"registered_to": "corporation"}'::jsonb)))), test.id('q50_web')) as r;
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
select test.eq('the car is on the lease at the supplier''s tier', (select string_agg(a.lease_tier, ',') from vehicle_owner_arrangements a where a.owner_id = test.q50owner() and a.cancelled_at is null), 'troubled');
select test.ok('the Fleet Supplier Lease Agreement is made for signing', exists (select 1 from owner_agreements g where g.owner_id = test.q50owner() and g.variant = 'fleet_lease' and g.status <> 'void'));
select test.eq('approved once only', test.q50call('q50-w', 'approve_owner_car', jsonb_build_object('application', (select r ->> 'application_id' from q50_app))) ->> 'error', 'This application is approved already');

-- ================================================================ 2. fleet_lease_car_set
select test.eq('a car already on the lease is refused with the reason',
  test.q50call('q50-w', 'fleet_lease_car_set', '{"vehicle": "Q50A", "tier": "regular"}') ->> 'error', 'This car is on the lease already and its tier is fixed. An Admin corrects a tier entered by mistake');
select test.eq('an unknown car', test.q50call('q50-w', 'fleet_lease_car_set', '{"vehicle": "NOPE50", "tier": "regular"}') ->> 'status', '404');

select test.ok('every call is logged', (select count(*) from api_calls c where c.tool like 'approve_owner_car%' and c.user_id = test.id('q50_admin')) >= 3);
select test.eq('the other tools still go through', test.q50call('q50-r', 'helcim_account', '{}') #>> '{result,run}', 'helcim_account');
