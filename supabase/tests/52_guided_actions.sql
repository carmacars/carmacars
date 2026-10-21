-- 52: guided actions (the guided actions migration). Insurer confirmed for one car and for several (the onboarding past
-- the insurer step, the flag, the Enrollment Date, the owner's T22, the audit, the paperwork kept open, a listed car
-- keeping its status); the texts that name the button; the handover gate; renter documents reviewed by an Admin or
-- customer service with no task; the To do prompts (each appears with its work and disappears when done); Publish now
-- with the rates in one step; tasks closed by rule; assistant tasks and staff emails falling back to the Admin while no
-- real assistant holds the function; privileges. Fixtures start with "ga".
select test.suite('52 guided actions');

select test.mk_user('ga_admin', 'admin');
select test.mk_user('ga_cs', 'va', 'cs');
select test.mk_user('ga_fleet', 'va', 'fleet');
select test.mk_user('ga_sales', 'va', 'sales');
select test.mk_owner('ga_own');
select test.mk_vehicle('GA0', 'ga_own');
select test.mk_renter('ga_rita');
select test.mk_renter('ga_rob');

create or replace function test.ga_err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function test.ga_day(p_days integer, p_hour integer default 10) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || lpad(p_hour::text, 2, '0') || ':00' $$;
-- a program owner's car in onboarding at a step, with its unsigned schedule, rates, and optionally its status
create or replace function test.ga_car(p_label text, p_step vehicle_onboarding_status, p_status vehicle_status default 'onboarding',
                                       p_mode management_mode default 'managed') returns uuid
language plpgsql as $$
declare
  v_id uuid := test.id('vehicle:' || p_label);
begin
  insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy)
  values (v_id, test.id('owner:ga_own'), 'F-' || p_label, 2021, 'Volkswagen', 'Jetta ' || p_label, upper(substr(md5(p_label), 1, 17)),
          'G' || upper(substr(md5(p_label), 1, 6)), 'standard', p_status, p_mode,
          case when p_mode = 'turo_only' then 'none'::onboarding_method else 'transfer'::onboarding_method end, false);
  insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status,
      management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps)
  values (test.id('schedule:' || p_label), v_id, test.id('agreement:ga_own'), 'VS-' || p_label, 10 + (select count(*) from vehicle_schedules s where s.owner_agreement_id = test.id('agreement:ga_own')),
          'individual', 'owned_outright', p_mode, case when p_mode = 'turo_only' then 'none'::onboarding_method else 'transfer'::onboarding_method end,
          case when p_mode = 'turo_only' then 0 else 33900 end, 0, 0, 3500);
  insert into vehicle_onboardings (id, vehicle_id, status, terms_set_at) values (test.id('onb:' || p_label), v_id, p_step, now() - interval '3 days');
  insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
        km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
  values (v_id, 7000, 7000, 42000, 154000, 200, 35, 50000, 7500, 7500, now() - interval '1 day');
  return v_id;
end $$;
create or replace function test.ga_prompts() returns jsonb language sql stable as $$
  select app.todo_prompts(test.id('ga_admin')) -> 'prompts' $$;
create or replace function test.ga_has(p_key text) returns boolean language sql stable as $$
  select exists (select 1 from jsonb_array_elements(test.ga_prompts()) x where x ->> 'key' = p_key) $$;
create or replace function test.ga_prompt(p_key text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(test.ga_prompts()) x where x ->> 'key' = p_key $$;
grant execute on all functions in schema test to authenticated, anon;

select test.ga_car('GA1', 'terms_set');
select test.ga_car('GA2', 'documents_sent');
select test.ga_car('GA3', 'terms_set', 'available');     -- listed and Available, never confirmed (the Malibu case)
select test.ga_car('GA4', 'documents_sent', 'onboarding', 'turo_only');
select test.ga_car('GA5', 'terms_set');
insert into vehicle_listings (vehicle_id, slug, status, published_at, first_published_at) values (test.id('vehicle:GA3'), 'ga3-jetta', 'published', now(), now());

-- ================================================================ 1. on the policy, the gate and the texts
select test.eq('a program owner''s car is on the policy only once the insurer confirmed it (in onboarding; listed but never confirmed; an enrolled car)',
  app.vehicle_on_policy(test.id('vehicle:GA1')) || '/' || app.vehicle_on_policy(test.id('vehicle:GA3')) || '/' || app.vehicle_on_policy(test.id('vehicle:GA0')),
  'false/false/true');
select test.ok('the checklist names the button, not a screen that did not exist',
  (select x ->> 'action' from jsonb_array_elements(app.listing_checklist(test.id('vehicle:GA1'))) x where x ->> 'code' = 'insurance') like '%press Insurer confirmed'
  and (select x ->> 'act' from jsonb_array_elements(app.listing_checklist(test.id('vehicle:GA1'))) x where x ->> 'code' = 'insurance') = 'insurer_confirm');
select test.ok('the car''s listing state: the warning names the button, and an Admin and fleet may press it (customer service may not)',
  (app.listing_state(test.id('ga_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'))) ->> 'handover_note') like '%Press Insurer confirmed%'
  and (app.listing_state(test.id('ga_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'))) ->> 'can_insure')::boolean
  and (app.listing_state(test.id('ga_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'))) ->> 'can_insure')::boolean
  and not (app.listing_state(test.id('ga_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'))) ->> 'can_insure')::boolean);
select test.mk_booking('GA-H', 'GA3', 'ga_rita', test.ga_day(-1), test.ga_day(2), 'confirmed');
select test.throws('the handover of a car not on the policy is refused, and the message names the button',
  format('update bookings set status = ''on_rent'', handed_over_at = now() where id = %L', test.id('booking:GA-H')), 'press Insurer confirmed');

-- ================================================================ 2. the prompts before
select test.ok('each car waiting for the insurer has a prompt, with a booking named when one is near (urgent); a Turo-only car has none',
  test.ga_has('insurer:' || test.id('vehicle:GA1')) and test.ga_has('insurer:' || test.id('vehicle:GA2')) and not test.ga_has('insurer:' || test.id('vehicle:GA4'))
  and (test.ga_prompt('insurer:' || test.id('vehicle:GA3')) ->> 'priority') = '1'
  and (test.ga_prompt('insurer:' || test.id('vehicle:GA3')) ->> 'why') like 'Booking GA-H picks it up%'
  and (test.ga_prompt('insurer:' || test.id('vehicle:GA1')) ->> 'title') = 'Insurer has not confirmed 2021 Volkswagen Jetta GA1: mark it insured');
select test.ok('several cars waiting: one prompt marks them together, listing each car',
  jsonb_array_length(test.ga_prompt('insurer_bulk') -> 'cars') >= 4);
select test.throws('only an Admin sees the To do', format('select app.todo_prompts(%L)', test.id('ga_cs')), 'Not permitted');

-- ================================================================ 3. Insurer confirmed, one car
select test.throws('customer service cannot mark a car insured', format($$select app.confirm_fleet_policy(%L, '{"vehicle_id": "%s"}')$$, test.id('ga_cs'), test.id('vehicle:GA1')), 'An Admin or fleet');
select test.throws('the date cannot be in the future',
  format($$select app.confirm_fleet_policy(%L, jsonb_build_object('vehicle_id', %L, 'on', app.today() + 1))$$, test.id('ga_admin'), test.id('vehicle:GA1')), 'cannot be in the future');
select test.throws('a Turo-only car is not on the fleet policy',
  format($$select app.confirm_fleet_policy(%L, jsonb_build_object('vehicle_id', %L))$$, test.id('ga_admin'), test.id('vehicle:GA4')), 'Turo-only');
create temp table ga_c1 as select app.confirm_fleet_policy(test.id('ga_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'), 'on', app.today() - 2, 'note', 'Broker email of Oct 19')) as r;
select test.eq('Insurer confirmed: the onboarding is enrolled from the date, the car is on the policy with that date and Enrollment Date, ready to list',
  (select ob.status || '/' || ob.insured_before_paperwork_from || '/' || app.local_date(ob.on_fleet_policy_at) || '/' || app.local_date(ob.enrolled_confirmed_at)
     from vehicle_onboardings ob where ob.id = test.id('onb:GA1'))
  || '|' || (select v.on_fleet_policy || '/' || v.fleet_policy_added_on || '/' || v.enrollment_date || '/' || v.status from vehicles v where v.id = test.id('vehicle:GA1')),
  'enrolled/terms_set/' || (app.today() - 2) || '/' || (app.today() - 2) || '|true/' || (app.today() - 2) || '/' || (app.today() - 2) || '/ready_to_list');
select test.ok('the owner gets the enrollment notice (T22), and it is audited with the note',
  exists (select 1 from app_events e where e.code = 'owner_vehicle_enrolled' and e.entity_id = test.id('onb:GA1'))
  and exists (select 1 from audit_log a where a.action = 'insurer_confirmed' and a.entity_id = test.id('vehicle:GA1')::text and a.actor_user_id = test.id('ga_admin')
                and a.after ->> 'note' = 'Broker email of Oct 19'));
select test.eq('the paperwork stays open: the schedule is not signed, the registry visit is not done',
  (select string_agg(c.code || '=' || c.status, ',' order by c.code) from app.onboarding_checklist(test.id('vehicle:GA1')) c where c.code in ('signatures', 'registry_visit', 'insurer_confirmation')),
  'insurer_confirmation=done,registry_visit=open,signatures=open');
select test.eq('it can now be handed over', app.vehicle_on_policy(test.id('vehicle:GA1')), true);
select test.eq('pressing it again changes nothing', (app.confirm_fleet_policy(test.id('ga_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:GA1'))) ->> 'already'), 'true');
select test.eq('its prompt is gone', test.ga_has('insurer:' || test.id('vehicle:GA1')), false);
-- a listed, Available car keeps its status
select app.confirm_fleet_policy(test.id('ga_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:GA3')));
select test.eq('fleet may press it; a listed Available car stays Available, and the insurance no longer stops its handover (only the renter''s checks remain)',
  (select v.status || '/' || v.on_fleet_policy from vehicles v where v.id = test.id('vehicle:GA3'))
  || '/' || (test.ga_err(format('update bookings set status = ''on_rent'', handed_over_at = now() where id = %L', test.id('booking:GA-H'))) not like '%fleet insurance policy%'),
  'available/true/true');

-- ================================================================ 4. several cars at once
create temp table ga_bulk as select app.confirm_fleet_policy_bulk(test.id('ga_admin'),
  jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:GA2'), test.id('vehicle:GA4'), test.id('vehicle:GA5')), 'on', app.today())) as r;
select test.eq('several at once: each car on its own; the one that cannot is named with the reason',
  (select (r ->> 'count') || '/' || (r -> 'failed' -> 0 ->> 'name') || ': ' || (r -> 'failed' -> 0 ->> 'error') from ga_bulk),
  '2/2021 Volkswagen Jetta GA4: A Turo-only car is not on the CarmaCars fleet policy');
select test.eq('the two are on the policy', (select count(*) from vehicles where id in (test.id('vehicle:GA2'), test.id('vehicle:GA5')) and on_fleet_policy), 2::bigint);
select test.throws('nothing ticked', format($$select app.confirm_fleet_policy_bulk(%L, '{"vehicle_ids": []}')$$, test.id('ga_admin')), 'Tick the cars');
select test.eq('no bulk prompt once fewer than two cars wait', test.ga_has('insurer_bulk'), false);

-- ================================================================ 5. renter documents, reviewed from the booking
select test.mk_booking('GA-D', 'GA0', 'ga_rob', test.ga_day(1), test.ga_day(4), 'confirmed');
update bookings set coverage_option = 1 where id = test.id('booking:GA-D');
select app.register_verification_upload(test.id('booking:GA-D'), test.id('ga_rob'), 'coverage_proof', null, 'renters/ga/GA-D/p1.pdf', md5('ga-d-p1'), 'application/pdf',
  jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-9', 'policy_expiry', app.today() + 60));
update tasks set status = 'cancelled' where booking_id = test.id('booking:GA-D') and task_type in ('verify_renter', 'chase_verification', 'offer_approved_paid');
select test.ok('the documents prompt appears, urgent with the pickup tomorrow',
  (test.ga_prompt('documents:' || test.id('booking:GA-D')) ->> 'priority') = '1'
  and (test.ga_prompt('documents:' || test.id('booking:GA-D')) ->> 'title') = 'Check Ga Rob''s documents for booking GA-D');
select test.eq('an Admin and customer service open the documents with no review task; fleet cannot',
  (app.doc_review_read(test.id('ga_admin'), '{"booking": "GA-D"}') -> 'coverage' -> 'proof' ->> 'status')
  || '/' || (app.va_read(test.id('ga_cs'), 'verification', '{"booking": "GA-D"}') ->> 'booking_number')
  || '/' || test.ga_err(format($$select app.doc_review_read(%L, '{"booking": "GA-D"}')$$, test.id('ga_fleet'))),
  'submitted/GA-D/Only an Admin or customer service reviews identity and coverage documents');
select test.ok('every opening is logged', (select count(*) from data_access_log l where l.reason = 'identity and coverage review, booking GA-D') >= 2);
select test.throws('a rejection needs a reason',
  format($$select app.doc_review_coverage(%L, jsonb_build_object('proof', %L, 'approve', false))$$, test.id('ga_admin'), (select id from app.current_coverage_proof(test.id('booking:GA-D')))), 'needs a reason');
select app.doc_review_coverage(test.id('ga_admin'), jsonb_build_object('proof', (select id from app.current_coverage_proof(test.id('booking:GA-D'))), 'approve', true));
select test.eq('the Admin approves the proof: coverage confirmed, the prompt is gone',
  ((select coverage_confirmed_at is not null from bookings where id = test.id('booking:GA-D'))) || '/' || test.ga_has('documents:' || test.id('booking:GA-D')), 'true/false');

-- ================================================================ 6. Publish now with the rates
insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, supply_type)
values (test.id('vehicle:GA6'), null, 'F-GA6', 2020, 'Honda', 'Civic GA6', upper(substr(md5('GA6'), 1, 17)), 'GAP6', 'standard', 'ready_to_list', 'managed', 'none', true, 'company');
select test.ok('a real car not on the site has a prompt with the suggested daily rate',
  (test.ga_prompt('publish:' || test.id('vehicle:GA6')) -> 'suggested' ->> 'daily_cents')::bigint > 0
  and test.ga_prompt('publish:' || test.id('vehicle:GA6')) -> 'rates' = 'null'::jsonb);
select test.throws('sales cannot publish', format($$select app.todo_publish(%L, jsonb_build_object('vehicle_id', %L, 'daily', 5500))$$, test.id('ga_sales'), test.id('vehicle:GA6')), 'publishes a car');
create temp table ga_pub as select app.todo_publish(test.id('ga_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:GA6'), 'daily', '5500', 'weekly', '33000')) as r;
select test.eq('the rates and Publish now in one step: the card has the rates typed, the car is on the site, the prompt is gone',
  (select daily_rate_cents || '/' || weekly_rate_cents from rate_cards where vehicle_id = test.id('vehicle:GA6') and effective_to is null)
  || '/' || exists (select 1 from public_vehicle_listings p where p.vehicle_id = test.id('vehicle:GA6'))
  || '/' || (select r ->> 'rates_set' from ga_pub) || '/' || test.ga_has('publish:' || test.id('vehicle:GA6')),
  '5500/33000/true/true/false');

-- ================================================================ 7. tasks close by rule
insert into owner_invoices (id, owner_id, vehicle_id, kind, billing_date, status, fees_cents)
values (test.id('inv:ga:1'), test.id('owner:ga_own'), test.id('vehicle:GA2'), 'upfront', app.today(), 'issued', 67800),
       (test.id('inv:ga:2'), test.id('owner:ga_own'), test.id('vehicle:GA5'), 'upfront', app.today(), 'issued', 90400);
select test.ok('an issued upfront invoice has its collection task and a payment prompt',
  exists (select 1 from tasks where related_id = test.id('inv:ga:1') and task_type = 'collect_upfront' and status = 'open')
  and test.ga_has('invoice:' || test.id('inv:ga:1')));
update owner_invoices set status = 'void' where id = test.id('inv:ga:1');
select test.eq('voiding the invoice closes its task and its prompt',
  (select status from tasks where related_id = test.id('inv:ga:1') and task_type = 'collect_upfront') || '/' || test.ga_has('invoice:' || test.id('inv:ga:1')), 'cancelled/false');
-- a task left open from before (as the 8 of INV-1044 to INV-1051): the sweep closes it
update tasks set status = 'open' where related_id = test.id('inv:ga:1') and task_type = 'collect_upfront';
select app.raise_task(p_type => 'opening_checks', p_title => 'Opening checks, yesterday', p_due_at => now() - interval '1 day', p_dedupe => 'opening_checks:ga-yesterday');
select app.raise_task(p_type => 'opening_checks', p_title => 'Opening checks, today', p_due_at => now() + interval '1 hour', p_dedupe => 'opening_checks:ga-today');
insert into chat_conversations (id, visitor_id, name, status, human_requested_at) values (test.id('ga_chat'), test.id('ga_chatv'), 'Gail Chat', 'closed', now() - interval '2 days');
select app.raise_task(p_type => 'live_chat_waiting', p_title => 'Live chat: Gail asked for a person', p_related_table => 'chat_conversations', p_related_id => test.id('ga_chat'), p_dedupe => 'chat:ga');
insert into chat_conversations (id, visitor_id, name, status, human_requested_at, human_reason) values (test.id('ga_chat2'), test.id('ga_chatv2'), 'Gus Wait', 'waiting', now() - interval '5 minutes', 'price question');
select test.ok('a visitor waiting for a person is an urgent prompt; a closed chat is not',
  (test.ga_prompt('chat:' || test.id('ga_chat2')) ->> 'priority') = '1' and not test.ga_has('chat:' || test.id('ga_chat')));
create temp table ga_sweep as select app.job_task_hygiene() as r;
select test.eq('the sweep: the voided invoice''s task, yesterday''s checks and the closed chat''s task close; today''s checks stay',
  (select status from tasks where related_id = test.id('inv:ga:1') and task_type = 'collect_upfront')
  || '/' || (select status from tasks where dedupe_key = 'opening_checks:ga-yesterday')
  || '/' || (select status from tasks where dedupe_key = 'opening_checks:ga-today')
  || '/' || (select status from tasks where dedupe_key = 'chat:ga'),
  'cancelled/cancelled/open/done');
update owner_invoices set status = 'paid', paid_at = now() where id = test.id('inv:ga:2');
select test.eq('a paid upfront invoice closes its task', (select status from tasks where related_id = test.id('inv:ga:2') and task_type = 'collect_upfront'), 'done');

-- ================================================================ 8. assistant work while nobody real holds the function
select app.raise_task(p_type => 'check_owner_document', p_title => 'Check an owner document (ga)', p_owner => test.id('owner:ga_own'), p_dedupe => 'ga:check_doc');
select test.eq('with real customer service on staff, their task stays in their queue', test.ga_has('task:' || (select id from tasks where dedupe_key = 'ga:check_doc')), false);
create temp table ga_va as select user_id, is_active from staff_profiles where staff_type = 'va';
update staff_profiles set is_active = false where staff_type = 'va';
-- the live verification's account does not count as staff
update users set email = 'verify-va-cs@carmacars.ca' where id = test.id('ga_cs');
update staff_profiles set is_active = true where user_id = test.id('ga_cs');
select test.eq('only the live verification''s account holds customer service: nobody real does', app.va_function_staffed('cs'), false);
select test.ok('the task comes to the Admin''s To do, saying why',
  (test.ga_prompt('task:' || (select id from tasks where dedupe_key = 'ga:check_doc')) ->> 'why') is not null
  and (test.ga_prompt('task:' || (select id from tasks where dedupe_key = 'ga:check_doc')) ->> 'from_queue')::boolean);
update site_settings set admin_allowed_emails = admin_allowed_emails || array['ga_admin@example.test'] where singleton;
select app.emit_event('staff_identity_review', 'booking', test.id('booking:GA-D'),
  jsonb_build_object('booking_id', test.id('booking:GA-D'), 'booking_number', 'GA-D', 'kind', 'coverage', 'driver_name', 'Ga Rob', 'pickup_at', now() + interval '1 day'),
  'staff_identity_review:ga');
select test.ok('a customer service email also goes to the Admin, linking to Admin > Today',
  exists (select 1 from app_events e cross join lateral app.notification_recipients(e, (select c from notification_catalogue c where c.code = e.code)) r
           where e.dedupe_key = 'staff_identity_review:ga' and r.audience = 'staff_admin' and r.user_id = test.id('ga_admin'))
  and (select app.notification_payload('staff_identity_review', e, jsonb_build_object('audience', 'staff_admin')) ->> '_url' from app_events e where e.dedupe_key = 'staff_identity_review:ga') like '%/admin');
update users set email = 'ga_cs@example.test' where id = test.id('ga_cs');
update staff_profiles s set is_active = g.is_active from ga_va g where g.user_id = s.user_id;
select test.eq('with a real assistant back, the email goes to them only',
  (select count(*) from app_events e cross join lateral app.notification_recipients(e, (select c from notification_catalogue c where c.code = e.code)) r
    where e.dedupe_key = 'staff_identity_review:ga' and r.audience = 'staff_admin'), 0::bigint);
update site_settings set admin_allowed_emails = array_remove(admin_allowed_emails, 'ga_admin@example.test') where singleton;

-- ================================================================ 9. the To do read, the doors and privileges
select test.ok('Admin > To do carries the prompts, and the plate count leaves out sample cars',
  jsonb_typeof(app.admin_todo(test.id('ga_admin')) -> 'prompts') = 'array'
  and (select (i ->> 'count')::int from jsonb_array_elements(app.admin_todo(test.id('ga_admin')) -> 'items') i where i ->> 'key' = 'plates')
      = (select count(distinct ph.vehicle_id) from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id
          where ph.replaced_at is null and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status = 'unchecked'
            and v.retired_at is null and v.status <> 'exited' and not coalesce(v.is_sample, false)));
select test.eq('the door: an assistant cannot read the Admin''s prompts', test.ga_err(format($$select app.door(%L, 'aal2', 'ops_read', 'todo_prompts', '{}')$$, test.id('ga_fleet'))), 'Not permitted');
select test.throws('only an Admin checks an official form', format($$select app.form_verify(%L, '{"template": "%s"}')$$, test.id('ga_cs'), gen_random_uuid()), null);
select test.eq('the browser roles execute none of the new functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('confirm_fleet_policy', 'confirm_fleet_policy_bulk', 'doc_review_read', 'doc_review_upload', 'doc_review_coverage',
                                              'doc_review_plan', 'todo_prompts', 'todo_publish', 'form_verify', 'job_task_hygiene', 'ops77', 'va_function_staffed')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
