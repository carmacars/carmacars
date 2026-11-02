-- 99: test accounts fenced off from real work (0440) and Data health, the nightly self-check (0441).
-- docs/changes/2026-11-07-data-health.md. Fixtures start with "dh" and use example.test addresses; the test accounts use
-- the verification's own shapes (verify-<name>@carmacars.ca, delivered+...@resend.dev) as production does.
select test.suite('99 data health');

select test.mk_user('dh_admin', 'admin');
select test.mk_user('dh_sales', 'va', 'sales');
select test.mk_user('dh_tsales', 'va', 'sales');
update users set email = 'verify-dh-sales@carmacars.ca', full_name = 'Verify Dh Sales' where id = test.id('dh_tsales');
select test.mk_user('dh_invite', 'va', 'sales');
update users set email = 'delivered+verify-invite-dh@resend.dev', full_name = 'Verify Invitation' where id = test.id('dh_invite');
select test.mk_user('dh_gone', 'va', 'cs');
update users set status = 'suspended' where id = test.id('dh_gone');
select test.mk_owner('dh_olive');
select test.mk_vehicle('dh_a', 'dh_olive');
select test.mk_vehicle('dh_b', 'dh_olive');
select test.mk_vehicle('dh_c', 'dh_olive');
select test.mk_vehicle('dh_d', 'dh_olive');
select test.mk_vehicle('dh_e', 'dh_olive');
select test.mk_vehicle('dh_f', 'dh_olive');
select test.mk_vehicle('dh_g', 'dh_olive');
select test.mk_vehicle('dh_bare', 'dh_olive');
select test.mk_renter('dh_rita');
select test.mk_renter('dh_tina');
update renters set email = 'delivered@resend.dev' where id = test.id('renter:dh_tina');

create or replace function test.dht(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
-- a check's record ids in a data health read
create or replace function test.dh_ids(r jsonb, p_key text) returns text[] language sql stable as $$
  select coalesce(array_agg(i ->> 'id'), '{}') from jsonb_array_elements(r -> 'checks') c, jsonb_array_elements(c -> 'items') i where c ->> 'key' = p_key
$$;
create or replace function test.dh_has(r jsonb, p_key text, p_id uuid) returns boolean language sql stable as $$
  select p_id::text = any (test.dh_ids(r, p_key))
$$;

-- ================================================================ 1. what a test account is
select test.eq('test accounts: the verification''s addresses and Resend''s test inboxes; a real address is not',
  (select string_agg(is_test::text, '/' order by full_name) from users where id in (test.id('dh_tsales'), test.id('dh_invite'), test.id('dh_sales'))),
  'false/true/true');
select test.eq('0078''s test now covers the invitation''s leftover account too', app.staff_is_test(test.id('dh_invite')), true);
select test.eq('a test renter''s booking is a test record; a real renter''s is not',
  app.renter_is_test(test.id('renter:dh_tina')) || '/' || app.renter_is_test(test.id('renter:dh_rita')), 'true/false');

-- ================================================================ 2. the fences
select test.mk_booking('DH-REQ', 'dh_a', 'dh_rita', test.dht(interval '5 days'), test.dht(interval '8 days'), 'requested');
select test.mk_booking('DH-TEST', 'dh_b', 'dh_tina', test.dht(interval '5 days'), test.dht(interval '8 days'), 'requested');
select app.raise_task(p_type => 'booking_request', p_title => 'DH request', p_booking => test.id('booking:DH-REQ'), p_dedupe => 'dh:req');
select app.raise_task(p_type => 'booking_request', p_title => 'DH test request', p_booking => test.id('booking:DH-TEST'), p_dedupe => 'dh:test');
update tasks set assigned_to = test.id('dh_tsales'), status = 'in_progress' where dedupe_key = 'dh:req';
select test.eq('a real request''s task never goes to a test account: back to its queue',
  (select coalesce(assigned_to::text, 'nobody') || '/' || status from tasks where dedupe_key = 'dh:req'), 'nobody/open');
update tasks set assigned_to = test.id('dh_sales') where dedupe_key = 'dh:req';
select test.eq('a real person takes it as before', (select assigned_to from tasks where dedupe_key = 'dh:req'), test.id('dh_sales'));
update tasks set assigned_to = test.id('dh_tsales') where dedupe_key = 'dh:test';
select test.eq('the verification''s own request can go to the verification''s account', (select assigned_to from tasks where dedupe_key = 'dh:test'), test.id('dh_tsales'));

insert into leads (id, kind, name, email, assigned_to) values (test.id('lead:dh_owner'), 'owner_program', 'Dh Owen', 'dh_owen@example.test', test.id('dh_invite'));
-- (0343, Release 26: such a lead goes to the least busy real Sales person, or to nobody when there is none; never to a test account)
select test.ok('a real owner lead is never credited to the invitation''s test account',
  (select assigned_to is distinct from test.id('dh_invite') and (assigned_to is null or not app.staff_is_test(assigned_to)) from leads where id = test.id('lead:dh_owner')));
insert into leads (id, kind, name, email) values (test.id('lead:dh_fake'), 'owner_program', 'Verify Lead', 'delivered@resend.dev');
select test.eq('a lead from a test address is closed at once, no follow-up',
  (select status || '/' || closed_reason || '/' || (followup_next_at is null)::text from leads where id = test.id('lead:dh_fake')), 'closed/Test account/true');

insert into request_claims (booking_id, claimed_by, expires_at) values (test.id('booking:DH-REQ'), test.id('dh_tsales'), now() + interval '20 minutes');
select test.eq('a test account opening a real request does not claim it', (select count(*) from request_claims where booking_id = test.id('booking:DH-REQ')), 0::bigint);
update bookings set sales_staff_id = test.id('dh_tsales'), sales_source = 'admin', sales_attributed_at = now() where id = test.id('booking:DH-REQ');
select test.eq('no sales credit to a test account on a real booking', (select sales_staff_id from bookings where id = test.id('booking:DH-REQ')), null::uuid);

insert into notifications (user_id, code, title, dedupe_key) values (test.id('dh_tsales'), 'staff_data_health', 'DH notice', 'dh:n:test');
insert into notifications (user_id, code, title, dedupe_key) values (test.id('dh_sales'), 'staff_data_health', 'DH notice', 'dh:n:real');
select test.eq('no in-app notice about real work reaches a test account; a real one gets it',
  (select string_agg(dedupe_key, ',') from notifications where dedupe_key like 'dh:n:%'), 'dh:n:real');

-- ================================================================ 3. the choosers and lists
update staff_profiles set is_active = false where user_id <> test.id('dh_tsales') and 'sales' = any (functions);
create temp table dh_lead as select app.submit_lead('{"kind": "buyer", "name": "Dh Buyer", "email": "dh_buyer@example.test", "payload": {"vehicle": "a Corolla"}}'::jsonb) r;
select test.eq('a buyer lead with only a test account in sales goes unassigned, never to the test account',
  (select assigned_to from leads where id = (select (r ->> 'lead_id')::uuid from dh_lead)), null::uuid);
update staff_profiles set is_active = true where user_id = test.id('dh_sales');
create temp table dh_lead2 as select app.submit_lead('{"kind": "buyer", "name": "Dh Buyer Two", "email": "dh_buyer2@example.test"}'::jsonb) r;
select test.ok('with a real sales assistant, the lead goes to a real person',
  (select not app.is_test_user(assigned_to) and assigned_to is not null from leads where id = (select (r ->> 'lead_id')::uuid from dh_lead2)));
update staff_profiles sp set is_active = true where 'sales' = any (sp.functions) and sp.user_id in (select user_id from user_roles where role = 'va');
select test.ok('the sales team report and Settings > Sales leave test accounts out',
  not exists (select 1 from jsonb_array_elements(app.team_sales(test.id('dh_admin')) -> 'rows') x where app.is_test_user((x ->> 'staff_id')::uuid))
  and not exists (select 1 from jsonb_array_elements(app.sales_modes_admin(test.id('dh_admin')) -> 'people') x where app.is_test_user((x ->> 'id')::uuid)));
select test.ok('the sales credit picker leaves them out',
  not exists (select 1 from jsonb_array_elements(app.sales_staff_options(test.id('dh_admin'))) x where app.is_test_user((x ->> 'id')::uuid)));
select test.ok('Admin > Portals keeps them, marked as test accounts',
  exists (select 1 from jsonb_array_elements(app.admin_portal_people(test.id('dh_admin'), 'Verify Dh', 50) -> 'people') x
           where x ->> 'id' = test.id('dh_tsales')::text and (x ->> 'test')::boolean));

-- ================================================================ 4. every check finds its record
-- pickup not recorded, never closed (Bookings > Now's lists)
select test.mk_booking('DH-UNREC', 'dh_c', 'dh_rita', test.dht(interval '-1 day'), test.dht(interval '2 days'), 'confirmed');
select test.mk_booking('DH-NEVER', 'dh_d', 'dh_rita', test.dht(interval '-6 days'), test.dht(interval '-2 days'), 'confirmed');
-- expired, yet paid (the fixture's payment succeeded)
select test.mk_booking('DH-DEAD', 'dh_e', 'dh_rita', test.dht(interval '-20 days'), test.dht(interval '-18 days'), 'expired');
-- on rent with no signature and no deposit
select test.mk_booking('DH-OUT', 'dh_f', 'dh_rita', test.dht(interval '-1 day'), test.dht(interval '3 days'), 'on_rent');
-- back 10 days ago, its deposit still held
select test.mk_booking('DH-BACK', 'dh_g', 'dh_rita', test.dht(interval '-14 days'), test.dht(interval '-10 days'), 'returned');
insert into deposits (id, booking_id, amount_cents, method, status, taken_at) values (test.id('dep:DH-BACK'), test.id('booking:DH-BACK'), 100000, 'card_hold', 'held', now() - interval '14 days');
-- an offer that ran out three days ago and is still "offer out", with its chase task
select test.mk_booking('DH-OFFER', 'dh_a', 'dh_rita', test.dht(interval '20 days'), test.dht(interval '22 days'), 'offered');
update bookings set offer_expires_at = now() - interval '3 days' where id = test.id('booking:DH-OFFER');
select app.raise_task(p_type => 'chase_offer', p_title => 'DH offer expiring', p_booking => test.id('booking:DH-OFFER'), p_dedupe => 'dh:chase');

-- a task left with a test account (written before the fence) and one with someone suspended
alter table tasks disable trigger a_fence_test_accounts;
select app.raise_task(p_type => 'booking_request', p_title => 'DH old', p_booking => test.id('booking:DH-UNREC'), p_dedupe => 'dh:leak');
update tasks set assigned_to = test.id('dh_invite') where dedupe_key = 'dh:leak';
alter table tasks enable trigger a_fence_test_accounts;
select app.raise_task(p_type => 'review_photos', p_title => 'DH photos', p_booking => test.id('booking:DH-BACK'), p_dedupe => 'dh:gone');
update tasks set assigned_to = test.id('dh_gone') where dedupe_key = 'dh:gone';
-- the same task twice; "offer expiring" for a car already out; a request's task when it is no longer a request
select app.raise_task(p_type => 'maintenance_due', p_title => 'DH service', p_vehicle => test.id('vehicle:dh_g'), p_dedupe => 'dh:dup1');
select app.raise_task(p_type => 'maintenance_due', p_title => 'DH service', p_vehicle => test.id('vehicle:dh_g'), p_dedupe => 'dh:dup2');
-- since 0325 a second copy is merged at once; the check is for the copies already open (an older row, a hand-made one): reopen it
update tasks set created_at = created_at + interval '1 minute', status = 'open', completion_note = null where dedupe_key = 'dh:dup2';
select app.raise_task(p_type => 'chase_offer', p_title => 'DH offer expiring soon', p_booking => test.id('booking:DH-OUT'), p_dedupe => 'dh:out');

-- an owner lead whose follow-up was stopped before anyone replied; an old "new" contact lead
update leads set created_at = now() - interval '3 days', followup_stopped_at = now() - interval '2 days', followup_stop_reason = 'Assigned away'
 where id = test.id('lead:dh_owner');
insert into leads (id, kind, name, email, created_at) values (test.id('lead:dh_contact'), 'contact', 'Dh Cara', 'dh_cara@example.test', now() - interval '4 days');
-- a request on a sample car three hours ago
insert into leads (id, kind, name, email, payload, created_at) values (test.id('lead:dh_sample'), 'sample_car', 'Dh Sam', 'dh_sam@example.test',
  '{"car": "2023 Tesla Model 3"}', now() - interval '3 hours');
-- licence photos waiting two days
insert into documents (id, kind, storage_bucket, storage_path, booking_id) values (test.id('doc:dh_lic'), 'id_front', 'documents', 'dh/licence.jpg', test.id('booking:DH-REQ'));
insert into verification_uploads (booking_id, driver_id, kind, document_id, uploaded_at)
values (test.id('booking:DH-REQ'), test.id('driver:dh_rita'), 'licence_front', test.id('doc:dh_lic'), now() - interval '2 days');
-- a published car with no seats and no photos of its own
-- (named first in the list: the check shows the first 25 cars, and the cars of the other test files stay published)
update vehicles set year = 1995 where id = test.id('vehicle:dh_bare');
select app.ensure_listing(test.id('vehicle:dh_bare'));
update vehicle_listings set status = 'published', published_at = now(), first_published_at = now(), seats = null where vehicle_id = test.id('vehicle:dh_bare');
-- money with nothing to tie it to
insert into payments (id, owner_id, purpose, kind, method, amount_cents, status) values (test.id('pay:dh_loose'), test.id('owner:dh_olive'), 'booking_total', 'charge', 'card', 12300, 'succeeded');
-- email on course to go over
create temp table dh_usage as select used from usage_services where service = 'resend_month';
update usage_services set used = 50000 where service = 'resend_month';

create temp table dh1 as select app.data_health(now()) r;
select test.ok('pickup not recorded: the confirmed booking whose pickup passed (Mark picked up)',
  test.dh_has((select r from dh1), 'pickup_not_recorded', test.id('booking:DH-UNREC'))
  and exists (select 1 from dh1, jsonb_array_elements(r -> 'checks') c, jsonb_array_elements(c -> 'items') i
               where c ->> 'key' = 'pickup_not_recorded' and i ->> 'id' = test.id('booking:DH-UNREC')::text and i #>> '{fix,action}' = 'mark_picked_up'));
select test.ok('never closed: the confirmed booking whose return passed (Close)', test.dh_has((select r from dh1), 'never_closed', test.id('booking:DH-NEVER')));
select test.ok('expired but paid', test.dh_has((select r from dh1), 'dead_with_money', test.id('booking:DH-DEAD')));
select test.ok('on rent with no signed agreement and no deposit', test.dh_has((select r from dh1), 'on_rent_gaps', test.id('booking:DH-OUT')));
select test.ok('a real task left with a test account', test.dh_has((select r from dh1), 'test_accounts', (select id from tasks where dedupe_key = 'dh:leak')));
select test.ok('a task left with someone suspended', test.dh_has((select r from dh1), 'inactive_assignee', (select id from tasks where dedupe_key = 'dh:gone')));
select test.ok('the owner lead whose follow-up stopped, and the contact nobody answered',
  test.dh_has((select r from dh1), 'lead_followup', test.id('lead:dh_owner')) and test.dh_has((select r from dh1), 'lead_followup', test.id('lead:dh_contact')));
select test.ok('licence photos waiting more than 24 hours', test.dh_has((select r from dh1), 'licence_waiting', test.id('booking:DH-REQ')));
select test.ok('the second copy of a task, not the first',
  test.dh_has((select r from dh1), 'duplicate_tasks', (select id from tasks where dedupe_key = 'dh:dup2'))
  and not test.dh_has((select r from dh1), 'duplicate_tasks', (select id from tasks where dedupe_key = 'dh:dup1')));
select test.ok('"Offer expiring soon" for a car already out', test.dh_has((select r from dh1), 'resolved_tasks', (select id from tasks where dedupe_key = 'dh:out')));
select test.ok('a published car with no seats and no real photos',
  exists (select 1 from dh1, jsonb_array_elements(r -> 'checks') c, jsonb_array_elements(c -> 'items') i
           where c ->> 'key' = 'car_gaps' and i ->> 'id' = test.id('vehicle:dh_bare')::text and i ->> 'text' like '%seats%' and i ->> 'text' like '%real photos%'));
select test.ok('an owner with cars and no terms', test.dh_has((select r from dh1), 'owners_terms', test.id('owner:dh_olive')));
select test.ok('a renter''s payment tied to no booking', test.dh_has((select r from dh1), 'unmatched_payments', test.id('pay:dh_loose')));
select test.ok('a deposit held 10 days after the return', test.dh_has((select r from dh1), 'deposits_overdue', test.id('booking:DH-BACK')));
select test.ok('an offer that ran out 3 days ago: its booking and its chase task',
  test.dh_has((select r from dh1), 'offers_stale', test.id('booking:DH-OFFER')) and test.dh_has((select r from dh1), 'offers_stale', (select id from tasks where dedupe_key = 'dh:chase')));
select test.ok('a real request on a sample car not yet offered a real one', test.dh_has((select r from dh1), 'sample_requests', test.id('lead:dh_sample')));
select test.ok('email on course to go over its allowance',
  exists (select 1 from dh1, jsonb_array_elements(r -> 'checks') c where c ->> 'key' = 'usage_trend' and (c ->> 'count')::integer >= 1));
select test.ok('the verification''s own request is never reported',
  not exists (select 1 from dh1, jsonb_array_elements(r -> 'checks') c, jsonb_array_elements(c -> 'items') i where i ->> 'id' = (select id from tasks where dedupe_key = 'dh:test')::text));
select test.eq('every check has a plain line and a count',
  (select count(*) from dh1, jsonb_array_elements(r -> 'checks') c where coalesce(c ->> 'line', '') = '' or c ->> 'count' is null), 0::bigint);
update usage_services set used = (select used from dh_usage) where service = 'resend_month';

-- ================================================================ 5. the one-tap fixes
select test.throws('only an Admin fixes', format($$select app.data_health_fix(%L, '{"action": "close_task", "id": "%s"}')$$, test.id('dh_sales'), test.id('dh_sales')), null);
select app.data_health_store(now(), '{}'::jsonb, test.id('dh_admin'));
select app.data_health_fix(test.id('dh_admin'), jsonb_build_object('action', 'unassign_task', 'id', (select id from tasks where dedupe_key = 'dh:gone')));
select test.eq('Unassign: the task goes back to its queue', (select assigned_to from tasks where dedupe_key = 'dh:gone'), null::uuid);
select test.ok('and it leaves the card at once',
  not test.dh_has(app.data_health_read(test.id('dh_admin')), 'inactive_assignee', (select id from tasks where dedupe_key = 'dh:gone')));
select app.data_health_fix(test.id('dh_admin'), jsonb_build_object('action', 'restart_followup', 'id', test.id('lead:dh_owner')));
select test.eq('Restart follow-up: the owner lead''s next email is due now',
  (select (followup_stopped_at is null and followup_next_at <= now())::text from leads where id = test.id('lead:dh_owner')), 'true');
select app.data_health_fix(test.id('dh_admin'), jsonb_build_object('action', 'close_task', 'id', (select id from tasks where dedupe_key = 'dh:chase')));
select test.eq('Close: the stale offer''s task is closed', (select status from tasks where dedupe_key = 'dh:chase'), 'cancelled');

-- ================================================================ 6. the clear-cut fixes, without asking
create temp table dh_fix as select app.data_health_autofix(now()) r;
select test.eq('the test account comes off the real task', (select assigned_to from tasks where dedupe_key = 'dh:leak'), null::uuid);
select test.eq('the duplicate closes, the first copy stays',
  (select string_agg(status, ',' order by dedupe_key) from tasks where dedupe_key in ('dh:dup1', 'dh:dup2')), 'open,cancelled');
select test.eq('"Offer expiring soon" for the car already out closes, saying why',
  (select status || '/' || (completion_note like 'The offer is no longer out%')::text from tasks where dedupe_key = 'dh:out'), 'cancelled/true');
select test.eq('the verification''s own task is left alone', (select assigned_to from tasks where dedupe_key = 'dh:test'), test.id('dh_tsales'));
select test.ok('the auto-fix says what it did',
  (select (r ->> 'test_tasks')::integer >= 1 and (r ->> 'duplicate_tasks')::integer >= 1 and (r ->> 'resolved_tasks')::integer >= 1 from dh_fix));
select test.eq('judgment calls are left for an Admin: the expired booking that was paid stays expired',
  (select status::text from bookings where id = test.id('booking:DH-DEAD')), 'expired');
select test.ok('the hourly task hygiene does the same fixes', (app.job_task_hygiene() ? 'data_health'));

-- ================================================================ 7. the nightly run: one in-app notice a day, no email
delete from notifications where code = 'staff_data_health';
select app.job_data_health(now());
select app.job_data_health(now());
select test.eq('one notice a day to a real Admin, however often it runs',
  (select count(*) from notifications where code = 'staff_data_health' and user_id = test.id('dh_admin')), 1::bigint);
select test.eq('no email or text for it', (select count(*) from notification_outbox where code = 'staff_data_health'), 0::bigint);
select test.ok('the run is kept for the card', (select ran_at > now() - interval '1 minute' and issues > 0 from data_health_runs order by ran_at desc limit 1));
select test.ok('the card reads the last run through the door (Admins only)',
  (app.door(test.id('dh_admin'), 'aal2', 'ops_read', 'data_health', '{}') ->> 'issues')::integer > 0);
select test.throws('staff cannot read it', format($$select app.data_health_read(%L)$$, test.id('dh_sales')), null);
select test.eq('the browser roles execute none of the new functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('data_health', 'data_health_fix', 'data_health_autofix', 'data_health_read', 'data_health_run', 'job_data_health',
                                              'fence_test_accounts', 'row_is_test', 'subject_is_test')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
