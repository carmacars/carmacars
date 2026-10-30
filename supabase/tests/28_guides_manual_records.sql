-- 28: guides in every portal, payments recorded by hand, signatures on paper, and signing in the portals (migration 0044).
-- Every fixture label starts with "gm".
select test.suite('28 guides manual records');
grant usage on schema test to service_role;

select test.mk_user('gm_admin', 'admin');
select test.mk_user('gm_fin', 'va', 'finance');
select test.mk_user('gm_cs', 'va', 'cs');
select test.mk_user('gm_field', 'field');
select test.mk_user('gm_renter_user', 'renter');
insert into users (id, email, full_name) values (test.id('gm_olivia'), 'olivia.gm@example.test', 'Olivia Paper'),
  (test.id('gm_ivan'), 'ivan.gm@example.test', 'Ivan Investor'), (test.id('gm_nobody'), 'nobody.gm@example.test', 'No Body');
update staff_profiles set single_limit_cents = 20000 where user_id = test.id('gm_fin');

create table test.gm (k text primary key, v uuid);
grant select on test.gm to authenticated, service_role;
create function test.gmv(p text) returns uuid language sql stable as $$ select v from test.gm where k = p $$;
create function test.gm_vin(p text) returns text language sql immutable as $$ select upper(substr(md5('gm-vin-' || p), 1, 17)) $$;
create function test.gm_sha(p text) returns text language sql immutable as $$ select md5(p) || md5(p || 'x') $$;
create function test.gm_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.gm_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;

-- ================================================================ 1. guides
select test.eq('guides: one per portal, unpublished at first',
  (select string_agg(portal || ':' || version, ',' order by sort_order) from guides), 'renter:0,owner:0,admin:0,va:0,field:0,investor:0');

-- an owner on file, for access
insert into test.gm select 'app', (public.server_submit_owner_application(jsonb_build_object(
  'source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Olivia Paper', 'first_name', 'Olivia', 'last_name', 'Paper',
                              'email', 'olivia.gm@example.test', 'phone', '+16475550177', 'address_line1', '20 Bay Street',
                              'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5J 2N8', 'licence_number', 'P1234-56789-01234',
                              'date_of_birth', '1984-04-04'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', test.gm_vin('1'), 'plate', 'GMAA101', 'year', 2022, 'make', 'Toyota', 'model', 'Camry', 'colour', 'White', 'odometer_km', 20000,
                       'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact', 'title_brand_clear', true),
    jsonb_build_object('vin', test.gm_vin('2'), 'plate', 'GMAA102', 'year', 2023, 'make', 'Honda', 'model', 'Accord', 'colour', 'Black', 'odometer_km', 15000,
                       'title_status', 'financed', 'finance_party_name', 'RBC Auto', 'management_mode', 'managed', 'onboarding_method', 'transfer',
                       'current_insurer', 'Aviva'))), test.id('gm_olivia')) ->> 'owner_id')::uuid;
insert into test.gm select 'v' || row_number() over (order by v.created_at, v.plate), v.id from vehicles v where v.owner_id = test.gmv('app');
insert into investors (id, user_id, legal_name, investor_type, email, status) values (test.id('inv:gm_ivan'), test.id('gm_ivan'), 'Ivan Investor', 'individual', 'ivan.gm@example.test', 'prospect');

select test.eq('access: a renter reads the renter guide only; an owner the owner guide; staff their own; an Admin every guide',
  app.guide_access(test.id('gm_renter_user'), 'renter') || '/' || app.guide_access(test.id('gm_renter_user'), 'owner') || '/' ||
  app.guide_access(test.id('gm_olivia'), 'owner') || '/' || app.guide_access(test.id('gm_fin'), 'va') || '/' || app.guide_access(test.id('gm_fin'), 'field') || '/' ||
  app.guide_access(test.id('gm_field'), 'field') || '/' || app.guide_access(test.id('gm_ivan'), 'investor') || '/' ||
  (select bool_and(app.guide_access(test.id('gm_admin'), portal)) from guides), 'true/false/true/true/false/true/true/true');
select test.throws('access: another portal''s guide is refused', $$select public.guide_read(test.id('gm_renter_user'), 'admin')$$, 'people of that portal');
select test.throws('editing: only an Admin edits a guide', $$select test.gm_do('gm_fin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'title', 'X'))$$, 'Admin');

insert into test.gm select 'start', (test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'kind', 'start', 'title', 'Start here',
  'body_md', 'Sign in at `carmacars.ca/sign-in`.')) ->> 'id')::uuid;
insert into test.gm select 'c1', (test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'title', 'Your cars', 'blurb', 'Each car''s page',
  'body_md', E'## A car''s page\n\n1. Open **Vehicles**.\n2. Press a car.\n\n![The car page](/guides/img/owner-03.jpg "desktop")')) ->> 'id')::uuid;
insert into test.gm select 'c2', (test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'title', 'Money', 'body_md', 'Fees are debited on the 15th.')) ->> 'id')::uuid;
insert into test.gm select 'ref', (test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'kind', 'reference', 'title', 'Quick reference', 'body_md', '### Where things are')) ->> 'id')::uuid;
select test.eq('sections: in order, each with a slug and version 1 in its history',
  (select string_agg(slug || ':' || draft_version, ',' order by sort_order) from guide_sections where portal = 'owner'), 'start-here:1,your-cars:1,money:1,quick-reference:1');
select test.eq('history: one saved draft per section', (select count(*) from guide_section_versions h join guide_sections s on s.id = h.section_id where s.portal = 'owner'), 4::bigint);
select test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('id', test.gmv('c2'), 'body_md', 'Fees are debited on the 15th, after a notice.'));
select test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('id', test.gmv('c2'), 'body_md', 'Fees are debited on the 15th, after a notice.'));
select test.eq('saving: a change makes version 2; saving the same text again makes nothing new',
  (select draft_version || '/' || (select count(*) from guide_section_versions h where h.section_id = s.id) from guide_sections s where s.id = test.gmv('c2')), '2/2');
select test.eq('reading: nothing published yet, nothing to read', jsonb_array_length(public.guide_read(test.id('gm_olivia'), 'owner') -> 'sections'), 0);
select test.eq('banner: none before the guide is published', public.guide_banner(test.id('gm_olivia'), 'owner'), false);
select test.throws('publish: every visible section needs its HTML', format($$select test.gm_do('gm_admin', 'guide_publish', jsonb_build_object('portal', 'owner', 'html', jsonb_build_object(%L, '<p>x</p>')))$$, test.gmv('c1')), 'was not rendered');
select test.gm_do('gm_admin', 'guide_publish', jsonb_build_object('portal', 'owner', 'html', jsonb_build_object(test.gmv('start'), '<p>Start</p>', test.gmv('c1'), '<h2>A car''s page</h2>',
  test.gmv('c2'), '<p>Fees</p>', test.gmv('ref'), '<h3>Where things are</h3>')));
select test.eq('publish: version 1, every section published with its HTML, in order',
  (select g.version || '/' || (select string_agg(x ->> 'slug', ',') from jsonb_array_elements(public.guide_read(test.id('gm_olivia'), 'owner') -> 'sections') x)
     from guides g where g.portal = 'owner'), '1/start-here,your-cars,money,quick-reference');
select test.eq('publish: audited', (select count(*) from audit_log where action = 'guide_publish' and entity_id = 'owner'), 1::bigint);
select test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('id', test.gmv('c2'), 'title', 'Fees and payouts', 'body_md', 'New text not published.'));
select test.eq('draft: an edit is not shown until it is published',
  (select x ->> 'title' from jsonb_array_elements(public.guide_read(test.id('gm_olivia'), 'owner') -> 'sections') x where x ->> 'slug' = 'money'), 'Money');
select test.eq('admin: the guide counts one section with unpublished changes', (select (x ->> 'unpublished')::int from jsonb_array_elements(test.gm_read('gm_admin', 'guides_admin')) x where x ->> 'portal' = 'owner'), 1);
select test.gm_do('gm_admin', 'guide_section_move', jsonb_build_object('id', test.gmv('c2'), 'dir', 'up'));
select test.eq('move: a chapter moves up, the start page stays first',
  (select string_agg(slug, ',' order by sort_order) from guide_sections where portal = 'owner'), 'start-here,money,your-cars,quick-reference');
select test.throws('move: the start page keeps its place', format($$select test.gm_do('gm_admin', 'guide_section_move', jsonb_build_object('id', %L, 'dir', 'down'))$$, test.gmv('start')), 'keep their places');
select test.throws('delete: a published section is hidden, not deleted', format($$select test.gm_do('gm_admin', 'guide_section_delete', jsonb_build_object('id', %L))$$, test.gmv('c1')), 'hide it instead');
insert into test.gm select 'c3', (test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('portal', 'owner', 'title', 'Scratch', 'body_md', 'x')) ->> 'id')::uuid;
select test.eq('delete: a section never published is deleted', test.gm_do('gm_admin', 'guide_section_delete', jsonb_build_object('id', test.gmv('c3'))) ->> 'deleted', test.gmv('c3')::text);
select test.gm_do('gm_admin', 'guide_section_save', jsonb_build_object('id', test.gmv('c1'), 'is_hidden', true));
select test.gm_do('gm_admin', 'guide_publish', jsonb_build_object('portal', 'owner', 'html', jsonb_build_object(test.gmv('start'), '<p>Start</p>', test.gmv('c2'), '<p>Fees and payouts</p>', test.gmv('ref'), '<h3>Where</h3>')));
select test.eq('hide: a hidden section leaves the published guide; version 2',
  (select (select version from guides where portal = 'owner') || '/' || string_agg(x ->> 'slug', ',') from jsonb_array_elements(public.guide_read(test.id('gm_olivia'), 'owner') -> 'sections') x),
  '2/start-here,money,quick-reference');
select test.eq('history: the published copies are kept beside the drafts',
  (select count(*) filter (where published) from guide_section_versions h join guide_sections s on s.id = h.section_id where s.portal = 'owner') >= 5, true);
select test.eq('history: an earlier version can be read back',
  test.gm_read('gm_admin', 'guide_section_version', jsonb_build_object('section', test.gmv('c2'), 'version', 1)) ->> 'body_md', 'Fees are debited on the 15th.');

-- the banner and the reader
select test.eq('banner: shown to an owner who never opened the guide', public.guide_banner(test.id('gm_olivia'), 'owner'), true);
select public.guide_opened(test.id('gm_olivia'), 'owner');
select test.eq('opened: the banner goes, the version read is recorded',
  public.guide_banner(test.id('gm_olivia'), 'owner') || '/' || (select last_version || '/' || opens from guide_reads where user_id = test.id('gm_olivia') and portal = 'owner'), 'false/2/1');
select public.guide_dismiss(test.id('gm_admin'), 'owner');
select test.eq('dismiss: the banner goes without opening the guide', public.guide_banner(test.id('gm_admin'), 'owner'), false);
select test.eq('readers: Admin sees who opened which version',
  (select (r ->> 'name') || '/' || (r ->> 'last_version') from jsonb_array_elements(test.gm_read('gm_admin', 'guide_readers', jsonb_build_object('portal', 'owner')) -> 'readers') r
    where (r ->> 'user_id')::uuid = test.id('gm_olivia')), 'Olivia Paper/2');

-- the stored PDF
select test.throws('pdf: the file must be the guide''s own', $$select public.server_guide_pdf_record(jsonb_build_object('portal', 'owner', 'path', 'other/x.pdf', 'sha256', test.gm_sha('p'), 'bytes', 10, 'source', 'committed'))$$, 'Unknown file');
select public.server_guide_pdf_record(jsonb_build_object('portal', 'owner', 'path', 'guides/owner/committed.pdf', 'sha256', test.gm_sha('p1'), 'bytes', 2278866, 'source', 'committed',
  'generated_at', '2026-10-15T04:23:00Z'));
select test.eq('pdf: a committed PDF is stored only once', public.server_guide_pdf_record(jsonb_build_object('portal', 'owner', 'path', 'guides/owner/c2.pdf', 'sha256', test.gm_sha('p2'), 'bytes', 5, 'source', 'committed')) ->> 'skipped', 'true');
select test.eq('pdf: the web guide was published after the PDF was made, so it says it has newer edits',
  (public.guide_read(test.id('gm_olivia'), 'owner') -> 'pdf' ->> 'stale') || '/' || (public.guide_pdf_file(test.id('gm_olivia'), 'owner') ->> 'path'), 'true/guides/owner/committed.pdf');
select public.server_guide_pdf_record(jsonb_build_object('portal', 'owner', 'path', 'guides/owner/v2.pdf', 'sha256', test.gm_sha('p3'), 'bytes', 2000000, 'source', 'generated', 'guide_version', 2));
select test.eq('pdf: a PDF printed from the published guide is current and not stale',
  (public.guide_read(test.id('gm_olivia'), 'owner') -> 'pdf' ->> 'stale') || '/' || (public.guide_read(test.id('gm_olivia'), 'owner') -> 'pdf' ->> 'guide_version')
  || '/' || (select count(*) from guide_pdfs where portal = 'owner' and is_current), 'false/2/1');
select test.eq('pdf: someone outside the portal gets no file', public.guide_pdf_file(test.id('gm_renter_user'), 'owner'), null::jsonb);
select test.eq('print: the published content for the printer has the visible sections',
  jsonb_array_length(public.server_guide_print_content('owner') -> 'sections'), 3);

-- images
select test.gm_do('gm_admin', 'guide_image_record', jsonb_build_object('portal', 'owner', 'url', '/media/guides/owner/new.jpg', 'replaces_url', '/guides/img/owner-03.jpg'));
select test.eq('image: replacing a screenshot changes every draft that shows it (a new draft version)',
  (select position('/media/guides/owner/new.jpg' in body_md) > 0 and draft_version > 1 from guide_sections where id = test.gmv('c1')), true);

-- ================================================================ 2. payments recorded by hand
select public.admin_set_vehicle_terms(test.gmv(k), test.id('gm_admin'), '{}') from (values ('v1'), ('v2')) x(k);
update vehicle_onboardings ob set first_last_choice = 'send', first_last_choice_cents = 2 * s.insurance_fee_cents
  from vehicle_schedules s where s.vehicle_id = ob.vehicle_id and s.superseded_by is null and ob.vehicle_id in (test.gmv('v1'), test.gmv('v2'));
select public.admin_issue_upfront_invoices(test.gmv('app'), test.id('gm_admin'));
insert into test.gm select 'inv1', id from owner_invoices where vehicle_id = test.gmv('v1') and kind = 'upfront';
insert into test.gm select 'inv2', id from owner_invoices where vehicle_id = test.gmv('v2') and kind = 'upfront';
create table test.gm_total as select id, total_cents from owner_invoices where id in (test.gmv('inv1'), test.gmv('inv2'));
grant select on test.gm_total to service_role, authenticated;
-- a scheduled debit for the first invoice, as the notice day leaves it
insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key)
select id, owner_id, 1, app.today() + 10, balance_cents, 'gm-attempt-1' from owner_invoices where id = test.gmv('inv1');
update owner_invoices set debit_on = app.today() + 10 where id = test.gmv('inv1');

select test.eq('invoices: both upfront invoices are issued', (select string_agg(status, ',') from owner_invoices where id in (test.gmv('inv1'), test.gmv('inv2'))), 'issued,issued');
select test.throws('limits: Finance above their single limit is refused', format($$select test.gm_do('gm_fin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'e_transfer', 'reference', 'REF-A1', 'amount_cents', 25000))$$, test.gmv('inv1')), 'above your single limit');
select test.throws('limits: customer service may not record a payment', format($$select test.gm_do('gm_cs', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'cash', 'amount_cents', 100))$$, test.gmv('inv1')), 'Only an Admin or Finance');
select test.throws('check: an e-Transfer needs its reference', format($$select test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'e_transfer', 'amount_cents', 100))$$, test.gmv('inv1')), 'reference');
select test.throws('check: another way needs a note saying how', format($$select test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'other', 'amount_cents', 100))$$, test.gmv('inv1')), 'note');
select test.throws('check: not in the future', format($$select test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'cash', 'amount_cents', 100, 'received_on', app.today() + 1))$$, test.gmv('inv1')), 'future');

insert into test.gm select 'mp1', (test.gm_do('gm_fin', 'manual_payment_record', jsonb_build_object('invoice', test.gmv('inv1'), 'method', 'e_transfer', 'reference', 'REF-A1',
  'amount_cents', 15000, 'received_on', app.today() - 2, 'note', 'Part of the upfront',
  'proof', jsonb_build_object('path', 'payments/gm/proof.png', 'sha256', test.gm_sha('proof'), 'mime', 'image/png'))) ->> 'id')::uuid;
select test.eq('partial: the invoice stays issued, partly paid, the balance falls by the amount',
  (select i.status || '/' || i.paid_cents || '/' || (i.balance_cents = t.total_cents - 15000) from owner_invoices i join test.gm_total t on t.id = i.id where i.id = test.gmv('inv1')),
  'issued/15000/true');
select test.eq('partial: the scheduled debit now debits only the balance',
  (select a.status || '/' || (a.amount_cents = i.balance_cents) from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id where a.idempotency_key = 'gm-attempt-1'), 'scheduled/true');
select test.eq('partial: the receipt for this payment, not "payment received"',
  (select count(*) filter (where code = 'owner_payment_recorded') || '/' || count(*) filter (where code = 'owner_payment_received')
     from app_events where entity_id in (test.gmv('mp1'), test.gmv('inv1'))), '1/0');
select test.eq('partial: the proof is stored privately (no owner on the file)',
  (select d.kind || '/' || coalesce(d.owner_id::text, 'none') from manual_payments m join documents d on d.id = m.proof_document_id where m.id = test.gmv('mp1')), 'receipt/none');
select test.eq('replay: the same reference again is the same payment',
  test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', test.gmv('inv1'), 'method', 'e_transfer', 'reference', 'ref-a1', 'amount_cents', 15000)) ->> 'repeat', 'true');
select test.eq('owner portal: the invoice lists the payment and is partly paid',
  (select (v ->> 'partly_paid') || '/' || jsonb_array_length(v -> 'manual') || '/' || (v -> 'manual' -> 0 ->> 'method_label') || '/' || coalesce(v -> 'manual' -> 0 ->> 'note', 'hidden')
     from app.owner_invoice_view(test.gmv('inv1')) v), 'true/1/e-Transfer/hidden');

insert into test.gm select 'mp2', (test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', test.gmv('inv1'), 'method', 'cheque', 'reference', '000123',
  'received_on', app.today() - 1)) ->> 'id')::uuid;
select test.eq('full: the rest by cheque marks the invoice paid, by cheque',
  (select status || '/' || payment_method || '/' || balance_cents from owner_invoices where id = test.gmv('inv1')), 'paid/cheque/0');
select test.eq('full: the scheduled debit is cancelled with the reason, and the invoice no longer has a debit day',
  (select a.status || '/' || (a.skip_reason like 'paid by cheque on %') || '/' || coalesce(i.debit_on::text, 'none')
     from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id where a.idempotency_key = 'gm-attempt-1'), 'canceled/true/none');
select test.eq('full: the owner''s invoice says how and when it was paid',
  (app.owner_invoice_view(test.gmv('inv1')) ->> 'paid_by') = 'Paid by cheque on ' || app.fmt_day(app.today() - 1), true);
select test.eq('full: the upfront payment moves the onboarding (its prepaid months are funded)',
  (select count(*) from vehicle_prepaids where source_invoice_id = test.gmv('inv1')), 2::bigint);
select test.eq('audit: each recorded payment is in the audit log', (select count(*) from audit_log where action = 'record_manual_payment' and entity_id = test.gmv('inv1')::text), 2::bigint);
select app.process_events(100000);
select test.eq('email: the receipt names the method, the date, the reference and what is still owing',
  (select (payload ->> 'payment_method') || '/' || (payload ->> 'reference') || '/' || (payload ->> 'is_paid_in_full') || '/' || (payload ->> 'amount')
     from notification_outbox where code = 'owner_payment_recorded' and entity_id = test.gmv('mp2')), 'cheque/000123/true/' || app.fmt_money((select total_cents from test.gm_total where id = test.gmv('inv1')) - 15000));
select test.throws('check: a paid invoice owes nothing', format($$select test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'cash', 'amount_cents', 100))$$, test.gmv('inv1')), 'owes nothing');

-- void
select test.throws('void: an Admin only', format($$select test.gm_do('gm_fin', 'manual_payment_void', jsonb_build_object('id', %L, 'reason', 'x'))$$, test.gmv('mp2')), 'Admin');
select test.throws('void: the reason is required', format($$select test.gm_do('gm_admin', 'manual_payment_void', jsonb_build_object('id', %L))$$, test.gmv('mp2')), 'reason');
select test.gm_do('gm_admin', 'manual_payment_void', jsonb_build_object('id', test.gmv('mp2'), 'reason', 'The bank returned the cheque'));
select test.eq('void: the invoice owes the cheque again (the e-Transfer still counts), the payment is cancelled',
  (select i.status || '/' || i.paid_cents || '/' || (i.balance_cents = t.total_cents - 15000) || '/' || (select p.status from payments p join manual_payments m on m.payment_id = p.id where m.id = test.gmv('mp2'))
     from owner_invoices i join test.gm_total t on t.id = i.id where i.id = test.gmv('inv1')), 'issued/15000/true/cancelled');
select test.eq('void: the prepaid months it funded are given back', (select count(*) from vehicle_prepaids where source_invoice_id = test.gmv('inv1')), 0::bigint);
select test.eq('void: the owner is told; no "payment failed" email', (select count(*) filter (where code = 'owner_payment_reversed') || '/' || count(*) filter (where code = 'owner_payment_failed')
   from app_events where entity_id in (test.gmv('mp2'), test.gmv('inv1'))), '1/0');
select test.throws('void: once only', format($$select test.gm_do('gm_admin', 'manual_payment_void', jsonb_build_object('id', %L, 'reason', 'again'))$$, test.gmv('mp2')), 'already voided');
select test.eq('void: the owner portal shows it as reversed', (select count(*) from jsonb_array_elements(app.owner_invoice_view(test.gmv('inv1')) -> 'manual') x where x ->> 'voided_at' is not null), 1::bigint);
select test.eq('void: audited with the reason', (select after ->> 'reason' from audit_log where action = 'void_manual_payment' and entity_id = test.gmv('mp2')::text), 'The bank returned the cheque');

-- 0029's path goes through the same function; cash needs no reference
select test.eq('offline path: 0029''s Admin call records a manual payment',
  (select (public.admin_record_owner_offline_payment(test.gmv('inv2'), test.id('gm_admin'), jsonb_build_object('method', 'cash', 'amount_cents', 5000, 'received_on', app.today())) ->> 'manual_payment_id') is not null), true);
select test.eq('cash: recorded without a reference', (select method || '/' || coalesce(reference, 'none') from manual_payments where owner_invoice_id = test.gmv('inv2')), 'cash/none');
insert into owner_invoices (id, owner_id, vehicle_id, kind, billing_date, status) values (test.id('inv:gm:proc'), test.gmv('app'), test.gmv('v2'), 'adjustment', app.today(), 'draft');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values (test.id('inv:gm:proc'), 'adjustment', 'Registry cost', 10000, true, 1300);
update owner_invoices set status = 'issued' where id = test.id('inv:gm:proc');
update owner_invoices set status = 'processing' where id = test.id('inv:gm:proc');
select test.throws('processing: no payment by hand while a debit is processing', format($$select test.gm_do('gm_admin', 'manual_payment_record', jsonb_build_object('invoice', %L, 'method', 'cash', 'amount_cents', 100))$$,
  test.id('inv:gm:proc')), 'processing');
select test.eq('month: Finance sees the month''s payments by hand with the voided one marked, and the totals leave it out',
  (select (select count(*) from jsonb_array_elements(m -> 'rows') r where (r ->> 'id')::uuid = test.gmv('mp2') and r ->> 'voided_at' is not null) || '/' ||
          (coalesce((m -> 'totals' ->> 'cheque')::bigint, 0) = (select coalesce(sum(amount_cents), 0) from manual_payments where method = 'cheque' and voided_at is null
                                                                  and date_trunc('month', received_on) = date_trunc('month', app.today())))
     from (select test.gm_read('gm_fin', 'manual_payments_month', jsonb_build_object('month', app.today())) m) x), '1/true');

-- a renter's failed charge paid by e-Transfer
select test.mk_renter('gm_rena');
select test.mk_owner('gm_otto');
select test.mk_vehicle('GMV', 'gm_otto');
select test.mk_booking('GM-1', 'GMV', 'gm_rena', '2026-09-01 10:00', '2026-09-03 10:00', 'closed');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, next_retry_at, processed_at)
values (test.id('pay:gm:toll'), test.id('booking:GM-1'), test.id('renter:gm_rena'), 'toll_ticket', 'charge', 'card', 2350, 'failed', now() + interval '1 day', now());
select test.gm_do('gm_fin', 'manual_payment_record', jsonb_build_object('booking', 'GM-1', 'method', 'e_transfer', 'reference', 'TOLL-77', 'settles_payment', test.id('pay:gm:toll')));
select test.eq('renter: the e-Transfer settles the failed charge (no more card retries)',
  (select (next_retry_at is null) || '/' || (select m.amount_cents || '/' || m.target from manual_payments m where m.settles_payment_id = p.id) from payments p where p.id = test.id('pay:gm:toll')),
  'true/2350/booking');

-- ================================================================ 3. signatures on paper
select test.eq('owner checklist: agreements, schedules, debit agreement, Form A, Form C and Form D are open',
  (select string_agg(i ->> 'code' || '=' || (i ->> 'status'), ',') from jsonb_array_elements(app.owner_signables(test.gmv('app'))) i where i ->> 'group' = 'sign'),
  'enrollment=open,title_holding=open,schedule=open,schedule=open,debit_agreement=open,form_a=open,form_d=open,form_c=open');
select test.throws('paper: an Admin only (customer service only for rental documents)',
  format($$select test.gm_do('gm_cs', 'paper_signature_record', jsonb_build_object('doc_type', 'owner_agreement', 'target_id', %L, 'signer_name', 'Olivia Paper', 'signed_on', app.today(),
    'scan', jsonb_build_object('path', 'paper/x.pdf', 'sha256', test.gm_sha('s0'))))$$, test.gmv('app')), 'Admin');
select test.throws('paper: the scan is required', format($$select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'owner_agreement', 'target_id', %L,
  'signer_name', 'Olivia Paper', 'signed_on', app.today()))$$, test.gmv('app')), 'scan');
select test.throws('paper: Form D needs both witnesses', format($$select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'form_d', 'target_id', %L,
  'signer_name', 'Olivia Paper', 'signed_on', app.today(), 'witness_1_name', 'Wendy Witness', 'scan', jsonb_build_object('path', 'paper/d.pdf', 'sha256', test.gm_sha('d'))))$$, test.gmv('app')), 'two witnesses');

insert into test.gm select 'ps_owner', (test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'owner_agreement', 'target_id', test.gmv('app'),
  'signer_name', 'Olivia Paper', 'signed_on', app.today() - 3, 'note', 'Signed at the office',
  'scan', jsonb_build_object('path', 'paper/owners/gm/agreements.pdf', 'sha256', test.gm_sha('agreements'), 'mime', 'application/pdf'))) ->> 'id')::uuid;
select test.eq('paper: both agreements and both schedules are signed, with the date signed',
  (select string_agg(kind || ':' || status || ':' || agreement_date, ',' order by kind) from owner_agreements where owner_id = test.gmv('app'))
  || '/' || (select count(*) from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = test.gmv('app') and s.signed_at is not null and s.superseded_by is null),
  'enrollment:signed:' || (app.today() - 3) || ',title_holding:signed:' || (app.today() - 3) || '/2');
select test.eq('paper: the onboarding moves on exactly as after signing in the portal',
  (select string_agg(distinct ob.status::text, ',') from vehicle_onboardings ob where ob.vehicle_id in (test.gmv('v1'), test.gmv('v2'))), 'documents_signed');
select test.eq('paper: the checklist shows them signed, method paper',
  (select string_agg(distinct (i ->> 'status') || ':' || (i ->> 'method'), ',') from jsonb_array_elements(app.owner_signables(test.gmv('app'))) i where i ->> 'code' in ('enrollment', 'title_holding', 'schedule')), 'done:paper');
select test.eq('paper: the onboarding checklist item "Agreements signed" is done',
  (select status from app.onboarding_checklist(test.gmv('v1')) where code = 'signatures'), 'done');
select test.eq('paper: the owner portal no longer asks to sign', public.owner_portal_home(test.id('gm_olivia')) #>> '{signing,needed}', 'false');
select test.eq('paper: the scan is in the owner''s documents',
  (select count(*) from jsonb_array_elements(public.owner_portal_documents(test.id('gm_olivia'))) d where d ->> 'title' = 'Owner agreements and schedules, signed on paper'), 1::bigint);
select test.eq('paper: the signature record says paper, with the owner and CarmaCars',
  (select string_agg(r.signer_role || ':' || r.method, ',' order by r.signer_role) from signature_records r join owner_agreements a on a.signature_request_id = r.signature_request_id
    where a.owner_id = test.gmv('app') and a.kind = 'enrollment'), 'carmacars:automatic,owner_individual:paper');
select test.eq('paper (0051, 0053): the owner''s record keeps the paper date only (no time of day); CarmaCars'' countersignature is dated when staff recorded it',
  (select string_agg(r.signer_role || ':' || case when r.signer_role = 'carmacars' then app.local_date(r.signed_at) = app.today() else r.signed_at is null and r.signed_on = app.today() - 3 end, ',' order by r.signer_role)
     from signature_records r join owner_agreements a on a.signature_request_id = r.signature_request_id
    where a.owner_id = test.gmv('app') and a.kind = 'enrollment'), 'carmacars:true,owner_individual:true');
select test.throws('paper: nothing left to sign the second time', format($$select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'owner_agreement', 'target_id', %L,
  'signer_name', 'Olivia Paper', 'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/again.pdf', 'sha256', test.gm_sha('again'))))$$, test.gmv('app')), 'Nothing of');
select test.eq('audit: recorded', (select count(*) from audit_log where action = 'record_paper_signature' and entity_id = test.gmv('ps_owner')::text), 1::bigint);

-- void puts it back
select test.gm_do('gm_admin', 'paper_signature_void', jsonb_build_object('id', test.gmv('ps_owner'), 'reason', 'Wrong scan uploaded'));
select test.eq('void: the agreements wait for a signature again, the schedules are unsigned, the onboarding goes back',
  (select string_agg(status, ',' order by kind) from owner_agreements where owner_id = test.gmv('app')) || '/' ||
  (select count(*) from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = test.gmv('app') and s.signed_at is not null and s.superseded_by is null) || '/' ||
  (select string_agg(distinct ob.status::text, ',') from vehicle_onboardings ob where ob.vehicle_id in (test.gmv('v1'), test.gmv('v2'))), 'draft,draft/0/documents_sent');
select test.eq('void: the portal asks the owner to sign again', public.owner_portal_home(test.id('gm_olivia')) #>> '{signing,needed}', 'true');
select test.eq('void: kept with the reason', (select void_reason from paper_signatures where id = test.gmv('ps_owner')), 'Wrong scan uploaded');
select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'owner_agreement', 'target_id', test.gmv('app'),
  'signer_name', 'Olivia Paper', 'signed_on', app.today() - 3, 'scan', jsonb_build_object('path', 'paper/owners/gm/agreements-2.pdf', 'sha256', test.gm_sha('agreements2'))));

-- forms
insert into test.gm select 'ps_d', (test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'form_d', 'target_id', test.gmv('app'), 'signer_name', 'Olivia Paper',
  'signed_on', app.today() - 2, 'witness_1_name', 'Wendy Witness', 'witness_2_name', 'Walt Witness', 'scan', jsonb_build_object('path', 'paper/owners/gm/form-d.pdf', 'sha256', test.gm_sha('fd')))) ->> 'id')::uuid;
select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'form_c', 'target_id', test.gmv('v2'), 'signer_name', 'Olivia Paper',
  'signed_on', app.today() - 2, 'witness_1_name', 'Wendy Witness', 'scan', jsonb_build_object('path', 'paper/owners/gm/form-c.pdf', 'sha256', test.gm_sha('fc'))));
select test.eq('forms: Forms C and D on paper are approved, with their witnesses, and the witnessed forms item is done',
  (select string_agg(x ->> 'code' || ':' || (x ->> 'status') || ':' || coalesce(x ->> 'witness_2_name', '-'), ',' order by x ->> 'code') from jsonb_array_elements(app.owner_witnessed_forms(test.gmv('app'))) x)
  || '/' || (select status from app.onboarding_checklist(test.gmv('v2')) where code = 'witnessed_forms'), 'C:approved:-,D1:approved:Walt Witness/done');
select test.eq('forms: the witnesses are in the signature record', (select count(*) from signature_records r join owner_agreement_forms f on f.signature_request_id = r.signature_request_id
   where f.owner_id = test.gmv('app') and f.form_code = 'D1' and r.signer_role = 'witness'), 2::bigint);
select test.throws('forms: a form not needed is refused', format($$select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'form_b', 'target_id', %L, 'signer_name', 'Olivia Paper',
  'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/b.pdf', 'sha256', test.gm_sha('b'))))$$, test.gmv('app')), 'does not need');
select test.gm_do('gm_admin', 'paper_signature_void', jsonb_build_object('id', test.gmv('ps_d'), 'reason', 'Witness did not sign'));
select test.eq('forms: a voided Form D is needed again', (select x ->> 'status' from jsonb_array_elements(app.owner_witnessed_forms(test.gmv('app'))) x where x ->> 'code' = 'D1'), 'needed');

-- the debit agreement on paper
select test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'debit_agreement', 'target_id', test.gmv('app'), 'signer_name', 'Olivia Paper',
  'signed_on', app.today() - 1, 'scan', jsonb_build_object('path', 'paper/owners/gm/pad.pdf', 'sha256', test.gm_sha('pad'))));
select test.eq('debit agreement: on paper, done, and it says the bank account is still needed for the automatic debit',
  (select (i ->> 'status') || '/' || (i ->> 'method') || '/' || (i ->> 'detail' like '%still needs the bank account%') from jsonb_array_elements(app.owner_signables(test.gmv('app'))) i where i ->> 'code' = 'debit_agreement'),
  'done/paper/true');

-- Forms A on screen (the owner opens and signs it in the portal)
select test.eq('form A: the owner needs Form A (a car under the Transfer method)', (select string_agg(x ->> 'code' || ':' || (x ->> 'status'), ',') from jsonb_array_elements(public.owner_screen_forms(test.id('gm_olivia'))) x), 'A:needed');
select test.eq('form A: the facts list the cars it covers', jsonb_array_length(public.server_owner_form_ab_facts(test.id('gm_olivia'), 'A') -> 'vehicles'), 2);
insert into test.gm select 'srA', (public.owner_form_ab_open(test.id('gm_olivia'), 'A', test.gm_sha('formA'), 'owners/' || test.gmv('app') || '/forms/form-a.pdf', 'forms-ab-test') ->> 'id')::uuid;
select test.eq('form A: opening the same document again returns the same request',
  (public.owner_form_ab_open(test.id('gm_olivia'), 'A', test.gm_sha('formA'), 'owners/' || test.gmv('app') || '/forms/form-a.pdf', 'forms-ab-test') ->> 'id')::uuid, test.gmv('srA'));
select test.throws('sign: the typed name must be the signer''s', format($$select public.sign_request_sign(test.id('gm_olivia'), %L, jsonb_build_object('typed_name', 'Someone Else', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('formA')))$$, test.gmv('srA')), 'full legal name');
select test.throws('sign: the document must be the one opened', format($$select public.sign_request_sign(test.id('gm_olivia'), %L, jsonb_build_object('typed_name', 'Olivia Paper', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('other')))$$, test.gmv('srA')), 'changed');
select test.throws('sign: only the signer', format($$select public.sign_request_sign(test.id('gm_ivan'), %L, jsonb_build_object('typed_name', 'Ivan Investor', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('formA')))$$, test.gmv('srA')), 'Not found');
select test.eq('sign: signed on screen', public.sign_request_sign(test.id('gm_olivia'), test.gmv('srA'), jsonb_build_object('typed_name', 'Olivia Paper', 'consent_text', 'I agree to sign Form A electronically.',
  'document_sha256', test.gm_sha('formA'), 'ip', '203.0.113.9', 'user_agent', 'test')) ->> 'status', 'signed');
select test.eq('form A: approved, signed on screen; the checklist shows it',
  (select string_agg(x ->> 'status' || ':' || (x ->> 'method'), ',') from jsonb_array_elements(public.owner_screen_forms(test.id('gm_olivia'))) x)
  || '/' || (select (i ->> 'status') || ':' || (i ->> 'method') from jsonb_array_elements(app.owner_signables(test.gmv('app'))) i where i ->> 'code' = 'form_a'), 'signed:screen/done:screen');
select test.eq('form A: CarmaCars countersigned automatically',
  (select string_agg(x.signer_role || ':' || x.method, ',' order by x.signer_role) from signature_records x join sign_requests r on r.signature_request_id = x.signature_request_id where r.id = test.gmv('srA')),
  'carmacars:automatic,owner_individual:typed');
insert into test.gm select 'formA_signed', public.server_sign_request_attach(test.gmv('srA'), 'owners/' || test.gmv('app') || '/forms/form-a-signed.pdf', test.gm_sha('formAs'));
select test.eq('form A: the signed copy is filed', (select document_id from owner_agreement_forms where owner_id = test.gmv('app') and form_code = 'A' and status = 'approved'), test.gmv('formA_signed'));

-- registry forms
insert into pdf_templates (id, form_code, title, version, kind, is_current) values (test.id('tpl:gm'), 'GM-REG', 'Test registry form', 'v1', 'generated', false);
insert into government_form_fills (id, form_code, pdf_template_id, template_version, vehicle_id, owner_id, mode, status)
values (test.id('fill:gm'), 'GM-REG', test.id('tpl:gm'), 'v1', test.gmv('v1'), test.gmv('app'), 'data_sheet', 'ready');
insert into test.gm select 'ps_reg', (test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'registry_form', 'target_id', test.id('fill:gm'), 'signer_name', 'Olivia Paper',
  'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/owners/gm/reg.pdf', 'sha256', test.gm_sha('reg')))) ->> 'id')::uuid;
select test.eq('registry form: signed on paper, the scan is the form''s document',
  (select status || '/' || signed_method || '/' || (document_id = (select document_id from paper_signatures where id = test.gmv('ps_reg'))) from government_form_fills where id = test.id('fill:gm')), 'signed/paper/true');
select test.gm_do('gm_admin', 'paper_signature_void', jsonb_build_object('id', test.gmv('ps_reg'), 'reason', 'Scanned the wrong form'));
select test.eq('registry form: void puts it back to ready', (select status || '/' || coalesce(signed_method, 'none') from government_form_fills where id = test.id('fill:gm')), 'ready/none');

-- the rental agreement
select test.mk_booking('GM-2', 'GMV', 'gm_rena', '2026-12-01 10:00', '2026-12-03 10:00', 'pending_payment');
update bookings set current_offer_version = 1, offer_approved_version = 1, offer_approved_at = now(), offer_approved_by = test.id('gm_renter_user') where id = test.id('booking:GM-2');
select test.throws('rental: the agreement must be opened first', $$select test.gm_do('gm_cs', 'paper_signature_record', jsonb_build_object('doc_type', 'rental_agreement', 'target_id', test.id('booking:GM-2'),
  'signer_name', 'Gm Rena', 'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/bookings/gm2.pdf', 'sha256', test.gm_sha('ra'))))$$, 'Open the rental agreement');
select app.open_rental_agreement(test.id('booking:GM-2'), test.id('gm_admin'), 'test-v1', test.gm_sha('ra-doc'), 'bookings/gm2/agreement.pdf');
insert into test.gm select 'ps_ra', (test.gm_do('gm_cs', 'paper_signature_record', jsonb_build_object('doc_type', 'rental_agreement', 'target_id', test.id('booking:GM-2'),
  'signer_name', 'Gm Rena', 'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/bookings/gm2.pdf', 'sha256', test.gm_sha('ra')))) ->> 'id')::uuid;
select test.eq('rental: customer service records it; the agreement is signed by the renter, on paper; the booking can be confirmed',
  (select a.status || '/' || (select r.method from signature_records r where r.id = g.signature_record_id) from rental_agreements a join rental_agreement_signers g on g.agreement_id = a.id and g.signer_role = 'renter'
    where a.booking_id = test.id('booking:GM-2') and a.status <> 'voided'), 'signed/paper');
select test.eq('rental: the scan is with the booking and the renter''s documents',
  (select d.booking_id = test.id('booking:GM-2') and d.renter_id = test.id('renter:gm_rena') and d.kind = 'rental_agreement' from paper_signatures p join documents d on d.id = p.document_id where p.id = test.gmv('ps_ra')), true);
select test.throws('rental: only an Admin voids', format($$select test.gm_do('gm_cs', 'paper_signature_void', jsonb_build_object('id', %L, 'reason', 'x'))$$, test.gmv('ps_ra')), 'Admin');
select test.gm_do('gm_admin', 'paper_signature_void', jsonb_build_object('id', test.gmv('ps_ra'), 'reason', 'Signed by the wrong person'));
select test.eq('rental: void voids the agreement (a signature is never changed); a new one is opened and signed',
  (select string_agg(status, ',' order by opened_at) from rental_agreements where booking_id = test.id('booking:GM-2')), 'voided');

-- an amendment to a booking
select test.mk_booking('GM-3', 'GMV', 'gm_rena', '2027-01-10 10:00', '2027-01-12 10:00', 'confirmed');
insert into booking_change_requests (id, booking_id, requested_by_role, requested_by, status, changes, difference_cents, hst_cents, total_difference_cents, accept_by)
values (test.id('chg:gm'), test.id('booking:GM-3'), 'staff', test.id('gm_admin'), 'proposed', '{}'::jsonb, 4425, 575, 5000, now() + interval '2 days');
insert into test.gm select 'ps_am', (test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'rental_amendment', 'target_id', test.id('chg:gm'),
  'signer_name', 'Gm Rena', 'signed_on', app.today(), 'scan', jsonb_build_object('path', 'paper/bookings/gm3-a1.pdf', 'sha256', test.gm_sha('am')))) ->> 'id')::uuid;
select test.eq('amendment: signed on paper, the renter''s agreement recorded; more is owed, so it is applied when paid',
  (select am.status || '/' || c.status || '/' || (c.renter_agreed_at is not null) || '/' || (select r.method from signature_records r where r.id = am.signature_record_id)
     from booking_amendments am join booking_change_requests c on c.id = am.change_request_id where c.id = test.id('chg:gm')), 'signed/approved/true/paper');
select test.gm_do('gm_admin', 'paper_signature_void', jsonb_build_object('id', test.gmv('ps_am'), 'reason', 'The renter did not initial it'));
select test.eq('amendment: void voids it and clears the agreement', (select am.status || '/' || (c.renter_agreed_at is null) from booking_amendments am join booking_change_requests c on c.id = am.change_request_id
   where c.id = test.id('chg:gm')), 'voided/true');

-- ================================================================ 4. documents sent to sign: investors and staff
select test.eq('investor: a prospect without anything to sign has no investor portal', (app.my_roles(test.id('gm_ivan')) ->> 'investor')::boolean, false);
select test.throws('send: the prospectus exemption is required', $$select test.gm_do('gm_admin', 'sign_request_create', jsonb_build_object('doc_type', 'investment_agreement', 'investor_id', test.id('inv:gm_ivan'),
  'document', jsonb_build_object('path', 'investors/gm/ia.pdf', 'sha256', test.gm_sha('ia'))))$$, 'exemption');
insert into test.gm select 'srI', (test.gm_do('gm_admin', 'sign_request_create', jsonb_build_object('doc_type', 'investment_agreement', 'investor_id', test.id('inv:gm_ivan'),
  'exemption_category', 'accredited_investor', 'document', jsonb_build_object('path', 'investors/gm/ia.pdf', 'sha256', test.gm_sha('ia')))) ->> 'id')::uuid;
select test.eq('send: the agreement is numbered and sent, the investor reaches the portal to sign, and is told in the portal',
  (select a.status || '/' || (a.agreement_number like 'IA-%') from investment_agreements a where a.investor_id = test.id('inv:gm_ivan'))
  || '/' || (app.my_roles(test.id('gm_ivan')) ->> 'investor') || '/' || (select count(*) from notifications where user_id = test.id('gm_ivan') and code = 'person_document_to_sign'), 'sent/true/true/1');
select test.eq('investor: the home read works for an invited prospect', (public.door(test.id('gm_ivan'), null, 'investor_read', 'home') #>> '{investor,legal_name}'), 'Ivan Investor');
select test.eq('list: the investor sees one document to sign', jsonb_array_length(public.my_sign_requests(test.id('gm_ivan')) -> 'open'), 1);
select test.throws('sign: the legal advice choice is required', format($$select public.sign_request_sign(test.id('gm_ivan'), %L, jsonb_build_object('typed_name', 'Ivan Investor', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('ia'), 'initials', 'II'))$$, test.gmv('srI')), 'legal advice');
select test.throws('sign: Schedule C is initialled', format($$select public.sign_request_sign(test.id('gm_ivan'), %L, jsonb_build_object('typed_name', 'Ivan Investor', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('ia'), 'legal_advice_choice', 'declined'))$$, test.gmv('srI')), 'Initial');
select public.sign_request_sign(test.id('gm_ivan'), test.gmv('srI'), jsonb_build_object('drawn_signature', 'investors/gm/sig.png', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('ia'),
  'legal_advice_choice', 'declined', 'initials', 'ii'));
select test.eq('signed: the agreement is signed with its schedules and choices; CarmaCars signs when funds clear',
  (select a.status || '/' || a.legal_advice_choice || '/' || a.exemption_category || '/' || (a.schedule_c_document_id is not null and a.schedule_d_document_id is not null) || '/' || coalesce(a.company_signed_at::text, 'company to sign')
     from investment_agreements a where a.investor_id = test.id('inv:gm_ivan')), 'signed/declined/accredited_investor/true/company to sign');
select test.eq('signed: drawn, with the initials on record', (select r.method || '/' || (r.initials ->> 'schedule_c') from sign_requests s join signature_records r on r.id = s.signature_record_id where s.id = test.gmv('srI')), 'drawn/II');
select test.eq('signed: the investor sees it under signed', (select x ->> 'method' from jsonb_array_elements(public.my_sign_requests(test.id('gm_ivan')) -> 'signed') x), 'drawn');

-- staff agreements
insert into test.gm select 'srS', (test.gm_do('gm_admin', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('gm_field'),
  'title', 'Field Staff Agreement', 'document', jsonb_build_object('path', 'staff/gm/fsa.pdf', 'sha256', test.gm_sha('fsa')))) ->> 'id')::uuid;
insert into test.gm select 'srS2', (test.gm_do('gm_admin', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('gm_field'),
  'title', 'Field Staff Agreement (corrected)', 'document', jsonb_build_object('path', 'staff/gm/fsa2.pdf', 'sha256', test.gm_sha('fsa2')))) ->> 'id')::uuid;
select test.eq('staff: a new version voids the one before; the field portal is pointed at',
  (select string_agg(status, ',' order by sent_at) from sign_requests where staff_user_id = test.id('gm_field'))
  || '/' || (select url like '%/staff/field/sign' from notifications where user_id = test.id('gm_field') and code = 'person_document_to_sign' limit 1), 'voided,sent/true');
select public.sign_request_sign(test.id('gm_field'), test.gmv('srS2'), jsonb_build_object('typed_name', 'Gm Field', 'consent_text', 'I agree', 'document_sha256', test.gm_sha('fsa2')));
select test.eq('staff: signed; the staff profile carries the agreement', (select sp.agreement_document_id = s.document_id from staff_profiles sp, sign_requests s where sp.user_id = test.id('gm_field') and s.id = test.gmv('srS2')), true);
select test.eq('staff: the person may open the agreement they signed, not another''s',
  (public.my_sign_document(test.id('gm_field'), (select document_id from sign_requests where id = test.gmv('srS2'))) ->> 'path') || '/' ||
  coalesce(public.my_sign_document(test.id('gm_fin'), (select document_id from sign_requests where id = test.gmv('srS2'))) ->> 'path', 'refused'), 'staff/gm/fsa2.pdf/refused');
insert into test.gm select 'ps_staff', (test.gm_do('gm_admin', 'paper_signature_record', jsonb_build_object('doc_type', 'staff_agreement', 'target_id', test.id('gm_fin'), 'signer_name', 'Gm Fin',
  'signed_on', app.today() - 30, 'scan', jsonb_build_object('path', 'paper/staff/gm/va.pdf', 'sha256', test.gm_sha('va')))) ->> 'id')::uuid;
select test.eq('staff on paper: the profile carries the scan, and the person sees it as signed on paper',
  (select (sp.agreement_document_id = p.document_id) || '/' || (select x ->> 'method' from jsonb_array_elements(public.my_sign_requests(test.id('gm_fin')) -> 'signed') x)
     from staff_profiles sp, paper_signatures p where sp.user_id = test.id('gm_fin') and p.id = test.gmv('ps_staff')), 'true/paper');
select test.eq('staff on paper: the scan is the person''s own document', (public.my_sign_document(test.id('gm_fin'), (select document_id from paper_signatures where id = test.gmv('ps_staff'))) ->> 'path'), 'paper/staff/gm/va.pdf');

select test.eq('staff agreements: Admin sees each one, how it was signed',
  (select string_agg((x ->> 'name') || ':' || coalesce(x #>> '{signed,method}', 'none'), ',' order by x ->> 'name')
     from jsonb_array_elements(test.gm_read('gm_admin', 'staff_agreements')) x where (x ->> 'user_id')::uuid in (test.id('gm_field'), test.id('gm_fin'))), 'Gm Field:typed,Gm Fin:paper');
select test.eq('reads: what was sent to an investor, and the paper signatures of a staff member',
  jsonb_array_length(test.gm_read('gm_admin', 'sign_requests', jsonb_build_object('investor', test.id('inv:gm_ivan')))) || '/' ||
  jsonb_array_length(test.gm_read('gm_admin', 'paper_signatures', jsonb_build_object('staff', test.id('gm_fin')))), '1/1');
select test.eq('files: Finance opens a proof of payment, not a paper scan; customer service a rental scan, not a proof',
  (test.gm_read('gm_fin', 'staff_document', jsonb_build_object('document', (select proof_document_id from manual_payments where proof_document_id is not null limit 1))) is not null)
  || '/' || (test.gm_read('gm_fin', 'staff_document', jsonb_build_object('document', (select document_id from paper_signatures where doc_type = 'rental_agreement' limit 1))) is null)
  || '/' || (test.gm_read('gm_cs', 'staff_document', jsonb_build_object('document', (select document_id from paper_signatures where doc_type = 'rental_agreement' limit 1))) is not null)
  || '/' || (test.gm_read('gm_cs', 'staff_document', jsonb_build_object('document', (select proof_document_id from manual_payments where proof_document_id is not null limit 1))) is null),
  'true/true/true/true');
select test.throws('staff agreements: Admins only', $$select test.gm_read('gm_fin', 'staff_agreements')$$, 'Admin');

-- ================================================================ 5. Admin > Owners and privileges
select test.eq('checklists: Admin sees the owner with what is signed and paid and how',
  (select (o ->> 'legal_name') || '/' || ((o ->> 'paper')::int >= 3) || '/' || (select count(*) from jsonb_array_elements(o -> 'items') i where i ->> 'group' = 'pay')
     from jsonb_array_elements(test.gm_read('gm_admin', 'owner_checklists', jsonb_build_object('owner', test.gmv('app')))) o), 'Olivia Paper/true/3');
select test.eq('checklists: an upfront invoice partly paid says so', (select i ->> 'detail' like 'Partly paid%' from jsonb_array_elements(app.owner_signables(test.gmv('app'))) i where (i ->> 'invoice_id')::uuid = test.gmv('inv1')), true);
select test.eq('open invoices: Finance sees what is still owing, with the payments recorded by hand',
  (select (x ->> 'balance_cents')::int > 0 and jsonb_array_length(x -> 'manual') >= 1 from jsonb_array_elements(test.gm_read('gm_fin', 'owner_invoices_open', jsonb_build_object('q', 'Olivia'))) x
    where (x ->> 'id')::uuid = test.gmv('inv1')), true);
select test.throws('checklists: not for field staff', $$select test.gm_read('gm_field', 'owner_checklists')$$, 'Not permitted');
select test.eq('privileges: the browser roles cannot call the new functions',
  has_function_privilege('authenticated', 'app.record_manual_payment(uuid, jsonb)', 'execute') or has_function_privilege('anon', 'public.guide_read(uuid, text)', 'execute')
  or has_function_privilege('authenticated', 'app.record_paper_signature(uuid, jsonb)', 'execute'), false);
select test.login(test.id('gm_olivia'));
select test.eq('rls: an owner reads their own manual payments, not another owner''s; no paper signature records',
  test.visible('select 1 from manual_payments where owner_id = test.gmv(''app'')') || '/' || test.visible('select 1 from manual_payments where owner_id is distinct from test.gmv(''app'')')
  || '/' || test.visible('select 1 from paper_signatures'), '3/0/0');
select test.logout();
select test.login(test.id('gm_field'));
select test.eq('rls: a staff member reads their own documents to sign only', test.visible('select 1 from sign_requests') || '/' || test.visible('select 1 from guide_reads'), '2/0');
select test.logout();
