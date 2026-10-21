-- 49: listing with no roadblocks (migration 0070). Only the basics keep a car off the site; everything else is a
-- checklist item; Publish now with default rates; new cars published automatically (on by default); a car added by its
-- plate; the public view with cars in onboarding; enrollment keeping a published car available; the handover refused
-- before the fleet policy; photos with an unchecked plate kept private (never an example car's); a deleted car's unsent
-- events closed. Fixtures start with "nr".
select test.suite('49 listing without roadblocks');

-- the earlier suites run with automatic publishing off (helpers.sql): on here, as in production
update program_settings set listing_publish_new_cars_automatically = true;
select test.mk_user('nr_admin', 'admin');
select test.mk_user('nr_fleet', 'va', 'fleet');
select test.mk_user('nr_fin', 'va', 'finance');
select test.mk_owner('nr_own');
select test.mk_renter('nr_rita');

-- ================================================================ 1. the basics, the checklist
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:NR1'), test.id('owner:nr_own'), 2021, 'Kia', 'Forte NR', null, 'NR1AAA', 'standard', 'onboarding', 'managed', 'transfer');
select test.eq('a car in onboarding with no VIN, no rates, no listing: only the rates are missing',
  (select string_agg(m ->> 'code', ',') from jsonb_array_elements(app.listing_basics_missing(test.id('vehicle:NR1'))) m), 'rates');
select test.ok('the checklist: not on the fleet policy (a handover item), no VIN, sample photos, plain text',
  (select bool_or(x ->> 'code' = 'insurance' and x ->> 'kind' = 'handover') and bool_or(x ->> 'code' = 'vin') and bool_or(x ->> 'code' = 'photos') and bool_or(x ->> 'code' = 'copy')
     from jsonb_array_elements(app.listing_checklist(test.id('vehicle:NR1'))) x));
select test.throws('a car with neither plate nor VIN is refused', $$update vehicles set plate = null where id = test.id('vehicle:NR1')$$, '%plate_or_vin%');
select test.throws('finance does not publish', $$select app.listing_publish_now(test.id('nr_fin'), jsonb_build_object('vehicle_id', test.id('vehicle:NR1')))$$, '%publishes a car%');

-- ================================================================ 2. Publish now: default rates, template text
create temp table nr_pub as select app.listing_publish_now(test.id('nr_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:NR1'))) r;
grant all on nr_pub to public;
select test.eq('fleet publishes it in one click', (select r ->> 'status' from nr_pub), 'published');
select test.ok('the default rates are set and said', (select (r -> 'default_rates' ->> 'daily_cents')::bigint > 0 from nr_pub)
  and exists (select 1 from rate_cards r where r.vehicle_id = test.id('vehicle:NR1') and r.effective_to is null and r.daily_rate_cents > 0 and r.monthly_rate_cents > 0));
select test.ok('a template text stands in for the AI copy', exists (select 1 from vehicle_listings l where l.vehicle_id = test.id('vehicle:NR1') and nullif(btrim(l.headline), '') is not null));
select test.ok('on the site while its onboarding is open', exists (select 1 from public_vehicle_listings p where p.vehicle_id = test.id('vehicle:NR1')));
select test.eq('still in onboarding', (select status::text from vehicles where id = test.id('vehicle:NR1')), 'onboarding');
select test.eq('no gates left', app.vehicle_public_gates(test.id('vehicle:NR1')), '[]'::jsonb);
select test.ok('the owner''s "live" email waits for the enrollment',
  not exists (select 1 from app_events where code = 'owner_vehicle_listed' and entity_id = test.id('vehicle:NR1')));

-- ================================================================ 3. the handover waits for the fleet policy
select test.mk_booking('NR-1', 'NR1', 'nr_rita', '2031-03-02 10:00', '2031-03-05 10:00', 'confirmed');
select test.throws('the car is not handed over before it is on the fleet policy',
  $$update bookings set status = 'on_rent', handed_over_at = now() where id = test.id('booking:NR-1')$$, '%not on the fleet insurance policy%');
select test.ok('staff see the warning on the booking''s car', (app.listing_state(test.id('nr_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:NR1'))) ->> 'handover_note') like 'Not on the fleet insurance policy yet%');
-- enrollment of a published car: available, and the owner hears it is live
update vehicles set status = 'ready_to_list' where id = test.id('vehicle:NR1');
select test.eq('enrolled while published: available at once', (select status::text from vehicles where id = test.id('vehicle:NR1')), 'available');
select test.ok('the owner''s "live" email at the enrollment', exists (select 1 from app_events where code = 'owner_vehicle_listed' and entity_id = test.id('vehicle:NR1')));
select test.ok('on the policy now', app.vehicle_on_policy(test.id('vehicle:NR1')));

-- ================================================================ 4. new cars published automatically
create temp table nr_add as select app.vehicle_add(test.id('nr_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'NR4BBB',
  'year', 2024, 'make', 'Toyota', 'model', 'Camry NR', 'rates', jsonb_build_object('daily', 7900))) r;
grant all on nr_add to public;
select test.ok('Add a car by its plate, with rates: published at once', (select (r #>> '{listing,published}')::boolean from nr_add) and exists (select 1 from public_vehicle_listings p where p.vehicle_id = (select (r ->> 'vehicle_id')::uuid from nr_add)));
update program_settings set listing_publish_new_cars_automatically = false;
create temp table nr_add2 as select app.vehicle_add(test.id('nr_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'NR5CCC',
  'year', 2024, 'make', 'Toyota', 'model', 'Corolla NR', 'rates', jsonb_build_object('daily', 6900))) r;
grant all on nr_add2 to public;
select test.eq('with the setting off it waits for Publish now', (select (r #>> '{listing,published}')::boolean from nr_add2), false);
update program_settings set listing_publish_new_cars_automatically = true;

-- ================================================================ 5. the states that keep a car off
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:NR3'), test.id('owner:nr_own'), 2020, 'Kia', '', 'NR3KIAFORTE000003', 'NR3AAA', 'standard', 'onboarding', 'managed', 'transfer');
select test.throws('without its model a car is not published', $$select app.listing_publish_now(test.id('nr_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:NR3')))$$, '%Year, make and model%');

-- ================================================================ 6. photos: an unchecked plate stays private, never an example car's
update program_settings set listing_plate_check_required = true;
insert into vehicle_photos (vehicle_id, shot_type, angle, status, processed_path, original_path, is_public, sort_order, plate_status)
values (test.id('vehicle:NR1'), 'front', 'front', 'approved', 'vehicles/nr1/front.jpg', 'vehicles/nr1/front-o.jpg', true, 1, 'unchecked');
select test.ok('a real photo with an unchecked plate stays private', not (select is_public from vehicle_photos where vehicle_id = test.id('vehicle:NR1') and shot_type = 'front'));
update vehicle_photos set plate_status = 'not_visible', plate_checked_by = test.id('nr_admin') where vehicle_id = test.id('vehicle:NR1') and shot_type = 'front';
select test.ok('once checked it goes public by itself', (select is_public from vehicle_photos where vehicle_id = test.id('vehicle:NR1') and shot_type = 'front'));
update vehicles set is_sample = true where id = test.id('vehicle:NR3');
insert into vehicle_photos (vehicle_id, shot_type, angle, status, processed_path, original_path, is_public, sort_order, plate_status)
values (test.id('vehicle:NR3'), 'front', 'front', 'approved', '/sample-photos/cars/x.svg', '/sample-photos/cars/x.svg', true, 1, 'unchecked');
select test.ok('an example car''s sample picture is never held back', (select is_public from vehicle_photos where vehicle_id = test.id('vehicle:NR3') and shot_type = 'front'));
update program_settings set listing_plate_check_required = false;

-- ================================================================ 7. a car deleted before its events are sent
select app.emit_event('owner_vehicle_listed', 'vehicle', (select (r ->> 'vehicle_id')::uuid from nr_add2), '{}'::jsonb, 'nr-del-test');
select app.vehicle_delete(test.id('nr_admin'), jsonb_build_object('vehicle_id', (select (r ->> 'vehicle_id')::uuid from nr_add2), 'confirm', 'NR5CCC'));
select test.ok('its unsent events are closed, so the outbox batch goes on',
  (select processed_at is not null from app_events where dedupe_key = 'nr-del-test'));

update program_settings set listing_publish_new_cars_automatically = false;
