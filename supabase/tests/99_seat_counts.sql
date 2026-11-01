-- 99: seats from the VIN or the seat table, never a guess of 5 for an SUV (migration 0350). A 3-row SUV added by its VIN
-- gets 7 or 8 seats and shows under 7+; a car nobody knows the seats of has none, flagged "Seats missing"; a person's
-- value is never changed; the backfill corrects a body default. Fixtures start with "seat"; VINs are made up.
select test.suite('99 seat counts');
select test.mk_user('seat_admin', 'admin');
select test.mk_owner('seat_owner');

-- ---------------------------------------------------------------- the table
select test.eq('table: Yukon XL 8, Yukon XL Denali 7, Palisade SEL 8, Palisade Calligraphy 7, Carnival 8, Sienna XSE 7',
  array[app.seat_count_for('GMC', 'Yukon XL', 'SLT'), app.seat_count_for('GMC', 'Yukon XL', 'Denali'), app.seat_count_for('Hyundai', 'Palisade', 'SEL'),
        app.seat_count_for('Hyundai', 'Palisade', 'Calligraphy'), app.seat_count_for('Kia', 'Carnival', 'LX'), app.seat_count_for('Toyota', 'Sienna', 'XSE')],
  array[8, 7, 8, 7, 8, 7]::smallint[]);
select test.eq('table: a longer model name still matches (Palisade SEL as the model), a car not in it has none',
  array[app.seat_count_for('Hyundai', 'Palisade SEL', null), app.seat_count_for('Lamborghini', 'Urus', null)], array[8, null]::smallint[]);
select test.eq('body: an SUV or a minivan is never a guessed 5', array[app.body_default_seats('Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)'), app.body_default_seats('Minivan')], array[null, null]::integer[]);

-- ---------------------------------------------------------------- a 3-row SUV added by its VIN, the decode without seats
select app.record_vin_decode('KM8R54GE0SU000350', 'fake', '{"ok": true, "year": "2026", "make": "Hyundai", "model": "Palisade", "trim": "SEL", "body_class": "Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)", "fuel": "gasoline", "drivetrain": "AWD/All-Wheel Drive", "transmission": "Automatic, 8 speeds", "doors": "4"}');
create temp table seat_add as select app.vehicle_add(test.id('seat_admin'), jsonb_build_object('supply_type', 'company', 'vin', 'KM8R54GE0SU000350',
  'class', 'suv', 'class_source', 'inferred', 'rates', jsonb_build_object('daily', 14900))) r;
grant all on seat_add to public;
create function test.seat_id() returns uuid language sql stable as $$ select (r ->> 'vehicle_id')::uuid from seat_add $$;
-- on the site (a car added without photos waits as a draft; the fixture publishes it)
update vehicle_listings set status = 'published', first_published_at = coalesce(first_published_at, now()) where vehicle_id = test.seat_id();
select test.eq('VIN add: the Palisade SEL has 8 seats, from the seat table', (select l.seats || '/' || (l.spec_sources #>> '{seats,source}') from vehicle_listings l where l.vehicle_id = test.seat_id()), '8/seat_table');
select test.eq('VIN add: the public row says 8 (the /cars filter, the JSON-LD and the page all read it)', (app.public_listing_row(test.seat_id()) ->> 'seats')::integer, 8);
select test.ok('VIN add: it shows under 7+ seats', exists (select 1 from app.public_fleet('{}'::jsonb) r where (r ->> 'vehicle_id')::uuid = test.seat_id() and (r ->> 'seats')::integer >= 7));

-- a decode that gives the seats wins over the table
select app.record_vin_decode('1GKS2GKD0PR000350', 'fake', '{"ok": true, "year": "2023", "make": "GMC", "model": "Yukon XL", "trim": "Denali", "body_class": "Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)", "fuel": "gasoline", "seats": "8"}');
create temp table seat_add2 as select app.vehicle_add(test.id('seat_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1GKS2GKD0PR000350', 'class', 'suv', 'class_source', 'inferred', 'rates', jsonb_build_object('daily', 17900))) r;
grant all on seat_add2 to public;
select test.eq('VIN add: the decode''s 8 seats win over the table''s 7 for a Denali', (select l.seats || '/' || (l.spec_sources #>> '{seats,source}') from vehicle_listings l where l.vehicle_id = (select (r ->> 'vehicle_id')::uuid from seat_add2)), '8/decoded');

-- ---------------------------------------------------------------- no seats known: empty and flagged, never 5
select app.record_vin_decode('ZPBUA1ZL0RLA00350', 'fake', '{"ok": true, "year": "2024", "make": "Lamborghini", "model": "Urus", "trim": "S", "body_class": "Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)", "fuel": "gasoline"}');
create temp table seat_add3 as select app.vehicle_add(test.id('seat_admin'), jsonb_build_object('supply_type', 'company', 'vin', 'ZPBUA1ZL0RLA00350', 'class', 'luxury', 'class_source', 'inferred', 'rates', jsonb_build_object('daily', 89900))) r;
grant all on seat_add3 to public;
create function test.seat_urus() returns uuid language sql stable as $$ select (r ->> 'vehicle_id')::uuid from seat_add3 $$;
select test.ok('unknown: no seats, never a guessed 5', (select seats is null from vehicle_listings where vehicle_id = test.seat_urus()));
select test.ok('unknown: Admin > Cars flags it Seats missing, and not the Palisade',
  (select bool_and(case (x ->> 'id')::uuid when test.seat_urus() then (x ->> 'seats_missing')::boolean when test.seat_id() then not (x ->> 'seats_missing')::boolean else true end)
     from jsonb_array_elements(app.admin_read(test.id('seat_admin'), 'vehicles', '{}')) x));
select test.ok('unknown: the listing''s checklist says the seats are not shown',
  exists (select 1 from jsonb_array_elements(app.listing_checklist(test.seat_urus())) g where g ->> 'code' = 'details' and g ->> 'label' ilike '%seats%'));

-- ---------------------------------------------------------------- a person's value stays; the backfill corrects a guess
insert into vehicles (id, owner_id, year, make, model, trim, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:seatpal'), test.id('owner:seat_owner'), 2026, 'Hyundai', 'Palisade', 'SEL', 'SCP350', 'suv', 'ready_to_list', 'managed', 'transfer', 'SUV'),
       (test.id('vehicle:seattah'), test.id('owner:seat_owner'), 2022, 'Chevrolet', 'Tahoe', 'LT', 'SCT350', 'suv', 'ready_to_list', 'managed', 'transfer', 'SUV');
select app.ensure_listing(test.id('vehicle:seatpal'));
select app.ensure_listing(test.id('vehicle:seattah'));
-- the Palisade as 0094 left it (the body's 5), the Tahoe typed by a person as 7
update vehicle_listings set seats = 5, spec_sources = coalesce(spec_sources, '{}'::jsonb) || '{"seats": {"source": "body_default"}}' where vehicle_id = test.id('vehicle:seatpal');
update vehicle_listings set seats = 7, spec_sources = coalesce(spec_sources, '{}'::jsonb) || '{"seats": {"source": "person"}}' where vehicle_id = test.id('vehicle:seattah');
select test.eq('backfill: the body''s 5 on a Palisade becomes 8', (app.seats_refresh(test.id('vehicle:seatpal')) ->> 'to')::integer, 8);
select test.ok('backfill: a person''s 7 on a Tahoe is never changed', app.seats_refresh(test.id('vehicle:seattah')) is null
  and (select seats = 7 from vehicle_listings where vehicle_id = test.id('vehicle:seattah')));
-- a later change of trim follows (the table's 7 for the Calligraphy)
update vehicles set trim = 'Calligraphy' where id = test.id('vehicle:seatpal');
select test.eq('trim changed: the seats follow the table', (select seats from vehicle_listings where vehicle_id = test.id('vehicle:seatpal'))::integer, 7);

