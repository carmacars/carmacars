-- 99: field staff review the renter's licence (migration 0162, docs/changes/2026-10-25-field-licence-review.md).
-- Field staff approve all or reject with a reason, only for bookings of their own field jobs (today and the next 7 days);
-- the statuses, the history and the renter's notice are customer service's; customer service and Admin are unchanged.
-- Fixtures start with "fl".
select test.suite('99 field licence review');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('fl_admin', 'admin');
select test.mk_user('fl_cs', 'va', 'cs');
select test.mk_user('fl_field_a', 'field', null, 'driver');
select test.mk_user('fl_field_b', 'field', null, 'driver');
select test.mk_owner('fl_o');
select test.mk_vehicle('FLA', 'fl_o');
select test.mk_vehicle('FLB', 'fl_o');
select test.mk_vehicle('FLC', 'fl_o');
select test.mk_vehicle('FLD', 'fl_o');
select test.mk_vehicle('FLE', 'fl_o');
select test.mk_renter('fl_r');
create function test.fll(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;
create function test.flb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.fl_upload(p_booking text, p_kind text) returns uuid language sql as $$
  select app.register_verification_upload(test.flb(p_booking), test.id('fl_cs'), p_kind, test.id('driver:fl_r'),
    'renters/fl/' || p_booking || '-' || p_kind || '-' || gen_random_uuid() || '.jpg', repeat('d', 64), 'image/jpeg', null, 'identity') $$;
create function test.fl_job(p_booking text, p_user text, p_days integer) returns uuid language sql as $$
  insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, scheduled_at, status)
  select 'handover', b.id, b.vehicle_id, test.id(p_user), (test.fll(p_days, '09:00'))::timestamp at time zone 'America/Toronto', 'scheduled'
    from bookings b where b.id = test.flb(p_booking) returning id $$;
create function test.fl_door(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- FL-1: A's job tomorrow; FL-2: B's job in 3 days; FL-3: A's job in 10 days (too far); FL-4: nobody's job; FL-5: A's job, cancelled
select test.mk_booking('FL-1', 'FLA', 'fl_r', test.fll(1, '09:00'), test.fll(3, '09:00'), 'confirmed');
select test.mk_booking('FL-2', 'FLB', 'fl_r', test.fll(3, '09:00'), test.fll(5, '09:00'), 'confirmed');
select test.mk_booking('FL-3', 'FLC', 'fl_r', test.fll(10, '09:00'), test.fll(12, '09:00'), 'confirmed');
select test.mk_booking('FL-4', 'FLD', 'fl_r', test.fll(2, '09:00'), test.fll(4, '09:00'), 'confirmed');
select test.mk_booking('FL-5', 'FLE', 'fl_r', test.fll(2, '11:00'), test.fll(4, '11:00'), 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
select test.flb(n), test.id('driver:fl_r'), 'renter', 'Fl R', date '1990-05-05', 'L1', 'G', date '2031-01-01', 36, '26_plus' from unnest(array['FL-1', 'FL-2', 'FL-3', 'FL-4', 'FL-5']) n;
create table test.fljobs as
  select 'FL-1' as n, test.fl_job('FL-1', 'fl_field_a', 1) as id union all select 'FL-2', test.fl_job('FL-2', 'fl_field_b', 3)
  union all select 'FL-3', test.fl_job('FL-3', 'fl_field_a', 10) union all select 'FL-5', test.fl_job('FL-5', 'fl_field_a', 2);
update field_jobs set status = 'cancelled', cancel_reason = 'Handed over by the owner' where id = (select id from test.fljobs where n = 'FL-5');
create function test.fljob(p text) returns uuid language sql stable as $$ select id from test.fljobs where n = p $$;
create table test.flup as
  select b.n, k.kind, test.fl_upload(b.n, k.kind) as id
    from unnest(array['FL-1', 'FL-2', 'FL-3', 'FL-4', 'FL-5']) b(n), unnest(array['licence_front', 'licence_back', 'selfie']) k(kind);
create function test.flup(p_n text, p_kind text) returns uuid language sql stable as $$ select id from test.flup where n = p_n and kind = p_kind $$;
create function test.flstatus(p_n text) returns text language sql stable as $$
  select string_agg(left(kind, 5) || ':' || status, ',' order by kind) from verification_uploads where booking_id = test.flb(p_n) and kind in ('licence_front', 'licence_back', 'selfie')
$$;

-- ================================================================ 1. the list on the field home
select test.eq('list: field staff see the pending licence reviews of their own upcoming jobs only (not another''s, not beyond 7 days, not a cancelled job)',
  (select string_agg((x ->> 'booking_number') || ':' || (x ->> 'waiting'), ',' order by x ->> 'scheduled_at') from jsonb_array_elements(test.fl_door('fl_field_a', 'field_read', 'licences')) x), 'FL-1:3');
select test.eq('list: the other field staff member sees their own',
  (select string_agg((x ->> 'booking_number') || ':' || (x ->> 'waiting'), ',') from jsonb_array_elements(test.fl_door('fl_field_b', 'field_read', 'licences')) x), 'FL-2:3');
select test.eq('list: the card has what the home needs (the car, the plate, the renter''s first name, the job)',
  (select (x ->> 'renter_first_name') || '/' || (x ->> 'field_job_id' = test.fljob('FL-1')::text) || '/' || (x ->> 'vehicle_label' is not null)
     from jsonb_array_elements(test.fl_door('fl_field_a', 'field_read', 'licences')) x), 'Fl/true/true');
select test.throws('list: field staff only (customer service)', format($$select test.fl_door('fl_cs', 'field_read', 'licences')$$), 'Only field staff');
select test.throws('list: field staff only (an Admin)', format($$select test.fl_door('fl_admin', 'field_read', 'licences')$$), 'Only field staff');

-- ================================================================ 2. who may open and decide
select test.eq('read: the licence images, the drivers, no coverage', 
  (select jsonb_array_length(x -> 'uploads') || '/' || jsonb_array_length(x -> 'drivers') || '/' || (x -> 'coverage' = 'null'::jsonb) || '/' || (x ->> 'waiting') || '/' || (x ->> 'booking_number')
     from test.fl_door('fl_field_a', 'field_read', 'licence_review', jsonb_build_object('job', test.fljob('FL-1'))) x), '3/1/true/3/FL-1');
select test.eq('read: the opening is logged as for customer service',
  (select count(*) from data_access_log where user_id = test.id('fl_field_a') and reason like 'licence review by field staff, booking FL-1%'), 1::bigint);
select test.throws('read: not another field staff member''s job', format($$select test.fl_door('fl_field_b', 'field_read', 'licence_review', jsonb_build_object('job', %L))$$, test.fljob('FL-1')), 'not one of yours');
select test.throws('read: not a job more than 7 days away', format($$select test.fl_door('fl_field_a', 'field_read', 'licence_review', jsonb_build_object('job', %L))$$, test.fljob('FL-3')), 'not one of yours');
select test.throws('read: not a cancelled job', format($$select test.fl_door('fl_field_a', 'field_read', 'licence_review', jsonb_build_object('job', %L))$$, test.fljob('FL-5')), 'not one of yours');
select test.throws('reject: not on another''s job', format($$select test.fl_door('fl_field_b', 'field_do', 'licence_reject', jsonb_build_object('job', %L, 'upload', %L, 'reason', 'Photo unreadable'))$$,
  test.fljob('FL-1'), test.flup('FL-1', 'licence_front')), 'not one of yours');
select test.throws('reject: an upload of another booking is not found on one''s own job', format($$select test.fl_door('fl_field_b', 'field_do', 'licence_reject', jsonb_build_object('job', %L, 'upload', %L, 'reason', 'Photo unreadable'))$$,
  test.fljob('FL-2'), test.flup('FL-1', 'licence_front')), 'not found');
select test.throws('approve all: not on another''s job', format($$select test.fl_door('fl_field_b', 'field_do', 'licence_approve_all', jsonb_build_object('job', %L))$$, test.fljob('FL-1')), 'not one of yours');
select test.throws('approve all: not beyond 7 days', format($$select test.fl_door('fl_field_a', 'field_do', 'licence_approve_all', jsonb_build_object('job', %L))$$, test.fljob('FL-3')), 'not one of yours');
select test.eq('nothing was decided by those refusals', test.flstatus('FL-1') || '|' || test.flstatus('FL-2') || '|' || test.flstatus('FL-3'),
  (select string_agg(test.flstatus(n), '|' order by n) from unnest(array['FL-1', 'FL-2', 'FL-3']) n));
select test.throws('the office''s approve all is not opened to field staff', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FL-1'))$$, test.id('fl_field_a')), 'Only an Admin or customer service');
select test.throws('the office''s one-image review is not opened to field staff', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', true))$$,
  test.id('fl_field_a'), test.flup('FL-1', 'licence_front')), 'Only an Admin or customer service');
select test.eq('the licence rule: own job in the window yes, others no',
  app.field_licence_can(test.id('fl_field_a'), test.flb('FL-1')) || '/' || app.field_licence_can(test.id('fl_field_a'), test.flb('FL-2')) || '/' || app.field_licence_can(test.id('fl_field_a'), test.flb('FL-3'))
  || '/' || app.field_licence_can(test.id('fl_field_a'), test.flb('FL-4')) || '/' || app.field_licence_can(test.id('fl_field_a'), test.flb('FL-5')) || '/' || app.field_licence_can(test.id('fl_cs'), test.flb('FL-1')),
  'true/false/false/false/false/false');
select test.eq('the existing check admits the same people as the new one, and more', app.doc_review_licence_can(test.id('fl_field_a'), test.flb('FL-1')) || '/' || app.doc_review_licence_can(test.id('fl_cs'), test.flb('FL-1'))
  || '/' || app.doc_review_licence_can(test.id('fl_admin'), test.flb('FL-4')) || '/' || app.doc_review_licence_can(test.id('fl_field_a'), test.flb('FL-4')), 'true/true/true/false');

-- ================================================================ 3. reject with a reason, then approve all
select test.throws('reject: a reason the renter can act on is needed', format($$select test.fl_door('fl_field_a', 'field_do', 'licence_reject', jsonb_build_object('job', %L, 'upload', %L))$$,
  test.fljob('FL-1'), test.flup('FL-1', 'licence_front')), 'needs a reason');
select test.lives('reject: the front, with a reason', format($$select test.fl_door('fl_field_a', 'field_do', 'licence_reject', jsonb_build_object('job', %L, 'upload', %L, 'reason', 'The photo is too dark to read'))$$,
  test.fljob('FL-1'), test.flup('FL-1', 'licence_front')));
select test.eq('reject: the image is rejected with the reason, by the field staff member, at once',
  (select status || '/' || reject_reason || '/' || (reviewed_by = test.id('fl_field_a')) from verification_uploads where id = test.flup('FL-1', 'licence_front')), 'rejected/The photo is too dark to read/true');
select test.eq('reject: the booking''s driver is no longer verified, as with customer service''s rejection',
  (select identity_verified_on is null from booking_drivers where booking_id = test.flb('FL-1')), true);
select test.eq('reject: the renter is told (the same event customer service''s rejection emits)',
  (select count(*) from app_events where code = 'renter_identity_rejected' and entity_id = test.flb('FL-1') and payload ->> 'reject_reason' = 'The photo is too dark to read'), 1::bigint);
select test.eq('reject: the history says who decided, the reason and the role',
  (select (details ->> 'decision') || '/' || (details ->> 'reviewer_role') || '/' || note || '/' || (actor_user_id = test.id('fl_field_a')) || '/' || actor_type
     from booking_events where booking_id = test.flb('FL-1') and kind = 'verification' order by id desc limit 1),
  'rejected/field/The photo is too dark to read/true/staff');
select test.throws('reject: a decided image is not decided twice', format($$select test.fl_door('fl_field_a', 'field_do', 'licence_reject', jsonb_build_object('job', %L, 'upload', %L, 'reason', 'Again please'))$$,
  test.fljob('FL-1'), test.flup('FL-1', 'licence_front')), 'not waiting for review');
-- the renter sends a new front; the list still shows the booking while something waits
select test.fl_upload('FL-1', 'licence_front');
select test.eq('list: the new front and the two others wait', (select (x ->> 'waiting') from jsonb_array_elements(test.fl_door('fl_field_a', 'field_read', 'licences')) x), '3');
select test.eq('approve all: the three waiting are approved, nothing refused, the driver is verified',
  (select (x ->> 'approved') || '/' || jsonb_array_length(x -> 'refused') || '/' || (x #>> '{readiness,all_drivers_verified}')
     from test.fl_door('fl_field_a', 'field_do', 'licence_approve_all', jsonb_build_object('job', test.fljob('FL-1'))) x), '3/0/true');
select test.eq('approve all: the same statuses as customer service gives (approved, reviewed by the field staff member), the driver and the booking drivers verified',
  (select count(*) || ':' || bool_and(reviewed_by = test.id('fl_field_a')) from verification_uploads where booking_id = test.flb('FL-1') and status = 'approved') || '/' ||
  (select identity_status::text from drivers where id = test.id('driver:fl_r')) || '/' ||
  (select (identity_verified_on is not null) || ':' || identity_method from booking_drivers where booking_id = test.flb('FL-1')), '3:true/verified/true:staff_review');
select test.eq('approve all: three history lines of the approvals, each with the role',
  (select count(*) || ':' || bool_and(details ->> 'reviewer_role' = 'field' and details ->> 'decision' = 'approved') from booking_events where booking_id = test.flb('FL-1') and kind = 'verification' and details ->> 'decision' = 'approved'), '3:true');
select test.eq('list: nothing left to review on that job', (select count(*) from jsonb_array_elements(test.fl_door('fl_field_a', 'field_read', 'licences')) x), 0::bigint);
select test.eq('approve all: nothing waiting, nothing done the second time',
  (test.fl_door('fl_field_a', 'field_do', 'licence_approve_all', jsonb_build_object('job', test.fljob('FL-1'))) ->> 'approved'), '0');

-- ================================================================ 4. no rights left over, customer service and Admin unchanged
select test.eq('no customer service rights are left over after a review', app.user_va_has(test.id('fl_field_a'), 'cs') || '/' || coalesce(current_setting('app.field_as_cs', true), '') || '/' || coalesce(current_setting('app.review_role', true), ''), 'false//');
select test.eq('a history line written later is not marked as a field review',
  (select count(*) from (select app.log_booking_event(test.flb('FL-4'), 'verification', 'confirmed', 'confirmed', null, 'Checked', test.id('fl_cs'), 'staff', '{}'::jsonb)) x), 1::bigint);
select test.eq('...its details carry no role', (select coalesce(details ->> 'reviewer_role', 'none') || '/' || note from booking_events where booking_id = test.flb('FL-4') and kind = 'verification' order by id desc limit 1), 'none/Checked');
select test.eq('customer service: approve all on any booking, as before (FL-4 has no field job)',
  (select (x ->> 'approved') || '/' || (x #>> '{readiness,all_drivers_verified}') from app.door(test.id('fl_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FL-4')) x), '3/true');
select test.eq('customer service: the history carries no field role',
  (select count(*) from booking_events where booking_id = test.flb('FL-4') and kind = 'verification' and details ? 'reviewer_role'), 0::bigint);
select test.lives('customer service: rejects one image with a reason, as before', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', false, 'reason', 'Name does not match'))$$,
  test.id('fl_cs'), test.flup('FL-2', 'selfie')));
select test.eq('customer service: the image is rejected by customer service', (select status || '/' || (reviewed_by = test.id('fl_cs')) from verification_uploads where id = test.flup('FL-2', 'selfie')), 'rejected/true');
select test.lives('Admin: opens the review of any booking, as before', format($$select app.door(%L, 'aal2', 'admin_read', 'doc_review', jsonb_build_object('booking', 'FL-3'))$$, test.id('fl_admin')));
select test.eq('Admin: approve all on any booking, as before',
  (select (x ->> 'approved') from app.door(test.id('fl_admin'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FL-3')) x), '3');
select test.eq('field staff on FL-2 see the front and back still waiting and the selfie they cannot re-decide',
  (select (x ->> 'waiting') from test.fl_door('fl_field_b', 'field_read', 'licence_review', jsonb_build_object('job', test.fljob('FL-2'))) x), '2');

-- ================================================================ privileges
set role anon;
select test.throws('anon: no door', $$select app.door(null, 'aal1', 'field_read', 'licences', '{}')$$, null);
reset role;
set role authenticated;
select test.throws('authenticated: the review functions are the server''s call only', format($$select app.field_licence_approve_all(%L, '{}')$$, test.id('fl_field_a')), null);
select test.throws('authenticated: nor the rule', format($$select app.field_licence_can(%L, %L)$$, test.id('fl_field_a'), test.flb('FL-1')), null);
reset role;
