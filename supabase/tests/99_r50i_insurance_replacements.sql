-- 99: Insurance replacements (migration 5120): the short entry (a fleet car or one typed in, a renter with a name only), off
-- the calendar and owner notices, invoice versions (estimate and invoice, edited and sent again, frozen once sent), no more
-- "Nothing is left to invoice", payments (part, cheque, direct deposit), approved, write-off of the rest, the extension,
-- the PDF of a version, the connector's preview and confirm, who may do what, and drafts that never vanish.
-- Fixtures start with "r50i".
select test.suite('99 r50i insurance replacements');
select set_config('app.paper_fixture', 'on', false);
create temp table r50i_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;

select test.mk_user('r50i_admin', 'admin');
select test.mk_user('r50i_fin', 'va', 'finance');
select test.mk_user('r50i_cs', 'va', 'cs');
select test.mk_user('r50i_fleet', 'va', 'fleet');
create table test.r50i (k text primary key, v jsonb);
grant select on test.r50i to authenticated, service_role;
create function test.r50iv(p text) returns jsonb language sql stable as $$ select v from test.r50i where k = p $$;
create function test.r50ib(p text) returns bookings language sql stable security definer as $$ select * from bookings where booking_number = test.r50iv(p) ->> 'booking_number' $$;
create function test.r50ii(p text) returns insurer_invoices language sql stable security definer as $$ select * from insurer_invoices where booking_id = (test.r50ib(p)).id order by created_at desc limit 1 $$;
insert into insurers (name, billing_email) values ('R50i Example Mutual', 'claims.r50i@example.test');
insert into test.r50i select 'ins', to_jsonb((select id from insurers where name = 'R50i Example Mutual'));
insert into test.r50i select 'car', app.vehicle_add(test.id('r50i_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM005120',
  'plate', 'RFI512', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.r50inew(p jsonb) returns jsonb language sql as $$
  select jsonb_build_object('renter_name', 'Rae Example', 'insurer_id', test.r50iv('ins') #>> '{}', 'claim_number', 'R50I-1',
    'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '12 days') || p $$;

-- ================================================================ 1. entry
select test.throws('the renter''s name is needed', $$select app.insurer_rental_create(test.id('r50i_cs'), test.r50inew('{"renter_name": ""}'))$$, '%renter''s name%');
select test.throws('the claim number is needed', $$select app.insurer_rental_create(test.id('r50i_cs'), test.r50inew('{"claim_number": " "}'))$$, '%claim number%');
select test.throws('the return comes after the pickup', $$select app.insurer_rental_create(test.id('r50i_cs'), test.r50inew(jsonb_build_object('return_at', now() + interval '1 day', 'car', '{"year": 2023, "make": "Kia", "model": "Soul"}')))$$, '%return after the pickup%');
select test.throws('a typed-in car needs its plate', $$select app.insurer_rental_create(test.id('r50i_cs'), test.r50inew('{"car": {"year": 2023, "make": "Kia", "model": "Soul"}}'))$$, '%year, make, model and plate%');
select test.throws('the car is needed', $$select app.insurer_rental_create(test.id('r50i_cs'), test.r50inew('{}'))$$, '%Choose the car%');
select test.throws('Fleet staff do not work insurance replacements', $$select app.insurer_rental_create(test.id('r50i_fleet'), test.r50inew('{"car": {"year": 2023, "make": "Kia", "model": "Soul", "plate": "X1"}}'))$$, '%Admins, Finance and customer service%');

-- a car not in the fleet, a renter with a name only (CC-10067's case): off the calendar and owner notices by default
insert into test.r50i select 'out', app.door(test.id('r50i_cs'), 'aal2', 'ops_do', 'insurer_rental_create', test.r50inew(jsonb_build_object(
  'renter_name', 'Sib Example', 'claim_number', 'R50I-OUT', 'adjuster_name', 'Pat Adjuster', 'adjuster_email', 'pat.adjuster@example.test',
  'car', jsonb_build_object('year', 2026, 'make', 'Hyundai', 'model', 'Palisade', 'plate', 'rfi 999'), 'daily_rate_cents', 6500)));
select test.eq('typed-in car: added, billed to the insurer, off the calendar, not the owner''s',
  (select (b.bill_to, b.blocks_calendar, app.booking_owner_view(b), app.booking_counts_for_owner(b), b.insurer_claim_number, b.insurer_adjuster_email)::text from bookings b where b.id = (test.r50ib('out')).id),
  '(insurer,f,unavailable,f,R50I-OUT,pat.adjuster@example.test)');
select test.eq('typed-in car: outside the fleet, retired at once (not listed, not bookable, off the calendars), plate kept',
  (select (v.outside_fleet, v.retired_at is not null, v.plate, v.supply_type, app.vehicle_bookable(v.id))::text from vehicles v where v.id = (test.r50ib('out')).vehicle_id), '(t,t,RFI999,company,f)');
select test.eq('the renter has a name only: no account, email or phone', (select (r.user_id is null, r.email is null, r.mobile is null)::text from renters r where r.id = (test.r50ib('out')).renter_id), '(t,t,t)');
select test.eq('the rental charge is the insurer''s rate a day', ((test.r50ib('out')).rental_charge_cents), 65000::bigint);
select test.eq('Finance and the Admins are told', (select count(*) from notification_outbox o where o.code = 'staff_insurer_rental_added' and o.entity_id = (test.r50ib('out')).id) > 0
  or exists (select 1 from app_events e where e.code = 'staff_insurer_rental_added' and e.entity_id = (test.r50ib('out')).id), true);
select test.throws('a typed-in car never goes on the calendar', $$select app.insurer_rental_update(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'bypass', false))$$, '%always off the calendar%');

-- a fleet car: on the calendar unless switched off; the switch takes it off and hides it from the owner
insert into test.r50i select 'fleet', app.insurer_rental_create(test.id('r50i_admin'), test.r50inew(jsonb_build_object('vehicle_id', test.r50iv('car') ->> 'vehicle_id', 'renter_name', 'Flo Example', 'claim_number', 'R50I-FL',
  'pickup_at', date_trunc('hour', now()) + interval '40 days', 'return_at', date_trunc('hour', now()) + interval '45 days')));
select test.eq('fleet car: on the calendar by default', (test.r50ib('fleet')).blocks_calendar, true);
select app.insurer_rental_update(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('fleet') ->> 'booking_number', 'bypass', true));
select test.eq('the switch: off the calendar, not the owner''s (no owner email, not on statements)', ((test.r50ib('fleet')).blocks_calendar, app.booking_owner_view(test.r50ib('fleet')), app.booking_counts_for_owner(test.r50ib('fleet')))::text, '(f,unavailable,f)');
select app.insurer_rental_update(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('fleet') ->> 'booking_number', 'bypass', false));
select test.eq('and back on, the owner''s again', ((test.r50ib('fleet')).blocks_calendar, app.booking_counts_for_owner(test.r50ib('fleet')))::text, '(t,t)');

-- ================================================================ 2. the list and the page
select test.eq('the list has both, with their stage', (select string_agg(e ->> 'stage', ',' order by e ->> 'booking_number')
  from jsonb_array_elements(app.insurer_rentals_json(test.id('r50i_fin'), '{"q": "r50i-"}') -> 'rows') e), 'upcoming,upcoming');
select test.eq('search by plate', jsonb_array_length(app.insurer_rentals_json(test.id('r50i_cs'), '{"q": "rfi999"}') -> 'rows'), 1);
select test.throws('Fleet staff do not read it', $$select app.door(test.id('r50i_fleet'), 'aal2', 'ops_read', 'insurer_rentals', '{}')$$, '%Admins, Finance and customer service%');

-- ================================================================ 3. invoicing back and forth
select app.insurer_invoice_save(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number',
  'lines', jsonb_build_array(jsonb_build_object('description', 'Replacement rental', 'quantity', 10, 'rate_cents', 6500), jsonb_build_object('description', 'Winter tire fee', 'amount_cents', 5000),
                             jsonb_build_object('description', 'Admin fee (no HST)', 'amount_cents', 1000, 'taxable', false)),
  'notes', 'Thank you', 'bill_to', jsonb_build_object('name', 'R50i Example Mutual', 'attention', 'Pat Adjuster', 'email', 'billing.r50i@example.test')));
select test.eq('the draft: every line as typed, the amount from days times rate, HST on the taxable lines only',
  (select (ii.status, ii.amount_cents, ii.hst_cents, jsonb_array_length(ii.lines), ii.notes, ii.bill_to ->> 'email')::text from insurer_invoices ii where ii.id = (test.r50ii('out')).id),
  '(draft,71000,9100,3,"Thank you",billing.r50i@example.test)');
select test.throws('customer service does not send it', $$select app.insurer_invoice_send(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number'))$$, '%Finance or an Admin%');
insert into test.r50i select 'v1', app.door(test.id('r50i_fin'), 'aal2', 'ops_do', 'insurer_invoice_send', jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'kind', 'estimate'));
select test.eq('an estimate is version 1, emailed to the bill-to address, and bills nothing',
  (test.r50iv('v1') ->> 'version') || '/' || (test.r50iv('v1') ->> 'to') || '/' || (test.r50ii('out')).status || '/' || (select count(*) from insurer_invoice_versions where invoice_id = (test.r50ii('out')).id),
  '1/billing.r50i@example.test/draft/1');
select test.eq('the estimate email names its version', (select (e.code, e.payload ->> 'version')::text from app_events e where e.entity_id = (test.r50ii('out')).id and e.code like 'insurer_%' order by e.id desc limit 1), '(insurer_estimate,1)');
insert into test.r50i select 'v2', app.insurer_invoice_send(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'kind', 'invoice', 'email', false));
select test.eq('the invoice is version 2, sent, owing $801.00', ((test.r50ii('out')).version, (test.r50ii('out')).status, (test.r50ii('out')).total_cents)::text, '(2,sent,80100)');
select test.throws('a version sent is never changed', format($$update insurer_invoice_versions set kind = 'estimate' where invoice_id = %L and version = 2$$, (test.r50ii('out')).id), '%never changed%');

-- re-invoicing: the next version is edited aside, the insurer owes the last one sent until it is sent
select app.insurer_invoice_save(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number',
  'lines', jsonb_build_array(jsonb_build_object('description', 'Replacement rental', 'quantity', 12, 'rate_cents', 6500), jsonb_build_object('description', 'Winter tire fee', 'amount_cents', 5000))));
select test.eq('edited after sending: the invoice still says $801.00, the changes wait', ((test.r50ii('out')).total_cents, (test.r50ii('out')).pending is not null)::text, '(80100,t)');
select app.insurer_invoice_send(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'email', false));
select test.eq('sent again: version 3 owes $937.90, and three versions are kept', ((test.r50ii('out')).version, (test.r50ii('out')).total_cents, (test.r50ii('out')).pending is null,
  (select count(*) from insurer_invoice_versions where invoice_id = (test.r50ii('out')).id))::text, '(3,93790,t,3)');
select test.eq('each version keeps what it said', (select string_agg(v.kind || ':' || (v.snapshot ->> 'total_cents'), ',' order by v.version) from insurer_invoice_versions v where v.invoice_id = (test.r50ii('out')).id),
  'estimate:80100,invoice:80100,invoice:93790');
select test.eq('drafting again never says nothing is left to invoice: it is the same invoice', app.draft_insurer_invoice((test.r50ib('out')).id, test.id('r50i_fin')), (test.r50ii('out')).id);

-- ================================================================ 4. getting paid
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'payment', 'amount_cents', 50000, 'method', 'cheque', 'reference', 'CHQ 1', 'received_on', current_date));
select test.eq('a part payment by cheque', ((test.r50ii('out')).status, (test.r50ii('out')).paid_cents, (test.r50ii('out')).balance_cents)::text, '(part_paid,50000,43790)');
select test.eq('it is a payment on the booking', (select string_agg(p.method || ':' || p.amount_cents, ',') from payments p where p.booking_id = (test.r50ib('out')).id and p.purpose = 'other'), 'cheque:50000');
select test.throws('a later version cannot owe less than was paid', $$select app.insurer_invoice_save(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number',
  'lines', '[{"description": "Rental", "amount_cents": 1000}]'::jsonb))$$, '%less than the%already paid%');
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'negotiating', 'note', 'Adjuster disputes 2 days'));
select test.eq('negotiating', app.insurer_stage(test.r50ib('out'), test.r50ii('out')), 'negotiating');
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'approved', 'amount_cents', 80100));
select test.eq('approved: the amount, the negotiation over', ((test.r50ii('out')).approved_cents, (test.r50ii('out')).negotiating_at is null, app.insurer_stage(test.r50ib('out'), test.r50ii('out')))::text, '(80100,t,approved)');
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'payment', 'amount_cents', 30100, 'method', 'direct_deposit'));
select test.throws('a write-off needs its reason', $$select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'write_off'))$$, '%reason%');
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('out') ->> 'booking_number', 'action', 'write_off', 'reason', 'Approved less than billed'));
select test.eq('the rest is written off and kept: $136.90', ((test.r50ii('out')).status, (test.r50ii('out')).paid_cents, (test.r50ii('out')).written_off_cents, app.insurer_stage(test.r50ib('out'), test.r50ii('out')))::text,
  '(written_off,80100,13690,written_off)');
select test.eq('direct deposit is recorded as a bank transfer', (select count(*) from payments p where p.booking_id = (test.r50ib('out')).id and p.method = 'bank_transfer' and p.amount_cents = 30100), 1::bigint);

-- ================================================================ 5. extension, the PDF of a version
select app.insurer_invoice_send(test.id('r50i_admin'), jsonb_build_object('booking', test.r50iv('fleet') ->> 'booking_number', 'email', false));
select app.insurer_rental_extend(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('fleet') ->> 'booking_number', 'return_at', (test.r50ib('fleet')).return_at + interval '3 days', 'reason', 'Insurer approved 3 more days'));
select test.eq('extended by 3 days', ((test.r50ib('fleet')).return_at - (test.r50ib('fleet')).pickup_at)::text, '8 days');
select test.eq('the invoice''s next version has the new figures, the version sent is unchanged',
  ((test.r50ii('fleet')).pending is not null, app.insurer_lines_sum((test.r50ii('fleet')).pending -> 'lines') > (test.r50ii('fleet')).amount_cents)::text, '(t,t)');
select test.eq('a version''s PDF: an estimate, its own figures, stored once',
  (select (f ->> 'title', f ->> 'doc_kind', f ->> 'total_cents', f ->> 'store') from app.pdf_facts('insurer_invoice', ((test.r50ii('out')).id)::text || ':v1', test.id('r50i_fin')) f)::text,
  '("Estimate ' || (test.r50ii('out')).invoice_number || '",estimate,80100,true)');
select test.eq('the invoice as it stands is drawn each time', (app.pdf_facts('insurer_invoice', ((test.r50ii('out')).id)::text, test.id('r50i_fin')) ->> 'store'), 'false');
select test.eq('a version that does not exist has no PDF', app.pdf_facts('insurer_invoice', ((test.r50ii('out')).id)::text || ':v9', test.id('r50i_fin')) is null, true);

-- ================================================================ 6. the connector: preview changes nothing, confirm does
create function test.r50ih(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('r50i_admin'), test.id('r50i_admin'), 'Laptop', array['admin:read', 'admin:write'], test.r50ih('cc_live_r50i_full'), 'cc_live_r50i');
insert into test.r50i select 'pv', app.api_call(test.r50ih('cc_live_r50i_full'), 'insurer_rental_create', test.r50inew(jsonb_build_object('renter_name', 'Con Example', 'claim_number', 'R50I-API',
  'car', jsonb_build_object('year', 2022, 'make', 'Kia', 'model', 'Carnival', 'plate', 'RFI777'))), 'test');
select test.eq('preview: ok, nothing added, the outcome shown', ((test.r50iv('pv') ->> 'ok'), (select count(*) from bookings where insurer_claim_number = 'R50I-API'),
  test.r50iv('pv') #>> '{result,after,outside_fleet}')::text, '(true,0,true)');
select test.throws('a confirm with other arguments is refused', format($$select app.api_call(%L, 'insurer_rental_create', %L::jsonb, 'test') ->> 'error'$$, test.r50ih('cc_live_r50i_full'),
  (test.r50inew(jsonb_build_object('renter_name', 'Other Example', 'claim_number', 'R50I-API', 'car', jsonb_build_object('year', 2022, 'make', 'Kia', 'model', 'Carnival', 'plate', 'RFI777'))) || jsonb_build_object('confirm', true, 'preview_id', test.r50iv('pv') #>> '{result,preview_id}'))::text)
  || ' is null or 1/0 = 1', null);
insert into test.r50i select 'cf', app.api_call(test.r50ih('cc_live_r50i_full'), 'insurer_rental_create', test.r50inew(jsonb_build_object('renter_name', 'Con Example', 'claim_number', 'R50I-API',
  'car', jsonb_build_object('year', 2022, 'make', 'Kia', 'model', 'Carnival', 'plate', 'RFI777'))) || jsonb_build_object('confirm', true, 'preview_id', test.r50iv('pv') #>> '{result,preview_id}'), 'test');
select test.eq('confirm: added once, logged', ((select count(*) from bookings where insurer_claim_number = 'R50I-API'),
  (select string_agg(tool, ',' order by created_at) from api_calls where target = 'R50I-API' and ok))::text, '(1,"insurer_rental_create:preview,insurer_rental_create")');
select test.eq('get_insurer_rental reads it', app.api_call(test.r50ih('cc_live_r50i_full'), 'get_insurer_rental', jsonb_build_object('booking', test.r50iv('cf') #>> '{result,result,booking_number}'), 'test') #>> '{result,claim,claim_number}', 'R50I-API');

-- the two new emails are built (07_notifications leaves them to this file), with every variable, and the estimate to the
-- insurer names no CarmaCars in what it prints (it goes as Blind Spot Car Rental)
select app.process_events(100000);
select test.eq('the new emails are built with every variable',
  (select string_agg(distinct o.code || ':' || cardinality(o.missing_variables), ',' order by o.code || ':' || cardinality(o.missing_variables)) from notification_outbox o
    where o.code in ('insurer_estimate', 'staff_insurer_rental_added')), 'insurer_estimate:0,staff_insurer_rental_added:0');
select test.eq('the estimate to the insurer names no CarmaCars in any value its template prints (emails/templates/insurer_estimate.html)',
  (select count(*) from notification_outbox o, unnest(array['amount', 'claim_number', 'company_address', 'first_name', 'insurer_name', 'invoice_amount', 'invoice_hst', 'invoice_number',
      'invoice_total', 'label', 'period', 'renter_name', 'reply_time', 'support_phone', 'vehicle_name', 'version']) k
    where o.code = 'insurer_estimate' and coalesce(o.payload ->> k, '') || coalesce(o.to_name, '') ~* 'carma ?cars'), 0::bigint);

-- ================================================================ 7. drafts never vanish
insert into rental_drafts (id, kind, created_by, data, title, updated_at) values (test.id('draft:r50i'), 'rental', test.id('r50i_cs'), '{"form": "insurer", "f": {"renter_name": "Old Example"}}', 'Old Example', now() - interval '60 days');
select test.ok('a draft untouched for 60 days is still listed, with its form', exists (select 1 from jsonb_array_elements(app.drafts_list(test.id('r50i_cs'), '{"kind": "rental"}')) e
  where e ->> 'id' = test.id('draft:r50i')::text and e ->> 'form' = 'insurer'));
select app.draft_close(test.id('r50i_cs'), jsonb_build_object('id', test.id('draft:r50i'), 'status', 'discarded'));
select test.eq('a discarded draft says who discarded it', (app.draft_get(test.id('r50i_admin'), jsonb_build_object('id', test.id('draft:r50i'))) ->> 'closed_by'), 'R50i Cs');
select app.door(test.id('r50i_admin'), 'aal2', 'ops_do', 'draft_restore', jsonb_build_object('id', test.id('draft:r50i')));
select test.eq('and is restored, as it was', (select (status, data #>> '{f,renter_name}')::text from rental_drafts where id = test.id('draft:r50i')), '(open,"Old Example")');

-- ================================================================ 8. review fixes (Nov 27)
select test.mk_user('r50i_sales', 'va', 'sales');
select test.mk_user('r50i_field', 'field', null, 'driver');
-- 1. an insurance replacement draft (the renter's phone and email) is not shown to Field or Sales
insert into rental_drafts (id, kind, created_by, data, title) values (test.id('draft:r50i2'), 'rental', test.id('r50i_cs'),
  '{"form": "insurer", "f": {"renter_name": "Dee Example", "renter_phone": "4165550100", "renter_email": "dee@example.test"}}', 'Dee Example');
select test.eq('an insurer draft: customer service sees it, Sales and Field do not',
  (select string_agg(u || ':' || exists (select 1 from jsonb_array_elements(app.drafts_list(test.id(u), '{"kind": "rental"}')) e where e ->> 'id' = test.id('draft:r50i2')::text), ',' order by u)
     from unnest(array['r50i_cs', 'r50i_field', 'r50i_sales']) u), 'r50i_cs:true,r50i_field:false,r50i_sales:false');
select test.throws('Sales cannot open it by its link', $$select app.draft_get(test.id('r50i_sales'), jsonb_build_object('id', test.id('draft:r50i2')))$$, '%insurance replacement%');
select test.throws('Field cannot restore it', $$select app.draft_restore(test.id('r50i_field'), jsonb_build_object('id', test.id('draft:r50i2')))$$, '%Not permitted%');
-- 2. Paste text (the AI read) asks the database first
select test.eq('Paste text: customer service may', app.door(test.id('r50i_cs'), 'aal2', 'ops_read', 'insurer_may', '{}') ->> 'ok', 'true');
select test.throws('Paste text: Sales may not', $$select app.door(test.id('r50i_sales'), 'aal2', 'ops_read', 'insurer_may', '{}')$$, '%Admins, Finance and customer service%');

-- 3. an extension keeps the lines typed by hand and bills the new days: a typed-in car with no rate card, at the rate agreed
insert into test.r50i select 'ext', app.insurer_rental_create(test.id('r50i_cs'), test.r50inew(jsonb_build_object('renter_name', 'Ext Example', 'claim_number', 'R50I-EXT',
  'car', jsonb_build_object('year', 2025, 'make', 'Toyota', 'model', 'RAV4', 'plate', 'RFI555'), 'daily_rate_cents', 7000,
  'pickup_at', date_trunc('hour', now()) + interval '60 days', 'return_at', date_trunc('hour', now()) + interval '65 days')));
select app.insurer_invoice_save(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number',
  'lines', jsonb_build_array(jsonb_build_object('description', 'Replacement rental, 5 day(s)', 'quantity', 5, 'rate_cents', 7000), jsonb_build_object('description', 'Winter tire fee', 'amount_cents', 5000))));
select app.insurer_rental_extend(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'return_at', (test.r50ib('ext')).return_at + interval '3 days'));
select test.eq('a draft edited by hand, extended 3 days: 8 days at $70 and the winter tire fee kept',
  (select string_agg((e ->> 'description') || '=' || (e ->> 'amount_cents'), ',') from jsonb_array_elements((test.r50ii('ext')).lines) e) || '/' || (test.r50ii('ext')).hst_cents,
  'Replacement rental, 8 day(s)=56000,Winter tire fee=5000/7930');
select app.insurer_invoice_send(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'email', false));
-- 6. the adjuster approves, the rental is extended, the next invoice asks again
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'action', 'approved', 'amount_cents', 61000));
select app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'action', 'negotiating', 'note', 'One day in question'));
select app.insurer_rental_extend(test.id('r50i_cs'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'return_at', (test.r50ib('ext')).return_at + interval '2 days'));
select test.eq('a sent invoice, extended 2 days: the next version has 10 days at $70 and still the winter tire fee',
  (select string_agg((e ->> 'description') || '=' || (e ->> 'amount_cents'), ',') from jsonb_array_elements((test.r50ii('ext')).pending -> 'lines') e),
  'Replacement rental, 10 day(s)=70000,Winter tire fee=5000');
-- 5. a send repeated with nothing changed is not a new version
insert into test.r50i select 'ext_s1', app.insurer_invoice_send(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'email', false));
insert into test.r50i select 'ext_s2', app.insurer_invoice_send(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'email', false));
select test.eq('sent twice in a row: one new version, the second says it is a repeat',
  ((test.r50iv('ext_s1') ->> 'version'), (test.r50iv('ext_s2') ->> 'version'), (test.r50iv('ext_s2') ->> 'repeat'), (select count(*) from insurer_invoice_versions where invoice_id = (test.r50ii('ext')).id))::text,
  '(2,2,true,2)');
select test.eq('the new invoice clears the approval and the negotiation; aging counts from it',
  ((test.r50ii('ext')).approved_cents is null, (test.r50ii('ext')).negotiating_at is null, (test.r50ii('ext')).total_cents,
   (test.r50ii('ext')).sent_at = (select max(v.sent_at) from insurer_invoice_versions v where v.invoice_id = (test.r50ii('ext')).id))::text, '(t,t,84750,t)');
select test.eq('the stage is invoiced again', app.insurer_stage(test.r50ib('ext'), test.r50ii('ext')), 'invoiced');
-- 5. a payment sent twice with the same client id is recorded once
insert into test.r50i select 'pay1', app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'action', 'payment', 'amount_cents', 20000, 'method', 'e_transfer', 'client_id', 'pay:r50i:ext:1'));
insert into test.r50i select 'pay2', app.insurer_money(test.id('r50i_fin'), jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'action', 'payment', 'amount_cents', 20000, 'method', 'e_transfer', 'client_id', 'pay:r50i:ext:1'));
select test.eq('a double click records the payment once', ((test.r50ii('ext')).paid_cents, test.r50iv('pay2') ->> 'repeat',
  (select count(*) from payments p where p.booking_id = (test.r50ib('ext')).id and p.purpose = 'other'))::text, '(20000,true,1)');

-- 4. back on the calendar: refused while another booking holds the car
insert into test.r50i select 'ova', app.insurer_rental_create(test.id('r50i_admin'), test.r50inew(jsonb_build_object('vehicle_id', test.r50iv('car') ->> 'vehicle_id', 'renter_name', 'Ova Example', 'claim_number', 'R50I-OVA',
  'pickup_at', date_trunc('hour', now()) + interval '100 days', 'return_at', date_trunc('hour', now()) + interval '105 days', 'bypass', true)));
insert into test.r50i select 'ovb', app.insurer_rental_create(test.id('r50i_admin'), test.r50inew(jsonb_build_object('vehicle_id', test.r50iv('car') ->> 'vehicle_id', 'renter_name', 'Ovb Example', 'claim_number', 'R50I-OVB',
  'pickup_at', date_trunc('hour', now()) + interval '101 days', 'return_at', date_trunc('hour', now()) + interval '103 days')));
select test.throws('back on the calendar over another booking: refused, naming it',
  format($$select app.insurer_rental_update(test.id('r50i_cs'), jsonb_build_object('booking', %L, 'bypass', false))$$, test.r50iv('ova') ->> 'booking_number'),
  '%taken on these dates (' || (test.r50iv('ovb') ->> 'booking_number') || '%');
select test.eq('and it stays off', (test.r50ib('ova')).blocks_calendar, false);

-- 9. the connector's logs and previews keep the renter's email and phone masked
insert into test.r50i select 'mpv', app.api_call(test.r50ih('cc_live_r50i_full'), 'insurer_rental_update',
  jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'renter_email', 'mask.me@example.test', 'renter_phone', '4165550123'), 'test');
select app.api_call(test.r50ih('cc_live_r50i_full'), 'insurer_rental_update', jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'renter_email', 'mask.me@example.test',
  'renter_phone', '4165550123', 'confirm', true, 'preview_id', test.r50iv('mpv') #>> '{result,preview_id}'), 'test');
select app.api_call(test.r50ih('cc_live_r50i_full'), 'insurer_rental_update', jsonb_build_object('booking', test.r50iv('ext') ->> 'booking_number', 'notes', 'R50i masked'), 'test');
select test.eq('the renter''s email and phone are not in the logs or the previews'' before and after',
  (select count(*) from api_calls c where c.target = test.r50iv('ext') ->> 'booking_number' and (c.args::text || coalesce(c.before::text, '') || coalesce(c.after::text, '')) ~ 'mask\.me@|4165550123')
  + (select count(*) from api_previews v where v.tool = 'insurer_rental_update' and (coalesce(v.before::text, '') || coalesce(v.after::text, '')) ~ 'mask\.me@|4165550123'), 0::bigint);
select test.eq('masked as the e-sign pages mask them', (select c.args ->> 'renter_email' from api_calls c where c.target = test.r50iv('ext') ->> 'booking_number' and c.tool = 'insurer_rental_update'), 'm******@example.test');

-- 7. 5123 (CC-10067): changes nothing, with a notice, when the Admin account is missing
update bookings set booking_number = booking_number || '-R50IHOLD' where booking_number = 'CC-10067';
update bookings set booking_number = 'CC-10067' where id = (test.r50ib('ovb')).id;
\ir ../migrations/5123_r50i_cc10067_off_calendar.sql
select test.eq('5123 without rent@carmacars.ca: CC-10067 stays on the calendar', (select blocks_calendar from bookings where booking_number = 'CC-10067'),
  not exists (select 1 from users where lower(email) = 'rent@carmacars.ca'));
update bookings set booking_number = (test.r50iv('ovb') ->> 'booking_number') where booking_number = 'CC-10067';
update bookings set booking_number = 'CC-10067' where booking_number = 'CC-10067-R50IHOLD';

select test.ok('the functions are for the server only', not has_function_privilege('authenticated', 'app.insurer_rental_create(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.insurer_money(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.draft_restore(uuid, jsonb)', 'execute'));
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from r50i_ps s where p.id = s.id;
