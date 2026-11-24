-- r49 (3610): Renter sent an e-Transfer (Sales) and Check e-Transfer (Finance, the Admins, the connector). Fixtures "etr";
-- example.test only. Sales never records money; Confirm received records it by the record_payment path; Not received
-- goes back to the rep; one open report per booking; audited.
select test.suite('99 r49 e-Transfer reports');

select test.mk_user('etr_admin', 'admin');
select test.mk_user('etr_sales', 'va', 'sales');
select test.mk_user('etr_sales2', 'va', 'sales');
select test.mk_user('etr_cs', 'va', 'cs');
select test.mk_user('etr_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 1000 where user_id = test.id('etr_fin');  -- raised below: the limit applies first

create table test.etr (k text primary key, v jsonb);
grant select on test.etr to authenticated, service_role;
create function test.etrv(p text) returns jsonb language sql stable as $$ select v from test.etr where k = p $$;
create function test.etrb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.etrv(p) ->> 'booking_id')::uuid, (test.etrv(p) ->> 'id')::uuid) $$;
create function test.etru(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.etrb(p)).renter_id $$;
create function test.etr_open(p text) returns bigint language sql stable security definer as $$
  select app.booking_part_open((test.etrb(p)).id, 'rental') + app.booking_part_open((test.etrb(p)).id, 'fees') $$;
create function test.etr_proof(p text) returns jsonb language sql as $$
  select jsonb_build_object('path', 'etransfer/' || (test.etrb(p)).id || '/' || gen_random_uuid() || '.png', 'sha256', repeat('a', 64), 'mime', 'image/png') $$;
create function test.etr_report(p_user text, p_key text, p_amount bigint, p_covers text) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'etransfer_report', jsonb_build_object('booking', (test.etrb(p_key)).booking_number,
    'amount_cents', p_amount, 'covers', p_covers, 'sender_name', 'Erin Transfer', 'proof', test.etr_proof(p_key))) $$;
create function test.etr_decide(p_user text, p_report text, p jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'etransfer_decide', p || jsonb_build_object('id', test.etrv(p_report) ->> 'id')) $$;

do $$
begin
  insert into test.etr select 'car1', app.vehicle_add(test.id('etr_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXET0000000001',
    'plate', 'ETR001', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
end $$;
-- an offer paid by e-Transfer (the rental and the deposit), approved by the renter: waiting for payment
create function test.etr_offer(p_key text, p_email text, p_from interval) returns void language plpgsql as $$
declare v_driver uuid; k text;
begin
  insert into test.etr select p_key, app.door(test.id('etr_admin'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object(
    'vehicle_id', (test.etrv('car1') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Erin Transfer', 'email', p_email, 'mobile', '(289) 555-07' || (10 + length(p_key))::text, 'date_of_birth', (now() - interval '30 years')::date),
    'coverage_option', 2, 'rental_pay_method', 'e_transfer', 'deposit_pay_method', 'e_transfer', 'channels', jsonb_build_object('email', false, 'text', false)));
  v_driver := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.etrb(p_key)).id and bd.role = 'renter');
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.etrb(p_key)).id, test.etru(p_key), k, v_driver, 'renters/etr/' || p_key || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.etru(p_key), jsonb_build_object('licence_number', 'E1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.etrb(p_key)).id);
  perform public.renter_approve_offer((test.etrb(p_key)).id, (test.etrb(p_key)).current_offer_version, test.etru(p_key));
end $$;

select test.etr_offer('b1', 'erin.transfer1@example.test', interval '6 days');
select test.etr_offer('b2', 'erin.transfer2@example.test', interval '20 days');
select test.eq('both bookings wait for payment', (test.etrb('b1')).status::text || '/' || (test.etrb('b2')).status::text, 'pending_payment/pending_payment');
insert into test.etr select 'open1', jsonb_build_object('cents', test.etr_open('b1'));
select test.ok('the rental and fees are open on b1', (test.etrv('open1') ->> 'cents')::bigint > 0);

-- ================================================================ 1. who may report, and what a report needs
select test.throws('customer service cannot report it', $$select test.etr_report('etr_cs', 'b1', 10000, 'rental')$$, 'Only Sales');
select test.throws('an Admin records it directly instead', $$select test.etr_report('etr_admin', 'b1', 10000, 'rental')$$, 'records the payment directly');
select test.throws('the proof is required', $$select app.door(test.id('etr_sales'), 'aal2', 'ops_do', 'etransfer_report',
  jsonb_build_object('booking', (test.etrb('b1')).booking_number, 'amount_cents', 10000, 'covers', 'rental'))$$, 'screenshot or proof');
select test.throws('a proof outside etransfer/ is refused', $$select app.door(test.id('etr_sales'), 'aal2', 'ops_do', 'etransfer_report',
  jsonb_build_object('booking', (test.etrb('b1')).booking_number, 'amount_cents', 10000, 'covers', 'rental', 'proof', jsonb_build_object('path', 'payments/x.png', 'sha256', repeat('a', 64), 'mime', 'image/png')))$$, 'screenshot or proof');
select test.throws('the amount is required', $$select test.etr_report('etr_sales', 'b1', 0, 'rental')$$, 'amount');
select test.throws('what it covers is one of three', $$select test.etr_report('etr_sales', 'b1', 10000, 'fees')$$, 'covers');
select test.eq('nothing was made by the refusals', (select count(*) from etransfer_reports where booking_id = (test.etrb('b1')).id), 0::bigint);

-- ================================================================ 2. Sales reports it: no money, a To do, the notice, the history
insert into test.etr select 'r1', test.etr_report('etr_sales', 'b1', (test.etrv('open1') ->> 'cents')::bigint, 'rental');
select test.eq('the report is open, numbered ET-', (select status || '/' || (report_number like 'ET-%')::text from etransfer_reports where id = (test.etrv('r1') ->> 'id')::uuid), 'open/true');
select test.eq('Sales recorded no money: no payment, no manual payment, still waiting for payment',
  (select count(*) from manual_payments where booking_id = (test.etrb('b1')).id)::text || '/' || (select count(*) from payments where booking_id = (test.etrb('b1')).id and status = 'succeeded' and method = 'e_transfer')::text
    || '/' || (test.etrb('b1')).status::text, '0/0/pending_payment');
select test.eq('two To dos: Finance and the Admins', (select string_agg(t.queue, ',' order by t.queue) from tasks t
  where t.task_type = 'etransfer_check' and t.related_id = (test.etrv('r1') ->> 'id')::uuid and t.status = 'open'), 'admin,finance');
select test.eq('the To do is on the booking', (select count(*) from tasks t where t.task_type = 'etransfer_check' and t.booking_id = (test.etrb('b1')).id), 2::bigint);
select test.eq('Finance and the Admins are told once, with the amount and the rep',
  (select count(*)::text || '/' || max(payload ->> 'reporter_name') || '/' || max(payload ->> 'etransfer_covers') from app_events where code = 'staff_etransfer_reported' and (payload ->> 'report_id') = test.etrv('r1') ->> 'id'),
  '1/Etr Sales/the rental and fees');
select test.ok('the notice goes to Finance (staff_va_finance) and the Admins',
  (select bool_or(x.audience = 'staff_va_finance') and bool_or(x.audience = 'staff_admin') from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_etransfer_reported')) x
    where e.code = 'staff_etransfer_reported' and (e.payload ->> 'report_id') = test.etrv('r1') ->> 'id'));
select test.ok('the booking''s history says it waits', exists (select 1 from booking_events where booking_id = (test.etrb('b1')).id and note like 'e-Transfer of % reported by Etr Sales%waiting for Finance%'));
select test.eq('an audit row for the report', (select count(*) from audit_log where action = 'etransfer_report' and entity_id = test.etrv('r1') ->> 'id'), 1::bigint);
select test.eq('the proof is a document of its own', (select d.storage_path like 'etransfer/%' from etransfer_reports r join documents d on d.id = r.proof_document_id where r.id = (test.etrv('r1') ->> 'id')::uuid), true);
select test.throws('a second report while one is open is refused', $$select test.etr_report('etr_sales2', 'b1', 5000, 'rental')$$, 'already waiting');

-- the views: Sales sees it waiting and may not decide; Finance may decide and sees what would be recorded
select test.eq('Sales: waiting, may not report again, may not decide',
  (select (x ->> 'may_report') || '/' || (x ->> 'may_decide') || '/' || (x ->> 'own_report') || '/' || (x #>> '{reports,0,status}')
     from (select app.door(test.id('etr_sales'), 'aal2', 'ops_read', 'etransfer_reports', jsonb_build_object('booking', (test.etrb('b1')).id)) x) q), 'false/false/true/open');
select test.eq('Finance: may decide; the plan records the rental and fees, nothing for the deposit',
  (select (x ->> 'may_decide') || '/' || (x #>> '{plan,rental_cents}') || '/' || (x #>> '{plan,deposit_cents}') || '/' || coalesce(x #>> '{plan,problem}', 'ok')
     from (select app.door(test.id('etr_fin'), 'aal2', 'ops_read', 'etransfer_reports', jsonb_build_object('booking', (test.etrb('b1')).id)) x) q),
  'true/' || (test.etrv('open1') ->> 'cents') || '/0/ok');
select test.ok('Finance and Sales open the proof; customer service does not',
  app.door(test.id('etr_fin'), 'aal2', 'ops_read', 'etransfer_proof', jsonb_build_object('document', (select proof_document_id from etransfer_reports where id = (test.etrv('r1') ->> 'id')::uuid))) ->> 'path' like 'etransfer/%'
  and app.door(test.id('etr_sales'), 'aal2', 'ops_read', 'etransfer_proof', jsonb_build_object('document', (select proof_document_id from etransfer_reports where id = (test.etrv('r1') ->> 'id')::uuid))) is not null
  and app.door(test.id('etr_cs'), 'aal2', 'ops_read', 'etransfer_proof', jsonb_build_object('document', (select proof_document_id from etransfer_reports where id = (test.etrv('r1') ->> 'id')::uuid))) is null);

-- ================================================================ 3. Sales can never mark it paid
select test.throws('Sales cannot confirm it', $$select test.etr_decide('etr_sales', 'r1', '{"decision":"confirm"}')$$, 'Only Finance or an Admin');
select test.throws('customer service cannot confirm it', $$select test.etr_decide('etr_cs', 'r1', '{"decision":"confirm"}')$$, 'Only Finance or an Admin');
select test.eq('the browser role cannot write the table or run the functions',
  has_table_privilege('authenticated', 'etransfer_reports', 'insert')::text || '/' || has_table_privilege('authenticated', 'etransfer_reports', 'update')::text
  || '/' || has_function_privilege('authenticated', 'app.etransfer_decide(uuid, jsonb, text)', 'execute')::text
  || '/' || has_function_privilege('authenticated', 'app.etransfer_report(uuid, jsonb)', 'execute')::text
  || '/' || has_function_privilege('anon', 'app.etransfer_plan(uuid, bigint)', 'execute')::text, 'false/false/false/false/false');
select test.eq('every function of 3610 runs with pg_temp last on its search_path',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname like 'etransfer%' and p.prosecdef
     and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')), 0::bigint);

-- ================================================================ 4. Not received: back to the rep with the reason
select test.throws('a reason is needed', $$select test.etr_decide('etr_fin', 'r1', '{"decision":"decline","reason":"no"}')$$, 'Say why');
select test.etr_decide('etr_fin', 'r1', '{"decision":"decline","reason":"Nothing from this sender in the bank yet"}');
select test.eq('sent back: declined with the reason, nothing recorded, still waiting for payment',
  (select status || '/' || decline_reason from etransfer_reports where id = (test.etrv('r1') ->> 'id')::uuid) || '/'
    || (select count(*) from manual_payments where booking_id = (test.etrb('b1')).id)::text || '/' || (test.etrb('b1')).status::text,
  'declined/Nothing from this sender in the bank yet/0/pending_payment');
select test.eq('both To dos are done', (select count(*) from tasks where task_type = 'etransfer_check' and related_id = (test.etrv('r1') ->> 'id')::uuid and status = 'done'), 2::bigint);
select test.eq('the rep is told, at their own address only',
  (select string_agg(x.audience || ':' || x.email, ',') from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_etransfer_declined')) x
    where e.code = 'staff_etransfer_declined' and (e.payload ->> 'report_id') = test.etrv('r1') ->> 'id'), 'staff_va_sales:etr_sales@example.test');
select test.eq('an audit row for the decision', (select count(*) from audit_log where action = 'etransfer_decline' and entity_id = test.etrv('r1') ->> 'id'), 1::bigint);
select test.throws('a decided report is not decided again', $$select test.etr_decide('etr_fin', 'r1', '{"decision":"confirm"}')$$, 'already');

-- ================================================================ 5. Confirm received: the record_payment path and its rules
insert into test.etr select 'r2', test.etr_report('etr_sales', 'b1', (test.etrv('open1') ->> 'cents')::bigint, 'rental');
select test.throws('the payment''s own rules apply: Finance''s single limit', $$select test.etr_decide('etr_fin', 'r2', '{"decision":"confirm"}')$$, 'single limit');
select test.eq('refused whole: the report is still open, nothing recorded',
  (select status from etransfer_reports where id = (test.etrv('r2') ->> 'id')::uuid) || '/' || (select count(*) from manual_payments where booking_id = (test.etrb('b1')).id)::text, 'open/0');
update staff_profiles set single_limit_cents = 900000 where user_id = test.id('etr_fin');
insert into test.etr select 'c2', test.etr_decide('etr_fin', 'r2', '{"decision":"confirm","reference":"CA8xQk2"}');
select test.eq('recorded as e-Transfers of the whole amount, with the bank reference, and the booking is confirmed',
  (select count(*) filter (where method = 'e_transfer')::text || '/' || sum(amount_cents)::text || '/' || bool_and(reference like 'CA8xQk2%')::text from manual_payments where booking_id = (test.etrb('b1')).id and voided_at is null)
    || '/' || test.etr_open('b1')::text || '/' || (test.etrb('b1')).status::text,
  (select count(*)::text from manual_payments where booking_id = (test.etrb('b1')).id) || '/' || (test.etrv('open1') ->> 'cents') || '/true/0/confirmed');
select test.eq('the screenshot is the proof of each payment', (select bool_and(proof_document_id = (select proof_document_id from etransfer_reports where id = (test.etrv('r2') ->> 'id')::uuid))
  from manual_payments where booking_id = (test.etrb('b1')).id), true);
select test.eq('the report is confirmed with its payments', (select status || '/' || cardinality(payment_ids)::text from etransfer_reports where id = (test.etrv('r2') ->> 'id')::uuid),
  'confirmed/' || (select count(*)::text from manual_payments where booking_id = (test.etrb('b1')).id));
select test.eq('the renter''s receipt went as for any payment recorded', (select count(*) > 0 from app_events where code = 'renter_payment_receipt' and (payload ->> 'booking_id')::uuid = (test.etrb('b1')).id), true);
select test.eq('the rep is told it is confirmed', (select payload ->> 'booking_status' from app_events where code = 'staff_etransfer_confirmed' and (payload ->> 'report_id') = test.etrv('r2') ->> 'id'), 'Confirmed');
select test.eq('the To dos are done', (select count(*) from tasks where task_type = 'etransfer_check' and related_id = (test.etrv('r2') ->> 'id')::uuid and status = 'done'), 2::bigint);
select test.eq('audit rows: the report and the confirmation', (select count(*) from audit_log where action in ('etransfer_report', 'etransfer_confirm') and entity_id = test.etrv('r2') ->> 'id'), 2::bigint);
select test.throws('a booking no longer waiting for payment takes no report', $$select test.etr_report('etr_sales', 'b1', 5000, 'rental')$$, 'waiting for payment');

-- ================================================================ 6. both: the rental and the deposit, split by what is owed
insert into test.etr select 'open2', jsonb_build_object('cents', test.etr_open('b2'), 'dep', app.deposit_for_method(test.etrb('b2'), 'e_transfer'));
select test.eq('the deposit by e-Transfer is doubled (3052)', (test.etrv('open2') ->> 'dep')::bigint, 60000::bigint);
insert into test.etr select 'r3', test.etr_report('etr_sales2', 'b2', (test.etrv('open2') ->> 'cents')::bigint + 60000, 'both');
-- the connector: preview first (nothing changes), then confirm with the preview
create function test.etr_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
create temp table etr_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select app.api_key_create(test.id('etr_admin'), test.id('etr_admin'), 'Laptop', array['admin:read', 'admin:write'], test.etr_h('cc_live_etr_full'), 'cc_live_etr_');
insert into test.etr select 'pv', app.api_call(test.etr_h('cc_live_etr_full'), 'etransfer_check', jsonb_build_object('report', (select report_number from etransfer_reports where id = (test.etrv('r3') ->> 'id')::uuid), 'decision', 'received'), 'test');
select test.eq('the preview says what would be recorded and changes nothing',
  (test.etrv('pv') #>> '{result,preview}') || '/' || (test.etrv('pv') #>> '{result,report,plan,deposit_cents}') || '/' || (test.etrv('pv') #>> '{result,report,plan,rental_cents}')
    || '/' || (select status from etransfer_reports where id = (test.etrv('r3') ->> 'id')::uuid) || '/' || (select count(*) from manual_payments where booking_id = (test.etrb('b2')).id)::text,
  'true/60000/' || (test.etrv('open2') ->> 'cents') || '/open/0');
select test.eq('a confirm with other arguments than the preview is refused', app.api_call(test.etr_h('cc_live_etr_full'), 'etransfer_check',
  jsonb_build_object('report', (select report_number from etransfer_reports where id = (test.etrv('r3') ->> 'id')::uuid), 'decision', 'received', 'reference', 'other',
    'confirm', true, 'preview_id', test.etrv('pv') #>> '{result,preview_id}'), 'test') ->> 'ok', 'false');
insert into test.etr select 'cf', app.api_call(test.etr_h('cc_live_etr_full'), 'etransfer_check', jsonb_build_object('report', (select report_number from etransfer_reports where id = (test.etrv('r3') ->> 'id')::uuid),
  'decision', 'received', 'confirm', true, 'preview_id', test.etrv('pv') #>> '{result,preview_id}'), 'test');
select test.eq('confirmed from the connector: the rental and fees, and the deposit taken by e-Transfer',
  (test.etrv('cf') #>> '{result,status}') || '/' || test.etr_open('b2')::text || '/' || (select status::text || ':' || method || ':' || paid_method || ':' || amount_cents from deposits where booking_id = (test.etrb('b2')).id)
    || '/' || (test.etrb('b2')).status::text,
  'confirmed/0/captured:offline:e_transfer:60000/confirmed');
select test.ok('the connector calls are logged', (select count(*) from api_calls where tool like 'etransfer_check%') >= 3);
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from etr_ps s where s.id = p.id;
