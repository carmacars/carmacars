-- 85: owner terms per car (migration 0135, docs/changes/2026-10-24-owner-terms-per-car.md). The terms editor's one call
-- per car: before signing the numbers apply at once (and the mode while the terms are open); once signed, lower amounts
-- from today or a chosen date without notice, higher Fees by 30 days' written notice, a higher management fee by the
-- notice and an updated Vehicle Schedule the owner signs; cancel what has not started; the reads (Admin and owner
-- portal), the notice email and document; the monthly invoice billed per day at each rate. Fixtures start with "ct".
select test.suite('85 owner terms per car');
grant usage on schema test to service_role;
create table test.ct (k text primary key, v jsonb);
create function test.ctv(p text) returns jsonb language sql stable as $$ select v from test.ct where k = p $$;
create function test.ct_do(p_user text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', 'car_terms_change', p) $$;
create function test.ct_read(p_user text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', 'car_terms', p) $$;
create function test.ct_car(p_label text) returns jsonb language sql as $$
  select x from jsonb_array_elements(test.ct_read('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:' || p_label))) -> 'cars') x limit 1 $$;
create function test.ct_terms(p_label text, p_on date) returns text language sql stable as $$
  select t.insurance_fee_cents || '/' || t.tracker_fee_cents || '/' || t.revenue_share_bps from app.vehicle_terms(test.id('vehicle:' || p_label), p_on) t $$;

select test.mk_user('ct_admin', 'admin');
select test.mk_user('ct_fin', 'va', 'finance');
select test.mk_owner('ct_ola');
select test.mk_owner('ct_ben');
select test.mk_vehicle('CTA', 'ct_ola', 'managed', 45000, 2500, 3500, date '2026-09-01');
select test.mk_vehicle('CTB', 'ct_ola', 'managed', 45000, 2500, 3500, date '2026-09-01');
select test.mk_vehicle('CTC', 'ct_ben', 'managed', 45000, 2500, 3500, date '2026-09-01');
select test.mk_vehicle('CTS', 'ct_ben', 'managed', 0, 0, 1000, date '2026-09-01', true);

-- ================================================================ 1. the read
select test.eq('read: every car of the owner, signed and enrolled, the terms in force and from when',
  (select string_agg((x ->> 'state') || ':' || (x #>> '{current,insurance_fee_cents}') || ':' || (x #>> '{current,revenue_share_bps}') || ':' || (x ->> 'since'), ',' order by x ->> 'name')
     from jsonb_array_elements(test.ct_read('ct_admin', jsonb_build_object('owner_id', test.id('owner:ct_ola'))) -> 'cars') x),
  'signed:45000:3500:2026-09-01,signed:45000:3500:2026-09-01');
select test.eq('read: the editor knows what can change once signed (fees only) and the notice rule',
  (select (x #>> '{editable,fees}') || '/' || (x #>> '{editable,install}') || '/' || (x #>> '{editable,mode}') from (select test.ct_car('CTA') x) y)
  || '/' || (test.ct_read('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTA'))) ->> 'notice_days'), 'true/false/false/30');
select test.throws('read: Admins only', format($$select test.ct_read('ct_fin', %L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:CTA'))), '');

-- ================================================================ 2. a lower amount: at once, no notice period
insert into test.ct select 'prev', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'insurance_fee_cents', 40000, 'preview', true));
select test.eq('lower: the review says what happens and changes nothing',
  (test.ctv('prev') ->> 'done') || '/' || (test.ctv('prev') #>> '{fields,0,direction}') || '/' || (test.ctv('prev') #>> '{steps,0}' like '%No notice period%') || '/' || test.ct_terms('CTA', app.today()),
  'false/lower/true/45000/2500/3500');
insert into test.ct select 'lower', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'insurance_fee_cents', 40000, 'tracker_fee_cents', 2500,
  'revenue_share_bps', 3500, 'install_fee_cents', 10000));
select test.eq('lower: in force today, the earlier terms until yesterday, a "lower" change applied and countersigned',
  test.ct_terms('CTA', app.today()) || ' ' || test.ct_terms('CTA', app.today() - 1) || ' '
  || (select c.kind || ':' || c.status || ':' || (c.countersignature like 'Signed electronically for %') from vehicle_term_changes c where c.vehicle_id = test.id('vehicle:CTA')),
  '40000/2500/3500 45000/2500/3500 decrease:applied:true');
select test.eq('lower: the owner gets the written notice: lower, one line, no notice period counted',
  (select x ->> 'is_decrease' || '/' || jsonb_array_length(x -> 'fee_changes') || '/' || (x #>> '{fee_changes,0,after}') || '/' || (x ->> 'notice_days') || '/' || (x ->> 'is_share_change')
     from app_events e cross join lateral app.notification_payload('owner_fee_change_notice', e, '{"audience": "owner"}') x
    where e.code = 'owner_fee_change_notice' and e.payload ->> 'vehicle_id' = test.id('vehicle:CTA')::text), 'true/1/$400.00/0/false');
insert into test.ct select 'lower10', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'revenue_share_bps', 3000, 'lower_from', app.today() + 10));
select test.eq('lower: on a chosen date: the management fee from in 10 days',
  (test.ctv('lower10') ->> 'done') || ' ' || test.ct_terms('CTB', app.today() + 9) || ' ' || test.ct_terms('CTB', app.today() + 10), 'true 45000/2500/3500 45000/2500/3000');
select test.throws('lower: never in the past', format($$select test.ct_do('ct_admin', %L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:CTC'), 'insurance_fee_cents', 40000, 'lower_from', app.today() - 1)), 'today or later');
select test.throws('lower: one change at a time: a change that has not started blocks a new one',
  format($$select test.ct_do('ct_admin', %L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'insurance_fee_cents', 40000)), 'already starts on');

-- ================================================================ 3. cancel what has not started
insert into test.ct select 'cancel', public.door(test.id('ct_admin'), null, 'ops_do', 'car_terms_cancel', jsonb_build_object('change_id', (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:CTB')), 'reason', 'Entered by mistake'));
select test.eq('cancel: the change in 10 days is cancelled, the terms before it run on',
  (test.ctv('cancel') ->> 'cancelled')
  || ' ' || test.ct_terms('CTB', app.today() + 20) || ' ' || (select count(*) from vehicle_fee_history where vehicle_id = test.id('vehicle:CTB') and effective_to is null)
  || ' ' || (select status from vehicle_term_changes where vehicle_id = test.id('vehicle:CTB')), 'true 45000/2500/3500 1 cancelled');
select test.throws('cancel: a change in force is not cancelled',
  format($$select public.door(%L, null, 'ops_do', 'car_terms_cancel', %L)$$, test.id('ct_admin'), jsonb_build_object('change_id', (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:CTA')), 'reason', 'x')), 'not started yet');

-- ================================================================ 4. higher: Fees by notice, the management fee by notice and signature
select test.throws('higher: 30 days'' written notice', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'tracker_fee_cents', 3000, 'raise_from', app.today() + 10, 'reason', 'Tracker costs')), 'days'' written notice');
select test.throws('higher: the reason is needed (the owner reads it)', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'tracker_fee_cents', 3000, 'raise_from', app.today() + 30)), 'reason');
insert into test.ct select 'up', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'tracker_fee_cents', 3000, 'revenue_share_bps', 4000,
  'raise_from', app.today() + 30, 'reason', 'New program terms'));
select test.eq('higher: the Fees from the notice date; the share waits for the owner''s signature',
  test.ct_terms('CTA', app.today() + 29) || ' ' || test.ct_terms('CTA', app.today() + 30) || ' '
  || (select string_agg(kind || ':' || status, ',' order by created_at, kind) from vehicle_term_changes where vehicle_id = test.id('vehicle:CTA') and edit_id = (test.ctv('up') ->> 'edit_id')::uuid),
  '40000/2500/3500 40000/3000/3500 fee_notice:noticed,new_schedule:awaiting_signature');
select test.eq('higher: the owner is emailed the notice (with the share) and the updated schedule to sign',
  (select count(*) from app_events e where e.code = 'owner_schedule_resign' and e.entity_id = any (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:CTA'))) || '/'
  || (select x ->> 'is_share_change' || ':' || jsonb_array_length(x -> 'fee_changes') || ':' || (x ->> 'notice_days')
        from app_events e cross join lateral app.notification_payload('owner_fee_change_notice', e, '{"audience": "owner"}') x
       where e.code = 'owner_fee_change_notice' and e.payload ->> 'vehicle_id' = test.id('vehicle:CTA')::text and (e.payload ->> 'is_share_change')::boolean), '1/true:2:30');
select test.throws('higher: nothing else changes while the schedule waits for the owner',
  format($$select test.ct_do('ct_admin', %L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:CTA'), 'insurance_fee_cents', 39000)), 'waiting for the owner');
insert into test.ct select 'sched', (select to_jsonb(c) from vehicle_term_changes c where c.vehicle_id = test.id('vehicle:CTA') and c.status = 'awaiting_signature');
select public.server_schedule_change_sign(test.id('ct_ola'), jsonb_build_object('change_id', test.ctv('sched') ->> 'id', 'agree', true, 'name', 'Ct Ola',
  'sha256', public.server_owner_schedule_change(test.id('ct_ola'), (test.ctv('sched') ->> 'id')::uuid) ->> 'sha256'));
select test.eq('signed: a new schedule version with the new share; the share and Fees from the notice date; the notice gave way to it',
  (select s.revenue_share_bps || ':' || s.tracker_fee_cents || ':' || s.insurance_fee_cents from vehicle_schedules s where s.vehicle_id = test.id('vehicle:CTA') and s.superseded_by is null)
  || ' ' || test.ct_terms('CTA', app.today() + 29) || ' ' || test.ct_terms('CTA', app.today() + 30)
  || ' ' || (select string_agg(kind || ':' || status, ',' order by kind) from vehicle_term_changes where vehicle_id = test.id('vehicle:CTA') and edit_id = (test.ctv('up') ->> 'edit_id')::uuid),
  '4000:3000:40000 40000/2500/3500 40000/3000/4000 fee_notice:applied,new_schedule:applied');
-- a share raise signed after its date applies from the day it is signed
insert into test.ct select 'up2', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTC'), 'revenue_share_bps', 3800, 'raise_from', app.today() + 30, 'reason', 'Program terms'));
update vehicle_term_changes set effective_from = app.today() - 5 where vehicle_id = test.id('vehicle:CTC') and status = 'awaiting_signature';
select public.door(test.id('ct_admin'), null, 'ops_do', 'schedule_change_admin', jsonb_build_object('change_id', (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:CTC') and status = 'awaiting_signature'), 'do', 'paper'));
select test.eq('signed late: the higher share from the day signed, never back-dated',
  test.ct_terms('CTC', app.today() - 1) || ' ' || test.ct_terms('CTC', app.today()), '45000/2500/3500 45000/2500/3800');

-- ================================================================ 5. what the signed schedule fixes
select test.throws('signed: the Install Fee is on the signed schedule', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'install_fee_cents', 5000)), 'Install Fee');
select test.throws('signed: the Management Mode is on the signed schedule', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'management_mode', 'self_managed', 'revenue_share_bps', 0)), 'Management Mode');
select test.throws('a shareholder-owned car has fixed terms', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.id('vehicle:CTS'), 'revenue_share_bps', 500)), 'fixed terms');
select test.throws('only an Admin changes terms', format($$select public.door(%L, null, 'ops_do', 'car_terms_change', %L)$$, test.id('ct_fin'),
  jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'insurance_fee_cents', 1)), '');
select test.throws('nothing changed is refused', format($$select test.ct_do('ct_admin', %L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:CTB'))), 'already in place');

-- ================================================================ 6. signed, not enrolled yet: an updated schedule at once (lower) or to sign (higher)
select test.mk_vehicle('CTN', 'ct_ben', 'managed', 45000, 2500, 3500, date '2026-09-01');
delete from vehicle_fee_history where vehicle_id = test.id('vehicle:CTN');
update vehicles set enrollment_date = null where id = test.id('vehicle:CTN');
update vehicle_schedules set enrollment_date = null where vehicle_id = test.id('vehicle:CTN');
select test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTN'), 'insurance_fee_cents', 42000));
select test.eq('not enrolled, lower: the schedule enrollment reads is updated at once (2 versions), no dated terms yet',
  (select count(*) from vehicle_schedules where vehicle_id = test.id('vehicle:CTN')) || '/'
  || (select insurance_fee_cents from vehicle_schedules where vehicle_id = test.id('vehicle:CTN') and superseded_by is null) || '/'
  || (select count(*) from vehicle_fee_history where vehicle_id = test.id('vehicle:CTN')), '2/42000/0');
insert into test.ct select 'nup', test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTN'), 'revenue_share_bps', 4000, 'reason', 'Agreed on the phone'));
select test.eq('not enrolled, higher: the owner signs an updated schedule, from today, no notice period',
  (test.ctv('nup') ->> 'raise_from')
  || '/' || (select status from vehicle_term_changes where vehicle_id = test.id('vehicle:CTN') and kind = 'new_schedule'), app.today()::text || '/awaiting_signature');

-- ================================================================ 7. before signing: an application's car, the numbers at once
insert into users (id, email, full_name) values (test.id('ct_pia'), 'pia.ct@example.test', 'Pia Pending');
insert into test.ct select 'app', public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Pia Pending', 'first_name', 'Pia', 'email', 'pia.ct@example.test',
                              'phone', '+16475550188', 'address_line1', '2 Bay Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5J 2R8',
                              'licence_number', 'P1234-56789-01234', 'date_of_birth', '1986-02-02'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', upper(substr(md5('ct-vin-1'), 1, 17)), 'plate', 'CTPP101', 'year', 2022, 'make', 'Toyota', 'model', 'RAV4', 'colour', 'Grey',
    'odometer_km', 20000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva', 'title_brand_clear', true))),
  test.id('ct_pia'));
create function test.ct_pcar() returns uuid language sql stable as $$ select (test.ctv('app') #>> '{vehicles,0,vehicle_id}')::uuid $$;
select test.eq('pending: a car not approved yet: the would-be terms and the editor (fees, install and mode)',
  (select (x ->> 'state') || '/' || (x #>> '{current,insurance_fee_cents}') || '/' || (x #>> '{editable,install}') || '/' || (x #>> '{editable,mode}') || '/' || (jsonb_array_length(x #> '{options,managed}') > 0)
     from jsonb_array_elements(test.ct_read('ct_admin', jsonb_build_object('vehicle_id', test.ct_pcar())) -> 'cars') x), 'not_set/45000/true/true/true');
select test.throws('pending: a Self-Managed car has no management fee', format($$select test.ct_do('ct_admin', %L)$$,
  jsonb_build_object('vehicle_id', test.ct_pcar(), 'management_mode', 'self_managed', 'revenue_share_bps', 3000)), 'Self-Managed');
select test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.ct_pcar(), 'insurance_fee_cents', 41000, 'tracker_fee_cents', 2000, 'revenue_share_bps', 2800, 'install_fee_cents', 9000));
select test.eq('pending: kept for the car: the Approve step starts from them',
  (select (r ->> 'insurance_fee_cents') || '/' || (r ->> 'revenue_share_bps') || '/' || (r ->> 'install_fee_cents') || '/' || (r #>> '{sources,insurance_fee_cents}') from (select app.owner_terms_resolve(test.ct_pcar()) r) x)
  || '/' || (public.door(test.id('ct_admin'), null, 'ops_read', 'application_approve_plan', jsonb_build_object('id', test.ctv('app') ->> 'application_id')) #>> '{cars,0,terms,insurance_fee_cents}'),
  '41000/2800/9000/car/41000');
select public.door(test.id('ct_admin'), null, 'ops_do', 'application_approve', jsonb_build_object('id', test.ctv('app') ->> 'application_id'));
select test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.ct_pcar(), 'insurance_fee_cents', 39500, 'tracker_fee_cents', 2000, 'revenue_share_bps', 2500, 'install_fee_cents', 9000));
select test.eq('pending: approved, not signed: an edit is written into the unsigned schedule at once, no notice, no new version',
  (select s.insurance_fee_cents || '/' || s.revenue_share_bps || '/' || (s.signed_at is null) from vehicle_schedules s where s.vehicle_id = test.ct_pcar() and s.superseded_by is null)
  || '/' || (select count(*) from vehicle_schedules where vehicle_id = test.ct_pcar()) || '/' || (select count(*) from vehicle_term_changes where vehicle_id = test.ct_pcar()), '39500/2500/true/1/0');
select test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.ct_pcar(), 'management_mode', 'self_managed', 'onboarding_method', 'transfer', 'revenue_share_bps', 0,
  'insurance_fee_cents', 39500, 'tracker_fee_cents', 2000, 'install_fee_cents', 9000));
select test.eq('pending: the Management Mode while the terms are open: schedule, car and onboarding',
  (select s.management_mode || '/' || s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = test.ct_pcar() and s.superseded_by is null)
  || '/' || (select management_mode from vehicles where id = test.ct_pcar()), 'self_managed/0/self_managed');

-- ================================================================ 8. the owner portal, the notice document
insert into test.ct select 'portal', public.server_owner_car_terms(test.id('ct_ola'));
select test.eq('portal: the owner''s cars only, with the periods (from when) and the changes with their notices',
  (select jsonb_array_length(test.ctv('portal') -> 'cars')) || '/'
  || (select jsonb_array_length(x -> 'periods') || ':' || jsonb_array_length(x -> 'changes') || ':' || (x -> 'editable' is null or x -> 'editable' = 'null'::jsonb)
        from jsonb_array_elements(test.ctv('portal') -> 'cars') x where x ->> 'vehicle_id' = test.id('vehicle:CTA')::text), '2/3:3:true');
select test.eq('portal: the vehicles show the terms in force (the lower Insurance Fee), not only the signed schedule''s',
  (select x ->> 'insurance_fee_cents' from jsonb_array_elements(app.owner_portal_vehicles(test.id('ct_ola'))) x where x ->> 'vehicle_id' = test.id('vehicle:CTA')::text), '40000');
insert into test.ct select 'notice', (select to_jsonb(c) from vehicle_term_changes c where c.vehicle_id = test.id('vehicle:CTA') and c.kind = 'decrease');
select test.eq('document: the owner downloads their own notice, another owner not, Finance yes; the lines and the text',
  app.file_access(test.id('ct_ola'), 'terms_notice', test.ctv('notice') ->> 'id') || '/' || app.file_access(test.id('ct_ben'), 'terms_notice', test.ctv('notice') ->> 'id')
  || '/' || app.file_access(test.id('ct_fin'), 'terms_notice', test.ctv('notice') ->> 'id')
  || '/' || (app.pdf_facts('terms_notice', test.ctv('notice') ->> 'id') #>> '{lines,0,after}') || '/' || (app.pdf_facts('terms_notice', test.ctv('notice') ->> 'id') ->> 'title'),
  'true/false/true/$400.00/Notice of lower terms');

-- ================================================================ 9. billing by effective date
-- car CTB: a lower Insurance Fee from the 15th of next month: next month is billed per day at each rate
select test.ct_do('ct_admin', jsonb_build_object('vehicle_id', test.id('vehicle:CTB'), 'insurance_fee_cents', 30000, 'lower_from', (date_trunc('month', app.today() + 31)::date + 14)));
select app.generate_owner_invoice(test.id('vehicle:CTB'), date_trunc('month', app.today() + 31)::date);
select test.eq('billing: a month whose Insurance Fee changes on the 15th: 14 days at $450, the rest at $300',
  (select l.amount_cents from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id
    where i.vehicle_id = test.id('vehicle:CTB') and i.period_month = date_trunc('month', app.today() + 31)::date and l.kind = 'insurance_fee'),
  public.calc_prorated_fee(45000, 14, app.days_in_month(date_trunc('month', app.today() + 31)::date)) + public.calc_prorated_fee(30000, app.days_in_month(date_trunc('month', app.today() + 31)::date) - 14, app.days_in_month(date_trunc('month', app.today() + 31)::date)));
select test.eq('billing: the invoice line says how it was counted',
  (select l.description like '%14 days at $450.00%days at $300.00%' from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id
    where i.vehicle_id = test.id('vehicle:CTB') and i.period_month = date_trunc('month', app.today() + 31)::date and l.kind = 'insurance_fee'), true);
select app.generate_owner_invoice(test.id('vehicle:CTB'), date_trunc('month', app.today() + 62)::date);
select test.eq('billing: the month after, one rate: the whole month at $300',
  (select l.amount_cents from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id
    where i.vehicle_id = test.id('vehicle:CTB') and i.period_month = date_trunc('month', app.today() + 62)::date and l.kind = 'insurance_fee'), 30000::bigint);
select test.eq('billing: the Revenue Share of a rental is the one in force the day it is booked (stored on the booking)',
  (select company_share_bps from app.vehicle_split_terms(test.id('vehicle:CTA'), app.today() + 30)), 4000);

-- ================================================================ 10. privileges
select test.throws('privileges: a browser session cannot read an owner''s terms', $$set local role authenticated; select public.server_owner_car_terms(gen_random_uuid())$$, 'permission denied');
select test.throws('privileges: nor change them directly', $$set local role authenticated; select app.car_terms_change(gen_random_uuid(), '{}')$$, 'permission denied');
