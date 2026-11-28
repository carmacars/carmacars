-- 99: R50 hotfix 2, academy and field routing (migrations 5170 to 5173; docs/changes/2026-11-27-r50-hotfix2-academy.md).
-- The basics of each path open the portal, the leads and the work; the whole academy opens commission, bonuses and referral
-- fees (refused with the reason, kept out of pay lines; hours worked are always paid); an Admin opens any lesson and quiz; a person stuck on a page gets its section,
-- required before that area opens again; the academy is shorter and every question kept is taught by its lessons. Field
-- routing with shifts paused, on data shaped like production on Nov 27 (one field person on today's 10:00 to 17:00 shift, every
-- open job with nobody): work not done carries over, every pickup and return of the day reaches the person on shift, days
-- without a shift go to the shift before (pickups) or after (returns). Fixtures start with "bas".
select test.suite('99 r50h2 academy basics, payouts, stuck sections, field routing paused');
grant usage on schema test to service_role;

select test.mk_user('bas_admin', 'admin');
select test.mk_user('bas_cs', 'va', 'cs');          -- a customer service learner held by the gate
select test.mk_user('bas_fleet', 'va', 'fleet');
select test.mk_user('bas_sales', 'va', 'sales');      -- a salesperson: Sales opens on the basics
select test.mk_user('bas_field', 'field');           -- the field person on today's shift (the production case)
select test.mk_user('bas_field2', 'field');
update staff_profiles set onboarding_exempt = false, agreement_waived_at = now(), agreement_waived_by = test.id('bas_admin'), agreement_waived_reason = 'Signed on paper',
       whatsapp_joined = array['team'], onboarding_approved_at = now(), onboarding_approved_by = test.id('bas_admin')
 where user_id in (test.id('bas_cs'), test.id('bas_fleet'), test.id('bas_sales'));
update program_settings set academy_gate = true, staff_onboarding_gate = true, academy_read_wpm = 0, academy_fail_cooldown_minutes = 2, academy_attempts_per_day = 10
 where id = (app.settings()).id;
insert into academy_enrollments (user_id, path_code, source, gate, lock_from) values (test.id('bas_cs'), 'cs', 'admin', true, now() - interval '1 day');
insert into academy_enrollments (user_id, path_code, source, gate, lock_from)
select test.id('bas_sales'), c, 'admin', true, now() - interval '1 day' from unnest(app.academy_paths_of(test.id('bas_sales'))) c on conflict do nothing;

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
-- pass a section by its quiz (every answer right)
create function pg_temp.pass(p_user text, p_slug text) returns boolean language plpgsql as $$
begin
  perform pg_temp.dr(p_user, 'ops_do', 'academy_opened', jsonb_build_object('section', p_slug));
  perform pg_temp.dr(p_user, 'ops_do', 'academy_quiz_start', jsonb_build_object('section', p_slug));
  return (pg_temp.dr(p_user, 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', p_slug, 'answers',
    (select jsonb_object_agg(q.id::text, q.answer) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = p_slug))) ->> 'passed')::boolean;
end $$;

-- ================================================================ 1. the basics (5170)
select test.eq('basics: the first sections of each path', (select string_agg(code || '=' || core_count, ',' order by code) from academy_paths),
  'admin=4,cs=5,field=5,finance=5,fleet=4,manager=0,renter_side=0,sales_in_person=6,sales_remote=5'); -- R51 (5206): the Managers path has no basics
select test.eq('basics: the field Today is the 5th field section', (select s.slug from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = 'field' and ps.sort = 5), 'new-r35-field-today');
select test.eq('basics: field sorts stay 1 to N', (select count(*) = max(sort) from academy_path_sections where path_code = 'field'), true);
-- the owner (Nov 27 15:05): Field, customer service, Finance and Fleet stay locked until the full academy; Sales and Admins open on the basics
select test.eq('who needs the full academy for the portal: customer service, Fleet, Field yes; Sales no', app.academy_hours_role(test.id('bas_cs')) || '/' || app.academy_hours_role(test.id('bas_fleet'))
  || '/' || app.academy_hours_role(test.id('bas_field')) || '/' || app.academy_hours_role(test.id('bas_sales')), 'true/true/true/false');
select test.eq('held before: locked and not done', app.academy_locked(test.id('bas_cs')) || '/' || app.academy_done(test.id('bas_cs')), 'true/false');
select test.eq('the basics of customer service, passed one by one', (select string_agg(pg_temp.pass('bas_cs', s.slug)::text, ',' order by ps.sort)
  from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = 'cs' and ps.sort <= 5), 'true,true,true,true,true');
select test.eq('customer service with the basics only: still locked (the full academy opens the portal)', app.academy_locked(test.id('bas_cs')) || '/' || app.academy_done(test.id('bas_cs')), 'true/false');
select app.staff_onboarding_refresh(test.id('bas_cs'));
select test.eq('customer service with the basics only: not onboarded, the portal stays shut', app.staff_fully_onboarded(test.id('bas_cs')) || '/' || (app.my_roles(test.id('bas_cs')) ->> 'onboarding_locked'), 'false/true');
select test.ok('customer service: every section counts toward the portal', (select (c ->> 'core_total')::int = (c ->> 'total')::int from (select app.academy_counts(test.id('bas_cs')) c) x));
-- Sales: the basics open the portal and the leads
create temp table bas_sp as select (app.academy_paths_of(test.id('bas_sales')))[1] as p;
create temp table bas_spass (sort int, ok boolean);
do $$ declare r record; begin
  for r in select ps.sort, s.slug from academy_path_sections ps join academy_sections s on s.id = ps.section_id join academy_paths ap on ap.code = ps.path_code
            where ps.path_code = (select p from bas_sp) and ps.sort <= ap.core_count order by ps.sort loop
    insert into bas_spass values (r.sort, pg_temp.pass('bas_sales', r.slug));
  end loop; end $$;
select test.eq('the basics of Sales, passed one by one, in order', (select bool_and(ok) and count(*) = (select core_count from academy_paths where code = (select p from bas_sp)) from bas_spass), true);
select test.eq('Sales basics passed: not locked, done, the whole academy not', app.academy_locked(test.id('bas_sales')) || '/' || app.academy_done(test.id('bas_sales')) || '/' || app.academy_full_done(test.id('bas_sales')), 'false/true/false');
-- Sales also joins the Sales WhatsApp group (1151)
update staff_profiles set whatsapp_joined = array['team', 'sales'] where user_id = test.id('bas_sales');
update staff_profiles set onboarding_approved_at = now(), onboarding_approved_by = test.id('bas_admin') where user_id = test.id('bas_sales');
select app.staff_onboarding_refresh(test.id('bas_sales'));
select test.eq('Sales basics passed: fully onboarded (portal and work open), leads gate cleared', app.staff_fully_onboarded(test.id('bas_sales')) || '/' || app.staff_academy_cleared(test.id('bas_sales')), 'true/true');
select test.eq('my_roles: the portal is open', (app.my_roles(test.id('bas_sales')) ->> 'onboarding_locked'), 'false');
select test.ok('Welcome: the academy step counts the basics and is done', (select (s ->> 'done')::boolean and (s ->> 'passed')::int = (s ->> 'sections')::int and (s ->> 'full_sections')::int > (s ->> 'sections')::int
  from jsonb_array_elements(app.staff_welcome(test.id('bas_sales')) -> 'steps') s where s ->> 'key' = 'academy'));
select test.ok('the academy home: the basics done, the counts and the pay hold', (select (h ->> 'basics_done')::boolean and (h -> 'counts' ->> 'core_passed')::int = (h -> 'counts' ->> 'core_total')::int and h ->> 'pay_hold' like 'Academy not finished:%'
  from (select app.academy_home(test.id('bas_sales')) h) x));
select test.ok('a section carries core: the first ones of the Sales path', (select bool_and((s ->> 'core')::boolean = ((s ->> 'sort')::int <= (select core_count from academy_paths where code = (select p from bas_sp))))
  from jsonb_array_elements(app.academy_path_progress(test.id('bas_sales'), (select p from bas_sp)) -> 'sections') s));

-- ================================================================ 2. pay waits for the whole academy (5170, REQ-067)
-- The owner (Nov 27 12:36): "Pay for hours should also be held until academy is passed. Field staff must finish entire academy.
-- Same with customer service and fleet and finance." Commission, bonuses and referral fees wait for everyone.
-- bas_sales: mid-academy (the basics only) with an approved commission
select test.mk_owner('bas_po');
select test.mk_vehicle('BASPAY', 'bas_po', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_renter('bas_pr');
select test.mk_booking('BAS-P1', 'BASPAY', 'bas_pr', (app.today() - 20)::text || ' 10:00', (app.today() - 18)::text || ' 10:00', 'closed', 20000);
insert into staff_commissions (booking_id, staff_id, kind, scheme, month, rental_days, base_cents, rate_bps, amount_cents, status, approved_at)
values (test.id('booking:BAS-P1'), test.id('bas_sales'), 'commission', 'flat', app.month_start(app.today()), 2, 20000, 1000, 2000, 'approved', now() - interval '1 day');
select test.ok('pay hold: the reason names the sections passed (the entire academy) and the release on the next pay run',
  app.academy_pay_hold(test.id('bas_sales')) ~ '^Academy not finished: \d+ of \d+ sections passed\. Held pay .* is paid in full on the first pay run after the whole academy is passed');
select test.eq('pay hold: the entire academy, not the basics (Sales has passed its basics)', app.academy_done(test.id('bas_sales')) || '/' || (app.academy_pay_hold(test.id('bas_sales')) is not null), 'true/true');
select test.eq('the hours part covers Field, customer service, Fleet and Finance, not Sales', app.academy_hours_role(test.id('bas_cs')) || '/' || app.academy_hours_role(test.id('bas_fleet'))
  || '/' || app.academy_hours_role(test.id('bas_field')) || '/' || app.academy_hours_role(test.id('bas_sales')), 'true/true/true/false');
select test.eq('the setting is on by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'academy_hold_hours'), 'true');
select test.eq('pay hold: none for an Admin or an exempt person', coalesce(app.academy_pay_hold(test.id('bas_admin')), 'none') || '/' || coalesce(app.academy_pay_hold(test.id('bas_field2')), 'none'), 'none/none');
select test.throws('commission is held: a commission payout to a person mid-academy is refused with the reason',
  $$insert into staff_commission_payouts (staff_id, method, reference, paid_on, amount_cents, recorded_by) values (test.id('bas_sales'), 'e_transfer', 'REF1', app.today(), 2000, test.id('bas_admin'))$$, 'Academy not finished');
select test.eq('commission is held: it stays out of a new pay line, carried', (select (c ->> 'cents') || '/' || (c ->> 'carried_cents') from (select app.fp_commissions(test.id('bas_sales'), app.today()) c) x), '0/2000');
insert into field_pay_runs (id, period_start, period_end, status, settings) values (test.id('run:bas'), app.today() - 14, app.today() - 1, 'approved', '{}');
insert into field_pay_lines (id, run_id, staff_id, rate_cents, wage_cents, gross_cents, statement_number) values
  (test.id('line:bas_cs'), test.id('run:bas'), test.id('bas_cs'), 2000, 40000, 40000, 'BAS-1'),
  (test.id('line:bas_f2'), test.id('run:bas'), test.id('bas_field2'), 1800, 18000, 18000, 'BAS-2'),
  (test.id('line:bas_sa'), test.id('run:bas'), test.id('bas_sales'), 2000, 30000, 30000, 'BAS-3'),
  (test.id('line:bas_fl'), test.id('run:bas'), test.id('bas_fleet'), 2000, 20000, 20000, 'BAS-5');
select test.throws('hourly pay is held: customer service mid-academy, the pay line cannot be marked paid',
  $$select app.field_pay_line_paid(test.id('bas_admin'), jsonb_build_object('line_id', test.id('line:bas_cs'), 'method', 'cash'))$$, 'Academy not finished');
select test.eq('the payroll lines: Held (pay), nothing, Commission held, Held',
  (select string_agg(coalesce(app.payroll_line_json(l) ->> 'academy_hold_kind', 'none'), '/' order by statement_number) from field_pay_lines l where run_id = test.id('run:bas')), 'pay/none/commission/pay');
-- the owner can turn the hours part off later (one setting)
update program_settings set academy_hold_hours = false where id = (app.settings()).id;
select test.eq('hours part off: Fleet''s hourly pay is paid mid-academy', (app.field_pay_line_paid(test.id('bas_admin'), jsonb_build_object('line_id', test.id('line:bas_fl'), 'method', 'cash')) ->> 'status'), 'paid');
update program_settings set academy_hold_hours = true where id = (app.settings()).id;
select test.eq('Record all payments pays the rest and holds customer service''s line', (select (r ->> 'paid') || '/' || (r ->> 'held') || '/' || (r ->> 'commission_held') from (
  select app.payroll_pay_all(test.id('bas_admin'), jsonb_build_object('run_id', test.id('run:bas'), 'method', 'cash')) r) x), '2/1/1');
select test.eq('the held line waits, marked held', (select status || '/' || (academy_held_at is not null) from field_pay_lines where id = test.id('line:bas_cs')), 'pending/true');
select test.ok('the held person is told their pay waits', exists (select 1 from app_events e where e.entity = 'field_pay_line' and e.entity_id = test.id('line:bas_cs') and e.payload ->> 'rule' = 'academy_pay_held'));
-- review 5: told once a pay period, however often Record all payments runs
do $$ begin perform app.payroll_pay_all(test.id('bas_admin'), jsonb_build_object('run_id', test.id('run:bas'), 'method', 'cash')); exception when others then null; end $$;
select test.eq('the commission held alert: once a person a pay period', (select count(*) from app_events e join field_pay_lines y on y.id = e.entity_id
  where e.entity = 'field_pay_line' and e.payload ->> 'rule' = 'academy_pay_held' and y.staff_id = test.id('bas_sales')), 1::bigint);
-- review 4: the line says Commission held only when a commission of its period is actually held
insert into field_pay_runs (id, period_start, period_end, status, settings) values (test.id('run:bas_old'), app.today() - 40, app.today() - 27, 'approved', '{}');
insert into field_pay_lines (id, run_id, staff_id, rate_cents, wage_cents, gross_cents, statement_number) values
  (test.id('line:bas_sa_old'), test.id('run:bas_old'), test.id('bas_sales'), 2000, 10000, 10000, 'BAS-4');
select test.eq('no Commission held on a line whose period has no held commission (approved after it ended)',
  app.payroll_line_json((select l from field_pay_lines l where l.id = test.id('line:bas_sa_old'))) ->> 'academy_hold', null::text);
-- review 3: the pay_statement method skips the hold only on the statement path itself
select test.throws('a commission payout marked pay statement outside a pay line is held too',
  $$insert into staff_commission_payouts (staff_id, method, reference, paid_on, pay_period, amount_cents, recorded_by) values (test.id('bas_sales'), 'pay_statement', 'X', app.today(), app.month_start(app.today()), 2000, test.id('bas_admin'))$$, 'Academy not finished');
select test.throws('an Admin''s manual commission payout (Record payout) meets the hold, whatever the method',
  $$select app.commission_payout_record(test.id('bas_admin'), jsonb_build_object('staff', test.id('bas_sales'), 'method', 'pay_statement', 'pay_period', app.today()))$$, 'Academy not finished');
select test.throws('...by e-Transfer too',
  $$select app.commission_payout_record(test.id('bas_admin'), jsonb_build_object('staff', test.id('bas_sales'), 'method', 'e_transfer', 'reference', 'ET-555'))$$, 'Academy not finished');
select test.ok('the held person is told their commission waits', exists (select 1 from app_events e where e.entity = 'field_pay_line' and e.entity_id = test.id('line:bas_sa')));
insert into academy_waivers (user_id, reason, waived_by) values (test.id('bas_sales'), 'Trained in person', test.id('bas_admin'));
select test.eq('the waiver releases commission: it joins the next pay line', app.fp_commissions(test.id('bas_sales'), app.today()) ->> 'cents', '2000');
select test.ok('the waiver releases commission: the Admin''s Record payout goes through', app.commission_payout_record(test.id('bas_admin'), jsonb_build_object('staff', test.id('bas_sales'), 'method', 'e_transfer', 'reference', 'REF2')) is not null);
select test.eq('the waiver releases commission: the payout is recorded', (select count(*) from staff_commission_payouts where staff_id = test.id('bas_sales') and reference = 'REF2'), 1::bigint);
select test.eq('a pay line''s commission is paid on the statement path (the flag is cleared after)', coalesce(current_setting('app.pay_line_commission', true), ''), '');
update academy_waivers set revoked_at = now(), revoked_by = test.id('bas_admin') where user_id = test.id('bas_sales');
-- held pay is never lost: the first pay run after the pass pays the held line in full, with a release note
insert into field_pay_runs (id, period_start, period_end, status, settings) values (test.id('run:bas_next'), app.today() - 70, app.today() - 57, 'approved', '{}');
select test.eq('still held before the pass: the next run leaves it', (select (r ->> 'released') from (
  select app.payroll_pay_all(test.id('bas_admin'), jsonb_build_object('run_id', test.id('run:bas_next'), 'method', 'cash')) r) x), '0');
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('bas_cs'), ps.section_id, 1, 1, 10000, true from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(test.id('bas_cs')));
select test.eq('passed the whole academy: nothing holds them', app.academy_pay_hold(test.id('bas_cs')), null::text);
select test.eq('the first pay run after the pass releases the held line', (select (r ->> 'released') from (
  select app.payroll_pay_all(test.id('bas_admin'), jsonb_build_object('run_id', test.id('run:bas_next'), 'method', 'cash')) r) x), '1');
select test.eq('paid in full, with the release note', (select status || '/' || gross_cents || '/' || (note like '%Held for the academy since%released in full%') from field_pay_lines where id = test.id('line:bas_cs')), 'paid/40000/true');

-- ================================================================ 3. an Admin opens any lesson and quiz (5170)
select test.ok('Admin: every path is listed, every section open', (select (h ->> 'all_paths')::boolean and jsonb_array_length(h -> 'paths') = (select count(*) from academy_paths)
  and not exists (select 1 from jsonb_array_elements(h -> 'paths') p, jsonb_array_elements(p -> 'sections') s where not (s ->> 'open')::boolean)
  from (select app.academy_home(test.id('bas_admin')) h) x));
select test.ok('Admin: the last field section opens with its lessons and quiz, nothing passed before', (select jsonb_array_length(v -> 'lessons') > 0 and jsonb_array_length(v -> 'questions') > 0
  from (select pg_temp.dr('bas_admin', 'ops_read', 'academy_section', jsonb_build_object('path', 'field', 'section', (select s.slug from academy_path_sections ps join academy_sections s on s.id = ps.section_id
    where ps.path_code = 'field' order by ps.sort desc limit 1))) v) x));
select test.eq('Admin: takes that quiz at once', pg_temp.pass('bas_admin', (select s.slug from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = 'field' order by ps.sort desc limit 1)), true);

-- ================================================================ 4. stuck on a page: its section first (5171)
create temp table bas_a1 as select public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/staff/bookings", "lesson": "cs/cs-requests", "reason": "stuck_idle"}') j;
select test.eq('stuck: the page''s section is assigned', (select j ->> 'assigned' from bas_a1), 'true');
select test.ok('stuck: my_roles names the area and the section', (select r ->> 'area' = '/staff/bookings' and r ->> 'href' = '/staff/academy/cs/cs-requests'
  from jsonb_array_elements(app.my_roles(test.id('bas_fleet')) -> 'academy_required') r));
select test.eq('stuck: once, while open', public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/staff/bookings", "lesson": "cs/cs-requests", "reason": "stuck_errors"}') ->> 'why', 'open');
select test.eq('stuck: never an Admin', public.academy_assign_stuck(test.id('bas_admin'), '{"area": "/staff/bookings", "lesson": "cs/cs-requests", "reason": "stuck_idle"}') ->> 'assigned', 'false');
select test.throws('stuck: only a staff area', $$select public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/admin/money", "lesson": "cs/cs-requests", "reason": "stuck_idle"}')$$, 'Not a staff area');
select test.ok('stuck: the person is told (alert academy_assigned)', exists (select 1 from app_events e where e.entity = 'academy_assignment' and e.entity_id = (select (j ->> 'id')::uuid from bas_a1)));
select test.ok('stuck: a section off their path opens to them (lessons and quiz)', jsonb_array_length(pg_temp.dr('bas_fleet', 'ops_read', 'academy_section', '{"path": "cs", "section": "cs-requests"}') -> 'lessons') > 0);
select test.eq('stuck: the section passed', pg_temp.pass('bas_fleet', 'cs-requests'), true);
select test.eq('stuck: passing it clears the area', jsonb_array_length(app.my_roles(test.id('bas_fleet')) -> 'academy_required'), 0);
select test.eq('stuck: not again within 7 days of the pass', public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/staff/bookings", "lesson": "cs/cs-requests", "reason": "stuck_idle"}') ->> 'why', 'recent');
-- repeated browser errors: the setting's count on the area within 30 minutes
insert into client_errors (path, message, user_id, kind) values ('/staff/fleet', 'TypeError: x', test.id('bas_fleet'), 'crash');
select test.eq('errors: one is not repeated', public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/staff/fleet", "lesson": "fleet/fleet-field-jobs", "reason": "client_errors"}') ->> 'why', 'not repeated');
insert into client_errors (path, message, user_id, kind) values ('/staff/fleet', 'TypeError: x', test.id('bas_fleet'), 'crash'), ('/staff/fleet/jobs', 'TypeError: y', test.id('bas_fleet'), 'crash');
select test.eq('errors: three on the area assign its section', public.academy_assign_stuck(test.id('bas_fleet'), '{"area": "/staff/fleet", "lesson": "fleet/fleet-field-jobs", "reason": "client_errors"}') ->> 'assigned', 'true');
select test.eq('Admin sees it on the person', (select r ->> 'area' from jsonb_array_elements(app.academy_gate_state(test.id('bas_fleet')) -> 'required') r), '/staff/fleet');

-- ================================================================ 5. shorter, every question taught (5172)
select test.ok('the audit: the questions the lessons never teach are gone', not exists (select 1 from academy_questions q where q.prompt in (
  'How long are the points of a field job kept?', 'Can Fleet give you prep on a day you have no shift?')));
select test.ok('the audit: the rideshare question stays and its lesson now teaches it', exists (select 1 from academy_lessons l join academy_sections s on s.id = l.section_id
  where s.slug = 'trip-rules' and l.scenes::text ~* 'rideshare and delivery driving are welcome')
  and exists (select 1 from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'trip-rules' and q.prompt ~* 'uber'));
select test.eq('the audit: the prep certificate answer follows the lesson', (select q.options ->> q.answer from academy_questions q join academy_sections s on s.id = q.section_id
  where s.slug = 'new-r35-field-prep' and q.sort = 2), 'The certificate PDF or photo, uploaded');
select test.ok('repetition: the renter''s side is customer service''s only', 'renter_side' = any (app.academy_paths_of(test.id('bas_cs'))) and not ('renter_side' = any (app.academy_paths_of(test.id('bas_fleet')))));

-- ================================================================ 5b. review: no stuck section while the agreement is unsigned; an Admin clears one
create temp table bas_gate as select staff_agreement_gate as g from program_settings where id = (app.settings()).id;
update program_settings set staff_agreement_gate = true where id = (app.settings()).id;
select test.mk_user('bas_unsigned', 'va', 'cs');
update staff_profiles set onboarding_exempt = false, agreement_waived_at = null, agreement_waived_by = null, agreement_waived_reason = null, agreement_lock_from = null
 where user_id = test.id('bas_unsigned');
select test.ok('the agreement is unsigned: locked', app.agreement_locked(test.id('bas_unsigned')));
select test.eq('stuck while the agreement is unsigned: no section is assigned (the academy is not open to them yet)',
  public.academy_assign_stuck(test.id('bas_unsigned'), jsonb_build_object('area', '/staff/bookings', 'lesson', 'cs/cs-requests', 'reason', 'stuck_idle')) ->> 'why', 'agreement');
insert into academy_assignments (id, user_id, section_id, path_code, area, reason)
select test.id('asg:bas_unsigned'), test.id('bas_unsigned'), s.id, 'cs', '/staff/bookings', 'stuck_idle' from academy_sections s where s.slug = 'cs-requests';
select test.eq('an open section never holds them while the agreement is unsigned (no loop from the documents)', jsonb_array_length(app.academy_required(test.id('bas_unsigned'))), 0);
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('bas_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id('bas_unsigned');
select test.eq('signed or waived: the section holds that area again', jsonb_array_length(app.academy_required(test.id('bas_unsigned'))), 1);
select test.throws('clear: Admins only', $$select public.door(test.id('bas_fleet'), 'aal2', 'admin_do', 'academy_assignment_clear', jsonb_build_object('id', test.id('asg:bas_unsigned'), 'reason', 'Shown in person'))$$, null);
select test.throws('clear: with a reason', $$select public.door(test.id('bas_admin'), 'aal2', 'admin_do', 'academy_assignment_clear', jsonb_build_object('id', test.id('asg:bas_unsigned'), 'reason', ''))$$, 'reason');
select test.eq('clear: an Admin clears it', public.door(test.id('bas_admin'), 'aal2', 'admin_do', 'academy_assignment_clear', jsonb_build_object('id', test.id('asg:bas_unsigned'), 'reason', 'Shown in person')) ->> 'ok', 'true');
select test.ok('clear: logged with who and why, and the area opens', exists (select 1 from academy_assignments a where a.id = test.id('asg:bas_unsigned') and a.done_at is not null and a.cleared_by = test.id('bas_admin') and a.clear_reason = 'Shown in person')
  and exists (select 1 from audit_log l where l.after ->> 'clear_reason' = 'Shown in person') and jsonb_array_length(app.academy_required(test.id('bas_unsigned'))) = 0);
select test.throws('clear: only an open one', $$select app.academy_assignment_clear(test.id('bas_admin'), jsonb_build_object('id', test.id('asg:bas_unsigned'), 'reason', 'Again'))$$, 'not required');
update program_settings set staff_agreement_gate = (select g from bas_gate) where id = (app.settings()).id;

-- ================================================================ 6. field routing with shifts paused (5173)
-- the settings 5173 leaves (other files of a CI slice set field_jobs_auto_assign to none for their own cases)
update program_settings set field_slots_auto = false, field_jobs_auto_assign = 'least_busy' where id = (app.settings()).id;
select test.eq('paused: no slot publishes by itself, routing on', (app.settings()).field_slots_auto || '/' || (app.settings()).field_jobs_auto_assign, 'false/least_busy');
select test.eq('paused: the auto publisher does nothing', app.field_slots_auto_publish(now()) ->> 'off', 'true');
-- production-like: earlier suites' shifts and open work cleared; one person on yesterday's and today's 10:00 to 17:00 shift
delete from field_shift_offers; delete from field_shift_plans;
select set_config('app.fx_no_slot', 'on', false); update field_jobs set shift_slot_id = null where shift_slot_id is not null;
update field_jobs set status = 'cancelled' where status in ('scheduled', 'acknowledged');
delete from field_shift_slots;
select test.mk_owner('bas_o');
select test.mk_vehicle('BASCAR', 'bas_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
create function pg_temp.at(p_days integer, p_hour integer) returns timestamptz language sql as $$
  select ((app.today() + p_days)::timestamp + make_interval(hours => p_hour)) at time zone 'America/Toronto' $$;
create function pg_temp.shift(p_label text, p_who text, p_days integer) returns uuid language plpgsql as $$
begin
  insert into field_shift_slots (id, starts_at, ends_at, capacity, note) values (test.id(p_label), pg_temp.at(p_days, 10), pg_temp.at(p_days, 17), 1, 'bas');
  if p_who is not null then
    insert into field_shift_plans (slot_id, staff_id, starts_at, ends_at) values (test.id(p_label), test.id(p_who), pg_temp.at(p_days, 10), pg_temp.at(p_days, 17));
  end if;
  return test.id(p_label);
end $$;
create function pg_temp.job(p_label text, p_kind text, p_at timestamptz, p_slot uuid default null) returns uuid language sql as $$
  insert into field_jobs (id, kind, vehicle_id, scheduled_at, auto_created, shift_slot_id) values (test.id(p_label), p_kind, test.id('vehicle:BASCAR'), p_at, true, p_slot) returning id $$;
select pg_temp.shift('slot:bas_yday', 'bas_field', -1);
select pg_temp.shift('slot:bas_today', 'bas_field', 0);
-- the jobs as production had them: every one with nobody (field_jobs_auto_assign was 'none')
select pg_temp.job('job:bas_old', 'return_check_in', pg_temp.at(-1, 11), test.id('slot:bas_yday'));   -- yesterday's shift, not done
select pg_temp.job('job:bas_late', 'pickup_from_renter', pg_temp.at(-1, 22));                          -- last night, after the shift
select pg_temp.job('job:bas_night', 'handover', pg_temp.at(0, 23));                                     -- tonight, after today's shift
select pg_temp.job('job:bas_tmr_ret', 'return_check_in', pg_temp.at(1, 10));                           -- tomorrow, no shift, no shift after
select pg_temp.job('job:bas_tmr_pick', 'handover', pg_temp.at(1, 9));                                  -- tomorrow morning, no shift
select set_config('app.fx_no_slot', 'off', false);
-- the routing run of a moment inside today's shift (the hourly job passes now)
select test.eq('the run routes the open work', app.field_route_run(pg_temp.at(0, 12)), '5 field job(s) routed to a shift, 0 with no shift anybody works');
create function pg_temp.where_is(p_label text) returns text language sql as $$
  select coalesce((select case j.shift_slot_id when test.id('slot:bas_today') then 'today' when test.id('slot:bas_d2') then 'd2' when test.id('slot:bas_yday') then 'yday' else 'other' end
                     || ':' || coalesce(split_part(u.full_name, ' ', 2), 'nobody')
                     from field_jobs j left join users u on u.id = j.assigned_to where j.id = test.id(p_label)), 'none') $$;
select test.eq('(a) carried over: yesterday''s return not done goes to today''s shift and its person', pg_temp.where_is('job:bas_old'), 'today:Field');
select test.eq('(a) last night''s return with nobody goes to the next shift', pg_temp.where_is('job:bas_late'), 'today:Field');
select test.eq('(b) tonight''s handover after the shift: today''s shift', pg_temp.where_is('job:bas_night'), 'today:Field');
select test.eq('(c) tomorrow''s handover, no shift: the shift before', pg_temp.where_is('job:bas_tmr_pick'), 'today:Field');
select test.eq('(c) tomorrow''s return, no shift after it: the shift before', pg_temp.where_is('job:bas_tmr_ret'), 'today:Field');
-- a held shift the day after tomorrow: a return tomorrow evening goes after, a pickup that day goes on it
select pg_temp.shift('slot:bas_d2', 'bas_field2', 2);
select test.eq('(c) a return the evening before a shift: the shift after', app.fx_route_slot('return_check_in', pg_temp.at(1, 20), pg_temp.at(0, 12)), test.id('slot:bas_d2'));
select test.eq('(c) a pickup before that shift starts, a day without one: the shift before', app.fx_route_slot('handover', pg_temp.at(1, 20), pg_temp.at(0, 12)), test.id('slot:bas_today'));
select pg_temp.job('job:bas_d2', 'handover', pg_temp.at(2, 12));
select test.eq('a new job on a day with a shift goes on it', pg_temp.where_is('job:bas_d2'), 'd2:Field2');
-- the Admin's own job of today (no shift), as Fleet gives one by hand
insert into field_jobs (id, kind, vehicle_id, scheduled_at, assigned_to) values (test.id('job:bas_admin'), 'handover', test.id('vehicle:BASCAR'), pg_temp.at(0, 14), test.id('bas_admin'));
-- (b) Today of the person on shift: every pickup and return of the day, and what comes before the next shift
create temp table bas_today as select app.fx_today(test.id('bas_field'), app.today()) t;
select test.ok('(b) Today: the routed work is the person''s own cards', (select bool_and(exists (select 1 from jsonb_array_elements(t -> 'cards') c where c ->> 'id' = test.id(l)::text))
  from bas_today, unnest(array['job:bas_old', 'job:bas_late', 'job:bas_night', 'job:bas_tmr_pick', 'job:bas_tmr_ret']) l));
select test.ok('(b) Today: a pickup of the day held by someone else is listed too', (select exists (select 1 from jsonb_array_elements(t -> 'mates') m where m ->> 'id' = test.id('job:bas_admin')::text) from bas_today));
select test.ok('(b) Today: every pickup and return of the day reaches the person on shift', (select bool_and(exists (select 1 from jsonb_array_elements((t -> 'cards') || (t -> 'mates')) c where c ->> 'id' = j.id::text))
  from bas_today, field_jobs j where app.fx_job_day(j) = app.today() and j.status not in ('cancelled', 'done') and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')));
select test.ok('(b) Today: the work up to the next shift, to prep the car', (select exists (select 1 from jsonb_array_elements(t -> 'ahead') a where a ->> 'id' = test.id('job:bas_d2')::text)
  and (t ->> 'next_shift_day')::date = app.today() + 2 from bas_today));
select test.eq('(b) Take it: the person on shift takes the day''s job from the Admin', (app.fx_job_take(test.id('bas_field'), jsonb_build_object('job', test.id('job:bas_admin'))) ->> 'id')::uuid, test.id('job:bas_admin'));
select test.eq('(b) taken: on their shift', pg_temp.where_is('job:bas_admin'), 'today:Field');
-- (a) later: today's shift ended with work not done: it carries over to the next shift
select test.eq('(a) after the shift: the work not done moves to the next shift', app.field_route_run(pg_temp.at(0, 18)) not like '0 field job(s) routed%', true);
select test.eq('(a) carried over to the shift after', pg_temp.where_is('job:bas_night'), 'd2:Field2');
select test.ok('the hourly job runs the routing', app.job_field_shift_plan(now()) like '%field job(s) routed to a shift%');
-- review 2: never onto a shift nobody works; a job left on one moves; with no shift anybody works, unassigned and one Fleet To do
select pg_temp.shift('slot:bas_empty', null, 3);
select test.eq('a shift somebody works comes first (a return on the day of an empty shift goes to the worked shift before)', app.fx_route_slot('return_check_in', pg_temp.at(3, 12), pg_temp.at(0, 18)), test.id('slot:bas_d2'));
select set_config('app.fx_no_slot', 'on', false);
select pg_temp.job('job:bas_onempty', 'handover', pg_temp.at(3, 12), test.id('slot:bas_empty'));
select pg_temp.job('job:bas_far', 'handover', pg_temp.at(30, 12), test.id('slot:bas_empty'));
select set_config('app.fx_no_slot', 'off', false);
select test.eq('the run: a job on a shift nobody works moves; one with no worked shift near it is left unassigned', app.field_route_run(pg_temp.at(0, 18)), '1 field job(s) routed to a shift, 1 with no shift anybody works');
select test.eq('moved to the worked shift', pg_temp.where_is('job:bas_onempty'), 'd2:Field2');
select test.eq('no worked shift: unassigned, off the empty shift', (select coalesce(shift_slot_id::text, 'none') || '/' || coalesce(assigned_to::text, 'nobody') from field_jobs where id = test.id('job:bas_far')), 'none/nobody');
select app.field_route_run(pg_temp.at(0, 18));
select test.eq('Fleet gets one To do for it, not one a run', (select count(*) from tasks where dedupe_key = 'field_jobs_no_shift' and queue = 'fleet' and status = 'open'), 1::bigint);
