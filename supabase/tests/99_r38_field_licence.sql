-- 99: the Field Staff Agreement waits only for the licence number the staff member gives (2373). Fixtures start with "fl".
select test.suite('99 r38 field staff licence number');
select test.mk_user('fl_field', 'field', null, 'driver');
select test.mk_user('fl_admin', 'admin');
select test.ok('a field hire without the number: the agreement waits for it', app.staff_licence_number_needed(test.id('fl_field')));
insert into staff_agreement_auto (user_id, tries, last_at, missing) values (test.id('fl_field'), 1, now(), array['Driver''s licence number'])
  on conflict (user_id) do update set request_id = null, last_at = now();
select test.throws('a number that is not one is refused',
  $$ select app.door(test.id('fl_field'), 'aal1', 'ops_do', 'staff_licence_number_save', '{"licence_number": "abc"}') $$, 'licence number');
select app.door(test.id('fl_field'), 'aal1', 'ops_do', 'staff_licence_number_save', '{"licence_number": "c1234 56789 01234"}');
select test.eq('it is kept in the Ontario shape', (select licence_number from staff_profiles where user_id = test.id('fl_field')), 'C1234-56789-01234');
select test.ok('the waiting row is cleared, so the agreements job sends it next', not exists (select 1 from staff_agreement_auto where user_id = test.id('fl_field') and request_id is null));
select test.eq('the read gives the last 4 only', app.door(test.id('fl_field'), 'aal1', 'field_read', 'staff_licence_number', '{}') ->> 'last4', '1234');
select test.eq('the agreement carries it', app.staff_agreement_prepare(test.id('fl_admin'), test.id('fl_field')) #>> '{staff,licence_number}', 'C1234-56789-01234');
select test.ok('Welcome no longer asks', not app.staff_licence_number_needed(test.id('fl_field')));
