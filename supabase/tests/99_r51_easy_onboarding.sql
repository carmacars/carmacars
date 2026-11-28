-- 99: R51 easy onboarding (migration 5197, REQ-135; docs/changes/2026-11-27-r51-staff.md). A staff member in the state the
-- owner reported (Nov 27): Sales and Field, the academy waived, no agreement made (the agreements job gave up after 5 tries),
-- when they can work not set, the WhatsApp groups not confirmed. Welcome names the next step, every step left has its
-- button, Sign now clears the job's stop so the agreement is made at once, and the Admins hear what only they can set.
-- Fixtures start with "eo51".
select test.suite('99 r51 easy onboarding: Sign now, the pay step, the next step, no dead end');

select test.mk_user('eo51_admin', 'admin');
select test.mk_user('eo51_new', 'va', 'sales');
-- Sales and Field, a member who is not exempt, the academy waived, no agreement and no availability
insert into user_roles (user_id, role) values (test.id('eo51_new'), 'field') on conflict do nothing;
update staff_profiles set onboarding_exempt = false, functions = array['sales', 'field']::text[], field_function = 'driver_detailer', is_active = true
 where user_id = test.id('eo51_new');
insert into academy_waivers (user_id, waived_by, reason) values (test.id('eo51_new'), test.id('eo51_admin'), 'Experienced');
-- the job tried 5 times and stopped (the state that left the page with nothing to press)
insert into staff_agreement_auto (user_id, tries, last_at, last_error) values (test.id('eo51_new'), 5, now(), 'made up failure for the test')
  on conflict (user_id) do update set tries = 5, last_at = now(), last_error = excluded.last_error;

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.step(p_key text) returns jsonb language sql as
$$ select x from jsonb_array_elements(pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') -> 'steps') x where x ->> 'key' = p_key $$;

-- ---------------------------------------------------------------- 1. the state
select test.eq('the person is held at the agreement', app.staff_onboarding_state(test.id('eo51_new')) ->> 'step', 'agreement');
select test.eq('no agreement was made (state none)', pg_temp.step('agreement') ->> 'state', 'none');
select test.eq('the academy step is done (waived)', (pg_temp.step('academy') ->> 'done')::boolean, true);
select test.ok('the job skips them (5 tries)', test.id('eo51_new') not in (select app.staff_agreements_due_rows(1000)));

-- ---------------------------------------------------------------- 2. Welcome: the next step and the pay step
select test.eq('an unfinished profile comes first', pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') ->> 'next', 'profile');
update users set greeting_name = 'Eo', phone = '+16475550151', phone_verified_at = now() where id = test.id('eo51_new');
update staff_profiles set location_city = 'Toronto', location_country = 'CA' where user_id = test.id('eo51_new');
select test.eq('the profile is done', (pg_temp.step('profile') ->> 'done')::boolean, true);
select test.eq('Welcome names the agreement as the next step', pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') ->> 'next', 'agreement');
select test.ok('the pay details step is listed, not done, not holding the portal',
  pg_temp.step('pay') is not null and not (pg_temp.step('pay') ->> 'done')::boolean and (pg_temp.step('pay') ->> 'required') = 'false');
select test.ok('the pay step comes before the first tasks',
  (select n from jsonb_array_elements(pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') -> 'steps') with ordinality t(x, n) where x ->> 'key' = 'pay')
  < coalesce((select n from jsonb_array_elements(pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') -> 'steps') with ordinality t(x, n) where x ->> 'key' = 'tasks'), 1000));
select test.ok('when they can work is a step (Field) and not done', pg_temp.step('availability') is not null and not (pg_temp.step('availability') ->> 'done')::boolean);

-- ---------------------------------------------------------------- 3. Sign now
select test.eq('Sign now answers the state (none, now due)',
  (select (r ->> 'state') || ':' || (r ->> 'due') from (select pg_temp.dr('eo51_new', 'ops_do', 'staff_agreement_now') r) x), 'none:true');
select test.ok('the job''s stop is cleared for them: they are due now', test.id('eo51_new') in (select app.staff_agreements_due_rows(1000)));
select test.eq('the wait and the tries are reset', (select tries || ':' || coalesce(last_at::text, 'none') from staff_agreement_auto where user_id = test.id('eo51_new')), '0:none');
-- still missing a value only an Admin sets: the Admins hear it, urgently, with what is missing
select test.eq('help alerts the Admins', pg_temp.dr('eo51_new', 'ops_do', 'staff_agreement_help', '{"missing": ["Start date"]}') ->> 'alerted', 'true');
select test.eq('the alert is urgent and names what is missing',
  (select (code = 'staff_alert_urgent') || ':' || (payload ->> 'alert_body' like 'Missing: Start date.%') from app_events
    where payload ->> 'rule' = 'staff_agreement_stuck' and entity_id = test.id('eo51_new') order by id desc limit 1), 'true:true');
select test.eq('the alert opens the staff list for the Admin',
  (select payload ->> 'path_admin' from app_events where payload ->> 'rule' = 'staff_agreement_stuck' and entity_id = test.id('eo51_new') order by id desc limit 1), '/admin/settings/staff');

-- once the agreement is sent, Sign now changes nothing and Welcome's next step is still the agreement (to sign)
select pg_temp.dr('eo51_admin', 'ops_do', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('eo51_new'),
  'title', 'Staff agreement, test', 'document', jsonb_build_object('path', 'staff/eo51/sa.pdf', 'sha256', repeat('b', 64))));
select test.eq('sent: Sign now answers sent and resets nothing', pg_temp.dr('eo51_new', 'ops_do', 'staff_agreement_now') ->> 'state', 'sent');
select test.eq('sent: the agreement step is ready to sign', pg_temp.step('agreement') ->> 'state', 'sent');
select test.eq('sent: help does not alert again', pg_temp.dr('eo51_new', 'ops_do', 'staff_agreement_help') ->> 'alerted', 'false');

-- signed (waived here: the e-signature has its own suite): the next step moves on
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('eo51_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id('eo51_new');
select test.ok('after the agreement the next step is one the person can do (the groups or when they can work)',
  pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') ->> 'next' in ('team', 'availability', 'profile'), pg_temp.dr('eo51_new', 'ops_read', 'staff_welcome') ->> 'next');
select test.eq('the WhatsApp step is open now', (pg_temp.step('team') ->> 'open')::boolean, true);

-- ---------------------------------------------------------------- 4. only staff, only their own
select test.throws('a person with no staff record cannot ask for a staff agreement', $$select app.staff_agreement_now(test.id('eo51_admin'))$$, 'Only staff');
select test.eq('the browser roles cannot call it', has_function_privilege('authenticated', 'app.staff_agreement_now(uuid)', 'execute'), false);
