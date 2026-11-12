-- 99: migration 2460 (release 40 hotfix): a salesperson calls a lead through the site; no mobile on file asks for it.
-- Fixtures: "zc". Test data only (example.test addresses, 555 numbers).
select test.suite('99 r40 calls through the site, the caller''s own mobile (2460)');

select test.mk_user('zc_sales', 'va', 'sales');
select test.mk_user('zc_cs', 'va', 'cs');
select test.mk_user('zc_fleet', 'va', 'fleet');
select test.mk_user('zc_admin', 'admin');
select test.mk_renter('zc_rena');
update program_settings set phone_enabled = true;
update renters set mobile = '(416) 555-0142', legal_name = 'Zc Rena' where id = test.id('renter:zc_rena');
insert into leads (id, kind, name, email, phone, source, message)
values (test.id('lead:zc1'), 'contact', 'Zc Lead', 'zc_lead@example.test', '905-555-0143', 'web', 'A car for the weekend');

-- ---------------------------------------------------------------- Sales is shown the lead's number masked, and the server finds it
select test.eq('Sales: the lead''s number is masked on the lead page',
  app.door(test.id('zc_sales'), 'aal2', 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zc1'))) ->> 'phone',
  '(905) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '43');
select test.eq('Sales: the Call button''s masked number is found on the server',
  app.server_phone_unmask(test.id('zc_sales'), jsonb_build_object('masked', '(905) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '43', 'name', 'Zc Lead')), '+19055550143');

-- ---------------------------------------------------------------- no mobile on file: the pop-up, never an error
select test.eq('no mobile on file: the call answers need_phone (the pop-up asks for it)',
  app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zc_sales'), 'number', '+19055550143')) ->> 'need_phone', 'true');
select test.eq('no mobile on file: no call was kept', (select count(*) from outbound_calls where staff_user_id = test.id('zc_sales'))::int, 0);

-- ---------------------------------------------------------------- saving the mobile from the pop-up (no texted code)
select test.throws('the mobile: a Philippine number is refused (Canadian or US only)', format($$select app.staff_set_call_phone(%L, '+63 917 555 0100')$$, test.id('zc_sales')), '%Canadian or US mobile%');
select test.throws('the mobile: 7 digits are refused', format($$select app.staff_set_call_phone(%L, '555-0144')$$, test.id('zc_sales')), '%10 digits%');
select test.throws('the mobile: a toll-free number is refused', format($$select app.staff_set_call_phone(%L, '1-800-555-0144')$$, test.id('zc_sales')), '%Canadian or US mobile%');
update site_settings set phone = '+14165550100';
select test.throws('the mobile: the CarmaCars number is refused', format($$select app.staff_set_call_phone(%L, '416-555-0100')$$, test.id('zc_sales')), '%CarmaCars number%');
select test.throws('the mobile: only staff', format($$select app.staff_set_call_phone(%L, '647-555-0145')$$, test.id('renter:zc_rena')), '%staff%');
select test.eq('the mobile: typed any way, saved as +1',
  app.staff_set_call_phone(test.id('zc_sales'), '(647) 555-0145') ->> 'phone', '+16475550145');
select test.eq('the mobile: on the profile, not verified', (select phone || '/' || (phone_verified_at is null)::text from users where id = test.id('zc_sales')), '+16475550145/true');
select test.eq('the mobile: audited', (select count(*) from audit_log where actor_user_id = test.id('zc_sales') and action = 'staff_call_phone_set')::int, 1);
select test.eq('the mobile: the same number again changes nothing',
  (select app.staff_set_call_phone(test.id('zc_sales'), '+1 647 555 0145') ->> 'ok') || '/' || (select count(*) from audit_log where actor_user_id = test.id('zc_sales') and action = 'staff_call_phone_set'), 'true/1');

-- ---------------------------------------------------------------- then the call starts, end to end in the database
create temp table zc_call as select app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zc_sales'), 'number', '+19055550143')) j;
select test.eq('the call starts: ok, rings the salesperson''s mobile, for the lead',
  (select concat_ws('/', j ->> 'ok', j ->> 'staff_number', (select (c.lead_id = test.id('lead:zc1'))::text from outbound_calls c where c.id = (j ->> 'id')::uuid)) from zc_call), 'true/+16475550145/true');
select test.eq('the call: the TwiML dials the lead', (select app.server_twilio_call_get((j ->> 'id')::uuid) ->> 'to' from zc_call), '+19055550143');

-- ---------------------------------------------------------------- customer service and Fleet use the same path
select test.eq('customer service: no mobile asks for it too', app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zc_cs'), 'number', '+14165550142')) ->> 'need_phone', 'true');
select app.staff_set_call_phone(test.id('zc_cs'), '416 555 0146');
select app.staff_set_call_phone(test.id('zc_fleet'), '416 555 0147');
select test.eq('customer service and Fleet: the call starts once the mobile is saved',
  (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zc_cs'), 'number', '+14165550142')) ->> 'ok') || '/' ||
  (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zc_fleet'), 'number', '+14165550142')) ->> 'staff_number'), 'true/+14165550147');

-- ---------------------------------------------------------------- a verified number is never replaced this way
update users set phone = '+14165550148', phone_verified_at = now() where id = test.id('zc_admin');
select test.throws('a verified number stays on file', format($$select app.staff_set_call_phone(%L, '416 555 0149')$$, test.id('zc_admin')), '%verified number stays%');
select test.eq('a verified number: the same number is fine', app.staff_set_call_phone(test.id('zc_admin'), '416-555-0148') ->> 'ok', 'true');

-- ---------------------------------------------------------------- only the server
set role authenticated;
select test.throws('the browser cannot save a staff mobile directly', format($$select public.server_staff_set_call_phone(%L, '647 555 0150')$$, test.id('zc_sales')), '%permission denied%');
select test.throws('the browser cannot start a call directly', format($$select public.server_twilio_call_start(%L)$$, jsonb_build_object('user_id', test.id('zc_sales'), 'number', '+19055550143')), '%permission denied%');
reset role;
