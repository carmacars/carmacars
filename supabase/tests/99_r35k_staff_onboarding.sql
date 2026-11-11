-- 99: release 35 part K (migrations 1060 to 1064): the staff onboarding order (academy, agreement, access) per role, the right
-- agreement, the team groups, the inactivity lock, clock in, Finance in Partners, Unanswered, the townhall, careers to Sales
-- (closed roles, referrals, AI interviews for every role, auto-hire), the standard pay, the late return rule, return lines,
-- an expired hold, Close ended trips and the live map count. Fixtures "r35k"; example.test only.
select test.suite('99 r35k staff onboarding');
grant usage on schema test to service_role;

select test.mk_user('r35k_admin', 'admin');
select test.mk_user('r35k_cs', 'va', 'cs');
select test.mk_user('r35k_fleet', 'va', 'fleet');
select test.mk_user('r35k_fin', 'va', 'finance');
select test.mk_user('r35k_spi', 'va', 'sales');
select test.mk_user('r35k_spr', 'va', 'sales');
select test.mk_user('r35k_field', 'field');
update staff_profiles set sales_work_mode = 'in_person' where user_id = test.id('r35k_spi');
update staff_profiles set sales_work_mode = 'remote' where user_id = test.id('r35k_spr');
update program_settings set academy_gate = true, staff_agreement_gate = true, hiring_refer_va_to_sales = true, hiring_ai_all_roles = true, hiring_auto_hire_sales = true, whatsapp_sales_group_url = 'https://chat.whatsapp.com/ExampleSalesGroup01',
       whatsapp_team_group_url = 'https://chat.whatsapp.com/ExampleTeamGroup001';
create function test.r35k(p_who text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, p_call, p_name, p) $$;
create temp table r35k_people (label text, fn text, grp text);
insert into r35k_people values ('r35k_cs', 'cs', 'team'), ('r35k_fleet', 'fleet', 'team'), ('r35k_fin', 'finance', 'team'), ('r35k_spi', 'sales', 'sales'), ('r35k_spr', 'sales', 'sales'), ('r35k_field', 'field', 'team');
grant select on r35k_people to public;
-- every one a new hire: enrolled with the gate on
select app.academy_enroll(test.id(label), test.id('r35k_admin'), 'hire', now()) from r35k_people;

-- ================================================================ 1. the right agreement per function
select test.eq('the agreement of each role: the field agreement for field work only (in-person Sales signs the contractor agreement)',
  (select string_agg(p.label || '=' || app.staff_agreement_kind(sp), ',' order by p.label) from r35k_people p join staff_profiles sp on sp.user_id = test.id(p.label)),
  'r35k_cs=remote,r35k_field=in_person,r35k_fin=remote,r35k_fleet=remote,r35k_spi=remote,r35k_spr=remote');

-- ================================================================ 2. academy first, then the agreement, then access (every role)
select test.eq('step 1, every role: held by the academy, not yet by the agreement, no team group',
  (select string_agg(p.label || '=' || app.academy_locked(test.id(p.label)) || '/' || app.agreement_locked(test.id(p.label)) || '/' || jsonb_array_length(app.staff_team_groups(test.id(p.label))), ',' order by p.label) from r35k_people p),
  'r35k_cs=true/false/0,r35k_field=true/false/0,r35k_fin=true/false/0,r35k_fleet=true/false/0,r35k_spi=true/false/0,r35k_spr=true/false/0');
select test.eq('my_roles carries both locks', (app.my_roles(test.id('r35k_cs')) ->> 'academy_locked')::boolean and not (app.my_roles(test.id('r35k_cs')) ->> 'agreement_locked')::boolean, true);
select app.academy_waive(test.id('r35k_admin'), jsonb_build_object('user_id', test.id(label), 'reason', 'Passed in the test')) from r35k_people;
select test.eq('step 2, every role: the academy done, the agreement holds the portal, still no team group',
  (select string_agg(p.label || '=' || app.academy_locked(test.id(p.label)) || '/' || app.agreement_locked(test.id(p.label)) || '/' || jsonb_array_length(app.staff_team_groups(test.id(p.label))), ',' order by p.label) from r35k_people p),
  'r35k_cs=false/true/0,r35k_field=false/true/0,r35k_fin=false/true/0,r35k_fleet=false/true/0,r35k_spi=false/true/0,r35k_spr=false/true/0');
select test.eq('Welcome lists the steps in order: academy, then agreement, then the team group',
  (select string_agg(s ->> 'key', ',' order by o) from jsonb_array_elements(app.staff_welcome(test.id('r35k_cs')) -> 'steps') with ordinality x(s, o)), 'welcome,profile,academy,agreement,team,tasks');
select test.eq('the team group stays closed on Welcome until the agreement is done', (select (s ->> 'open')::boolean from jsonb_array_elements(app.staff_welcome(test.id('r35k_cs')) -> 'steps') s where s ->> 'key' = 'team'), false);
select test.eq('the profile step asks for the preferred name', (select (s ->> 'done')::boolean from jsonb_array_elements(app.staff_welcome(test.id('r35k_cs')) -> 'steps') s where s ->> 'key' = 'profile'), false);
select test.r35k('r35k_cs', 'ops_do', 'staff_preferred_name_save', '{"preferred_name": "Kay"}');
select test.eq('the preferred name is saved, shown in my_roles', app.my_roles(test.id('r35k_cs')) ->> 'preferred_name', 'Kay');
select test.throws('only an Admin waives an agreement', format($$select test.r35k('r35k_cs', 'admin_do', 'staff_agreement_waive', %L)$$, jsonb_build_object('user_id', test.id('r35k_cs'), 'reason', 'x')));
select test.eq('the Admin list shows everyone not signed, with their agreement', (select count(*) from jsonb_array_elements(test.r35k('r35k_admin', 'ops_read', 'staff_agreements_status')) x
  where x ->> 'email' like 'r35k_%' and x ->> 'state' = 'none'), 6::bigint);
select test.eq('the agreement job lists them to send (never the Admin)', (select count(*) from app.staff_agreements_due_rows(100000) u where u in (select test.id(label) from r35k_people)), 6::bigint);
select test.ok('no Admin in the job', not exists (select 1 from app.staff_agreements_due_rows(50) u where app.user_is_admin(u)));
-- the agreement done (the Admin's waiver here; a signature does the same)
select test.r35k('r35k_admin', 'admin_do', 'staff_agreement_waive', jsonb_build_object('user_id', test.id(label), 'reason', 'Signed on paper in the test')) from r35k_people;
select test.eq('step 3, every role: open, and the right WhatsApp group on the home page',
  (select string_agg(p.label || '=' || app.agreement_locked(test.id(p.label)) || '/' || (app.staff_team_groups(test.id(p.label)) -> 0 ->> 'key'), ',' order by p.label) from r35k_people p),
  'r35k_cs=false/team,r35k_field=false/team,r35k_fin=false/team,r35k_fleet=false/team,r35k_spi=false/sales,r35k_spr=false/sales');
-- 1151: Sales staff join the Sales group and the Team group
select test.eq('and on Welcome', (select jsonb_array_length(s -> 'groups') from jsonb_array_elements(app.staff_welcome(test.id('r35k_spr')) -> 'steps') s where s ->> 'key' = 'team'), 2);
select app.job_staff_agreements();
select test.eq('the team group email goes once to each', (select count(*) from app_events where code = 'staff_team_group' and (payload ->> 'recipient_user_id')::uuid in (select test.id(label) from r35k_people)), 6::bigint);
select app.job_staff_agreements();
select test.eq('and never twice', (select count(*) from app_events where code = 'staff_team_group' and (payload ->> 'recipient_user_id')::uuid in (select test.id(label) from r35k_people)), 6::bigint);
select test.r35k('r35k_fleet', 'ops_do', 'staff_team_joined');
select test.eq('I joined hides it from the home page', jsonb_array_length(app.staff_team_groups(test.id('r35k_fleet'))), 0);
update program_settings set whatsapp_team_group_url = '';
select test.eq('no link set: no group shown', jsonb_array_length(app.staff_team_groups(test.id('r35k_cs'))), 0);
select test.throws('a group link must be a WhatsApp invite', $$update program_settings set whatsapp_team_group_url = 'https://example.test/x'$$);

-- ================================================================ 3. inactivity
update staff_profiles set last_seen_at = now() - interval '8 days', created_at = now() - interval '30 days' where user_id = test.id('r35k_fin');
update users set last_sign_in_at = null where id = test.id('r35k_fin');
delete from staff_seen where user_id = test.id('r35k_fin');
select test.eq('day 7 or more: warned by email, not locked', app.job_staff_inactivity() like '1 warned, 0 locked%', true);
select test.ok('the warning email is on its way', exists (select 1 from app_events where code = 'staff_inactivity_warning' and payload ->> 'recipient_user_id' = test.id('r35k_fin')::text));
update staff_profiles set last_seen_at = now() - interval '11 days' where user_id = test.id('r35k_fin');
select test.eq('day 10: locked', app.job_staff_inactivity() like '0 warned, 1 locked%', true);
select test.eq('my_roles says locked', (app.my_roles(test.id('r35k_fin')) ->> 'inactive_locked')::boolean, true);
select test.throws('a locked account opens nothing', $$select test.r35k('r35k_fin', 'ops_read', 'va_clock')$$, 'locked for inactivity');
select test.eq('a sign-in says so', (public.server_signed_in(test.id('r35k_fin')) ->> 'inactive_locked')::boolean, true);
select test.ok('the Admins are alerted', exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'staff_inactive_locked'));
select test.ok('an Admin is never locked', not exists (select 1 from staff_profiles where user_id = test.id('r35k_admin') and inactive_locked_at is not null));
select test.r35k('r35k_admin', 'admin_do', 'staff_unlock', jsonb_build_object('user_id', test.id('r35k_fin')));
select test.eq('Unlock opens it again', app.inactive_locked(test.id('r35k_fin')), false);
select test.eq('the staff list has the last sign-in and the lock', (test.r35k('r35k_admin', 'admin_read', 'staff_access_facts') -> test.id('r35k_fin')::text ->> 'locked_at') is null, true);

-- ================================================================ 4. clock in and out
select test.eq('customer service clocks in', (test.r35k('r35k_cs', 'ops_do', 'va_clock_in') -> 'open') is not null, true);
select test.throws('once', $$select test.r35k('r35k_cs', 'ops_do', 'va_clock_in')$$, 'already clocked in');
select test.eq('and out', (test.r35k('r35k_cs', 'ops_do', 'va_clock_out') -> 'open') = 'null'::jsonb, true);
select test.throws('field staff use their shifts', $$select test.r35k('r35k_field', 'ops_do', 'va_clock_in')$$, 'customer service, Fleet and Finance');
select test.ok('Finance reads the timesheet', jsonb_typeof(test.r35k('r35k_fin', 'ops_read', 'va_timesheet') -> 'people') = 'array');
select test.throws('customer service does not', $$select test.r35k('r35k_cs', 'ops_read', 'va_timesheet')$$, 'Finance and Admin');
select test.lives('Finance adds hours with a reason', format($$select test.r35k('r35k_fin', 'ops_do', 'va_clock_fix', %L)$$,
  jsonb_build_object('user_id', test.id('r35k_fleet'), 'started_at', now() - interval '5 hours', 'ended_at', now() - interval '1 hour', 'reason', 'Forgot to clock in')));
-- 1502: the start comes from the schedule (customer service 8:00 to 18:00, six days a week, Tuesday off)
select test.eq('the start times: customer service 8:00 Toronto on a working day', to_char(app.va_clock_start(test.id('r35k_cs'), date '2026-11-09') at time zone 'America/Toronto', 'HH24:MI'), '08:00');
select test.eq('no start on its day off (Tuesday)', app.va_clock_start(test.id('r35k_cs'), date '2026-11-10') is null, true);

-- ================================================================ 5. Finance in the Partners section
select test.ok('Finance reads the rental partners', jsonb_typeof(test.r35k('r35k_fin', 'ops_read', 'partners')) = 'array');
select test.ok('and the referral partners', jsonb_typeof(test.r35k('r35k_fin', 'va_read', 'referral_partners', '{"_va": "finance"}') -> 'partners') = 'array');
select test.throws('customer service does not', $$select test.r35k('r35k_cs', 'va_read', 'referral_partners')$$);

-- ================================================================ 6. Unanswered
insert into phone_threads (id, number, match_kind, name, last_at, last_direction) values (test.id('r35k_thread'), '+15555550123', 'lead', 'R35k Caller', now() - interval '30 minutes', 'in');
insert into phone_activity (thread_id, kind, direction, body, started_at) values (test.id('r35k_thread'), 'text', 'in', 'Is the car free on Friday?', now() - interval '30 minutes');
select test.eq('a text with no reply waits, late past the time', (select (x ->> 'late')::boolean from jsonb_array_elements(test.r35k('r35k_cs', 'ops_read', 'unanswered') -> 'rows') x where x ->> 'thread_id' = test.id('r35k_thread')::text), true);
select test.eq('the alert goes once', app.job_unanswered() >= 1 and app.job_unanswered() = 0, true);
select test.throws('Fleet does not see it', $$select test.r35k('r35k_fleet', 'ops_read', 'unanswered')$$);
select test.r35k('r35k_cs', 'ops_do', 'unanswered_done', jsonb_build_object('thread_id', test.id('r35k_thread')));
select test.eq('Mark answered takes it off', (select count(*) from app.unanswered_rows() where thread_id = test.id('r35k_thread')), 0::bigint);

-- ================================================================ 7. the townhall
select test.ok('the deck builds', app.townhall_build(null, test.id('r35k_admin')) is not null);
-- 1505: the 30-minute run (15 sections; the investor money and the revenue by car are the Admin's)
select test.eq('the Admin sees every slide', jsonb_array_length(test.r35k('r35k_admin', 'ops_read', 'townhall') -> 'deck' -> 'slides'), 15);
select test.eq('staff do not see the money slides', jsonb_array_length(test.r35k('r35k_cs', 'ops_read', 'townhall') -> 'deck' -> 'slides'), 13);
select test.throws('only an Admin writes notes', format($$select test.r35k('r35k_cs', 'admin_do', 'townhall_note', %L)$$, jsonb_build_object('deck', (select id from townhall_decks limit 1), 'key', 'week', 'note', 'x')));

-- ================================================================ 8. careers: closed roles, Sales, AI interviews, auto-hire
select test.eq('a closed role is filled, and sends to remote Sales', public.server_hiring_closed_role('va-customer-service') -> 'sales' ->> 'slug', 'sales-remote');
select test.eq('an application sent to it says so', public.server_hiring_apply(jsonb_build_object('role', 'va-customer-service', 'full_name', 'R35k Late', 'email', 'r35k_late@example.test'), null) ->> 'sales_slug', 'sales-remote');
select test.eq('an open role has no closed page', public.server_hiring_closed_role('sales-remote') is null, true);
update hiring_roles set active = true where slug = 'va-fleet-operations';
insert into job_applications (id, role_id, full_name, email, phone, status) values (test.id('r35k_app_fleet'), (select id from hiring_roles where slug = 'va-fleet-operations'), 'R35k Fleet Applicant', 'r35k_fa@example.test', '+15555550111', 'new');
select test.eq('refer every VA applicant to Sales: the fleet applicant is referred', app.hiring_screen(test.id('r35k_app_fleet')) ->> 'other_role', 'sales-remote');
select test.ok('with the referral email', exists (select 1 from app_events where code = 'applicant_referred' and payload ->> 'application_id' = test.id('r35k_app_fleet')::text));
update hiring_roles set active = false where slug = 'va-fleet-operations';
select test.eq('AI interviews for every role, the in-person ones too', (select string_agg(r.slug || '=' || app.ai_interview_applies(jsonb_populate_record(null::job_applications, jsonb_build_object('role_id', r.id))), ',' order by r.slug)
  from hiring_roles r where r.slug in ('field-staff', 'sales-in-person', 'sales-remote')), 'field-staff=true,sales-in-person=true,sales-remote=true');
select test.eq('every role has its nine questions', (select string_agg(r.slug || '=' || jsonb_array_length(app.ai_interview_questions(r.id)), ',' order by r.slug) from hiring_roles r),
  'field-staff=9,sales-in-person=9,sales-remote=9,va-customer-service=9,va-finance-billing=9,va-fleet-operations=9');
select test.ok('the field interview asks about driving, not the internet',
  (select bool_or(q ->> 'text' like '%driving and car care%') and not bool_or(q ->> 'text' like 'Describe your internet%') from jsonb_array_elements(app.ai_interview_questions((select id from hiring_roles where slug = 'field-staff'))) q));
-- apply, interview, score: a remote and an in-person Sales applicant at the pass mark (60), one below
insert into job_applications (id, role_id, full_name, email, phone, status, knockouts)
select test.id('r35k_app_' || x.k), (select id from hiring_roles where slug = x.slug), 'R35k ' || initcap(x.k), 'r35k_' || x.k || '@example.test', '+15555550100', 'interviewed', '{}'
  from (values ('rem', 'sales-remote'), ('inp', 'sales-in-person'), ('low', 'sales-remote')) x(k, slug);
insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at)
select a.id, a.role_id, '[]'::jsonb, 'scored', now() + interval '7 days', case when a.id = test.id('r35k_app_low') then 55 else 82 end, 'hire', now() from job_applications a
 where a.id in (test.id('r35k_app_rem'), test.id('r35k_app_inp'), test.id('r35k_app_low'));
select test.eq('auto-hire picks the two at the mark, each with its Sales mode',
  (select string_agg(x ->> 'function' || ':' || (x ->> 'mark'), ',' order by x ->> 'function') from jsonb_array_elements(public.server_hire_auto_due(10) -> 'applications') x
    where (x ->> 'id')::uuid in (test.id('r35k_app_rem'), test.id('r35k_app_inp'), test.id('r35k_app_low'))), 'sales_in_person:60,sales_remote:60');
select test.ok('as the Admin the automatic work acts as', public.server_hire_auto_due(10) ->> 'actor' is not null);
select public.server_hire_auto_done(test.id('r35k_app_rem'), '{"ok": true, "score": 82, "mark": 60}');
select test.ok('an Admin alert per auto-hire', exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'hire_auto'));
select test.eq('never twice', (select count(*) from jsonb_array_elements(public.server_hire_auto_due(10) -> 'applications') x where (x ->> 'id')::uuid = test.id('r35k_app_rem')), 0::bigint);
select test.eq('Sales hires, in person or remote, then take the academy and sign the contractor agreement (above)', app.hire_path_of('sales_in_person') ->> 'va_function', 'sales');

-- ================================================================ 9. the standard pay from the role
select test.eq('the Hire form''s standard pay is the role''s own pay', app.hire_standard_pay('cs', null) ->> 'cents', '40000');
update hiring_roles set pay_min_cents = null, pay_text = 'US$350 a month, full time' where slug = 'va-customer-service';
select test.eq('or the amount in its pay text', app.hire_standard_pay('cs', null) ->> 'text', 'USD 350.00 a month');

-- ================================================================ 10. the late return (the owner's rule)
select test.eq('1 day 1 hour late: 1 extra day and 1 started hour, not 2 days and the hourly fee',
  (select extra_days || '/' || extra_days_cents || '/' || late_fee_cents from public.calc_late_return(1500, 16200, 2500, 15000, 30)), '1/16200/2500');
select test.eq('31 minutes late: the hourly fee only', (select extra_days || '/' || late_fee_cents from public.calc_late_return(31, 10000)), '0/2500');
select test.eq('within the grace after whole days: the days only', (select extra_days || '/' || late_fee_cents from public.calc_late_return(1450, 10000)), '1/0');
select test.mk_owner('r35k_o');
select test.mk_vehicle('R35KA', 'r35k_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_renter('r35k_r');
select test.mk_booking('CC-R35K1', 'R35KA', 'r35k_r', '2026-10-01 10:00', '2026-10-02 10:00', 'returned', 16206);
select test.mk_line('CC-R35K1', 'delivery', 10000);
select test.eq('the owner''s example: a day of $162.06 plus $100 delivery costs $162.06 an extra day (delivery is one-time)', app.booking_daily_cost_cents(test.id('booking:CC-R35K1')), 16206::bigint);
select test.mk_line('CC-R35K1', 'coverage_sold', 2000);
select test.eq('a per-trip fee (Protection Plan) is in the daily cost', app.booking_daily_cost_cents(test.id('booking:CC-R35K1')), 18206::bigint);

-- ================================================================ 11. return lines changed or waived by an Admin
insert into booking_line_items (id, booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, assessment_key)
values (test.id('r35k_line'), test.id('booking:CC-R35K1'), 'late_return_fee', 'Late return fee: 65 minutes late', 1, 16250, 16250, true, 2113, 'company_only', 'check_in', 'late_return_fee');
select test.throws('only an Admin', format($$select test.r35k('r35k_fin', 'ops_do', 'line_adjust', %L)$$, jsonb_build_object('line', test.id('r35k_line'), 'amount_cents', 2500, 'reason', 'One hour only')));
select test.r35k('r35k_admin', 'ops_do', 'line_adjust', jsonb_build_object('line', test.id('r35k_line'), 'amount_cents', 2500, 'reason', 'One hour only'));
select test.eq('the amount is changed with its tax', (select amount_cents || '/' || hst_cents from booking_line_items where id = test.id('r35k_line')), '2500/325');
select test.lives('the next assessment keeps it', $$select app.set_assessed_line(test.id('booking:CC-R35K1'), 'late_return_fee', 'late_return_fee', 1, 16250, 16250, 'x', '{}'::jsonb)$$);
select test.eq('kept', (select amount_cents from booking_line_items where id = test.id('r35k_line')), 2500::bigint);
select test.ok('in the booking history', exists (select 1 from booking_events where booking_id = test.id('booking:CC-R35K1') and note like 'Late return fee%changed%One hour only'));
select test.r35k('r35k_admin', 'ops_do', 'line_adjust', jsonb_build_object('line', test.id('r35k_line'), 'waive', true, 'reason', 'Traffic, first time'));
select test.eq('waived, and the next assessment does not bring it back',
  (select app.set_assessed_line(test.id('booking:CC-R35K1'), 'late_return_fee', 'late_return_fee', 1, 16250, 16250, 'x', '{}'::jsonb) is null), true);

-- ================================================================ 12. an expired hold, released by expiry
insert into deposits (booking_id, amount_cents, method, status, taken_at, hold_expires_at) values (test.id('booking:CC-R35K1'), 50000, 'card_hold', 'held', now() - interval '9 days', now() - interval '2 days');
select test.r35k('r35k_fleet', 'ops_do', 'deposit_expired_settle', jsonb_build_object('booking', 'CC-R35K1'));
select test.eq('settled, released by expiry, no money moved', (select status || '/' || released_cents from deposits where booking_id = test.id('booking:CC-R35K1')), 'settled/50000');
select test.throws('only an expired hold', $$select test.r35k('r35k_fleet', 'ops_do', 'deposit_expired_settle', '{"booking": "CC-R35K1"}')$$, 'not an expired card hold');

-- ================================================================ 13. Close ended trips
select test.mk_booking('CC-R35K2', 'R35KA', 'r35k_r', '2026-10-05 10:00', '2026-10-06 10:00', 'confirmed', 10000);
select test.mk_booking('CC-R35K3', 'R35KA', 'r35k_r', '2026-10-08 10:00', '2026-10-09 10:00', 'returned', 10000);
insert into deposits (booking_id, amount_cents, method, status, taken_at, hold_expires_at) values (test.id('booking:CC-R35K3'), 30000, 'card_hold', 'held', now() - interval '20 days', now() - interval '13 days');
select test.eq('the list: never picked up, and returned not closed', (select string_agg(x ->> 'booking_number', ',' order by x ->> 'booking_number') from jsonb_array_elements(test.r35k('r35k_fin', 'ops_read', 'ended_trips') -> 'rows') x
  where x ->> 'booking_number' like 'CC-R35K%'), 'CC-R35K1,CC-R35K2,CC-R35K3');
select test.throws('customer service does not close trips', $$select test.r35k('r35k_cs', 'ops_read', 'ended_trips')$$);
select test.throws('Fleet cannot mark a no-show', $$select test.r35k('r35k_fleet', 'ops_do', 'ended_trip_close', '{"booking": "CC-R35K2", "mark": "no_show"}')$$, 'no-show');
select test.eq('a returned trip with an expired hold is settled by expiry when closed', (test.r35k('r35k_fin', 'ops_do', 'ended_trip_close', '{"booking": "CC-R35K3", "deposit": "full"}') ->> 'released_by_expiry')::boolean, true);
select test.eq('bulk: one call, the problems listed', (test.r35k('r35k_admin', 'ops_do', 'ended_trips_close_many', jsonb_build_object('bookings', jsonb_build_array(test.id('booking:CC-R35K2')), 'mark', 'no_show')) ->> 'closed')::int, 1);
select test.eq('the no-show is recorded', (select status::text from bookings where id = test.id('booking:CC-R35K2')), 'no_show');
select test.ok('nothing is released by itself: no decision waits without an Admin', not exists (select 1 from trip_close_decisions where status = 'done' and done_by is null));

-- ================================================================ 14. the live map count
select test.mk_booking('CC-R35K4', 'R35KA', 'r35k_r', to_char(now() at time zone 'America/Toronto' - interval '1 day', 'YYYY-MM-DD HH24:MI'), to_char(now() at time zone 'America/Toronto' + interval '1 day', 'YYYY-MM-DD HH24:MI'), 'confirmed', 10000);
select test.ok('On rent now counts a trip whose pickup was never recorded', (app.live_map(test.id('r35k_admin'), '{}'::jsonb) -> 'kpi' ->> 'on_rent_now')::int >= 1);
select test.ok('the live map has Working now and the week''s leaderboard', app.live_map(test.id('r35k_admin'), '{}'::jsonb) ?& array['working', 'leaderboard']);
