-- 59: an owner account without a car (migration 0087, section 6). The account-only application (the owner record, no per-car
-- intake task, one light follow-up task for the Admin), the inbox showing it as "Account only: no car yet", a second
-- press, refused without the flag, and the owner's first car later: an ordinary application, the follow-up closed and
-- the account-only row gone from the inbox. Fixtures start with "nc".
select test.suite('59 owner account without a car');

select test.mk_user('nc_admin', 'admin');
insert into users (id, email, full_name) values (test.id('nc_amy'), 'nc_amy@example.test', 'Amy Owner'), (test.id('nc_ben'), 'nc_ben@example.test', 'Ben Other');

create temp table s59 (k text primary key, r jsonb);
grant all on s59 to public;
create function test.s59(p_k text) returns jsonb language sql stable as $$ select r from s59 where k = p_k $$;
create function test.nc_owner(p_by uuid) returns jsonb language sql immutable as $$
  select jsonb_build_object('owner_type', 'individual', 'legal_name', 'Amy Owner', 'first_name', 'Amy', 'last_name', 'Owner',
    'address_line1', '9 Owner Road', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M4M 1A1', 'country', 'CA',
    'email', 'nc_amy@example.test', 'phone', '+14165550199', 'licence_number', 'A1234-56789-01234', 'date_of_birth', '1988-02-03') $$;

select test.throws('without a car and without "add my car later": refused as before',
  format($$select app.submit_owner_application(jsonb_build_object('owner', test.nc_owner(null), 'vehicles', '[]'::jsonb), %L)$$, test.id('nc_amy')), 'at least one vehicle');

insert into s59 select 'acct', app.submit_owner_application(jsonb_build_object('source', 'web', 'owner', test.nc_owner(null), 'vehicles', '[]'::jsonb, 'account_only', true), test.id('nc_amy'));
select test.eq('account only: the owner record, linked to the sign-in',
  (select o.user_id from owners o where o.id = (test.s59('acct') ->> 'owner_id')::uuid), test.id('nc_amy'));
select test.eq('account only: an application in the "no car yet" state with no car',
  (select format('%s %s', a.status, a.vehicle_count) from owner_applications a where a.id = (test.s59('acct') ->> 'application_id')::uuid), 'account_only 0');
select test.eq('account only: no per-car intake task',
  (select count(*) from tasks where owner_id = (test.s59('acct') ->> 'owner_id')::uuid and task_type = 'owner_intake'), 0::bigint);
select test.eq('account only: one follow-up task for the Admin',
  (select format('%s %s', count(*), max(queue)) from tasks where owner_id = (test.s59('acct') ->> 'owner_id')::uuid and task_type = 'owner_signup_no_car' and status = 'open'), '1 admin');
select test.ok('account only: the follow-up is on the Admin''s To do',
  exists (select 1 from jsonb_array_elements(app.todo_prompts(test.id('nc_admin')) -> 'prompts') p where p ->> 'task_type' = 'owner_signup_no_car'));
select test.ok('account only: in the inbox as "Account only: no car yet"',
  exists (select 1 from jsonb_array_elements(app.applications_list(test.id('nc_admin'), '{"status": "account_only"}') -> 'rows') r
           where r ->> 'id' = test.s59('acct') ->> 'application_id' and jsonb_array_length(r -> 'vehicles') = 0)
  and (app.applications_list(test.id('nc_admin'), '{}') -> 'counts' ->> 'account_only')::integer >= 1);
select test.eq('account only: a second submit keeps one application and one task',
  (select format('%s %s', (app.submit_owner_application(jsonb_build_object('owner', test.nc_owner(null), 'vehicles', '[]'::jsonb, 'account_only', true), test.id('nc_amy')) ->> 'application_id') = test.s59('acct') ->> 'application_id',
                 (select count(*) from tasks where owner_id = (test.s59('acct') ->> 'owner_id')::uuid and task_type = 'owner_signup_no_car'))), 't 1');
select test.throws('account only: someone else cannot open an account on this owner',
  format($$select app.submit_owner_application(jsonb_build_object('owner_id', %L, 'owner', test.nc_owner(null), 'vehicles', '[]'::jsonb, 'account_only', true), %L)$$,
         test.s59('acct') ->> 'owner_id', test.id('nc_ben')), 'only their own account');

-- the first car, later, from the owner portal (the same application form, with a car)
insert into s59 select 'car', app.submit_owner_application(jsonb_build_object('source', 'web', 'owner', test.nc_owner(null),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', '1NC59AA0000000001', 'plate', 'AO 001', 'year', 2021, 'make', 'Honda', 'model', 'Civic', 'colour', 'Blue',
    'odometer_km', 30000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'held_by', 'individual', 'branded', false, 'damage', false))), test.id('nc_amy'));
select test.eq('first car: the same owner, an ordinary new application with its car',
  (select format('%s %s %s', (test.s59('car') ->> 'owner_id') = (test.s59('acct') ->> 'owner_id'), a.status, a.vehicle_count) from owner_applications a where a.id = (test.s59('car') ->> 'application_id')::uuid), 't new 1');
select test.eq('first car: the follow-up is done', (select status from tasks where owner_id = (test.s59('acct') ->> 'owner_id')::uuid and task_type = 'owner_signup_no_car'), 'done');
select test.ok('first car: the account-only row leaves the inbox',
  not exists (select 1 from jsonb_array_elements(app.applications_list(test.id('nc_admin'), '{"status": "account_only"}') -> 'rows') r where r ->> 'id' = test.s59('acct') ->> 'application_id'));
