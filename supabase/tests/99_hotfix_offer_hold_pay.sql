-- 99_hotfix_offer_hold_pay: the unpaid hold never ends before the offer's own expiry or, for a pickup within 24 hours,
-- before 2 hours after the pickup; a typed expiry is kept; a reopened offer lasts as long as the original; the licence
-- and OPCF 27 are checked before handover, not payment; paying needs no confirmed account (3420). Fixtures start with "hx".
select test.suite('99 hotfix offer hold pay');
select app.expire_unpaid(now() + interval '1 year', true);

select test.mk_user('hx_cs', 'va', 'cs');
select test.mk_user('hx_admin', 'admin');
select test.mk_owner('hx_own');
select test.mk_vehicle('HXV1', 'hx_own');
select test.mk_vehicle('HXV2', 'hx_own');
select test.mk_vehicle('HXV3', 'hx_own');
select test.mk_renter('hx_ren');
update program_settings set offer_expiry_hours = 12, offer_cutoff_before_pickup_minutes = 60, offer_unpaid_hold_minutes = 120;

create function pg_temp.req(p_number text, p_vehicle text, p_pickup timestamptz, p_days integer) returns uuid language sql as $$
  select test.mk_booking(p_number, p_vehicle, 'hx_ren', to_char(p_pickup at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                         to_char((p_pickup + make_interval(days => p_days)) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested') $$;
create function pg_temp.bk(p text) returns bookings language sql as $$ select * from bookings where booking_number = p $$;

-- ================================================================ 1. defaults
select test.eq('defaults: the licence is not needed before payment',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'booking_licence_before_payment'), 'false');
select test.eq('defaults: OPCF 27 pages are not needed before payment',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'opcf27_before_payment'), 'false');
update program_settings set booking_licence_before_payment = false, opcf27_before_payment = false;

-- ================================================================ 2. the hold
-- a pickup 5 days away, staff typed a 3-day offer: kept as typed, and the hold lasts as long as the offer
select pg_temp.req('HX-1', 'HXV1', date_trunc('hour', now()) + interval '5 days', 2);
update payments set status = 'cancelled' where booking_id in (select id from bookings where booking_number like 'HX-%');
select app.send_offer(test.id('booking:HX-1'), test.id('hx_cs'), null, date_trunc('minute', now()) + interval '3 days');
select test.eq('typed expiry: kept as typed', (pg_temp.bk('HX-1')).offer_expires_at, date_trunc('minute', now()) + interval '3 days');
select app.approve_offer(test.id('booking:HX-1'), 1, test.id('hx_ren'));
select test.eq('hold: until the offer''s own expiry, not 2 hours after accepting',
  app.unpaid_hold_until(pg_temp.bk('HX-1')), date_trunc('minute', now()) + interval '3 days');
update bookings set offer_approved_at = now() - interval '3 hours' where booking_number = 'HX-1';
select test.eq('hold: 3 hours after accepting, still held', app.unpaid_hold_over(pg_temp.bk('HX-1')), false);
select test.ok('hold: the car stays off the site',
  not app.vehicle_is_available(test.id('vehicle:HXV1'), (pg_temp.bk('HX-1')).pickup_at, (pg_temp.bk('HX-1')).return_at, null));
select test.eq('hold: the job ends nothing', app.expire_unpaid(now()), 0);

-- a same-day pickup (5 hours away), Book it now style: held until 2 hours after the pickup
select pg_temp.req('HX-2', 'HXV2', date_trunc('minute', now()) + interval '5 hours', 30);
update payments set status = 'cancelled' where booking_id = test.id('booking:HX-2');
select app.send_offer(test.id('booking:HX-2'), test.id('hx_cs'));
select test.eq('same day: the default offer is open until 2 hours after the pickup',
  (pg_temp.bk('HX-2')).offer_expires_at, (pg_temp.bk('HX-2')).pickup_at + interval '2 hours');
select app.approve_offer(test.id('booking:HX-2'), 1, test.id('hx_ren'));
select test.eq('same day: held until 2 hours after the pickup', app.unpaid_hold_until(pg_temp.bk('HX-2')), (pg_temp.bk('HX-2')).pickup_at + interval '2 hours');
update bookings set offer_approved_at = now() - interval '90 minutes' where booking_number = 'HX-2';
select test.eq('same day: 90 minutes later, not expired', app.expire_unpaid(now()), 0);
select test.eq('same day: still waiting for payment', (pg_temp.bk('HX-2')).status::text, 'pending_payment');
select test.eq('same day: ends after 2 hours past the pickup', app.unpaid_hold_over(pg_temp.bk('HX-2'), (pg_temp.bk('HX-2')).pickup_at + interval '2 hours 1 minute'), true);

-- ================================================================ 3. reopening: as long as the original offer
select pg_temp.req('HX-3', 'HXV3', date_trunc('hour', now()) + interval '10 days', 2);
update payments set status = 'cancelled' where booking_id = test.id('booking:HX-3');
select app.send_offer(test.id('booking:HX-3'), test.id('hx_cs'), null, now() + interval '48 hours');
update booking_offers set sent_at = now() - interval '49 hours', expires_at = now() - interval '1 hour' where booking_id = test.id('booking:HX-3');
update bookings set offer_expires_at = now() - interval '1 hour' where id = test.id('booking:HX-3');
select app.expire_offers(now());
select test.eq('reopen: the offer expired', (pg_temp.bk('HX-3')).status::text, 'expired');
select app.reopen_offer(test.id('booking:HX-3'), test.id('hx_cs'), '{}'::jsonb);
select test.ok('reopen: open as long as the original offer (48 hours), not 24 or 1',
  abs(extract(epoch from (pg_temp.bk('HX-3')).offer_expires_at - (now() + interval '48 hours'))) < 120);

-- ================================================================ 4. the licence: before handover, not before accepting or paying
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:HX-3'), test.id('driver:hx_ren'), 'renter', 'Hx Ren', date '1990-05-05', 36, '26_plus');
update drivers set licence_expiry = null where id = test.id('driver:hx_ren');
select test.eq('setting off: nothing blocks accepting or paying', app.licence_gate(test.id('booking:HX-3')), '{}'::text[]);
select test.eq('setting off: the payment facts carry nothing missing',
  public.server_booking_payment_facts(test.id('booking:HX-3')) -> 'licence_missing', '[]'::jsonb);
update program_settings set booking_licence_before_payment = true;
select test.ok('setting on: the licence is missing', cardinality(app.licence_gate(test.id('booking:HX-3'))) > 0);
select test.throws('setting on: the renter cannot accept without it',
  $$select app.approve_offer(test.id('booking:HX-3'), (pg_temp.bk('HX-3')).current_offer_version, test.id('hx_ren'))$$, 'Upload the driver''s licence');
select test.throws('setting on, no photos: staff are refused too, and an Admin is told about the reason',
  $$select app.approve_offer(test.id('booking:HX-3'), (pg_temp.bk('HX-3')).current_offer_version, test.id('hx_admin'))$$, 'an Admin can accept anyway with a reason');
-- an Admin with a reason goes ahead without the licence (Renter approved by phone, override_reason)
select app.admin_do(test.id('hx_admin'), 'approve_offer_by_phone', jsonb_build_object('booking', test.id('booking:HX-3'), 'override_reason', 'Licence seen on a video call'));
select test.eq('Admin override: accepted', (pg_temp.bk('HX-3')).status::text, 'pending_payment');
select test.ok('Admin override: the reason is in the history',
  exists (select 1 from booking_events e where e.booking_id = test.id('booking:HX-3') and e.note like 'Admin accepted without the licence%Licence seen on a video call'));
-- another offer: the licence photos are there (submitted), the expiry not saved: staff on the phone go ahead
select pg_temp.req('HX-4', 'HXV2', date_trunc('hour', now()) + interval '40 days', 2);
update payments set status = 'cancelled' where booking_id = test.id('booking:HX-4');
select app.send_offer(test.id('booking:HX-4'), test.id('hx_cs'));
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:HX-4'), test.id('driver:hx_ren'), 'renter', 'Hx Ren', date '1990-05-05', 36, '26_plus');
insert into documents (id, kind, storage_bucket, storage_path, booking_id) values
  (test.id('doc:hx_f'), 'id_front', 'documents', 'hx/f.jpg', test.id('booking:HX-4')), (test.id('doc:hx_b'), 'id_back', 'documents', 'hx/b.jpg', test.id('booking:HX-4'));
insert into verification_uploads (booking_id, driver_id, kind, document_id, status) values
  (test.id('booking:HX-4'), test.id('driver:hx_ren'), 'licence_front', test.id('doc:hx_f'), 'submitted'),
  (test.id('booking:HX-4'), test.id('driver:hx_ren'), 'licence_back', test.id('doc:hx_b'), 'submitted');
select test.eq('photos on file', app.licence_photos_on_file(test.id('booking:HX-4')), true);
select test.throws('photos on file: the renter still cannot accept without the expiry',
  $$select app.approve_offer(test.id('booking:HX-4'), 1, test.id('hx_ren'))$$, 'Upload the driver''s licence');
select app.approve_offer(test.id('booking:HX-4'), 1, test.id('hx_cs'));
select test.eq('staff: renter approved by phone goes ahead with the photos on file', (pg_temp.bk('HX-4')).status::text, 'pending_payment');
select test.ok('staff: the history says what is still to check before handover',
  exists (select 1 from booking_events e where e.booking_id = test.id('booking:HX-4') and e.note like 'Accepted by staff with the licence photos on file%'));
update drivers set licence_expiry = date '2030-01-01' where id = test.id('driver:hx_ren');
update program_settings set booking_licence_before_payment = false;

-- ================================================================ 5. paying needs no confirmed account
update program_settings set signin_confirm_required = true;
update users set email_verified_at = null, phone_verified_at = null where id = test.id('hx_ren');
select test.eq('unconfirmed: paying goes ahead', app.account_gate(test.id('hx_ren'), 'pay') ->> 'ok', 'true');
select test.eq('unconfirmed: accepting still follows the setting', app.account_gate(test.id('hx_ren'), 'accept') ->> 'reason', 'unconfirmed');
