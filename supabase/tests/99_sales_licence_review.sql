-- 99: the Sales function reviews the renter's licence (migration 0169, docs/changes/2026-10-25-sales-licence-review.md).
-- Sales approve all or reject with a reason, for the licence front, back and selfie only; the proof of coverage and the
-- Protection Plan stay with customer service and Admin; the statuses, the history and the renter's notice are customer
-- service's; customer service, field staff and Admin are unchanged. Fixtures start with "ss".
select test.suite('99 sales licence review');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('ss_admin', 'admin');
select test.mk_user('ss_cs', 'va', 'cs');
select test.mk_user('ss_sales', 'va', 'sales');
select test.mk_user('ss_fleet', 'va', 'fleet');
select test.mk_user('ss_field', 'field', null, 'driver');
select test.mk_owner('ss_o');
select test.mk_vehicle('SSA', 'ss_o');
select test.mk_vehicle('SSB', 'ss_o');
select test.mk_vehicle('SSC', 'ss_o');
select test.mk_vehicle('SSD', 'ss_o');
select test.mk_renter('ss_r');
create function test.ss_day(p_days integer) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' 10:00' $$;
create function test.ssb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.ss_upload(p_booking text, p_kind text) returns uuid language sql as $$
  select app.register_verification_upload(test.ssb(p_booking), test.id('ss_cs'), p_kind, test.id('driver:ss_r'),
    'renters/sl/' || p_booking || '-' || p_kind || '-' || gen_random_uuid() || '.jpg', repeat('d', 64), 'image/jpeg', null, 'identity') $$;
create function test.ss_door(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.ss_status(p_n text) returns text language sql stable as $$
  select string_agg(left(kind, 5) || ':' || status, ',' order by kind) from verification_uploads where booking_id = test.ssb(p_n) and kind in ('licence_front', 'licence_back', 'selfie')
$$;

-- SS-1: an offer out (requested/offered stage); SS-2: confirmed, with a proof of coverage too; SS-3: confirmed (customer service decides it);
-- SS-4: cancelled, nothing waiting
select test.mk_booking('SS-1', 'SSA', 'ss_r', test.ss_day(5), test.ss_day(7), 'offered');
select test.mk_booking('SS-2', 'SSB', 'ss_r', test.ss_day(2), test.ss_day(4), 'confirmed');
select test.mk_booking('SS-3', 'SSC', 'ss_r', test.ss_day(3), test.ss_day(5), 'confirmed');
select test.mk_booking('SS-4', 'SSD', 'ss_r', test.ss_day(6), test.ss_day(8), 'cancelled');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
select test.ssb(n), test.id('driver:ss_r'), 'renter', 'Ss R', date '1990-05-05', 'L1', 'G', date '2031-01-01', 36, '26_plus' from unnest(array['SS-1', 'SS-2', 'SS-3', 'SS-4']) n;
update bookings set coverage_option = 1 where id = test.ssb('SS-2');
create table test.ssup as
  select b.n, k.kind, test.ss_upload(b.n, k.kind) as id
    from unnest(array['SS-1', 'SS-2', 'SS-3']) b(n), unnest(array['licence_front', 'licence_back', 'selfie']) k(kind);
create function test.ssup(p_n text, p_kind text) returns uuid language sql stable as $$ select id from test.ssup where n = p_n and kind = p_kind $$;
select app.register_verification_upload(test.ssb('SS-2'), test.id('ss_cs'), 'coverage_proof', null, 'renters/sl/SS-2/p1.pdf', md5('sl-2-p1'), 'application/pdf',
  jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-9', 'policy_expiry', app.today() + 60));

-- ================================================================ 1. the rule and the queue list
select test.eq('the rule: Sales yes on a booking being arranged or under way, no on a cancelled one with nothing waiting, no for anyone else',
  app.sales_licence_can(test.id('ss_sales'), test.ssb('SS-1')) || '/' || app.sales_licence_can(test.id('ss_sales'), test.ssb('SS-2')) || '/' || app.sales_licence_can(test.id('ss_sales'), test.ssb('SS-4'))
  || '/' || app.sales_licence_can(test.id('ss_cs'), test.ssb('SS-1')) || '/' || app.sales_licence_can(test.id('ss_fleet'), test.ssb('SS-1')) || '/' || app.sales_licence_can(test.id('ss_field'), test.ssb('SS-1')),
  'true/true/false/false/false/false');
select test.eq('the existing check admits Sales too', app.doc_review_licence_can(test.id('ss_sales'), test.ssb('SS-1')) || '/' || app.doc_review_licence_can(test.id('ss_cs'), test.ssb('SS-1'))
  || '/' || app.doc_review_licence_can(test.id('ss_admin'), test.ssb('SS-1')) || '/' || app.doc_review_licence_can(test.id('ss_fleet'), test.ssb('SS-1')), 'true/true/true/false');
select test.eq('queue: Sales see the bookings with a licence image waiting, with how many (the coverage proof is not counted)',
  (select string_agg((x ->> 'booking_number') || ':' || (x ->> 'waiting'), ',' order by x ->> 'booking_number') from jsonb_array_elements(test.ss_door('ss_sales', 'va_read', 'licences_waiting')) x where x ->> 'booking_number' like 'SS-%'), 'SS-1:3,SS-2:3,SS-3:3');
select test.eq('queue: the line has what the list needs (the car, the renter''s first name, the status)',
  (select (x ->> 'renter_first_name') || '/' || (x ->> 'vehicle_label' is not null) || '/' || (x ->> 'status')
     from jsonb_array_elements(test.ss_door('ss_sales', 'va_read', 'licences_waiting')) x where x ->> 'booking_number' = 'SS-1'), 'Ss/true/offered');
select test.throws('queue: Sales only (customer service)', $$select test.ss_door('ss_cs', 'va_read', 'licences_waiting')$$, null);

-- ================================================================ 2. open the review
select test.eq('read (the office''s call): the licence images and drivers, no coverage, licence only',
  (select jsonb_array_length(x -> 'uploads') || '/' || jsonb_array_length(x -> 'drivers') || '/' || (x -> 'coverage' = 'null'::jsonb) || '/' || (x ->> 'waiting') || '/' || (x ->> 'booking_number') || '/' || (x ->> 'licence_only')
     from test.ss_door('ss_sales', 'ops_read', 'doc_review', '{"booking": "SS-2"}') x), '3/1/true/3/SS-2/true');
select test.eq('read: no proof of coverage among the uploads',
  (select count(*) from jsonb_array_elements(test.ss_door('ss_sales', 'ops_read', 'doc_review', '{"booking": "SS-2"}') -> 'uploads') u where u ->> 'kind' = 'coverage_proof'), 0::bigint);
select test.eq('read (/va/verify): the same for the assistants'' screen',
  (select jsonb_array_length(x -> 'uploads') || '/' || (x -> 'coverage' = 'null'::jsonb) from test.ss_door('ss_sales', 'va_read', 'verification', '{"booking": "SS-1"}') x), '3/true');
select test.eq('read: every opening is logged as a licence review by sales',
  (select count(*) >= 3 from data_access_log where user_id = test.id('ss_sales') and reason like 'licence review by sales, booking SS-%'), true);
select test.throws('read: not a cancelled booking with nothing waiting', $$select test.ss_door('ss_sales', 'ops_read', 'doc_review', '{"booking": "SS-4"}')$$, 'Only an Admin or customer service');
select test.throws('read: fleet cannot', $$select test.ss_door('ss_fleet', 'ops_read', 'doc_review', '{"booking": "SS-1"}')$$, 'Only an Admin or customer service');
select test.eq('read: customer service still sees the coverage, as before',
  (select (x -> 'coverage' <> 'null'::jsonb) || '/' || coalesce(x ->> 'licence_only', 'no') from test.ss_door('ss_cs', 'ops_read', 'doc_review', '{"booking": "SS-2"}') x), 'true/no');

-- ================================================================ 3. coverage and the Protection Plan stay closed to Sales
select test.throws('coverage: Sales cannot approve the proof of coverage upload', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', true))$$,
  test.id('ss_sales'), (select id from verification_uploads where booking_id = test.ssb('SS-2') and kind = 'coverage_proof')), 'proof of coverage');
select test.throws('coverage: nor through the assistants'' screen', format($$select app.door(%L, 'aal2', 'va_do', 'verify_upload', jsonb_build_object('upload', %L, 'approve', true))$$,
  test.id('ss_sales'), (select id from verification_uploads where booking_id = test.ssb('SS-2') and kind = 'coverage_proof')), 'proof of coverage');
select test.throws('coverage: doc_review_coverage still refuses Sales', format($$select app.doc_review_coverage(%L, jsonb_build_object('proof', %L, 'approve', true))$$,
  test.id('ss_sales'), (select id from app.current_coverage_proof(test.ssb('SS-2')))), 'Only an Admin or customer service');
select test.throws('coverage: coverage_review still refuses Sales', format($$select app.door(%L, 'aal2', 'va_do', 'coverage_review', jsonb_build_object('proof', %L, 'approve', true))$$,
  test.id('ss_sales'), (select id from app.current_coverage_proof(test.ssb('SS-2')))), 'customer service');
select test.throws('the Protection Plan still refuses Sales (the office''s call)', format($$select app.doc_review_plan(%L, '{"booking": "SS-2"}')$$, test.id('ss_sales')), 'Only an Admin or customer service');
select test.throws('the Protection Plan still refuses Sales (the assistants'' call)', format($$select app.door(%L, 'aal2', 'va_do', 'protection_plan_confirm', '{"booking": "SS-2"}')$$, test.id('ss_sales')), 'customer service');
select test.eq('the coverage is untouched', (select status::text from coverage_proofs where booking_id = test.ssb('SS-2') order by created_at desc limit 1), 'submitted');
select test.eq('approve all by Sales on SS-2: three licence images approved, nothing refused, the driver verified',
  (select (x ->> 'approved') || '/' || jsonb_array_length(x -> 'refused') || '/' || (x #>> '{readiness,all_drivers_verified}')
     from test.ss_door('ss_sales', 'ops_do', 'doc_review_approve_all', '{"booking": "SS-2"}') x), '3/0/true');
select test.eq('...the proof upload is still waiting and the coverage not confirmed',
  (select status::text from verification_uploads where booking_id = test.ssb('SS-2') and kind = 'coverage_proof') || '/' || (select coverage_confirmed_at is null from bookings where id = test.ssb('SS-2')), 'submitted/true');

-- ================================================================ 4. reject with a reason, then approve all (SS-1)
select test.throws('reject: a reason the renter can act on is needed', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', false))$$,
  test.id('ss_sales'), test.ssup('SS-1', 'licence_front')), 'needs a reason');
select test.lives('reject: the front, with a reason', format($$select app.door(%L, 'aal2', 'va_do', 'verify_upload', jsonb_build_object('upload', %L, 'approve', false, 'reason', 'The photo is too dark to read'))$$,
  test.id('ss_sales'), test.ssup('SS-1', 'licence_front')));
select test.eq('reject: the image is rejected with the reason, by the Sales assistant, at once',
  (select status || '/' || reject_reason || '/' || (reviewed_by = test.id('ss_sales')) from verification_uploads where id = test.ssup('SS-1', 'licence_front')), 'rejected/The photo is too dark to read/true');
select test.eq('reject: the booking''s driver is no longer verified, as with customer service''s rejection',
  (select identity_verified_on is null from booking_drivers where booking_id = test.ssb('SS-1')), true);
select test.eq('reject: the renter is told (the same event customer service''s rejection emits)',
  (select count(*) from app_events where code = 'renter_identity_rejected' and entity_id = test.ssb('SS-1') and payload ->> 'reject_reason' = 'The photo is too dark to read'), 1::bigint);
select test.eq('reject: the history says who decided, the reason and the role',
  (select (details ->> 'decision') || '/' || (details ->> 'reviewer_role') || '/' || note || '/' || (actor_user_id = test.id('ss_sales')) || '/' || actor_type
     from booking_events where booking_id = test.ssb('SS-1') and kind = 'verification' order by id desc limit 1),
  'rejected/sales/The photo is too dark to read/true/staff');
select test.throws('reject: a decided image is not decided twice', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', false, 'reason', 'Again please'))$$,
  test.id('ss_sales'), test.ssup('SS-1', 'licence_front')), 'not waiting for review');
-- the renter sends a new front; the queue still shows the booking while something waits
select test.ss_upload('SS-1', 'licence_front');
select test.eq('queue: the new front and the two others wait', (select (x ->> 'waiting') from jsonb_array_elements(test.ss_door('ss_sales', 'va_read', 'licences_waiting')) x where x ->> 'booking_number' = 'SS-1'), '3');
select test.eq('approve all: the three waiting are approved, nothing refused, the driver is verified',
  (select (x ->> 'approved') || '/' || jsonb_array_length(x -> 'refused') || '/' || (x #>> '{readiness,all_drivers_verified}')
     from test.ss_door('ss_sales', 'ops_do', 'doc_review_approve_all', '{"booking": "SS-1"}') x), '3/0/true');
select test.eq('approve all: the same statuses as customer service gives (approved, reviewed by the Sales assistant), the driver and the booking drivers verified',
  (select count(*) || ':' || bool_and(reviewed_by = test.id('ss_sales')) from verification_uploads where booking_id = test.ssb('SS-1') and status = 'approved') || '/' ||
  (select identity_status::text from drivers where id = test.id('driver:ss_r')) || '/' ||
  (select (identity_verified_on is not null) || ':' || identity_method from booking_drivers where booking_id = test.ssb('SS-1')), '3:true/verified/true:staff_review');
select test.eq('approve all: three history lines of the approvals, each with the role',
  (select count(*) || ':' || bool_and(details ->> 'reviewer_role' = 'sales' and details ->> 'decision' = 'approved') from booking_events where booking_id = test.ssb('SS-1') and kind = 'verification' and details ->> 'decision' = 'approved'), '3:true');
select test.eq('queue: SS-1 and SS-2 are gone from the list (SS-2''s proof is not a licence image), SS-3 remains',
  (select string_agg(x ->> 'booking_number', ',') from jsonb_array_elements(test.ss_door('ss_sales', 'va_read', 'licences_waiting')) x where x ->> 'booking_number' like 'SS-%'), 'SS-3');
select test.eq('approve all: nothing waiting, nothing done the second time',
  (test.ss_door('ss_sales', 'ops_do', 'doc_review_approve_all', '{"booking": "SS-1"}') ->> 'approved'), '0');

-- ================================================================ 5. no rights left over; customer service, field staff and Admin unchanged
select test.eq('no customer service rights are left over after a review', app.user_va_has(test.id('ss_sales'), 'cs') || '/' || coalesce(current_setting('app.field_as_cs', true), '') || '/' || coalesce(current_setting('app.review_role', true), ''), 'false//');
select test.throws('Sales still cannot decide a booking''s documents outside the licence: the plan, the coverage, a refund', format($$select app.confirm_protection_plan(%L, %L)$$, test.ssb('SS-2'), test.id('ss_sales')), null);
select test.eq('customer service: approve all on SS-3, as before (three licence images, the history carries no role)',
  (select (x ->> 'approved') from app.door(test.id('ss_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'SS-3')) x) || '/' ||
  (select count(*) from booking_events where booking_id = test.ssb('SS-3') and kind = 'verification' and details ? 'reviewer_role'), '3/0');
select test.eq('customer service: the coverage proof on SS-2 is theirs, as before',
  (select (x ->> 'approved') from app.door(test.id('ss_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'SS-2')) x), '1');
select test.lives('Admin: opens the review of any booking, as before', format($$select app.door(%L, 'aal2', 'admin_read', 'doc_review', jsonb_build_object('booking', 'SS-4'))$$, test.id('ss_admin')));
select test.throws('fleet: still refused the office''s approve all', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'SS-3'))$$, test.id('ss_fleet')), 'Only an Admin or customer service');
select test.throws('field staff: still refused the office''s review', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', %L, 'approve', true))$$,
  test.id('ss_field'), test.ssup('SS-3', 'selfie')), null);

-- ================================================================ privileges
set role anon;
select test.throws('anon: no door', $$select app.door(null, 'aal1', 'va_read', 'licences_waiting', '{}')$$, null);
reset role;
set role authenticated;
select test.throws('authenticated: the review functions are the server''s call only', format($$select app.sales_licences(%L)$$, test.id('ss_sales')), null);
select test.throws('authenticated: nor the rule', format($$select app.sales_licence_can(%L, %L)$$, test.id('ss_sales'), test.ssb('SS-1')), null);
reset role;
