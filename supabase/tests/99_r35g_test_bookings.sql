-- r35 gaps, item 3 (owner, 997 and 999): an Admin marks bookings as tests; a car whose only bookings are tests is deleted with them
-- (typed confirmation, audit entry); a real booking still blocks the delete. Fixtures start with "g3".
select test.suite('99 r35g test bookings and deleting a car');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('g3_admin', 'admin');
select test.mk_user('g3_cs', 'va', 'cs');
select test.mk_owner('g3_o');
select test.mk_vehicle('G3A', 'g3_o');
select test.mk_vehicle('G3B', 'g3_o');
select test.mk_vehicle('G3C', 'g3_o');
select test.mk_renter('g3_r', false);
-- G3A: two confirmed, paid bookings (the owner's "two active bookings"); G3B: one test and one real; G3C: nothing marked
select test.mk_booking('G3-1', 'G3A', 'g3_r', '2026-12-02 10:00', '2026-12-04 10:00', 'confirmed', 20000);
select test.mk_booking('G3-2', 'G3A', 'g3_r', '2026-12-10 10:00', '2026-12-12 10:00', 'confirmed', 20000);
select test.mk_booking('G3-3', 'G3B', 'g3_r', '2026-12-02 10:00', '2026-12-04 10:00', 'confirmed', 20000);
select test.mk_booking('G3-4', 'G3B', 'g3_r', '2026-12-10 10:00', '2026-12-12 10:00', 'confirmed', 20000);
select test.mk_booking('G3-5', 'G3C', 'g3_r', '2026-12-02 10:00', '2026-12-04 10:00', 'confirmed', 20000);
update bookings set confirmed_at = now() where booking_number like 'G3-%';

select test.eq('before: confirmed, paid bookings stop the delete',
  (app.vehicle_delete_blockers(test.id('vehicle:G3A')))[1], '2 confirmed or paid bookings (G3-1, G3-2)');

-- who may mark
select test.throws(format($$select app.door(%L, 'aal2', 'ops_do', 'booking_test_set', '{"booking": "G3-1"}')$$, test.id('g3_cs')), 'Only an Admin');
select test.eq('a non-admin did not mark it', (select is_test from bookings where booking_number = 'G3-1'), false);
select test.ok('the Admin marks G3-1 and G3-2 as tests',
  (app.door(test.id('g3_admin'), 'aal2', 'ops_do', 'booking_test_set', '{"booking": "G3-1", "reason": "Test"}') ->> 'is_test')::boolean
  and (app.door(test.id('g3_admin'), 'aal2', 'ops_do', 'booking_test_set', '{"booking": "G3-2"}') ->> 'is_test')::boolean);
select test.ok('the mark is audited and in the booking history',
  exists (select 1 from audit_log a where a.action = 'booking_mark_test' and a.entity_id = test.id('booking:G3-1')::text and a.actor_user_id = test.id('g3_admin'))
  and exists (select 1 from booking_events e where e.booking_id = test.id('booking:G3-1') and e.kind = 'test_mark'));
select test.eq('the booking page carries the mark', (app.admin_booking_detail(test.id('booking:G3-1')) -> 'test' ->> 'on'), 'true');

-- (the fixture car's schedule is made unsigned: a signed schedule is its own, separate block)
update vehicle_schedules set signed_at = null where vehicle_id = test.id('vehicle:G3A');
-- G3A: only test bookings, so nothing blocks it; the typed confirmation is still needed
select test.eq('only test bookings: nothing stops the delete', to_jsonb(app.vehicle_delete_blockers(test.id('vehicle:G3A'))), '[]'::jsonb);
select test.eq('the delete lists the test bookings that go with the car',
  (select string_agg(x ->> 'booking_number' || ':' || (x ->> 'is_test'), ', ' order by x ->> 'booking_number') from jsonb_array_elements(app.vehicle_delete_removes(test.id('vehicle:G3A'))) x),
  'G3-1:true, G3-2:true');
select test.throws(format($$select app.vehicle_delete(%L, %L)$$, test.id('g3_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:G3A'), 'confirm', 'WRONG')), 'Type the plate');
select test.throws(format($$select app.vehicle_delete(%L, %L)$$, test.id('g3_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:G3A'), 'confirm', (select plate from vehicles where id = test.id('vehicle:G3A')))), 'Admin');
select app.vehicle_delete(test.id('g3_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:G3A'), 'confirm', (select plate from vehicles where id = test.id('vehicle:G3A'))));
select test.eq('the car and its test bookings are gone', (select count(*) from vehicles where id = test.id('vehicle:G3A')) || '/' || (select count(*) from bookings where booking_number in ('G3-1', 'G3-2')), '0/0');
select test.ok('the audit entry names the test bookings, and they are archived',
  exists (select 1 from audit_log a where a.action = 'vehicle_delete' and a.entity_id = test.id('vehicle:G3A')::text and a.before -> 'test_bookings' = '["G3-1", "G3-2"]'::jsonb)
  and (select count(*) from deleted_booking_requests where booking_number in ('G3-1', 'G3-2')) = 2);

-- G3B: one real booking left, so it still blocks, naming only the real one
select app.door(test.id('g3_admin'), 'aal2', 'ops_do', 'booking_test_set', '{"booking": "G3-3"}');
select test.eq('a real booking still blocks the delete (the test one is not named)', (app.vehicle_delete_blockers(test.id('vehicle:G3B')))[1], '1 confirmed or paid booking (G3-4)');
select test.throws(format($$select app.vehicle_delete(%L, %L)$$, test.id('g3_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:G3B'), 'confirm', (select plate from vehicles where id = test.id('vehicle:G3B')))), 'cannot be deleted');
-- G3C: never marked, still blocked as before
select test.eq('an unmarked booking blocks as before', (app.vehicle_delete_blockers(test.id('vehicle:G3C')))[1], '1 confirmed or paid booking (G3-5)');
-- unmarking brings the block back
select app.door(test.id('g3_admin'), 'aal2', 'ops_do', 'booking_test_set', '{"booking": "G3-3", "on": false}');
select test.eq('unmarked: it blocks again', (app.vehicle_delete_blockers(test.id('vehicle:G3B')))[1], '2 confirmed or paid bookings (G3-3, G3-4)');
