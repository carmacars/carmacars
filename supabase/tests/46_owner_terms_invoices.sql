-- 46: negotiated terms, the Approve step with its first invoices, owner invoices (drafts, issue, void and reissue,
-- credit notes, resend, PDF), updated Vehicle Schedules signed by the owner, and cars staff add for an owner (0067).
-- Fixtures start with "ot".
select test.suite('46 owner terms and invoices');
grant usage on schema test to service_role;
create table test.ot (k text primary key, v jsonb);
create function test.otv(p text) returns jsonb language sql stable as $$ select v from test.ot where k = p $$;
create function test.ot_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.ot_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;
create function test.ot_va(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'va_do', p_name, p) $$;

select test.mk_user('ot_admin', 'admin');
select test.mk_user('ot_cs', 'va', 'cs');
select test.mk_user('ot_fin', 'va', 'finance');
update program_settings set trackers_available = false;

-- an owner who applied themselves, with one car
insert into users (id, email, full_name) values (test.id('ot_oscar'), 'oscar.ot@example.test', 'Oscar Owner');
insert into test.ot select 'app', public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Oscar Owner', 'first_name', 'Oscar', 'email', 'oscar.ot@example.test',
                              'phone', '+16475550177', 'address_line1', '1 Bay Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5J 2R8',
                              'licence_number', 'O1234-56789-01234', 'date_of_birth', '1985-02-02'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', upper(substr(md5('ot-vin-1'), 1, 17)), 'plate', 'OTAA101', 'year', 2022, 'make', 'Honda', 'model', 'CR-V', 'colour', 'Blue',
    'odometer_km', 30000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva', 'title_brand_clear', true))),
  test.id('ot_oscar'));
create function test.ot_owner() returns uuid language sql stable as $$ select (test.otv('app') ->> 'owner_id')::uuid $$;
create function test.ot_car() returns uuid language sql stable as $$ select (test.otv('app') #>> '{vehicles,0,vehicle_id}')::uuid $$;
create function test.ot_appid() returns uuid language sql stable as $$ select (test.otv('app') ->> 'application_id')::uuid $$;
create function test.oti(p_number text) returns owner_invoices language sql stable as $$ select * from owner_invoices where invoice_number = p_number $$;

-- ================================================================ 1. terms: precedence and effective dates
select test.eq('terms: with nothing negotiated a car takes the standard grid; first and last is 2 x the Insurance Fee',
  (select (r ->> 'insurance_fee_cents') || '/' || (r #>> '{sources,insurance_fee_cents}') || '/' || (r ->> 'first_last_cents') || '/' || (r #>> '{sources,first_last_cents}')
     from (select app.owner_terms_resolve(test.ot_car()) r) x), '45000/standard/90000/two_months');
select test.ot_do('ot_admin', 'owner_terms_save', jsonb_build_object('owner_id', test.ot_owner(), 'insurance_fee_cents', 40000, 'first_last_cents', 80000, 'note', 'Agreed by phone'));
select test.eq('terms: the owner''s default wins over the grid, field by field (the Tracker Fee left to the grid)',
  (select (r ->> 'insurance_fee_cents') || '/' || (r #>> '{sources,insurance_fee_cents}') || '/' || (r ->> 'tracker_fee_cents') || '/' || (r #>> '{sources,tracker_fee_cents}')
          || '/' || (r ->> 'first_last_cents') || '/' || (r #>> '{sources,first_last_cents}')
     from (select app.owner_terms_resolve(test.ot_car()) r) x), '40000/owner/2500/standard/80000/owner');
select test.ot_do('ot_admin', 'owner_terms_save', jsonb_build_object('vehicle_id', test.ot_car(), 'insurance_fee_cents', 42000, 'revenue_share_bps', 3000));
select test.eq('terms: the car''s own terms win over the owner''s; the car not set yet keeps them for when its terms are set',
  (select (r ->> 'insurance_fee_cents') || '/' || (r #>> '{sources,insurance_fee_cents}') || '/' || (r ->> 'revenue_share_bps') || '/' || (r #>> '{sources,revenue_share_bps}')
     from (select app.owner_terms_resolve(test.ot_car()) r) x), '42000/car/3000/car');
select test.ot_do('ot_admin', 'owner_terms_save', jsonb_build_object('owner_id', test.ot_owner(), 'insurance_fee_cents', 39000, 'effective_from', app.today() + 10));
select test.eq('terms: effective dates: the owner''s new default applies from its date, the old one until then',
  (app.owner_terms_resolve(null, app.today(), test.ot_owner()) ->> 'insurance_fee_cents') || '/' || (app.owner_terms_resolve(null, app.today() + 10, test.ot_owner()) ->> 'insurance_fee_cents')
  || '/' || (select count(*) from owner_terms where owner_id = test.ot_owner() and vehicle_id is null and effective_to = app.today() + 10), '40000/39000/1');
select test.throws('terms: a row dated before one already saved is refused',
  format($$select test.ot_do('ot_admin', 'owner_terms_save', %L)$$, jsonb_build_object('owner_id', test.ot_owner(), 'insurance_fee_cents', 41000, 'effective_from', app.today() + 5)), 'already start after');
select test.throws('terms: only an Admin saves terms', format($$select test.ot_va('ot_cs', 'owner_terms_save', %L)$$, jsonb_build_object('owner_id', test.ot_owner())), '');
select test.eq('terms: the rows are audited', (select count(*) >= 3 from audit_log where entity_table = 'owner_terms'), true);

-- ================================================================ 2. Approve: custom terms, first and last paid by e-Transfer
insert into test.ot select 'plan', test.ot_read('ot_admin', 'application_approve_plan', jsonb_build_object('id', test.ot_appid()));
select test.eq('approve step: each car with its terms pre-filled from the negotiated defaults, trackers not available',
  (test.otv('plan') #>> '{cars,0,terms,insurance_fee_cents}') || '/' || (test.otv('plan') ->> 'trackers_available') || '/' || jsonb_array_length(test.otv('plan') -> 'cars'), '42000/false/1');
select test.throws('approve step: a Tracker Install invoice is refused while trackers are not available',
  format($$select test.ot_do('ot_admin', 'application_approve', %L)$$, jsonb_build_object('id', test.ot_appid(), 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.ot_car(),
    'invoices', '[{"type": "tracker_install", "action": "send"}]'::jsonb)))), 'Trackers are not available');
select test.eq('approve step: a refused approval changed nothing', (select status from owner_applications where id = test.ot_appid()) || '/' || (select count(*) from owner_invoices where owner_id = test.ot_owner()), 'new/0');
select test.throws('approve step: an e-Transfer recorded as paid needs its reference',
  format($$select test.ot_do('ot_admin', 'application_approve', %L)$$, jsonb_build_object('id', test.ot_appid(), 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.ot_car(),
    'invoices', '[{"type": "first_last", "action": "paid", "payment": {"method": "e_transfer"}}]'::jsonb)))), 'reference');
insert into test.ot select 'approve', test.ot_do('ot_admin', 'application_approve', jsonb_build_object('id', test.ot_appid(), 'cars', jsonb_build_array(jsonb_build_object(
  'vehicle_id', test.ot_car(),
  'terms', jsonb_build_object('insurance_fee_cents', 38000, 'tracker_fee_cents', 2000, 'revenue_share_bps', 3000, 'install_fee_cents', 10000, 'first_last_cents', 70000),
  'invoices', jsonb_build_array(
    jsonb_build_object('type', 'first_last', 'amount_cents', 70000, 'action', 'paid',
                       'payment', jsonb_build_object('method', 'e_transfer', 'reference', 'CAxOT123', 'received_on', app.today(), 'amount_cents', 79100)),
    jsonb_build_object('type', 'registration', 'amount_cents', 12345, 'action', 'send'),
    jsonb_build_object('type', 'custom', 'title', 'Detailing before listing', 'action', 'draft',
                       'lines', '[{"description": "Interior detail", "quantity": 1, "unit_amount_cents": 15000, "hst": true}]'::jsonb))))));
create function test.ot_inv(p_type text) returns owner_invoices language sql stable as $$
  select i.* from owner_invoices i where i.invoice_number = (select x ->> 'invoice_number' from jsonb_array_elements(test.otv('approve') -> 'invoices') x where x ->> 'type' = p_type) $$;
select test.eq('approve: the Vehicle Schedule has the exact terms agreed, the first and last amount included',
  (select s.insurance_fee_cents || '/' || s.tracker_fee_cents || '/' || s.revenue_share_bps || '/' || s.first_last_cents from vehicle_schedules s where s.vehicle_id = test.ot_car() and s.superseded_by is null),
  '38000/2000/3000/70000');
select test.eq('approve: first and last recorded as paid by e-Transfer: paid, $791.00, the two prepaid months held, no invoice email, the receipt',
  (test.ot_inv('first_last')).status || '/' || (test.ot_inv('first_last')).total_cents || '/'
  || (select string_agg(kind || ':' || amount_cents, ',' order by kind) from vehicle_prepaids where vehicle_id = test.ot_car()) || '/'
  || (select count(*) from app_events where entity_id = (test.ot_inv('first_last')).id and code = 'owner_upfront_invoice') || '/'
  || (select count(*) from manual_payments m where m.owner_invoice_id = (test.ot_inv('first_last')).id and m.method = 'e_transfer' and m.reference = 'CAxOT123') || '/'
  || (select count(*) from app_events where code = 'owner_payment_recorded' and payload ->> 'owner_invoice_id' = (test.ot_inv('first_last')).id::text),
  'paid/79100/first_month_insurance:35000,last_month_insurance:35000/0/1/1');
select test.eq('approve: the registration fee to the exact cent, sent: $123.45 plus HST $16.05, its own email, due in 7 days',
  (test.ot_inv('registration')).status || '/' || (test.ot_inv('registration')).fees_cents || '/' || (test.ot_inv('registration')).hst_cents || '/'
  || (select count(*) from app_events where entity_id = (test.ot_inv('registration')).id and code = 'owner_invoice_issued') || '/'
  || ((test.ot_inv('registration')).due_on - app.today()), 'issued/12345/1605/1/7');
select test.eq('approve: the custom invoice kept as a draft: not emailed, not in the owner portal, never debited',
  (test.ot_inv('custom')).status || '/' || (select count(*) from app_events where entity_id = (test.ot_inv('custom')).id) || '/'
  || (select count(*) from jsonb_array_elements(app.owner_portal_invoices(test.id('ot_oscar'))) x where x ->> 'id' = (test.ot_inv('custom')).id::text) || '/'
  || coalesce(app.owner_debit_block((test.ot_inv('custom')).id), 'debited'), 'draft/0/0/the invoice is draft');
select test.eq('approve: the owner''s approval email; the note lists each invoice and what was done',
  (select count(*) from app_events where code = 'owner_application_approved' and entity_id = test.ot_appid()) || '/'
  || (select body like '%recorded as paid%sent%draft%' from owner_application_notes where application_id = test.ot_appid() and kind = 'decision'), '1/true');
select test.eq('approve: the owner portal shows the exact agreed amounts (the registration line)',
  (select l ->> 'description' || '=' || (l ->> 'amount_cents') from jsonb_array_elements(public.owner_portal_invoice(test.id('ot_oscar'), (test.ot_inv('registration')).invoice_number) -> 'lines') l),
  'Registration fee=12345');
select test.eq('approve: a custom invoice is debited automatically once issued (Program settings kinds)',
  coalesce(app.owner_debit_block((test.ot_inv('registration')).id), 'none') <> 'this kind of invoice is not debited automatically', true);

-- ================================================================ 3. invoices: drafts, issue, void and reissue, credit notes
insert into test.ot select 'reg', test.ot_do('ot_admin', 'owner_invoice_draft_save', jsonb_build_object('vehicle_id', test.ot_car(), 'title', 'Registration fee', 'notes', 'ServiceOntario visit, Oct 20',
  'lines', '[{"kind": "registration_fee", "description": "Registration fee", "quantity": 1, "unit_amount_cents": 12345, "hst": false},
             {"description": "Plate stickers", "quantity": 2, "unit_amount_cents": 1234, "hst": true, "note": "two stickers"}]'::jsonb));
select test.eq('invoice: a draft line by line: quantity x unit to the cent, HST per line (off on the first)',
  (select string_agg(l.amount_cents || ':' || l.hst_cents, ',' order by l.sort_order) from owner_invoice_lines l where l.owner_invoice_id = (test.otv('reg') ->> 'id')::uuid)
  || '/' || (test.oti(test.otv('reg') ->> 'invoice_number')).total_cents, '12345:0,2468:321/15134');
select test.ot_do('ot_admin', 'owner_invoice_draft_save', jsonb_build_object('id', test.otv('reg') ->> 'id', 'title', 'Registration fee', 'due_on', app.today() + 3,
  'lines', '[{"kind": "registration_fee", "description": "Registration fee", "quantity": 1, "unit_amount_cents": 12345, "hst": true}]'::jsonb));
select test.eq('invoice: a draft is edited in place (lines replaced, due date kept)',
  (test.oti(test.otv('reg') ->> 'invoice_number')).total_cents || '/' || ((test.oti(test.otv('reg') ->> 'invoice_number')).due_on - app.today()), '13950/3');
select test.throws('invoice: an empty line is refused', format($$select test.ot_do('ot_admin', 'owner_invoice_draft_save', %L)$$,
  jsonb_build_object('id', test.otv('reg') ->> 'id', 'lines', '[{"description": "", "unit_amount_cents": 100}]'::jsonb)), 'description');
select test.throws('invoice: a second first and last invoice for a car is refused', format($$select test.ot_do('ot_admin', 'owner_invoice_draft_save', %L)$$,
  jsonb_build_object('vehicle_id', test.ot_car(), 'kind', 'upfront', 'lines', '[{"kind": "first_month_insurance", "description": "First", "unit_amount_cents": 100}]'::jsonb)), 'already has');
select test.ot_do('ot_admin', 'owner_invoice_issue', jsonb_build_object('id', test.otv('reg') ->> 'id'));
select test.throws('invoice: an issued invoice is never edited through the screens', format($$select test.ot_do('ot_admin', 'owner_invoice_draft_save', %L)$$,
  jsonb_build_object('id', test.otv('reg') ->> 'id', 'lines', '[{"description": "x", "unit_amount_cents": 100}]'::jsonb)), 'never edited');
select test.throws('invoice: nor in the database (a line of an issued invoice cannot change)',
  format($$update owner_invoice_lines set amount_cents = 1 where owner_invoice_id = %L$$, test.otv('reg') ->> 'id'), 'Void it with a reason');
select test.throws('invoice: a void needs the reason', format($$select test.ot_do('ot_admin', 'owner_invoice_void', %L)$$, jsonb_build_object('id', test.otv('reg') ->> 'id')), 'reason');
insert into test.ot select 'void', test.ot_do('ot_admin', 'owner_invoice_void', jsonb_build_object('id', test.otv('reg') ->> 'id', 'reason', 'The fee was $120.00, not $123.45.', 'reissue', true));
select test.eq('invoice: void and reissue: void with its reason, the owner told, a corrected draft made from it (same lines)',
  (test.oti(test.otv('reg') ->> 'invoice_number')).status || '/' || (test.oti(test.otv('reg') ->> 'invoice_number')).void_reason || '/'
  || (select count(*) from app_events where entity_id = (test.otv('reg') ->> 'id')::uuid and code = 'owner_invoice_voided') || '/'
  || (test.oti(test.otv('void') ->> 'replacement_number')).status || '/' || ((test.oti(test.otv('void') ->> 'replacement_number')).replaces_invoice_id::text = test.otv('reg') ->> 'id')
  || '/' || (test.oti(test.otv('void') ->> 'replacement_number')).total_cents,
  'void/The fee was $120.00, not $123.45./1/draft/true/13950');
select test.ot_do('ot_admin', 'owner_invoice_draft_save', jsonb_build_object('id', test.otv('void') ->> 'replacement_id', 'title', 'Registration fee',
  'lines', '[{"kind": "registration_fee", "description": "Registration fee", "quantity": 1, "unit_amount_cents": 12000, "hst": true}]'::jsonb));
select test.ot_do('ot_admin', 'owner_invoice_issue', jsonb_build_object('id', test.otv('void') ->> 'replacement_id'));
select test.eq('invoice: the corrected invoice issued at the right amount; the owner portal shows both (void with its reason, and the replacement)',
  (test.oti(test.otv('void') ->> 'replacement_number')).status || '/' || (test.oti(test.otv('void') ->> 'replacement_number')).total_cents || '/'
  || ((public.owner_portal_invoice(test.id('ot_oscar'), test.otv('reg') ->> 'invoice_number') ->> 'replaced_by') = (test.otv('void') ->> 'replacement_number')),
  'issued/13560/true');
select test.throws('invoice: a paid invoice is not voided (void the payment or issue a credit note)',
  format($$select test.ot_do('ot_admin', 'owner_invoice_void', %L)$$, jsonb_build_object('id', (test.ot_inv('first_last')).id, 'reason', 'x')), 'credit note');
insert into test.ot select 'cn', test.ot_do('ot_admin', 'owner_invoice_credit_note', jsonb_build_object('id', (test.ot_inv('first_last')).id, 'amount_cents', 5000, 'reason', 'Agreed discount'));
select test.eq('invoice: a credit note for a paid invoice: its own number, negative, issued, linked',
  (test.oti(test.otv('cn') ->> 'invoice_number')).kind || '/' || (test.oti(test.otv('cn') ->> 'invoice_number')).total_cents || '/' || (test.oti(test.otv('cn') ->> 'invoice_number')).status
  || '/' || ((test.oti(test.otv('cn') ->> 'invoice_number')).credit_for_invoice_id = (test.ot_inv('first_last')).id), 'credit_note/-5650/issued/true');
select test.ot_do('ot_admin', 'owner_invoice_void', jsonb_build_object('id', (test.ot_inv('custom')).id, 'reason', 'Not needed'));
select test.eq('invoice: voiding a draft tells nobody', (select count(*) from app_events where entity_id = (test.ot_inv('custom')).id), 0::bigint);
select test.ot_do('ot_admin', 'owner_invoice_resend', jsonb_build_object('id', (test.ot_inv('registration')).id));
select test.eq('invoice: resend sends the invoice email again',
  (select count(*) from app_events where entity_id = (test.ot_inv('registration')).id and code = 'owner_invoice_issued'), 2::bigint);
-- a manual payment on an issued invoice stops its debit (0044, unchanged)
insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key)
values ((test.ot_inv('registration')).id, test.ot_owner(), 1, app.today() + 10, 13950, 'ot-debit-1');
select test.ot_do('ot_admin', 'manual_payment_record', jsonb_build_object('invoice', (test.ot_inv('registration')).id, 'method', 'cash', 'amount_cents', 13950, 'received_on', app.today()));
select test.eq('invoice: paid in cash: paid, its scheduled debit cancelled',
  (test.ot_inv('registration')).status || '/' || (select status from owner_debit_attempts where idempotency_key = 'ot-debit-1'), 'paid/canceled');
select test.eq('invoice: Admin > the owner, the application and Money list every invoice, drafts and voids included',
  (select jsonb_array_length(test.ot_read('ot_admin', 'owner_invoices_admin', jsonb_build_object('owner_id', test.ot_owner())) -> 'rows')) || '/'
  || (select jsonb_array_length(test.ot_read('ot_admin', 'owner_invoices_admin', jsonb_build_object('application_id', test.ot_appid())) -> 'rows')) || '/'
  || (test.ot_read('ot_admin', 'owner_invoices_admin', jsonb_build_object('application_id', test.ot_appid())) #>> '{counts,void}'), '6/6/2');
select test.eq('invoice: one invoice page: lines, payments, manual payments, debits, emails, history, what can be done',
  (select jsonb_array_length(x -> 'lines') || '/' || jsonb_array_length(x -> 'payments') || '/' || jsonb_array_length(x -> 'manual') || '/' || jsonb_array_length(x -> 'debits')
          || '/' || (jsonb_array_length(x -> 'emails') >= 2) || '/' || (x #>> '{can,void}') || '/' || (x #>> '{can,credit}')
     from (select test.ot_read('ot_admin', 'owner_invoice_admin', jsonb_build_object('id', (test.ot_inv('registration')).id)) x) y), '1/1/1/1/true/false/true');
select test.throws('invoice: the invoice screens are for Admins', format($$select test.ot_read('ot_fin', 'owner_invoices_admin', %L)$$, jsonb_build_object('owner_id', test.ot_owner())), '');
insert into test.ot select 'draft2', test.ot_do('ot_admin', 'owner_invoice_draft_save', jsonb_build_object('vehicle_id', test.ot_car(),
  'lines', '[{"description": "Key copy", "quantity": 1, "unit_amount_cents": 4500}]'::jsonb));
select test.eq('invoice: the PDF: the owner downloads an issued invoice of theirs, not a draft; Finance any',
  app.file_access(test.id('ot_oscar'), 'owner_invoice', (test.ot_inv('registration')).id::text) || '/' || app.file_access(test.id('ot_oscar'), 'owner_invoice', test.otv('draft2') ->> 'id')
  || '/' || app.file_access(test.id('ot_fin'), 'owner_invoice', test.otv('draft2') ->> 'id')
  || '/' || (app.pdf_facts('owner_invoice', (test.ot_inv('registration')).id::text) #>> '{lines,0,amount_cents}'), 'true/false/true/12345');

-- ================================================================ 4. after the Vehicle Schedule is signed: an updated one to sign
select test.mk_owner('ot_sam');
select test.mk_vehicle('OTS', 'ot_sam', 'managed', 45000, 2500, 3500, date '2026-09-01');
insert into test.ot select 'warn', test.ot_do('ot_admin', 'owner_terms_save', jsonb_build_object('vehicle_id', test.id('vehicle:OTS'), 'insurance_fee_cents', 40000, 'revenue_share_bps', 3000, 'effective_from', app.today() + 20));
select test.eq('re-sign: a signed schedule: the warning, nothing saved',
  (test.otv('warn') ->> 'needs_resign') || '/' || coalesce(test.otv('warn') ->> 'saved', 'nothing') || '/' || (select count(*) from owner_terms where vehicle_id = test.id('vehicle:OTS')), 'true/nothing/0');
insert into test.ot select 'resign', test.ot_do('ot_admin', 'owner_terms_save', jsonb_build_object('vehicle_id', test.id('vehicle:OTS'), 'insurance_fee_cents', 40000, 'revenue_share_bps', 3000,
  'effective_from', app.today() + 20, 'confirm_resign', true));
select test.eq('re-sign: one click: the updated Vehicle Schedule waits for the owner, who is emailed; the signed terms still apply',
  (select c.status from vehicle_term_changes c where c.id = (test.otv('resign') ->> 'change_id')::uuid) || '/'
  || (select count(*) from app_events where code = 'owner_schedule_resign' and entity_id = (test.otv('resign') ->> 'change_id')::uuid) || '/'
  || (app.vehicle_terms(test.id('vehicle:OTS'), app.today() + 25)).insurance_fee_cents || '/' || jsonb_array_length(public.server_owner_schedule_changes(test.id('ot_sam'))),
  'awaiting_signature/1/45000/1');
select test.throws('re-sign: the owner signs only the text on screen (its SHA-256)',
  format($$select public.server_schedule_change_sign(%L, %L)$$, test.id('ot_sam'), jsonb_build_object('change_id', test.otv('resign') ->> 'change_id', 'agree', true, 'name', 'Ot Sam', 'sha256', repeat('0', 64))), 'changed since');
select test.throws('re-sign: another person cannot sign it',
  format($$select public.server_schedule_change_sign(%L, %L)$$, test.id('ot_oscar'), jsonb_build_object('change_id', test.otv('resign') ->> 'change_id', 'agree', true, 'name', 'x', 'sha256', 'x')), 'Not found');
insert into test.ot select 'signed', public.server_schedule_change_sign(test.id('ot_sam'), jsonb_build_object('change_id', test.otv('resign') ->> 'change_id', 'agree', true, 'name', 'Ot Sam',
  'sha256', public.server_owner_schedule_change(test.id('ot_sam'), (test.otv('resign') ->> 'change_id')::uuid) ->> 'sha256'));
select test.eq('re-sign: signed: a new schedule version, the old one superseded, the new terms from their date (fee history), countersigned',
  (select count(*) from vehicle_schedules where vehicle_id = test.id('vehicle:OTS')) || '/'
  || (select s.insurance_fee_cents || ':' || s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = test.id('vehicle:OTS') and s.superseded_by is null) || '/'
  || (app.vehicle_terms(test.id('vehicle:OTS'), app.today() + 19)).insurance_fee_cents || '/' || (app.vehicle_terms(test.id('vehicle:OTS'), app.today() + 20)).insurance_fee_cents || '/'
  || (select (countersignature like 'Signed electronically for %standing authorization%') from vehicle_term_changes where id = (test.otv('resign') ->> 'change_id')::uuid),
  '2/40000:3000/45000/40000/true');
select app.generate_owner_invoice(test.id('vehicle:OTS'), (date_trunc('month', app.today() + 60))::date);
select test.eq('re-sign: the monthly invoice after the date bills the new Insurance Fee',
  (select l.amount_cents from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id
    where i.vehicle_id = test.id('vehicle:OTS') and i.period_month = (date_trunc('month', app.today() + 60))::date and l.kind = 'insurance_fee'), 40000::bigint);

-- ================================================================ 5. staff add a car for an owner
insert into test.ot select 'cs_add', test.ot_va('ot_cs', 'staff_add_owner_car', jsonb_build_object(
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Nadia New', 'first_name', 'Nadia', 'email', 'nadia.ot@example.test', 'phone', '+16475550188',
                              'address_line1', '5 King Street', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1'),
  'vehicle', jsonb_build_object('vin', upper(substr(md5('ot-vin-2'), 1, 17)), 'plate', 'OTBB202', 'year', 2021, 'make', 'Toyota', 'model', 'Corolla', 'colour', 'White',
    'odometer_km', 41000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact'),
  'plan', jsonb_build_object('terms', jsonb_build_object('insurance_fee_cents', 41000), 'invoices', '[{"type": "first_last", "action": "send"}]'::jsonb)));
create function test.ot_napp() returns owner_applications language sql stable as $$ select * from owner_applications where id = (test.otv('cs_add') ->> 'application_id')::uuid $$;
select test.eq('staff add: customer service enters it: the same records, "Entered by staff", waiting for an Admin with a task, not approved',
  (test.ot_napp()).source || '/' || (test.ot_napp()).status || '/' || ((test.ot_napp()).entered_by = test.id('ot_cs')) || '/' || (test.otv('cs_add') ->> 'approved') || '/'
  || (select count(*) from tasks where related_id = (test.ot_napp()).id and task_type = 'owner_application_staff') || '/'
  || ((test.ot_napp()).plan ? (test.otv('cs_add') ->> 'vehicle_id')), 'staff/new/true/false/1/true');
select test.eq('staff add: the owner''s own application emails are not sent (one set-up email later)',
  (select count(*) from app_events e join vehicle_onboardings ob on ob.id = e.entity_id
    where ob.vehicle_id = (test.otv('cs_add') ->> 'vehicle_id')::uuid and e.code in ('owner_application_received', 'staff_owner_application_received') and e.processed_at is null) || '/'
  || (select count(*) from app_events e join vehicle_onboardings ob on ob.id = e.entity_id
    where ob.vehicle_id = (test.otv('cs_add') ->> 'vehicle_id')::uuid and e.process_note like 'entered by staff%'), '0/2');
select test.eq('staff add: entered for CarmaCars by default: not recorded as recruited by the staff member',
  (select coalesce(recruited_by::text, 'none') from owners where id = (test.ot_napp()).owner_id) || '/' || coalesce((test.ot_napp()).sourced_by::text, 'none'), 'none/none');
select test.throws('staff add: Finance does not add cars for owners', format($$select test.ot_va('ot_fin', 'staff_add_owner_car', %L)$$, jsonb_build_object('vehicle', '{}'::jsonb)), '');
insert into test.ot select 'n_approve', test.ot_do('ot_admin', 'application_approve', jsonb_build_object('id', (test.ot_napp()).id, 'cars', jsonb_build_array(jsonb_build_object(
  'vehicle_id', test.otv('cs_add') ->> 'vehicle_id', 'terms', jsonb_build_object('insurance_fee_cents', 41000), 'invoices', '[{"type": "first_last", "action": "send"}]'::jsonb))));
select test.eq('staff add: approved: no "approved" email; the set-up email is asked for (the owner has no sign-in yet); the invoice at 2 x $410.00',
  (select count(*) from app_events where code = 'owner_application_approved' and entity_id = (test.ot_napp()).id) || '/' || (test.otv('n_approve') #>> '{setup,needed}') || '/'
  || (test.otv('n_approve') #>> '{setup,has_account}') || '/' || (test.otv('n_approve') #>> '{invoices,0,total_cents}'), '0/true/false/92660');
select test.ot_do('ot_admin', 'owner_setup_email', jsonb_build_object('application_id', (test.ot_napp()).id, 'password_url', 'https://carmacars.ca/auth/callback?token_hash=ot&type=invite&next=/update-password'));
select test.eq('staff add: one set-up email, with the link to choose a password; asked twice, sent once',
  (select count(*) from app_events where code = 'owner_car_set_up' and entity_id = (test.ot_napp()).id) || '/'
  || (select (payload ->> 'password_url') like 'https://carmacars.ca/auth/callback%' from app_events where code = 'owner_car_set_up' and entity_id = (test.ot_napp()).id) || '/'
  || (test.ot_do('ot_admin', 'owner_setup_email', jsonb_build_object('application_id', (test.ot_napp()).id)) ->> 'sent'), '1/true/false');
-- an Admin adds another car for an owner they sourced: approved at once, terms from the owner's other car
insert into test.ot select 'a_add', test.ot_do('ot_admin', 'staff_add_owner_car', jsonb_build_object('owner_id', (test.ot_napp()).owner_id, 'sourced', true,
  'vehicle', jsonb_build_object('vin', upper(substr(md5('ot-vin-3'), 1, 17)), 'plate', 'OTCC303', 'year', 2020, 'make', 'Mazda', 'model', 'CX-5', 'colour', 'Red',
    'odometer_km', 60000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact'),
  'plan', jsonb_build_object('invoices', '[{"type": "registration", "amount_cents": 9999, "action": "draft"}]'::jsonb)));
select test.eq('staff add: "Add another car": approved at once with the terms of the owner''s other car; sourced: recorded as recruited',
  (test.otv('a_add') ->> 'approved') || '/'
  || (select s.insurance_fee_cents from vehicle_schedules s where s.vehicle_id = (test.otv('a_add') ->> 'vehicle_id')::uuid and s.superseded_by is null) || '/'
  || (test.otv('a_add') #>> '{approve,invoices,0,status}') || '/' || ((select recruited_by from owners where id = (test.ot_napp()).owner_id) = test.id('ot_admin')), 'true/41000/draft/true');
-- the owner reviews and corrects before signing
insert into users (id, email, full_name) values (test.id('ot_nadia'), 'nadia.ot@example.test', 'Nadia New');
update owners set user_id = test.id('ot_nadia') where id = (test.ot_napp()).owner_id;
insert into user_roles (user_id, role) values (test.id('ot_nadia'), 'owner') on conflict do nothing;
select test.eq('review: the owner sees what staff entered, with the agreed terms, editable before signing',
  (select jsonb_array_length(r -> 'cars') || '/' || (r ->> 'editable') || '/' || (r #>> '{cars,0,terms,first_last_cents}') || '/' || (r #>> '{cars,0,entered_by_staff}')
     from (select public.server_owner_review(test.id('ot_nadia')) r) x), '2/true/82000/true');
select public.server_owner_review_correct(test.id('ot_nadia'), jsonb_build_object('owner', jsonb_build_object('phone', '+16475550199'),
  'cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.otv('cs_add') ->> 'vehicle_id', 'odometer_km', '41500', 'colour', 'Pearl White'))));
select test.eq('review: a correction is saved (car, schedule and owner) and staff get a task',
  (select v.odometer_km || '/' || v.colour from vehicles v where v.id = (test.otv('cs_add') ->> 'vehicle_id')::uuid) || '/'
  || (select s.odometer_km from vehicle_schedules s where s.vehicle_id = (test.otv('cs_add') ->> 'vehicle_id')::uuid and s.superseded_by is null) || '/'
  || (select phone from owners where id = (test.ot_napp()).owner_id) || '/' || (select count(*) from tasks where task_type = 'owner_corrected_details' and owner_id = (test.ot_napp()).owner_id),
  '41500/Pearl White/41500/+16475550199/1');
update vehicle_schedules set signed_at = now() where vehicle_id = (test.otv('cs_add') ->> 'vehicle_id')::uuid and superseded_by is null;
select test.throws('review: a signed schedule is not corrected by the owner',
  format($$select public.server_owner_review_correct(%L, %L)$$, test.id('ot_nadia'), jsonb_build_object('cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.otv('cs_add') ->> 'vehicle_id', 'colour', 'Black')))), 'is signed');
select test.eq('staff add: owner search for customer service and fleet', jsonb_array_length(public.door(test.id('ot_cs'), null, 'va_read', 'owner_pick', '{"q": "nadia"}')), 1);

-- ================================================================ 6. privileges and records
select test.eq('privileges: owner_terms has row-level security and an audit trigger',
  (select relrowsecurity from pg_class where relname = 'owner_terms') || '/' || (select count(*) from pg_trigger where tgname = 'audit_owner_terms'), 'true/1');
select test.throws('privileges: a browser session cannot sign for an owner', $$set local role authenticated; select public.server_schedule_change_sign(gen_random_uuid(), '{}')$$, 'permission denied');
select test.throws('privileges: nor read the terms', $$set local role authenticated; select app.owner_terms_resolve(gen_random_uuid())$$, 'permission denied');
