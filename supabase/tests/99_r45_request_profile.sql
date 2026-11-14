-- 99: migration 2860 (release 45): a request fills itself from the renter's profile. The signed-in renter's own profile
-- (name, date of birth, licence with only its last 4, the drivers named before, the channel), what is out of date (an
-- expired licence, an address older than the rule), nothing for anyone else; staff who make offers or add rentals get
-- the same with the licence number whole. Fixtures "rpf"; example.test only.
select test.suite('99 r45 request profile (2860)');

select test.mk_user('rpf_admin', 'admin');
select test.mk_user('rpf_sales', 'va', 'sales');
select test.mk_user('rpf_field', 'field');
select test.mk_renter('rpf_ann');
select test.mk_renter('rpf_guest', false);
update renters set legal_name = 'Mary Ann Rpftest', address_line1 = '1 Test Street', city = 'Toronto', province = 'ON', postal_code = 'M1M 1M1'
 where id = test.id('renter:rpf_ann');
update users set notify_channel = 'text' where id = test.id('rpf_ann');
insert into drivers (renter_id, is_account_holder, full_name, date_of_birth, email, licence_class)
values (test.id('renter:rpf_ann'), false, 'Second Driver', date '1992-02-02', 'rpf-second@example.test', 'G');

create function pg_temp.mine() returns jsonb language sql as $$ select public.server_request_profile(test.id('rpf_ann')) $$;

select test.eq('the name in two parts (the last word is the last name)', (pg_temp.mine() ->> 'first') || '|' || (pg_temp.mine() ->> 'last'), 'Mary Ann|Rpftest');
select test.eq('the date of birth', pg_temp.mine() ->> 'date_of_birth', '1990-05-05');
select test.eq('the licence class, issuer and expiry', (pg_temp.mine() #>> '{licence,class}') || '|' || (pg_temp.mine() #>> '{licence,issuer}') || '|' || (pg_temp.mine() #>> '{licence,expiry}'), 'G|ON|2030-01-01');
select test.ok('the renter''s own browser never gets the licence number, only its last 4',
  pg_temp.mine() #> '{licence,number}' = 'null'::jsonb and length(pg_temp.mine() #>> '{licence,number_end}') = 4);
select test.eq('the drivers named before', (select string_agg(d ->> 'first' || ' ' || (d ->> 'last') || ' ' || (d ->> 'email'), ',') from jsonb_array_elements(pg_temp.mine() -> 'drivers') d),
  'Second Driver rpf-second@example.test');
select test.eq('the account''s channel', pg_temp.mine() ->> 'notify_channel', 'text');
select test.eq('the address', pg_temp.mine() #>> '{address,line1}', '1 Test Street');
select test.eq('nothing out of date yet', (pg_temp.mine() #>> '{stale,licence_expired}') || '|' || (pg_temp.mine() #>> '{stale,address_old}'), 'false|false');
select test.eq('the address rule is 12 months by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'profile_address_max_months'), '12');

-- out of date: the licence expired, the address older than the rule
update drivers set licence_expiry = app.today() - 1 where id = test.id('driver:rpf_ann');
update renters set address_updated_at = now() - interval '13 months' where id = test.id('renter:rpf_ann');
select test.eq('an expired licence and an old address are flagged', (pg_temp.mine() #>> '{stale,licence_expired}') || '|' || (pg_temp.mine() #>> '{stale,address_old}'), 'true|true');
update renters set postal_code = 'M2M 2M2' where id = test.id('renter:rpf_ann');
select test.eq('a changed address is new again (the trigger dates it)', pg_temp.mine() #>> '{stale,address_old}', 'false');
create temp table rpf_at as select address_updated_at a from renters where id = test.id('renter:rpf_ann');
update renters set city = 'Toronto', mobile = '647-555-0100' where id = test.id('renter:rpf_ann');
select test.ok('another change (the phone) does not date the address', (select r.address_updated_at = t.a from renters r, rpf_at t where r.id = test.id('renter:rpf_ann')));

-- nothing for anyone else
select test.ok('nobody signed in: nothing', public.server_request_profile(null) is null);
select test.ok('an account with no renter record (staff): nothing', public.server_request_profile(test.id('rpf_sales')) is null);
select test.ok('the browser roles cannot call it', not has_function_privilege('anon', 'public.server_request_profile(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_request_profile(uuid)', 'execute') and has_function_privilege('service_role', 'public.server_request_profile(uuid)', 'execute'));
update renters set is_blocked = true where id = test.id('renter:rpf_ann');
select test.ok('a blocked renter: nothing', pg_temp.mine() is null);
update renters set is_blocked = false where id = test.id('renter:rpf_ann');

-- staff picking the renter
select test.eq('an Admin picking the renter gets the licence number whole',
  app.door(test.id('rpf_admin'), 'aal2', 'ops_read', 'renter_profile_fill', jsonb_build_object('renter', test.id('renter:rpf_ann'))) #>> '{licence,number}',
  (select licence_number from drivers where id = test.id('driver:rpf_ann')));
select test.eq('Sales too (they make offers)',
  app.door(test.id('rpf_sales'), 'aal2', 'ops_read', 'renter_profile_fill', jsonb_build_object('renter', test.id('renter:rpf_ann'), '_va', 'sales')) ->> 'first', 'Mary Ann');
select test.throws('field staff do not', $$ select app.door(test.id('rpf_field'), 'aal2', 'ops_read', 'renter_profile_fill', jsonb_build_object('renter', test.id('renter:rpf_ann'))) $$, 'Not permitted');
select test.throws('a renter does not', $$ select app.door(test.id('rpf_ann'), 'aal2', 'ops_read', 'renter_profile_fill', jsonb_build_object('renter', test.id('renter:rpf_guest'))) $$, 'Not permitted');
select test.eq('a renter with one word for a name: first only', app.name_parts('Cher') ->> 'first' || '|' || (app.name_parts('Cher') ->> 'last'), 'Cher|');
