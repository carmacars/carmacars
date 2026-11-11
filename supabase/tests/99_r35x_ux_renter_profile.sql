-- 99: a renter's name and date of birth (1110): edited at once until a licence is verified, a correction request checked by
-- Sales, customer service or an Admin after; the extension link's request works on a trip under way. Fixtures start with "uxp".
select test.suite('99 r35 ux: renter profile, date of birth, extension');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('uxp_admin', 'admin');
select test.mk_user('uxp_sales', 'va', 'sales');
select test.mk_user('uxp_cs', 'va', 'cs');
select test.mk_user('uxp_fleet', 'va', 'fleet');
select test.mk_renter('uxp_new');
select test.mk_renter('uxp_ver');
-- uxp_new: no licence verified yet; uxp_ver: verified (the fixture's default)
update renters set identity_status = 'not_started' where id = test.id('renter:uxp_new');
update drivers set identity_status = 'not_started' where renter_id = test.id('renter:uxp_new');
create function test.uxp_try(p_user text, p_name text, p jsonb) returns text language plpgsql as $$
begin perform app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p); return 'ok'; exception when others then return sqlerrm; end $$;

-- ================================================================ 1. not verified yet: saved at once
select test.eq('the profile shows the date of birth, not locked', (select (x ->> 'date_of_birth') || '/' || (x ->> 'identity_locked') || '/' || (x ->> 'renter')
  from app.door(test.id('uxp_new'), 'aal2', 'ops_read', 'self_profile', '{}') x), '1990-05-05/false/true');
select test.eq('a renter changes the name and the date of birth', test.uxp_try('uxp_new', 'profile_identity_save', '{"legal_name": "Uxp Newname", "date_of_birth": "1992-03-04"}'), 'ok');
select test.eq('the renter, the account and the account holder''s driver changed',
  (select r.legal_name || '/' || r.date_of_birth || '/' || u.full_name || '/' || d.full_name || '/' || d.date_of_birth
     from renters r join users u on u.id = r.user_id join drivers d on d.renter_id = r.id and d.is_account_holder where r.id = test.id('renter:uxp_new')),
  'Uxp Newname/1992-03-04/Uxp Newname/Uxp Newname/1992-03-04');
select test.eq('a date in the future is refused', test.uxp_try('uxp_new', 'profile_identity_save', jsonb_build_object('date_of_birth', app.today() + 1)), 'Check the date of birth');
select test.eq('a child is refused', test.uxp_try('uxp_new', 'profile_identity_save', jsonb_build_object('date_of_birth', app.today() - 3650)), 'A driver is 16 or older');
select test.eq('nothing changed, nothing saved', test.uxp_try('uxp_new', 'profile_identity_save', '{"legal_name": "Uxp Newname"}'), 'Nothing changed');

-- ================================================================ 2. verified: a correction request
select test.eq('a reason is needed once the licence is verified', test.uxp_try('uxp_ver', 'profile_identity_save', '{"date_of_birth": "1991-05-05"}'),
  'Say why it changes (a typo, a legal name change): it is checked against your licence');
select test.eq('the request is made', test.uxp_try('uxp_ver', 'profile_identity_save', '{"date_of_birth": "1991-05-05", "reason": "Typo in the year"}'), 'ok');
select test.eq('nothing changed yet', (select date_of_birth::text from renters where id = test.id('renter:uxp_ver')), '1990-05-05');
select test.eq('the profile shows it waiting', (select (x -> 'pending' ->> 'requested_dob') || '/' || (x ->> 'identity_locked') from app.door(test.id('uxp_ver'), 'aal2', 'ops_read', 'self_profile', '{}') x), '1991-05-05/true');
select test.ok('a task for customer service', exists (select 1 from tasks t where t.task_type = 'name_change_approve' and t.queue = 'cs' and t.renter_id = test.id('renter:uxp_ver') and t.status = 'open'));
select test.eq('Sales and customer service read it on the renter; Fleet does not',
  (select jsonb_array_length(app.door(test.id('uxp_sales'), 'aal2', 'ops_read', 'name_change_pending', jsonb_build_object('renter_id', test.id('renter:uxp_ver'))))) || '/'
  || (select jsonb_array_length(app.door(test.id('uxp_cs'), 'aal2', 'ops_read', 'name_change_pending', jsonb_build_object('renter_id', test.id('renter:uxp_ver'))))), '1/1');
select test.throws('Fleet cannot', format($$select app.door(%L, 'aal2', 'ops_read', 'name_change_pending', jsonb_build_object('renter_id', %L))$$, test.id('uxp_fleet'), test.id('renter:uxp_ver')), 'Admin only');
select test.eq('Fleet cannot decide it', test.uxp_try('uxp_fleet', 'name_change_decide', jsonb_build_object('id', (select id from name_change_requests where user_id = test.id('uxp_ver') and status = 'requested'), 'decision', 'approve')),
  'An Admin approves or declines a name change (a renter''s correction: Sales, customer service or an Admin)');
select test.eq('Sales approve it against the licence', test.uxp_try('uxp_sales', 'name_change_decide', jsonb_build_object('id', (select id from name_change_requests where user_id = test.id('uxp_ver') and status = 'requested'), 'decision', 'approve')), 'ok');
select test.eq('the date of birth changed on the renter and the driver; the request and the task closed',
  (select r.date_of_birth || '/' || d.date_of_birth from renters r join drivers d on d.renter_id = r.id and d.is_account_holder where r.id = test.id('renter:uxp_ver'))
  || '/' || (select status from name_change_requests where user_id = test.id('uxp_ver') order by requested_at desc limit 1)
  || '/' || (select count(*) from tasks t where t.task_type = 'name_change_approve' and t.renter_id = test.id('renter:uxp_ver') and t.status = 'open'), '1991-05-05/1991-05-05/approved/0');
select test.ok('decided by Sales, in the audit trail', exists (select 1 from audit_log a where a.entity_table = 'name_change_requests' and a.actor_user_id = test.id('uxp_sales')));
select test.eq('the renter asks to change the name', test.uxp_try('uxp_ver', 'profile_identity_save', '{"legal_name": "Uxp Verified Other", "reason": "Legal name change"}'), 'ok');
select test.eq('customer service declines it: the name stays', test.uxp_try('uxp_cs', 'name_change_decide', jsonb_build_object('id', (select id from name_change_requests where user_id = test.id('uxp_ver') and status = 'requested'), 'decision', 'decline', 'note', 'Not the licence name'))
  || '/' || (select legal_name from renters where id = test.id('renter:uxp_ver')), 'ok/Uxp Ver');

-- ================================================================ 3. the extension link's request on a trip under way
select test.mk_owner('uxp_o');
select test.mk_vehicle('UXPA', 'uxp_o');
select test.mk_booking('UXP-1', 'UXPA', 'uxp_ver', to_char((now() at time zone 'America/Toronto')::date - 1, 'YYYY-MM-DD') || ' 10:00',
  to_char((now() at time zone 'America/Toronto')::date + 3, 'YYYY-MM-DD') || ' 10:00', 'on_rent');
select test.ok('the renter asks for one more day on a trip under way', (select r ->> 'status' in ('requested', 'approved') from app.request_extension_option(test.id('booking:UXP-1'), test.id('uxp_ver'), '1d') r));
