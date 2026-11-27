-- 99: R50 hotfix 2, Add old photos (migrations 5185 and 5186). Every past booking of the last 60 days, whoever handled it,
-- searchable by plate, car or renter, newest first; a photo attached to the check-in or check-out report "added later" with
-- its capture time, once per upload key; no booking change and no renter or owner notice; the bulk suggestion by time and
-- plate; who may. Fixtures start with "olp". Hotfix review: the capture time only inside the booking's dates, 200 photos a
-- report, photos added later hidden from the renter and the owner, 30 plate reads a person a day.
select test.suite('99 r50h2 add old photos');

select test.mk_user('olp_admin', 'admin');
select test.mk_user('olp_fleet', 'va', 'fleet');
select test.mk_user('olp_cs', 'va', 'cs');
select test.mk_user('olp_sales', 'va', 'sales');
select test.mk_user('olp_field', 'field');
select test.mk_owner('olp_owner');
select test.mk_vehicle('olp_car1', 'olp_owner');
select test.mk_vehicle('olp_car2', 'olp_owner');
select test.mk_renter('olp_renter');
select test.mk_renter('olp_quinn');

create function pg_temp.ago(p interval) returns text language sql as $$ select to_char((now() - p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('OLP-1', 'olp_car1', 'olp_renter', pg_temp.ago('20 days'), pg_temp.ago('17 days'), 'closed');
select test.mk_booking('OLP-2', 'olp_car2', 'olp_quinn', pg_temp.ago('3 days'), pg_temp.ago('-4 days'), 'on_rent');
select test.mk_booking('OLP-3', 'olp_car1', 'olp_renter', pg_temp.ago('90 days'), pg_temp.ago('85 days'), 'closed');
select test.mk_booking('OLP-4', 'olp_car1', 'olp_renter', pg_temp.ago('-5 days'), pg_temp.ago('-8 days'), 'confirmed');
select test.mk_booking('OLP-5', 'olp_car2', 'olp_renter', pg_temp.ago('30 days'), pg_temp.ago('28 days'), 'closed', null, 'owner');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
-- the base files leave many recent bookings (the list shows the newest 60): searched by the fixtures' number prefix
create function pg_temp.nums(p_user text, p_q text default 'OLP-') returns text language sql as $$
  select coalesce(string_agg(x ->> 'booking_number', ',' order by o), '') from jsonb_array_elements(pg_temp.dr(p_user, 'ops_read', 'old_photo_bookings', jsonb_build_object('q', p_q)) -> 'rows') with ordinality t(x, o)
   where x ->> 'booking_number' like 'OLP-%' $$;
create function pg_temp.plate(p_car text) returns text language sql as $$ select plate from vehicles where id = test.id('vehicle:' || p_car) $$;
create function pg_temp.at(p_number text, p_kind text) returns timestamptz language sql as $$
  select app.old_photo_at(b, p_kind) from bookings b where b.id = test.id('booking:' || p_number) $$;

-- ================================================================ 1. the list
select test.eq('list: field staff see every past booking of the window, handled or not, newest first (not too old, not future, not owner use)',
  pg_temp.nums('olp_field'), 'OLP-2,OLP-1');
select test.eq('list: Fleet, customer service and an Admin see the same', pg_temp.nums('olp_fleet') || '/' || pg_temp.nums('olp_cs') || '/' || pg_temp.nums('olp_admin'), 'OLP-2,OLP-1/OLP-2,OLP-1/OLP-2,OLP-1');
select test.eq('list: a car still out offers its check-in only', (select x -> 'kinds' from jsonb_array_elements(pg_temp.dr('olp_field', 'ops_read', 'old_photo_bookings', '{"q": "OLP-2"}') -> 'rows') x
  where x ->> 'booking_number' = 'OLP-2'), '["pickup"]'::jsonb);
select test.eq('list: the window is 60 days', (pg_temp.dr('olp_field', 'ops_read', 'old_photo_bookings') ->> 'days')::int, 60);
select test.eq('search: by plate, any case, with a space', pg_temp.nums('olp_field', lower(substr(pg_temp.plate('olp_car1'), 1, 3) || ' ' || substr(pg_temp.plate('olp_car1'), 4))), 'OLP-1');
select test.eq('search: by renter', pg_temp.nums('olp_field', 'quinn'), 'OLP-2');
select test.eq('search: by car', pg_temp.nums('olp_field', 'C 300 olp_car2'), 'OLP-2');
select test.throws('list: Sales cannot', $$ select pg_temp.dr('olp_sales', 'ops_read', 'old_photo_bookings') $$, '%Admin, Fleet, customer service or field%');
select test.throws('list: a renter cannot', $$ select pg_temp.dr('olp_renter', 'ops_read', 'old_photo_bookings') $$, '%');
update program_settings set old_photos_days = 10 where id = (app.settings()).id;
select test.eq('list: the window follows Program settings', pg_temp.nums('olp_field'), 'OLP-2');
update program_settings set old_photos_days = 60 where id = (app.settings()).id;

-- ================================================================ 2. the gate
select test.throws('gate: the check-out of a car still out', $$ select pg_temp.dr('olp_field', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', test.id('booking:OLP-2'), 'kind', 'return', 'key', gen_random_uuid())) $$, '%no check-out%');
select test.throws('gate: a booking older than the window', $$ select pg_temp.dr('olp_field', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', test.id('booking:OLP-3'), 'kind', 'pickup', 'key', gen_random_uuid())) $$, '%last 60 days%');
select test.throws('gate: check-in or check-out only', $$ select pg_temp.dr('olp_field', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', test.id('booking:OLP-1'), 'kind', 'swap_in', 'key', gen_random_uuid())) $$, '%check-in or the check-out%');
select test.throws('gate: Sales cannot', $$ select pg_temp.dr('olp_sales', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', test.id('booking:OLP-1'), 'kind', 'pickup', 'key', gen_random_uuid())) $$, '%');
select test.eq('gate: a new upload is not a duplicate', pg_temp.dr('olp_field', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', 'OLP-1', 'kind', 'pickup', 'key', test.id('olp_key1'))) ->> 'duplicate', 'false');

-- ================================================================ 3. attach
create temp table olp_before as select (select count(*) from notifications) n, (select count(*) from notification_outbox) o, (select count(*) from booking_events where booking_id = test.id('booking:OLP-1')) e;
create function pg_temp.attach(p_user text, p_key text, p_booking text default 'OLP-1', p_kind text default 'pickup', p_taken text default null, p_path text default null) returns jsonb language sql as $$
  select pg_temp.dr(p_user, 'ops_do', 'old_photo_attach', jsonb_build_object('booking', test.id('booking:' || p_booking), 'kind', p_kind, 'key', test.id(p_key),
    'path', coalesce(p_path, 'bookings/' || test.id('booking:' || p_booking) || '/old/' || test.id(p_key || ':file') || '.jpg'), 'taken_at', p_taken, 'width', 2000, 'height', 1500)) $$;
select test.throws('attach: a path outside this booking''s folder is refused', $$ select pg_temp.attach('olp_field', 'olp_keyx', 'OLP-1', 'pickup', null, 'bookings/' || test.id('booking:OLP-2') || '/old/' || gen_random_uuid() || '.jpg') $$, '%Unexpected path%');
select test.eq('attach: the first photo of a booking with no report', (pg_temp.attach('olp_field', 'olp_key1', 'OLP-1', 'pickup', (pg_temp.at('OLP-1', 'pickup') + interval '7 minutes')::text) ->> 'duplicate'), 'false');
select test.ok('attach: a check-in report is made, waiting for its readings ("Added after the trip")',
  (select c.details_pending and c.completed_at is null and c.recorded_now ->> 'reason' = 'Added after the trip' from condition_reports c where c.booking_id = test.id('booking:OLP-1') and c.kind = 'pickup'));
select test.ok('attach: the photo is marked added later, by the field staff member, with its capture time, as an unchecked angle',
  (select p.added_later_at is not null and p.uploaded_by = test.id('olp_field') and p.device_taken_at = pg_temp.at('OLP-1', 'pickup') + interval '7 minutes'
          and p.taken_at = p.device_taken_at and p.shot = 'other' and p.angle is null and p.width = 2000
     from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:OLP-1') and p.client_key = test.id('olp_key1')));
select test.eq('attach: the same upload sent again (a retry) is attached once', (pg_temp.attach('olp_field', 'olp_key1', 'OLP-1', 'pickup') ->> 'duplicate') || '/' ||
  (select count(*) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.id('booking:OLP-1')), 'true/1');
select test.eq('gate: that upload is now a duplicate', pg_temp.dr('olp_field', 'ops_read', 'old_photo_gate', jsonb_build_object('booking', 'OLP-1', 'kind', 'pickup', 'key', test.id('olp_key1'))) ->> 'duplicate', 'true');
select pg_temp.attach('olp_field', 'olp_key2', 'OLP-1', 'pickup', 'not a time');
select pg_temp.attach('olp_fleet', 'olp_key3', 'OLP-1', 'return', (now() + interval '30 days')::text);
select test.eq('attach: numbered in order on the report', (select string_agg(p.seq::text, ',' order by p.seq) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id
  where c.booking_id = test.id('booking:OLP-1') and c.kind = 'pickup'), '1,2');
select test.ok('attach: no readable time or a time in the future keeps no capture time', (select bool_and(p.device_taken_at is null) from condition_report_photos p where p.client_key in (test.id('olp_key2'), test.id('olp_key3'))));
select test.eq('attach: the booking is not moved', (select status::text from bookings where id = test.id('booking:OLP-1')), 'closed');
select test.ok('attach: no renter or owner notice', (select n = (select count(*) from notifications) and o = (select count(*) from notification_outbox) from olp_before));
select test.eq('attach: the log has the report made and one line per person and side (not one a photo)',
  (select count(*) from booking_events where booking_id = test.id('booking:OLP-1')) - (select e from olp_before), 4::bigint);
select test.throws('attach: Sales cannot', $$ select pg_temp.attach('olp_sales', 'olp_key4') $$, '%');

-- ================================================================ 4. the report
create temp table olp_rep as select app.handover_report(test.id('booking:OLP-1')) r;
select test.eq('report: the check-in and check-out with photos added later show before their readings are done',
  (select string_agg(x ->> 'kind', ',' order by x ->> 'kind') from olp_rep, jsonb_array_elements(r -> 'reports') x), 'pickup,return');
select test.eq('report: each photo says who added it later', (select string_agg(DISTINCT p ->> 'added_later_by', ',') from olp_rep, jsonb_array_elements(r -> 'reports') x, jsonb_array_elements(x -> 'photos') p
  where x ->> 'kind' = 'pickup'), 'Olp Field');
select test.ok('report: the capture time is the photo''s time', (select (p ->> 'taken_at')::timestamptz = pg_temp.at('OLP-1', 'pickup') + interval '7 minutes'
  from olp_rep, jsonb_array_elements(r -> 'reports') x, jsonb_array_elements(x -> 'photos') p where x ->> 'kind' = 'pickup' and (p ->> 'seq')::int = 1));

-- ================================================================ 5. the bulk suggestion
create function pg_temp.sugg(p_user text, p_groups jsonb) returns jsonb language sql as $$ select pg_temp.dr(p_user, 'ops_read', 'old_photo_suggest', jsonb_build_object('groups', p_groups)) -> 'groups' $$;
create temp table olp_s as select pg_temp.sugg('olp_field', jsonb_build_array(
  jsonb_build_object('i', 0, 'from', pg_temp.at('OLP-1', 'pickup') + interval '5 minutes', 'to', pg_temp.at('OLP-1', 'pickup') + interval '25 minutes', 'plate', pg_temp.plate('olp_car1')),
  jsonb_build_object('i', 1, 'from', pg_temp.at('OLP-1', 'pickup'), 'to', pg_temp.at('OLP-1', 'pickup'), 'plate', lower(pg_temp.plate('olp_car2'))),
  jsonb_build_object('i', 2, 'from', pg_temp.at('OLP-2', 'pickup') - interval '2 hours', 'to', pg_temp.at('OLP-2', 'pickup') - interval '1 hour', 'plate', 'ZZ 999'),
  jsonb_build_object('i', 3, 'from', pg_temp.at('OLP-1', 'return') + interval '20 hours', 'to', pg_temp.at('OLP-1', 'return') + interval '20 hours'))) g;
create function pg_temp.first(p_i int) returns jsonb language sql as $$ select x -> 'options' -> 0 from olp_s, jsonb_array_elements(g) x where (x ->> 'i')::int = p_i $$;
select test.eq('suggest: photos near a pickup, that car''s plate read: that check-in, 5 minutes apart', (select (pg_temp.first(0) ->> 'booking_number') || '/' || (pg_temp.first(0) ->> 'kind') || '/' || (pg_temp.first(0) ->> 'minutes_off')), 'OLP-1/pickup/5');
select test.ok('suggest: a plate read limits it to that car (none of its bookings then: no suggestion)', (select (x ->> 'plate_matched')::boolean and jsonb_array_length(x -> 'options') = 0 from olp_s, jsonb_array_elements(g) x where x ->> 'i' = '1'));
-- the base files' bookings may sit nearer in time to these groups: the fixtures' own options are checked
select test.ok('suggest: a plate that matches no car is ignored and the time decides (bookings of any car, within 12 hours)', (select
  not (x ->> 'plate_matched')::boolean and jsonb_array_length(x -> 'options') between 1 and 4
  and not exists (select 1 from jsonb_array_elements(x -> 'options') o where (o ->> 'minutes_off')::numeric > 720)
  from olp_s, jsonb_array_elements(g) x where x ->> 'i' = '2'));
select test.ok('suggest: nothing further than the match hours (12): not the check-out 20 hours before, no option over 12 hours', (select
  not exists (select 1 from jsonb_array_elements(x -> 'options') o where o ->> 'booking_number' = 'OLP-1' or (o ->> 'minutes_off')::numeric > 720)
  from olp_s, jsonb_array_elements(g) x where x ->> 'i' = '3'));
select test.throws('suggest: Sales cannot', $$ select pg_temp.sugg('olp_sales', '[]'::jsonb) $$, '%');

-- ================================================================ 6. the plate read gate
select test.ok('plate gate: field staff may ask (allowed or not by the day''s allowance)', pg_temp.dr('olp_field', 'ops_read', 'old_photo_plate_gate') ? 'allowed');
select test.throws('plate gate: Sales cannot', $$ select pg_temp.dr('olp_sales', 'ops_read', 'old_photo_plate_gate') $$, '%');
select test.lives('plate record: the call is recorded', $$ select pg_temp.dr('olp_field', 'ops_do', 'old_photo_plate_record', '{"model": "fake", "ok": false, "error": "no plate read"}') $$);

-- ================================================================ 7. review fixes: capture time, 200 photos, renter and owner, daily plate cap
-- a phone time 10 days before the pickup (the booking's dates, 3 days either side): kept as the device time, not the capture time
select pg_temp.attach('olp_field', 'olp_key5', 'OLP-1', 'pickup', (pg_temp.at('OLP-1', 'pickup') - interval '10 days')::text);
select test.ok('capture time: a phone time outside the booking''s dates is kept as the device time, not as the capture time',
  (select p.device_taken_at = pg_temp.at('OLP-1', 'pickup') - interval '10 days' and p.taken_at <> p.device_taken_at
     from condition_report_photos p where p.client_key = test.id('olp_key5')));
select test.ok('capture time: the report shows no capture time for it, and shows the accepted one',
  (select bool_or(p ->> 'taken_at' is null) and bool_or(p ->> 'taken_at' is not null)
     from olp_rep, jsonb_array_elements(app.handover_report(test.id('booking:OLP-1')) -> 'reports') x, jsonb_array_elements(x -> 'photos') p where x ->> 'kind' = 'pickup'));
select pg_temp.attach('olp_field', 'olp_key6', 'OLP-1', 'pickup', (pg_temp.at('OLP-1', 'pickup') - interval '2 days')::text);
select test.ok('capture time: 2 days before the pickup is inside the 3 days',
  (select p.taken_at = p.device_taken_at from condition_report_photos p where p.client_key = test.id('olp_key6')));

-- 200 photos a report
insert into condition_report_photos (condition_report_id, seq, shot, storage_path)
select c.id, s.n, 'other', 'bookings/' || c.booking_id || '/old/' || gen_random_uuid() || '.jpg'
  from condition_reports c, lateral (select max(seq) m from condition_report_photos where condition_report_id = c.id) mx, generate_series(mx.m + 1, 200) s(n)
 where c.booking_id = test.id('booking:OLP-1') and c.kind = 'pickup';
select test.throws('200 photos: the 201st is refused', $$ select pg_temp.attach('olp_field', 'olp_key7') $$, '%already has 200 photos%');
select test.eq('200 photos: a retry of a photo already attached still answers as a duplicate', pg_temp.attach('olp_field', 'olp_key1') ->> 'duplicate', 'true');
select test.eq('200 photos: the other side of the booking still takes photos', pg_temp.attach('olp_field', 'olp_key8', 'OLP-1', 'return') ->> 'duplicate', 'false');

-- the renter and the owner never see a photo added later
select test.ok('renter: a report not completed is not shown to the renter, though it shows to staff',
  jsonb_array_length(public.server_renter_handover_report(test.id('booking:OLP-1'), test.id('olp_renter')) -> 'reports') = 0
  and jsonb_array_length(app.handover_report(test.id('booking:OLP-1')) -> 'reports') = 2);
update condition_reports set completed_at = now(), details_pending = false where booking_id = test.id('booking:OLP-1') and kind = 'return';
insert into condition_report_photos (condition_report_id, seq, shot, storage_path, uploaded_by)
select c.id, (select max(seq) + 1 from condition_report_photos where condition_report_id = c.id), 'other', 'bookings/' || c.booking_id || '/front.jpg', test.id('olp_field')
  from condition_reports c where c.booking_id = test.id('booking:OLP-1') and c.kind = 'return';
select test.eq('renter: a completed report shows the renter its own photos only (staff see the photos added later too)',
  (select jsonb_array_length(x -> 'photos') from jsonb_array_elements(public.server_renter_handover_report(test.id('booking:OLP-1'), test.id('olp_renter')) -> 'reports') x where x ->> 'kind' = 'return')::text
  || '/' || (select jsonb_array_length(x -> 'photos') from jsonb_array_elements(app.handover_report(test.id('booking:OLP-1')) -> 'reports') x where x ->> 'kind' = 'return')::text, '1/3');
select test.eq('renter: no report of the renter carries an added-later photo',
  (select count(*) from jsonb_array_elements(public.server_renter_handover_report(test.id('booking:OLP-1'), test.id('olp_renter')) -> 'reports') x, jsonb_array_elements(x -> 'photos') p where p ->> 'added_later_at' is not null), 0::bigint);
update condition_reports set performed_by = test.id('olp_owner') where booking_id = test.id('booking:OLP-1') and kind = 'return';
select test.login(test.id('olp_owner'));
create temp table olp_own as select test.visible('select 1 from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = ''' || test.id('booking:OLP-1') || ''' and c.kind = ''return''') seen;
select test.logout();
select test.login(test.id('olp_admin'));
create temp table olp_adm as select test.visible('select 1 from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = ''' || test.id('booking:OLP-1') || ''' and c.kind = ''return''') seen;
select test.logout();
select test.eq('owner: a report the owner made shows the owner the photo of the report, not the ones added later; an Admin sees both', (select seen from olp_own) || '/' || (select seen from olp_adm), '1/3');

-- 30 plate reads a person a day
select pg_temp.dr('olp_cs', 'ops_do', 'old_photo_plate_record', '{"model": "fake", "ok": true}') from generate_series(1, 30);
select test.ok('plate cap: 30 reads in a day end that person''s day', pg_temp.dr('olp_cs', 'ops_read', 'old_photo_plate_gate') @> '{"allowed": false, "reason": "daily"}');
select test.ok('plate cap: another person is not held by it', pg_temp.dr('olp_fleet', 'ops_read', 'old_photo_plate_gate') ->> 'reason' is distinct from 'daily');
update program_settings set old_photos_plate_daily = 31 where id = (app.settings()).id;
select test.ok('plate cap: the number is a Program setting', pg_temp.dr('olp_cs', 'ops_read', 'old_photo_plate_gate') ->> 'reason' is distinct from 'daily');
update program_settings set old_photos_plate_daily = 30 where id = (app.settings()).id;
