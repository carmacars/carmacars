-- 99: bookings search (migration 0200, docs/changes/2026-10-31-bookings-search.md). Fixtures start with "bs".
select test.suite('99 bookings search');
select test.mk_user('bs_admin', 'admin');
select test.mk_user('bs_cs', 'va', 'cs');
select test.mk_owner('bs_o');
select test.mk_vehicle('BSA', 'bs_o');
select test.mk_vehicle('BSB', 'bs_o');
select test.mk_renter('bs_jane_river');
select test.mk_renter('bs_omar_stone');
update renters set mobile = '(647) 555-0142' where id = test.id('renter:bs_omar_stone');
select test.mk_booking('CC-91042', 'BSA', 'bs_jane_river', '2026-08-05 10:00', '2026-08-08 10:00', 'closed');
select test.mk_booking('CC-91043', 'BSB', 'bs_omar_stone', '2026-08-10 10:00', '2026-08-12 10:00', 'closed');
create function test.bs(p_user text, p_q text) returns text language sql as $$
  select coalesce(string_agg(x ->> 'booking_number', ',' order by x ->> 'booking_number'), '')
    from jsonb_array_elements(app.door(test.id(p_user), 'aal2', 'ops_read', 'bookings_search', jsonb_build_object('q', p_q))) x $$;

select test.eq('by the number as written', test.bs('bs_admin', 'CC-91042'), 'CC-91042');
select test.eq('by the number without the dash, lower case', test.bs('bs_admin', 'cc91042'), 'CC-91042');
select test.eq('by the digits alone', test.bs('bs_admin', '9104'), 'CC-91042,CC-91043');
select test.eq('by the renter''s name, any case', test.bs('bs_cs', 'JANE riv'), 'CC-91042');
select test.eq('by email', test.bs('bs_cs', 'bs_omar_stone@example'), 'CC-91043');
select test.eq('by phone in another format', test.bs('bs_cs', '647.555.0142'), 'CC-91043');
select test.eq('by plate with spaces', test.bs('bs_admin', (select substr(plate, 1, 3) || ' ' || substr(plate, 4) from vehicles where id = test.id('vehicle:BSB'))), 'CC-91043');
select test.eq('by car code', test.bs('bs_admin', (select car_code from vehicles where id = test.id('vehicle:BSA'))), 'CC-91042');
select test.eq('what matched is said', (app.door(test.id('bs_admin'), 'aal2', 'ops_read', 'bookings_search', '{"q": "647 555 0142"}') -> 0 ->> 'matched'), 'phone');
select test.eq('a status narrows it', (select jsonb_array_length(app.door(test.id('bs_admin'), 'aal2', 'ops_read', 'bookings_search', '{"q": "9104", "status": "cancelled"}'))), 0);
select test.eq('one character finds nothing', test.bs('bs_admin', 'C'), '');
select test.throws('a renter may not search', $$select app.door(test.id('bs_jane_river'), 'aal2', 'ops_read', 'bookings_search', '{"q": "CC-91042"}')$$, 'Only staff');
select test.eq('staff searches are logged', (select count(*) > 0 from data_access_log where user_id = test.id('bs_cs') and query = 'bookings: JANE riv'), true);
select test.eq('an Admin sees the email', app.door(test.id('bs_admin'), 'aal2', 'ops_read', 'bookings_search', '{"q": "CC-91042"}') -> 0 ->> 'renter_email', 'bs_jane_river@example.test');
select test.eq('staff: no email in the results', app.door(test.id('bs_cs'), 'aal2', 'ops_read', 'bookings_search', '{"q": "CC-91042"}') -> 0 ->> 'renter_email', null);
