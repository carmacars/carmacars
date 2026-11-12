-- 99: a value the staff agreement waits for, once filled in, makes the agreements job try again at its next run (2470). Fixtures start with "ar".
select test.suite('99 r40 staff agreement retry');
select test.mk_user('r40ar_field', 'field', null, 'driver');
insert into staff_agreement_auto (user_id, tries, last_at, missing) values (test.id('r40ar_field'), 1, now(), array['Home address'])
  on conflict (user_id) do update set request_id = null, last_at = now(), missing = excluded.missing;
select test.ok('the job just tried and waits a day', not exists (select 1 from app.staff_agreements_due_rows(50) x where x = test.id('r40ar_field')));
update staff_profiles set home_address = '12 Queen Street, Toronto, ON M5H 2N2' where user_id = test.id('r40ar_field');
select test.ok('a home address filled in clears the waiting row', not exists (select 1 from staff_agreement_auto where user_id = test.id('r40ar_field')));
insert into staff_agreement_auto (user_id, tries, last_at, missing) values (test.id('r40ar_field'), 1, now(), array['Start Date']);
update staff_profiles set started_on = current_date - 37 where user_id = test.id('r40ar_field');
select test.ok('a start date set clears it too', not exists (select 1 from staff_agreement_auto where user_id = test.id('r40ar_field')));
insert into staff_agreement_auto (user_id, tries, last_at, missing) values (test.id('r40ar_field'), 1, now(), array['Start Date']);
update staff_profiles set is_active = is_active where user_id = test.id('r40ar_field');
select test.ok('an unrelated save leaves the waiting row alone', exists (select 1 from staff_agreement_auto where user_id = test.id('r40ar_field')));
