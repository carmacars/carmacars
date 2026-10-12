-- 16: the owner portal (migration 0029). Every fixture label starts with "op".
select test.suite('16 owner portal');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('op_admin', 'admin');
select test.mk_user('op_cs', 'va', 'cs');
insert into users (id, email, full_name) values
  (test.id('op_olivia'), 'olivia.op@example.test', 'Olivia Owner'),
  (test.id('op_other'), 'other.op@example.test', 'Otto Other');

create table test.op (k text primary key, v uuid);
grant select on test.op to authenticated, service_role;
create function test.opv(p text) returns uuid language sql stable as $$ select v from test.op where k = p $$;
create function test.op_vin(p text) returns text language sql immutable as $$ select upper(substr(md5('op-vin-' || p), 1, 17)) $$;

-- ---------------------------------------------------------------- 1. the wizard's reads
select test.eq('facts: the grid has three tiers and the Install Fee is $100',
  (select jsonb_array_length(public.server_owner_program_facts() -> 'grid') || '/' || (public.server_owner_program_facts() ->> 'install_fee_cents')), '3/10000');
select test.eq('options: an individual who owns outright may choose among three methods',
  jsonb_array_length(public.server_onboarding_options('individual', 'owned_outright', 'managed')), 3);
select test.eq('vin: a bad VIN is not valid', (public.server_vin_lookup('123') ->> 'valid')::boolean, false);
select public.server_record_vin_decode(test.op_vin('1'), 'fake', '{"ok":true,"year":"2022","make":"Toyota","model":"Corolla","fuel":"gasoline","body_class":"Sedan"}');
select test.eq('vin: a stored decode is returned for the VIN', public.server_vin_lookup(lower(test.op_vin('1'))) #>> '{decode,make}', 'Toyota');
select test.eq('vin: an unknown fuel from a decoder is ignored, not an error',
  public.server_record_vin_decode(test.op_vin('9'), 'fake', '{"ok":true,"year":"2020","make":"Ford","model":"F-150","fuel":"flex"}') #>> '{decode,fuel}', null);

-- ---------------------------------------------------------------- 2. one application, three vehicles
insert into test.op select 'app', (public.server_submit_owner_application(jsonb_build_object(
  'source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Olivia Owner', 'first_name', 'Olivia', 'last_name', 'Owner',
                              'email', 'olivia.op@example.test', 'phone', '+16475550101', 'address_line1', '10 King Street West',
                              'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1', 'licence_number', 'O1234-56789-01234',
                              'date_of_birth', '1985-05-05'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', test.op_vin('1'), 'plate', 'OPAA101', 'colour', 'White', 'odometer_km', 20000, 'title_status', 'owned_outright',
                       'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact', 'title_brand_clear', true),
    jsonb_build_object('vin', test.op_vin('2'), 'plate', 'OPAA102', 'year', 2021, 'make', 'Honda', 'model', 'Civic', 'colour', 'Black',
                       'odometer_km', 30000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'co_registrant',
                       'current_insurer', 'Aviva'),
    jsonb_build_object('vin', test.op_vin('3'), 'plate', 'OPAA103', 'year', 2023, 'make', 'Tesla', 'model', 'Model 3', 'colour', 'Red',
                       'odometer_km', 10000, 'title_status', 'financed', 'finance_party_name', 'TD Auto Finance', 'management_mode', 'self_managed',
                       'onboarding_method', 'transfer', 'current_insurer', 'Belair'))), test.id('op_olivia')) ->> 'owner_id')::uuid;
insert into test.op select 'v' || row_number() over (order by v.created_at, v.plate), v.id from vehicles v where v.owner_id = test.opv('app');
select test.eq('application: one owner, three vehicles at intake, the VIN decode filled the first',
  (select count(*) || '/' || count(*) filter (where ob.status = 'intake') || '/' || max(v.make) filter (where v.plate = 'OPAA101')
     from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = test.opv('app')), '3/3/Toyota');
select test.eq('application: the owner role reaches the portal', (public.owner_portal_home(test.id('op_olivia')) #>> '{owner,legal_name}'), 'Olivia Owner');
select test.throws('portal: another user is not an owner', $$select public.owner_portal_home(test.id('op_other'))$$, 'Not an owner account');
select test.eq('portal: nothing to sign before terms', (public.owner_portal_home(test.id('op_olivia')) #>> '{signing,needed}'), 'false');

-- ---------------------------------------------------------------- 3. terms and upfront invoices (admin)
select test.throws('terms: a customer service assistant cannot use the admin path',
  $$select public.admin_set_vehicle_terms(test.opv('v1'), test.id('op_cs'), '{}')$$, 'Only an Admin');
select test.eq('terms: the grid for three vehicles applies to each', (select string_agg(public.admin_set_vehicle_terms(test.opv(k), test.id('op_admin'), '{}') ->> 'insurance_fee_cents', ',' order by k)
  from (values ('v1'), ('v2'), ('v3')) x(k)), '40000,40000,40000');
select test.eq('terms: the Self-Managed car has no Revenue Share',
  (select revenue_share_bps from vehicle_schedules where vehicle_id = test.opv('v3') and superseded_by is null), 0);
select test.eq('terms: the government forms were pre-filled for the method',
  (select count(*) > 0 from government_form_fills where vehicle_id = test.opv('v2') and superseded_at is null), true);
select test.eq('admin: the application list shows the owner with three vehicles',
  (select (x ->> 'vehicles') from jsonb_array_elements(public.admin_owner_applications(test.id('op_admin'))) x where (x ->> 'owner_id')::uuid = test.opv('app')), '3');
select test.throws('admin: the list is for Admins', $$select public.admin_owner_applications(test.id('op_cs'))$$, 'Only an Admin');
select test.eq('invoices: an Admin issues the three upfront invoices before signing: $400 x 2 + $100 + HST',
  (select string_agg(x ->> 'total_cents', ',') from jsonb_array_elements(public.admin_issue_upfront_invoices(test.opv('app'), test.id('op_admin'))) x),
  '101700,101700,101700');
select test.eq('invoices: issuing again issues nothing', jsonb_array_length(public.admin_issue_upfront_invoices(test.opv('app'), test.id('op_admin'))), 0);
insert into test.op select 'i' || substr(k, 2), (select upfront_invoice_id from vehicle_onboardings where vehicle_id = v) from test.op where k in ('v1', 'v2', 'v3');
select test.eq('invoices: the owner sees three payable invoices',
  (select count(*) filter (where (x ->> 'payable')::boolean) from jsonb_array_elements(public.owner_portal_home(test.id('op_olivia')) -> 'invoices') x), 3::bigint);
select test.eq('invoices: the owner_upfront_invoice email is queued for each',
  (select count(*) from app_events e where e.code = 'owner_upfront_invoice' and e.entity_id in (test.opv('i1'), test.opv('i2'), test.opv('i3'))), 3::bigint);
select test.eq('invoices: another owner reads nothing of it',
  public.owner_portal_invoice(test.id('op_olivia'), (select invoice_number from owner_invoices where id = test.opv('i1'))) ->> 'total_cents', '101700');

-- ---------------------------------------------------------------- 4. agreements
select test.eq('signing: the packet is needed for three schedules', (public.owner_portal_home(test.id('op_olivia')) #>> '{signing,unsigned_schedules}'), '3');
select test.throws('signing: another user cannot open the packet',
  $$select public.owner_open_agreements(test.opv('app'), test.id('op_other'), '[{"key":"enrollment","template_version":"t","sha256":"aa","storage_path":"x"}]')$$, 'Only the owner');
select public.owner_open_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_array(
  jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', repeat('e', 64), 'storage_path', 'owners/op/ea.pdf'),
  jsonb_build_object('key', 'title_holding', 'template_version', 'title-test', 'sha256', repeat('f', 64), 'storage_path', 'owners/op/ta.pdf')));
select test.eq('signing: opening sends the documents (terms_set to documents_sent)',
  (select count(*) from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where v.owner_id = test.opv('app') and ob.status = 'documents_sent'), 3::bigint);
select test.eq('signing: opening the same documents again keeps the same request',
  (select (public.owner_open_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_array(
     jsonb_build_object('key', 'enrollment', 'template_version', 'enrollment-test', 'sha256', repeat('e', 64), 'storage_path', 'owners/op/ea.pdf'))) #>> '{requests,0,signature_request_id}')::uuid
   = (select signature_request_id from owner_agreements where owner_id = test.opv('app') and kind = 'enrollment')), true);
select test.throws('signing: the three initials are required',
  $$select public.owner_sign_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_object('typed_name', 'Olivia Owner', 'consent_text', 'I sign.',
      'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', repeat('e', 64)))))$$, 'Initial each');
select test.throws('signing: a changed document is refused',
  $$select public.owner_sign_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_object('typed_name', 'Olivia Owner', 'consent_text', 'I sign.',
      'initials', '{"own_insurance":"OO","fees_no_income":"OO","tracker_downtime":"OO"}'::jsonb,
      'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', repeat('d', 64)))))$$, 'document changed');
select test.throws('signing: a typed name must be the legal name',
  $$select public.owner_sign_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_object('typed_name', 'Liv', 'consent_text', 'I sign.',
      'documents', jsonb_build_array(jsonb_build_object('key', 'title_holding', 'sha256', repeat('f', 64)))))$$, 'full legal name');

-- ---------------------------------------------------------------- 5. payments: card before signing, debit pending then paid, offline
select test.throws('pay: another user cannot record one',
  $$select public.server_record_owner_invoice_payment(test.opv('i1'), '{"status":"succeeded","method":"card","amount_cents":101700,"processor":{"payment_id":"pi_x"}}', test.id('op_other'))$$, 'Only the owner');
select test.eq('pay: a card payment marks the invoice paid',
  public.server_record_owner_invoice_payment(test.opv('i1'), jsonb_build_object('status', 'succeeded', 'method', 'card', 'amount_cents', 101700, 'currency', 'cad',
    'processor', jsonb_build_object('payment_id', 'pi_op_card', 'charge_id', 'ch_op', 'customer_id', 'cus_op', 'method_id', 'pm_op_card'),
    'card', jsonb_build_object('brand', 'visa', 'last4', '4242'), 'save_method', true), test.id('op_olivia')) ->> 'invoice_status', 'paid');
select test.eq('pay: the webhook for the same payment is a replay',
  (public.server_record_owner_invoice_payment(test.opv('i1'), jsonb_build_object('status', 'succeeded', 'method', 'card', 'amount_cents', 101700,
    'processor', jsonb_build_object('payment_id', 'pi_op_card'))) ->> 'repeat')::boolean, true);
select test.eq('pay: one payment row, the two prepaid months funded, the card saved',
  (select count(*) from payments where owner_invoice_id = test.opv('i1'))
  || '/' || (select sum(amount_cents) from vehicle_prepaids where vehicle_id = test.opv('v1'))
  || '/' || (select count(*) from owner_payment_methods where owner_id = test.opv('app') and kind = 'card'), '1/80000/1');
select test.eq('pay: the receipt email is queued (owner_payment_received)',
  (select count(*) from app_events where code = 'owner_payment_received' and entity_id = test.opv('i1')), 1::bigint);
select test.eq('pay: paid before signing, the vehicle waits for its signature', (select upfront_paid_at is not null || '/' || status from vehicle_onboardings where vehicle_id = test.opv('v1')), 'true/documents_sent');

select test.eq('debit: a submitted debit is pending, the invoice is not paid yet',
  public.server_record_owner_invoice_payment(test.opv('i2'), jsonb_build_object('status', 'pending', 'method', 'pre_authorized_debit', 'amount_cents', 101700,
    'processor', jsonb_build_object('payment_id', 'pi_op_pad', 'customer_id', 'cus_op', 'method_id', 'pm_op_pad', 'mandate_id', 'mandate_op'),
    'bank', jsonb_build_object('name', 'TD', 'last4', '6789'), 'save_method', true), test.id('op_olivia')) ->> 'invoice_status', 'issued');
select test.eq('debit: while pending the invoice cannot be paid twice',
  (select (x ->> 'pending') || '/' || (x ->> 'payable') from jsonb_array_elements(public.owner_portal_home(test.id('op_olivia')) -> 'invoices') x where (x ->> 'id')::uuid = test.opv('i2')), 'true/false');
select test.eq('debit: the webhook says it succeeded: paid, and the debit authorization is saved for the 15th',
  public.server_record_owner_invoice_payment(test.opv('i2'), jsonb_build_object('status', 'succeeded', 'method', 'pre_authorized_debit', 'amount_cents', 101700,
    'processor', jsonb_build_object('payment_id', 'pi_op_pad', 'customer_id', 'cus_op', 'method_id', 'pm_op_pad', 'mandate_id', 'mandate_op'),
    'bank', jsonb_build_object('name', 'TD', 'last4', '6789'), 'save_method', true)) ->> 'invoice_status', 'paid');
select test.eq('debit: one payment row moved from pending to succeeded; the mandate is on file',
  (select string_agg(status, ',') from payments where owner_invoice_id = test.opv('i2'))
  || '/' || (select s.processor_mandate_id from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id
              where m.owner_id = test.opv('app') and m.kind = 'pre_authorized_debit'), 'succeeded/mandate_op');

select test.eq('debit: a returned debit records a failure and leaves the invoice payable',
  (select public.server_record_owner_invoice_payment(test.opv('i3'), jsonb_build_object('status', 'failed', 'method', 'pre_authorized_debit', 'amount_cents', 101700,
     'processor', jsonb_build_object('payment_id', 'pi_op_fail'), 'failure_message', 'Insufficient funds')) ->> 'invoice_status')
   || '/' || (select (x ->> 'payable') from jsonb_array_elements(public.owner_portal_home(test.id('op_olivia')) -> 'invoices') x where (x ->> 'id')::uuid = test.opv('i3')),
  'issued/true');
select test.throws('offline: only an Admin records one',
  $$select public.admin_record_owner_offline_payment(test.opv('i3'), test.id('op_cs'), '{"method":"e_transfer","reference":"ETR123"}')$$, 'Only an Admin');
select test.throws('offline: the reference is required',
  $$select public.admin_record_owner_offline_payment(test.opv('i3'), test.id('op_admin'), '{"method":"cheque"}')$$, 'reference');
select test.eq('offline: an e-Transfer with its reference pays the invoice',
  public.admin_record_owner_offline_payment(test.opv('i3'), test.id('op_admin'), '{"method":"e_transfer","reference":"CA1234XYZ","note":"Received by email"}') ->> 'invoice_status', 'paid');
select test.eq('offline: the same reference again is a replay',
  (public.admin_record_owner_offline_payment(test.opv('i3'), test.id('op_admin'), '{"method":"e_transfer","reference":"CA1234XYZ"}') ->> 'repeat')::boolean, true);
select test.eq('offline: audited with the method and reference, shown on the invoice',
  (select a.actor_user_id = test.id('op_admin') and a.after ->> 'reference' = 'CA1234XYZ' from audit_log a
     where a.action = 'record_offline_payment' and a.entity_id = test.opv('i3')::text)::text
  || '/' || (select p ->> 'reference' from jsonb_array_elements(public.owner_portal_invoice(test.id('op_olivia'), (select invoice_number from owner_invoices where id = test.opv('i3'))) -> 'payments') p
              where p ->> 'status' = 'succeeded'), 'true/CA1234XYZ');
select test.eq('offline: a payment arriving on a settled invoice leaves it paid',
  (public.server_record_owner_invoice_payment(test.opv('i3'), jsonb_build_object('status', 'succeeded', 'method', 'card', 'amount_cents', 101700,
     'processor', jsonb_build_object('payment_id', 'pi_op_late'))) ->> 'invoice_status'), 'paid');
select test.eq('offline: and goes to an Admin task to refund or apply it',
  (select count(*) from tasks where task_type = 'owner_payment_unapplied' and owner_id = test.opv('app')), 1::bigint);
select test.eq('pay: a cheque is a payment method now', (select count(*) from pg_constraint where conname = 'payments_method_check' and pg_get_constraintdef(oid) like '%cheque%'), 1::bigint);

-- ---------------------------------------------------------------- 6. signing completes, paid vehicles move on
select test.eq('signing: one signature signs both agreements and every schedule',
  (public.owner_sign_agreements(test.opv('app'), test.id('op_olivia'), jsonb_build_object('typed_name', 'Olivia  owner', 'consent_text', 'I sign.',
     'ip', '203.0.113.5', 'user_agent', 'test',
     'initials', '{"own_insurance":"OO","fees_no_income":"OO","tracker_downtime":"OO"}'::jsonb,
     'documents', jsonb_build_array(jsonb_build_object('key', 'enrollment', 'sha256', repeat('e', 64)),
                                    jsonb_build_object('key', 'title_holding', 'sha256', repeat('f', 64))))) ->> 'vehicles_signed'), '3');
select test.eq('signing: agreements signed with the three confirmations, CarmaCars countersigned',
  (select string_agg(a.status, ',' order by a.kind) from owner_agreements a where a.owner_id = test.opv('app'))
  || '/' || (select (confirm_own_insurance_at is not null and confirm_fees_no_income_at is not null and confirm_tracker_downtime_at is not null)::text
               from owner_agreements where owner_id = test.opv('app') and kind = 'enrollment')
  || '/' || (select count(*) from signature_records r join owner_agreements a on a.signature_request_id = r.signature_request_id
              where a.owner_id = test.opv('app') and r.signer_role = 'carmacars'), 'signed,signed/true/2');
select test.eq('signing: the paid vehicles are upfront_paid, the schedules are signed',
  (select string_agg(ob.status::text, ',' order by v.plate) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = test.opv('app'))
  || '/' || (select count(*) from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = test.opv('app') and s.signed_at is not null),
  'upfront_paid,upfront_paid,upfront_paid/3');
select test.eq('signing: nothing left to sign', (public.owner_portal_home(test.id('op_olivia')) #>> '{signing,needed}'), 'false');
select public.server_attach_owner_signed_copy((select signature_request_id from owner_agreements where owner_id = test.opv('app') and kind = 'enrollment'),
                                              'owners/op/ea-signed.pdf', repeat('1', 64));
select test.eq('documents: the signed copy is the owner''s document',
  (select count(*) from jsonb_array_elements(public.owner_portal_documents(test.id('op_olivia'))) x where x ->> 'kind' = 'enrollment_agreement'), 2::bigint);
select test.eq('documents: a document is opened only by its owner',
  (public.owner_portal_document(test.id('op_olivia'), (select document_id from owner_agreements where owner_id = test.opv('app') and kind = 'enrollment')) ->> 'path'),
  'owners/op/ea-signed.pdf');

-- ---------------------------------------------------------------- 7. the rest of the portal
select test.eq('profile: contact details change, the legal name does not',
  (public.owner_save_profile(test.id('op_olivia'), '{"phone":"+16475550199","legal_name":"Someone Else","hst_number":"123456789RT0001"}') ->> 'phone')
  || '/' || (select legal_name from owners where id = test.opv('app')), '+16475550199/Olivia Owner');
select test.throws('profile: a malformed HST number is refused', $$select public.owner_save_profile(test.id('op_olivia'), '{"hst_number":"12345"}')$$, 'HST number');
select public.owner_submit_payout_account(test.id('op_olivia'), '{"method":"e_transfer","e_transfer_email":"olivia.op@example.test"}');
select test.eq('payout: new details wait for verification, with the security email queued',
  (select is_current::text from owner_payout_accounts where owner_id = test.opv('app') order by created_at desc limit 1)
  || '/' || (select count(*) from app_events where code = 'owner_bank_details_changed' and entity_id = test.opv('app')), 'false/3');
select test.eq('bookings: none yet', jsonb_array_length(public.owner_portal_bookings(test.id('op_olivia'))), 0);
select test.eq('forms: the data sheets are the owner''s', (select count(*) > 0 from jsonb_array_elements(public.owner_portal_forms(test.id('op_olivia')))), true);
select test.eq('admin: the detail lists the three paid upfront invoices',
  (select count(*) from jsonb_array_elements(public.admin_owner_detail(test.id('op_admin'), test.opv('app')) -> 'invoices') x where x ->> 'status' = 'paid'), 3::bigint);
select test.eq('admin: the gate reports roles', (public.admin_gate(test.id('op_admin')) ->> 'admin') || '/' || (public.admin_gate(test.id('op_olivia')) ->> 'admin'), 'true/false');
select public.server_send_link_email('new.op@example.test', 'New Owner', 'https://carmacars.ca/list-your-car/apply?invite=x', '7 days', 'op-test');
select test.eq('links: a resume or invitation link is queued as an email to the address given',
  (select count(*) from app_events where code = 'account_sign_in_link' and payload ->> 'signer_email' = 'new.op@example.test'), 1::bigint);

-- ---------------------------------------------------------------- 8. privileges
select test.login(test.id('op_olivia'));
select test.throws('privileges: a browser session cannot record a payment',
  $$select public.server_record_owner_invoice_payment(test.opv('i1'), '{}'::jsonb)$$, 'permission denied');
select test.throws('privileges: a signed-in owner cannot call the server wrappers directly', $$select public.owner_portal_home(auth.uid())$$, 'permission denied');
select test.throws('privileges: nor the admin ones', $$select public.admin_owner_applications(auth.uid())$$, 'permission denied');
select test.logout();
select test.eq('privileges: no 0029 function is open to anon or authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public') and p.proname in ('owner_portal_home', 'record_owner_invoice_payment', 'record_owner_offline_payment',
          'admin_issue_upfront_invoices', 'owner_sign_agreements', 'server_record_owner_invoice_payment', 'admin_record_owner_offline_payment')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
