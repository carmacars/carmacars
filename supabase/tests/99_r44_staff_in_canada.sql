-- 99: migration 2820 (release 44): staff who live in Canada get Canadian terms (Canada, CAD, e-Transfer or direct deposit)
-- on their agreement and never read as being in the Philippines. Fixtures start with "sic"; every address is example.test.
select test.suite('99 r44 staff in Canada (2820)');

select test.mk_user('sic_admin', 'admin');
select test.mk_user('sic_remote_ca', 'va', 'sales');
select test.mk_user('sic_in_person', 'va', 'sales');
select test.mk_user('sic_remote_ph', 'va', 'cs');
update staff_profiles set sales_work_mode = 'remote', location_country = 'CA', location_city = 'Toronto' where user_id = test.id('sic_remote_ca');
update staff_profiles set sales_work_mode = 'in_person', location_country = null where user_id = test.id('sic_in_person');
update staff_profiles set location_country = 'PH', location_city = 'Quezon City' where user_id = test.id('sic_remote_ph');

select test.ok('a remote Sales person living in Canada is in Canada', app.staff_in_canada(test.id('sic_remote_ca')));
select test.ok('an in-person Sales person with no location on file is in Canada', app.staff_in_canada(test.id('sic_in_person')));
select test.ok('an assistant in the Philippines paid there is not', not app.staff_in_canada(test.id('sic_remote_ph')));

select test.ok('the agreement of a remote Sales person in Canada never says the Philippines',
  coalesce((app.staff_agreement_prepare(test.id('sic_admin'), test.id('sic_remote_ca')) #>> '{defaults,country}'), 'Canada') = 'Canada'
  and coalesce((app.staff_agreement_prepare(test.id('sic_admin'), test.id('sic_remote_ca')) #>> '{defaults,currency}'), 'CAD') = 'CAD');
select test.eq('the assistant in the Philippines keeps the terms of Program settings',
  coalesce(app.staff_agreement_prepare(test.id('sic_admin'), test.id('sic_remote_ph')) #>> '{defaults,country}', 'Philippines'), 'Philippines');
select test.ok('the check is the server''s only', not has_function_privilege('authenticated', 'app.staff_in_canada(uuid)', 'execute'));
