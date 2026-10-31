-- 99: a booking message is texted once (migration 0270). Fixtures start with "ndt".
select test.suite('99 no double texts');
create table test.ndt_phone as select id, phone_enabled from program_settings;
update program_settings set phone_enabled = true;
select test.mk_owner('ndt_owner');
select test.mk_vehicle('ndt_car', 'ndt_owner');
select test.mk_renter('ndt_rita');
select test.mk_booking('NDT-1', 'ndt_car', 'ndt_rita', '2026-12-01 10:00', '2026-12-03 10:00', 'offered', 20000);
select test.eq('a first booking text goes', (select status from app.phone_outbox_put('+14165550199', 'CarmaCars: your offer is ready https://carmacars.ca/account/bookings/NDT-1/offer', 'booking', test.id('booking:NDT-1')) p) <> 'skipped', true);
select test.eq('the same words to the same number minutes later are skipped',
  (select status from app.phone_outbox_put('+14165550199', 'CarmaCars: your offer is ready https://carmacars.ca/account/bookings/NDT-1/offer?m=11111111-2222-3333-4444-555555555555', 'booking', test.id('booking:NDT-1')) p), 'skipped');
select test.eq('different words still go',
  (select status from app.phone_outbox_put('+14165550199', 'CarmaCars: your rental agreement is ready to sign', 'booking', test.id('booking:NDT-1')) p) <> 'skipped', true);
update program_settings p set phone_enabled = n.phone_enabled from test.ndt_phone n where n.id = p.id;
