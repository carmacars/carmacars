-- 99: release 33 part G (migrations 0730 to 0732, docs/changes/2026-11-07-r33-hire-academy-connector.md): one-step Hire
-- (the standard pay, the preview, the onboarding in one call, the status card, the pay details), the academy gate on with
-- the existing staff's week and the new sections, and the connector's Admin actions (preview rolled back, confirm with
-- the same arguments, used once, scopes, the log). Fixtures start with "rqg"; example.test addresses only.
select test.suite('99 r33 hire, academy, connector');
update app_events set processed_at = now() where processed_at is null;
create temp table rqg_ps as select id, require_staff_two_step t from program_settings;
update program_settings set require_staff_two_step = false where id is not null;
select test.mk_user('rqg_admin', 'admin');
select test.mk_user('rqg_cs', 'va', 'cs');
select test.mk_owner('rqg_own');
select test.mk_vehicle('RQGA', 'rqg_own');
select test.mk_renter('rqg_rita');
select test.mk_booking('RQG-201', 'RQGA', 'rqg_rita', to_char((now() + interval '40 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), to_char((now() + interval '43 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'confirmed', 30000);

insert into job_applications (role_id, status, full_name, email, phone, score, work_mode)
select r.id, 'interviewed', 'Hana Example', 'hana@rqg.example.test', '+639170000777', 88, r.work_mode from hiring_roles r where r.slug = 'va-customer-service';
create or replace function test.rqg_app() returns job_applications language sql stable as $$ select * from job_applications where email = 'hana@rqg.example.test' $$;
insert into tasks (queue, task_type, title, related_table, related_id) values ('admin', 'hiring_follow_up', 'Call Hana back', 'job_applications', (test.rqg_app()).id);

-- ================================================================ 1. the standard pay and the preview
select test.eq('customer service: the role''s posted pay, a month in USD', (select (p ->> 'basis') || ' ' || (p ->> 'cents') || ' ' || (p ->> 'currency') from (select app.hire_standard_pay('cs', (test.rqg_app()).role_id) p) x), 'monthly 40000 USD');
select test.eq('field work: the hourly wage in CAD', (select (p ->> 'basis') || ' ' || (p ->> 'currency') from (select app.hire_standard_pay('field') p) x), 'hourly CAD');
select test.ok('sales remote: commission only with the remote tier rule', (select p ->> 'basis' = 'commission' and p ->> 'text' like '%remote tiers%drops%' from (select app.hire_standard_pay('sales_remote') p) x));
select test.eq('the preview: the role''s function, six steps', (select (v ->> 'function') || ' ' || jsonb_array_length(v -> 'will_do') || ' ' || (v ->> 'can_hire')
  from (select app.door(test.id('rqg_admin'), 'aal2', 'admin_read', 'hire_preview', jsonb_build_object('id', (test.rqg_app()).id)) v) x), 'cs 6 true');
select test.throws('only an Admin hires', format($$select app.door(%L, 'aal2', 'admin_do', 'hire_onboard', %L)$$, test.id('rqg_cs'), jsonb_build_object('id', (test.rqg_app()).id)), '');
select test.throws('the sign-in comes first', format($$select app.door(%L, 'aal2', 'admin_do', 'hire_onboard', %L)$$, test.id('rqg_admin'), jsonb_build_object('id', (test.rqg_app()).id)), '%sign-in first%');

-- ================================================================ 2. Hire: one call does the database steps
-- the sign-in as the web layer makes it (the invitation and app.admin_invite_account)
select test.mk_user('rqg_hana', 'va', 'cs');
select test.eq('hired: the status card', (select string_agg((s ->> 'key') || '=' || (s ->> 'state'), ' ' order by o) from (select app.door(test.id('rqg_admin'), 'aal2', 'admin_do', 'hire_onboard',
  jsonb_build_object('id', (test.rqg_app()).id, 'user_id', test.id('rqg_hana'), 'function', 'cs', 'start_on', (app.today() + 3)::text, 'pay_cents', 42500)) v) x,
  jsonb_array_elements(v -> 'steps') with ordinality t(s, o)), 'account=done agreement=todo pay=waiting academy=waiting first_day=waiting hired=done');
select test.eq('the candidate is hired with the person', (select status || ' ' || (hired_user_id = test.id('rqg_hana'))::text from job_applications where id = (test.rqg_app()).id), 'hired true');
select test.eq('the pay and start date are kept', (select pay_text || ' ' || (start_on = app.today() + 3)::text from staff_onboarding where application_id = (test.rqg_app()).id), 'USD 425.00 a month true');
select test.eq('the staff profile has the start date', (select started_on = app.today() + 3 from staff_profiles where user_id = test.id('rqg_hana')), true);
select test.ok('the welcome email goes once, with the pay details link', exists (select 1 from hiring_decisions d where d.application_id = (test.rqg_app()).id and d.sent_at is not null and d.personal_note like '%/staff/profile#pay%')
  and (select count(*) from app_events e where e.code = 'applicant_hired' and e.processed_at is null and e.payload ->> 'email' = 'hana@rqg.example.test') = 1);
select test.eq('the candidate''s open To do is closed', (select status from tasks where related_id = (test.rqg_app()).id and task_type = 'hiring_follow_up'), 'done');
select test.eq('five first-day To do''s are theirs, due on the start date, and one for the Admins',
  (select count(*) filter (where task_type = 'first_day' and assigned_to = test.id('rqg_hana') and queue = 'cs' and (due_at at time zone 'America/Toronto')::date = app.today() + 3)
          || '/' || count(*) filter (where task_type = 'first_day_admin') from tasks where related_id in (test.id('rqg_hana'), (test.rqg_app()).id)), '5/1');
select test.ok('enrolled in their path with the gate on, held from now', exists (select 1 from academy_enrollments where user_id = test.id('rqg_hana') and path_code = 'cs' and gate and source = 'hire' and lock_from <= now()));
select test.ok('the gate holds the new hire until they pass', app.academy_locked(test.id('rqg_hana')));
select test.lives('Hire again changes nothing twice', format($$select app.door(%L, 'aal2', 'admin_do', 'hire_onboard', %L)$$, test.id('rqg_admin'),
  jsonb_build_object('id', (test.rqg_app()).id, 'user_id', test.id('rqg_hana'), 'function', 'cs', 'start_on', (app.today() + 3)::text, 'pay_cents', 42500)));
select test.eq('still five first-day To do''s and one welcome email', (select count(*) from tasks where task_type = 'first_day' and related_id = test.id('rqg_hana'))
  || '/' || (select count(*) from app_events e where e.code = 'applicant_hired' and e.payload ->> 'email' = 'hana@rqg.example.test'), '5/1');
select test.eq('the agreement step records what it waits for', (select s ->> 'state' || ' ' || (s ->> 'detail' like 'Waiting for: Home address%') from (select app.door(test.id('rqg_admin'), 'aal2', 'admin_do', 'hire_agreement_record',
  jsonb_build_object('id', (test.rqg_app()).id, 'missing', '["Home address"]'::jsonb)) v) x, jsonb_array_elements(v -> 'steps') s where s ->> 'key' = 'agreement'), 'todo true');

-- ================================================================ 3. the pay details: entered by the hire, shown masked, verified by an Admin
select test.throws('the account number is needed', format($$select app.door(%L, 'aal2', 'va_do', 'my_pay_details_save', '{"method": "bank_transfer", "account_holder": "Hana Example", "bank_name": "BDO"}')$$, test.id('rqg_hana')), '%account number%');
select test.eq('saved and shown by its last 4 only', (select v #>> '{current,shown}' from (select app.door(test.id('rqg_hana'), 'aal2', 'va_do', 'my_pay_details_save',
  '{"method": "bank_transfer", "account_holder": "Hana Example", "bank_name": "BDO", "account_no": "enc:v1:stand-in-ciphertext", "account_last4": "4321", "key_version": 1}') v) x), 'Bank account at BDO ending 4321');
select test.ok('the read never carries the account number', (select v::text not like '%stand-in-ciphertext%' from (select app.door(test.id('rqg_hana'), 'aal2', 'va_read', 'my_pay_details', '{}') v) x));
select test.ok('the first-day pay To do is done and an Admin is asked to verify', exists (select 1 from tasks where task_type = 'first_day' and related_id = test.id('rqg_hana') and dedupe_key like '%:pay' and status = 'done')
  and exists (select 1 from tasks where task_type = 'verify_staff_payout' and status = 'open'));
select test.ok('nobody reads the table directly', not has_table_privilege('authenticated', 'staff_payout_accounts', 'select') and not has_table_privilege('anon', 'staff_payout_accounts', 'select'));
select test.throws('a renter has no pay details', format($$select app.staff_payout_submit(%L, '{"method": "paypal", "account_holder": "Rita", "email": "rita@example.test"}')$$, test.id('rqg_rita')), '%for staff%');
select app.door(test.id('rqg_admin'), 'aal2', 'admin_do', 'staff_payout_verify',
  jsonb_build_object('id', (select id from staff_payout_accounts where user_id = test.id('rqg_hana') and is_current), 'method', 'Video call with Hana'));
select test.eq('an Admin verifies them: the step is done', (select s ->> 'state' from jsonb_array_elements(app.hire_status(test.id('rqg_admin'), jsonb_build_object('id', (test.rqg_app()).id)) -> 'steps') s
  where s ->> 'key' = 'pay'), 'done');

-- ================================================================ 4. the academy
select test.eq('the gate is on by default and now', (select academy_gate::text || '/' || (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'academy_gate') from program_settings), 'true/true');
insert into academy_enrollments (user_id, path_code, lock_from, source) values (test.id('rqg_cs'), 'cs', now() + interval '7 days', 'existing');
select test.ok('staff already working get their week before the hold', not app.academy_locked(test.id('rqg_cs')));
select test.ok('the home read says when it starts', (app.academy_home(test.id('rqg_cs')) ->> 'lock_from') is not null);
update academy_enrollments set lock_from = now() - interval '1 minute' where user_id = test.id('rqg_cs');
select test.ok('then held until they pass', app.academy_locked(test.id('rqg_cs')));
select test.eq('the new sections end each role''s path', (select string_agg(ps.path_code || ':' || s.slug, ' ' order by ps.path_code) from academy_path_sections ps join academy_sections s on s.id = ps.section_id
  where s.slug = 'new-bookings-r28-r32' and ps.sort = (select max(x.sort) - 1 from academy_path_sections x where x.path_code = ps.path_code and ps.path_code in ('cs', 'field'))), 'cs:new-bookings-r28-r32 field:new-bookings-r28-r32');
select test.eq('every role has a new section', (select count(distinct ps.path_code) from academy_path_sections ps join academy_sections s on s.id = ps.section_id where s.slug like 'new-%-r28-r32'), 7::bigint);
select test.eq('9 lessons and 20 questions, every answer one of the options', (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug like 'new-%-r28-r32')
  || '/' || (select count(*) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug like 'new-%-r28-r32' and q.answer < jsonb_array_length(q.options)), '9/20');
select test.throws('the order holds: a new section is closed until the one before it is passed', format($$select app.academy_section(%L, '{"path": "cs", "section": "new-documents-r28-r32"}')$$, test.id('rqg_hana')), '%Pass the section before%');

-- ================================================================ 5. the connector's Admin actions
create function test.rqg_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('rqg_admin'), test.id('rqg_admin'), 'Claude', array['bookings:read', 'admin:read', 'admin:write'], test.rqg_h('cc_live_rqg_full'), 'cc_live_rqg_');
select app.api_key_create(test.id('rqg_admin'), test.id('rqg_admin'), 'Read only', array['bookings:read'], test.rqg_h('cc_live_rqg_read'), 'cc_live_rqr_');
select test.eq('a read: the cars', (select (r -> 'result' -> 0 ->> 'plate') is not null from (select app.api_call(test.rqg_h('cc_live_rqg_full'), 'list_cars', '{"query": "RQGA"}') r) x), true);
select test.eq('without admin:write a write is refused', app.api_call(test.rqg_h('cc_live_rqg_read'), 'cancel_booking', '{"booking": "RQG-201", "reason": "renter_request"}') ->> 'status', '403');
create temp table rqg_pv as select app.api_call(test.rqg_h('cc_live_rqg_full'), 'cancel_booking', '{"booking": "RQG-201", "reason": "renter_request", "note": "Asked by phone"}') r;
select test.eq('the preview says what would change', (select r #>> '{result,will_change,status,after}' from rqg_pv), 'cancelled');
select test.eq('and changes nothing', (select status::text from bookings where booking_number = 'RQG-201'), 'confirmed');
select test.eq('confirm without the preview: refused', app.api_call(test.rqg_h('cc_live_rqg_full'), 'cancel_booking', '{"booking": "RQG-201", "reason": "renter_request", "note": "Asked by phone", "confirm": true}') ->> 'error', 'Preview first: call without confirm, then confirm with its preview_id');
select test.ok('confirm with other arguments: refused', (app.api_call(test.rqg_h('cc_live_rqg_full'), 'cancel_booking', jsonb_build_object('booking', 'RQG-201', 'reason', 'renter_request', 'note', 'Other', 'confirm', true,
  'preview_id', (select r #>> '{result,preview_id}' from rqg_pv))) ->> 'error') like 'The arguments differ%');
select test.eq('confirm with the same arguments: done, as the Admin', (select (r #>> '{result,changed,status,after}') from (select app.api_call(test.rqg_h('cc_live_rqg_full'), 'cancel_booking', jsonb_build_object('booking', 'RQG-201', 'reason', 'renter_request',
  'note', 'Asked by phone', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from rqg_pv))) r) x), 'cancelled');
select test.eq('the booking is cancelled', (select status::text from bookings where booking_number = 'RQG-201'), 'cancelled');
select test.ok('a preview is used once', (app.api_call(test.rqg_h('cc_live_rqg_full'), 'cancel_booking', jsonb_build_object('booking', 'RQG-201', 'reason', 'renter_request', 'note', 'Asked by phone', 'confirm', true,
  'preview_id', (select r #>> '{result,preview_id}' from rqg_pv))) ->> 'error') like '%already used%');
select test.eq('both calls are logged, with before and after on the change', (select string_agg(tool || ':' || ok::text || ':' || coalesce(after ->> 'status', '-'), ' ' order by id) from api_calls
  where key_id = (select id from api_keys where key_hash = test.rqg_h('cc_live_rqg_full')) and tool like 'cancel_booking%' and ok), 'cancel_booking:preview:true:- cancel_booking:true:cancelled');
select test.ok('a refused action fails at the preview, with the reason', (app.api_call(test.rqg_h('cc_live_rqg_full'), 'end_staff_access', jsonb_build_object('user', test.id('rqg_admin'))) ->> 'error') like 'It would be refused: You cannot end your own access%');
select test.eq('the onboarding card through the connector', app.api_call(test.rqg_h('cc_live_rqg_full'), 'get_hire_status',
  jsonb_build_object('application_id', app.api_call(test.rqg_h('cc_live_rqg_full'), 'list_applicants', '{"query": "hana"}') #>> '{result,0,application_id}')) #>> '{result,onboarding}', 'true');
select test.ok('a candidate already hired cannot be hired again', (app.api_call(test.rqg_h('cc_live_rqg_full'), 'hire_applicant', jsonb_build_object('application_id', (test.rqg_app()).id)) ->> 'error') like '%cannot be hired%');
insert into job_applications (role_id, status, full_name, email, phone, score, work_mode)
select r.id, 'interviewed', 'Ivo Example', 'ivo@rqg.example.test', '+639170000778', 80, r.work_mode from hiring_roles r where r.slug = 'va-fleet-operations';
select test.eq('a hire is previewed, and confirmed to the web layer as the Admin', (select (c #>> '{result,run}') || ' ' || ((c #>> '{result,actor}')::uuid = test.id('rqg_admin'))::text from (
  select app.api_call(test.rqg_h('cc_live_rqg_full'), 'hire_applicant', ('{"application_id": "' || x.id || '", "function": "fleet", "confirm": true, "preview_id": "' || (p #>> '{result,preview_id}') || '"}')::jsonb) c
    from (select a.id, app.api_call(test.rqg_h('cc_live_rqg_full'), 'hire_applicant', ('{"application_id": "' || a.id || '", "function": "fleet"}')::jsonb) p from job_applications a where a.email = 'ivo@rqg.example.test') x) y), 'hire true');
select test.ok('full-access keys made before got the Admin scopes', app.api_scopes_known() @> array['admin:read', 'admin:write']);
select test.ok('the connector''s functions are for the server only', not has_function_privilege('authenticated', 'app.api_call(text, text, jsonb, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_api_hire_result(text, uuid, boolean, text, text)', 'execute'));

update program_settings p set require_staff_two_step = x.t from rqg_ps x where p.id = x.id;
