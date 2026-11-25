-- 99: "Licence and selfie verified" follows the review screen (migration 3055; docs/changes/2026-11-15-r48-review-readiness.md):
-- a driver whose selfie was approved on an earlier booking and whose licence is approved here is verified, and the
-- readiness ticks. Fixtures start with "x55"; addresses are example.test.
-- (Bookings fall inside the fixture licence, valid to 2030-01-01: since 4730 an approval elsewhere counts only while the licence covers the return.)
select test.suite('99 r48 review readiness');
select test.mk_user('x55_admin', 'admin');
select test.mk_owner('x55_o');
select test.mk_vehicle('X55A', 'x55_o');
select test.mk_renter('x55_r');
select test.mk_booking('CC-X551', 'X55A', 'x55_r', '2029-07-01 10:00', '2029-07-02 10:00', 'closed');
select test.mk_booking('CC-X552', 'X55A', 'x55_r', '2029-08-01 10:00', '2029-08-02 10:00', 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:CC-X551'), test.id('driver:x55_r'), 'renter', 'X55 R', date '1990-05-05', 41, '26_plus'),
       (test.id('booking:CC-X552'), test.id('driver:x55_r'), 'renter', 'X55 R', date '1990-05-05', 41, '26_plus');
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, retention, booking_id)
values (test.id('doc:x55s'), 'face_photo', 'Selfie', 'identity', 'x55/s.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:CC-X551')),
       (test.id('doc:x55f'), 'id_front', 'Licence front', 'identity', 'x55/f.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:CC-X552')),
       (test.id('doc:x55b'), 'id_back', 'Licence back', 'identity', 'x55/b.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:CC-X552'));
-- the selfie approved on the earlier booking
insert into verification_uploads (booking_id, driver_id, kind, document_id, status, reviewed_by, reviewed_at) values (test.id('booking:CC-X551'), test.id('driver:x55_r'), 'selfie', test.id('doc:x55s'), 'approved', test.id('x55_admin'), now());
insert into verification_uploads (id, booking_id, driver_id, kind, document_id)
values (test.id('vu:x55f'), test.id('booking:CC-X552'), test.id('driver:x55_r'), 'licence_front', test.id('doc:x55f')),
       (test.id('vu:x55b'), test.id('booking:CC-X552'), test.id('driver:x55_r'), 'licence_back', test.id('doc:x55b'));
select test.eq('waiting for review: not verified', (app.booking_readiness(test.id('booking:CC-X552')) ->> 'all_drivers_verified'), 'false');
update verification_uploads set status = 'approved', reviewed_by = test.id('x55_admin'), reviewed_at = now() where id = test.id('vu:x55f');
select test.eq('one side approved: not verified yet', (app.booking_readiness(test.id('booking:CC-X552')) ->> 'all_drivers_verified'), 'false');
update verification_uploads set status = 'approved', reviewed_by = test.id('x55_admin'), reviewed_at = now() where id = test.id('vu:x55b');
select test.eq('both sides approved here, the selfie on the earlier booking: verified', (app.booking_readiness(test.id('booking:CC-X552')) ->> 'all_drivers_verified'), 'true');
select test.ok('the review screen reads the same', (select identity_verified_on is not null from booking_drivers where booking_id = test.id('booking:CC-X552')));
select test.eq('one driver: no additional driver to accept', (app.booking_readiness(test.id('booking:CC-X552')) ->> 'additional_drivers_accepted'), 'true');
-- a rejected image on this booking keeps the driver unverified
update booking_drivers set identity_verified_on = null where booking_id = test.id('booking:CC-X552');
update verification_uploads set status = 'rejected', reviewed_by = test.id('x55_admin'), reject_reason = 'Blurry photo' where id = test.id('vu:x55b');
select test.eq('a rejected side here: not verified', app.booking_driver_verify_sync(test.id('booking:CC-X552')), 0);
