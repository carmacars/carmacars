-- 99: release 43 access checks (migration 2760). A person who works in Sales only is shown customer numbers masked
-- (0970); the tables that hold those numbers are not readable by their session directly either.
select test.suite('99 r43 security a');

select test.mk_user('r43a_sales', 'va', 'sales');
select test.mk_user('r43a_cs', 'va', 'cs');
select test.mk_renter('r43a_renter');
insert into contact_captures (visitor_id, form, ref, phone, state) values (test.id('r43a_visitor'), 'phone_gate', 'r43a', '(416) 555-0143', 'phone_only');

select test.login(test.id('r43a_sales'));
select test.eq('sales only: no renter record is read directly (numbers are masked through the door)', test.visible('select * from renters'), 0::bigint);
select test.eq('sales only: no captured number, chauffeur request or phone box contact is read directly',
  test.visible('select * from contact_captures') + test.visible('select * from chauffeur_requests') + test.visible('select * from phone_gate_contacts'), 0::bigint);
select test.eq('sales only: the rule is on for this session', app.direct_read_masked(), true);
select test.logout();

select test.login(test.id('r43a_cs'));
select test.eq('customer service: reads renters in the window and the captures as before',
  (test.visible('select * from renters') > 0) || '/' || (test.visible('select * from contact_captures') > 0) || '/' || app.direct_read_masked(), 'true/true/false');
select test.logout();

select test.login(test.id('r43a_renter'));
select test.eq('a renter: still reads their own record, and only it', test.visible('select * from renters'), 1::bigint);
select test.logout();

select test.eq('the door still gives Sales its reads (the server is not a browser session)',
  (select count(*) > 0 from renters), true);
select test.eq('the rule is a restrictive policy on each table that holds customer numbers',
  (select string_agg(tablename, ',' order by tablename) from pg_policies where policyname = 'masked_no_direct' and permissive = 'RESTRICTIVE'),
  'chauffeur_requests,contact_captures,phone_gate_contacts,renters');
