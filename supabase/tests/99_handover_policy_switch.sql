-- 99: migration 0683: the insurer gate on handovers (0078) is a Program setting, off by default. Off, a car not on the
-- fleet policy is handed over; on, it is refused as before; the staff warning stays either way. Fixtures start with "hps".
select test.suite('99 handover policy switch (0683)');

create temp table hps_prev as select field_handover_requires_fleet_policy as v from app.settings();
update program_settings set field_handover_requires_fleet_policy = false where id = (select id from app.settings());

select test.mk_user('hps_fleet', 'va', 'fleet');
select test.mk_owner('hps_own');
select test.mk_renter('hps_rita');
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:HPS1'), test.id('owner:hps_own'), 2025, 'Hyundai', 'Elantra HPS', null, 'HPS1AAA', 'standard', 'onboarding', 'managed', 'transfer'),
       (test.id('vehicle:HPS2'), test.id('owner:hps_own'), 2026, 'Hyundai', 'Palisade HPS', null, 'HPS2AAA', 'standard', 'onboarding', 'managed', 'transfer');
select test.ok('neither car is on the fleet policy', not app.vehicle_on_policy(test.id('vehicle:HPS1')) and not app.vehicle_on_policy(test.id('vehicle:HPS2')));

select test.mk_booking('HPS-1', 'HPS1', 'hps_rita', '2031-04-02 10:00', '2031-04-05 10:00', 'confirmed');
update bookings set status = 'on_rent', handed_over_at = now() where id = test.id('booking:HPS-1');
select test.eq('setting off: the car is handed over', (select status::text from bookings where id = test.id('booking:HPS-1')), 'on_rent');
select test.ok('the staff warning stays', (app.listing_state(test.id('hps_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:HPS1'))) ->> 'handover_note') like 'Not on the fleet insurance policy yet%');

update program_settings set field_handover_requires_fleet_policy = true where id = (select id from app.settings());
select test.mk_booking('HPS-2', 'HPS2', 'hps_rita', '2031-04-02 10:00', '2031-04-05 10:00', 'confirmed');
select test.throws('setting on: refused as before (0078)',
  $$update bookings set status = 'on_rent', handed_over_at = now() where id = test.id('booking:HPS-2')$$, '%not on the fleet insurance policy%');

update program_settings set field_handover_requires_fleet_policy = (select v from hps_prev) where id = (select id from app.settings());
