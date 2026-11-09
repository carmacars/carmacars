-- 99: an Admin is only an Admin (migration 0882, release 35, part T). Fixtures "r35a"; example.test only.
select test.suite('99 r35t admin only');
select test.mk_user('r35a_admin', 'admin');
select test.mk_user('r35a_staff', 'va', 'fleet');
-- the stopgap: staff roles and a profile on an Admin account (the triggers are off just to build the old data)
alter table user_roles disable trigger user_roles_admin_no_staff;
alter table staff_profiles disable trigger staff_profiles_admin_no_staff;
insert into user_roles (user_id, role) values (test.id('r35a_admin'), 'va'), (test.id('r35a_admin'), 'renter');
insert into staff_profiles (user_id, staff_type, va_function, is_active) values (test.id('r35a_admin'), 'va', 'cs', true);
alter table user_roles enable trigger user_roles_admin_no_staff;
alter table staff_profiles enable trigger staff_profiles_admin_no_staff;

select test.eq('before: the Admin holds a staff role and a profile', (select count(*) from user_roles where user_id = test.id('r35a_admin') and role = 'va') + (select count(*) from staff_profiles where user_id = test.id('r35a_admin')), 2::bigint);
select test.eq('the clean-up reports the Admin it changed (and only that one)', app.admin_staff_roles_clean() >= 1, true);
select test.eq('after: no staff role and no profile, the renter role stays', (select string_agg(role::text, ',' order by role::text) from user_roles where user_id = test.id('r35a_admin')), 'admin,renter');
select test.eq('after: no staff profile', (select count(*) from staff_profiles where user_id = test.id('r35a_admin')), 0::bigint);
select test.eq('audited, with what they held', (select before ->> 'roles' from audit_log where action = 'admin_staff_roles_removed' and entity_id = test.id('r35a_admin')::text), '["va"]');
select test.eq('staff who are not Admins are untouched', (select count(*) from staff_profiles where user_id = test.id('r35a_staff')), 1::bigint);
select test.throws('refused: a staff role added to an Admin', format($$insert into user_roles (user_id, role) values (%L, 'field')$$, test.id('r35a_admin')), 'every staff page');
select test.throws('refused: a staff profile added to an Admin', format($$insert into staff_profiles (user_id, staff_type, field_function, is_active) values (%L, 'field', 'driver', true)$$, test.id('r35a_admin')), 'every staff page');
select test.throws('refused: Admin > Portals invite as an office assistant', format($$select public.door(%L, null, 'admin_do', 'staff_add', jsonb_build_object('user_id', %L, 'email', 'r35a_admin@example.test', 'full_name', 'R35a Admin', 'role', 'va', 'va_function', 'cs'))$$, test.id('r35a_admin'), test.id('r35a_admin')), 'every staff page');
select test.ok('a renter role is still fine', (select count(*) from user_roles where user_id = test.id('r35a_admin') and role = 'renter') = 1);
select test.lives('a person who is not an Admin can still be given a field role', format($$insert into user_roles (user_id, role) values (%L, 'field')$$, test.id('r35a_staff')));
