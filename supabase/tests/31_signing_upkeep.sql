-- 31: simple signing, partner insurance reminders, guide upkeep and the official form sources (migrations 0047 and 0049).
-- Fixtures start with "su".
select test.suite('31 signing, insurance reminders, guide upkeep');

select test.mk_user('su_admin', 'admin');
select test.mk_user('su_cs', 'va', 'cs');
select test.mk_user('su_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 25000, dual_approval_threshold_cents = 100000, started_on = date '2026-11-02' where user_id = test.id('su_fin');
insert into users (id, email, full_name) values (test.id('su_ivy'), 'su_ivy@example.test', 'Ivy Su');
insert into investors (id, user_id, legal_name, investor_type, email, phone, address, tax_resident_canada, status)
values (test.id('inv:su_ivy'), test.id('su_ivy'), 'Ivy Su', 'individual', 'su_ivy@example.test', '416-555-0177', '9 King Street West, Toronto', true, 'prospect');
select test.mk_owner('su_olga');
select test.mk_vehicle('su_car', 'su_olga');

create temp table su as select null::text as k, null::jsonb as v limit 0;
create or replace function test.su(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.su where k = p_k $$;
create or replace function test.su_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create or replace function test.su_read(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;
create or replace function test.su_sha(p text) returns text language sql immutable as $$ select encode(sha256(convert_to('su:' || p, 'UTF8')), 'hex') $$;

-- ================================================================ 1. agreements generated from the records
insert into su select 'inv_facts', test.su_do('su_admin', 'investor_agreement_prepare', jsonb_build_object('investor_id', test.id('inv:su_ivy')));
select test.eq('investor agreement: prepared from the record (name, the program''s minimum and lockup, no investment before signing, a numbered draft agreement)',
  (test.su('inv_facts') #>> '{investor,legal_name}') || '/' || (test.su('inv_facts') #>> '{terms,min_cents}') || '/' || (test.su('inv_facts') #>> '{terms,lockup_months}')
  || '/' || jsonb_array_length(test.su('inv_facts') -> 'investments') || '/' || (test.su('inv_facts') ->> 'agreement_number' like 'IA-%')
  || '/' || (select a.status from investment_agreements a where a.investor_id = test.id('inv:su_ivy')),
  'Ivy Su/2000000/6/0/true/draft');
select test.eq('investor agreement: preparing again keeps the same number', test.su_do('su_admin', 'investor_agreement_prepare', jsonb_build_object('investor_id', test.id('inv:su_ivy'))) ->> 'agreement_number',
  test.su('inv_facts') ->> 'agreement_number');
select test.throws('investor agreement: an Admin only', $$select test.su_do('su_cs', 'investor_agreement_prepare', jsonb_build_object('investor_id', test.id('inv:su_ivy')))$$, null);
insert into su select 'staff_facts', test.su_read('su_admin', 'staff_agreement_prepare', jsonb_build_object('staff_user_id', test.id('su_fin')));
select test.eq('staff agreement: the profile (function, limits, start) and the settings'' defaults for what it does not hold',
  (test.su('staff_facts') #>> '{staff,va_function}') || '/' || (test.su('staff_facts') #>> '{staff,single_limit_cents}') || '/' || (test.su('staff_facts') #>> '{staff,started_on}')
  || '/' || (test.su('staff_facts') #>> '{defaults,platform}') || '/' || (test.su('staff_facts') #>> '{defaults,country}'),
  'finance/25000/2026-11-02/OnlineJobs.ph/Philippines');
select test.throws('staff agreement: an Admin only', $$select test.su_read('su_cs', 'staff_agreement_prepare', jsonb_build_object('staff_user_id', test.id('su_fin')))$$, null);
insert into su select 'sr_ia', test.su_do('su_admin', 'sign_request_create', jsonb_build_object('doc_type', 'investment_agreement', 'investor_id', test.id('inv:su_ivy'),
  'exemption_category', 'accredited_investor', 'title', 'Investment agreement ' || (test.su('inv_facts') ->> 'agreement_number'),
  'document', jsonb_build_object('path', 'investors/su/ia.pdf', 'sha256', test.su_sha('ia')), 'template_version', 'person-test',
  'extra', jsonb_build_object('generated', true, 'summary', jsonb_build_array(jsonb_build_object('label', 'Invested Amount', 'value', '$25,000.00')))));
select test.eq('generated agreement: sent with its template version, generated flag and summary of the filled values',
  (select r.template_version || '/' || (r.extra ->> 'generated') || '/' || (r.extra #>> '{summary,0,value}') || '/' || (r.extra ->> 'exemption_category')
     from sign_requests r where r.id = (test.su('sr_ia') ->> 'id')::uuid), 'person-test/true/$25,000.00/accredited_investor');
select test.eq('generated agreement: the same number as prepared', (select a.agreement_number from investment_agreements a where a.investor_id = test.id('inv:su_ivy') and a.status = 'sent'),
  test.su('inv_facts') ->> 'agreement_number');
select test.eq('generated agreement: the person''s list carries the summary', public.my_sign_requests(test.id('su_ivy')) #>> '{open,0,extra,summary,0,label}', 'Invested Amount');
insert into su select 'sr_va', test.su_do('su_admin', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('su_fin'),
  'title', 'Virtual Assistant Contractor Agreement, Su Fin', 'document', jsonb_build_object('path', 'staff/su/va.pdf', 'sha256', test.su_sha('va')), 'template_version', 'person-test'));

-- ================================================================ 2. signing packages
select test.throws('package: refused before the documents are signed', format($$select public.server_signing_package_record(test.id('su_ivy'),
  jsonb_build_object('portal', 'investor', 'method', 'typed', 'documents', jsonb_build_array(jsonb_build_object('signature_request_id', %L, 'title', 'IA'))))$$,
  (select signature_request_id from sign_requests where id = (test.su('sr_ia') ->> 'id')::uuid)), 'no signature from you yet');
insert into su select 'signed_ia', public.sign_request_sign(test.id('su_ivy'), (test.su('sr_ia') ->> 'id')::uuid, jsonb_build_object('typed_name', 'Ivy Su', 'ip', '203.0.113.9',
  'user_agent', 'test phone', 'consent_text', 'I sign "Investment agreement" with the one signature I gave for these 1 documents.', 'document_sha256', test.su_sha('ia'),
  'legal_advice_choice', 'declined', 'initials', 'IS'));
select test.throws('package: refused for someone else''s documents', format($$select public.server_signing_package_record(test.id('su_fin'),
  jsonb_build_object('portal', 'staff', 'method', 'typed', 'documents', jsonb_build_array(jsonb_build_object('signature_request_id', %L, 'title', 'IA'))))$$,
  test.su('signed_ia') ->> 'signature_request_id'), 'no signature from you yet');
select test.throws('package: the method must be the documents''', format($$select public.server_signing_package_record(test.id('su_ivy'),
  jsonb_build_object('portal', 'investor', 'method', 'drawn', 'documents', jsonb_build_array(jsonb_build_object('signature_request_id', %L, 'title', 'IA'))))$$,
  test.su('signed_ia') ->> 'signature_request_id'), 'no signature from you yet');
insert into su select 'pkg', public.server_signing_package_record(test.id('su_ivy'), jsonb_build_object('portal', 'investor', 'method', 'typed', 'ip', '203.0.113.9',
  'user_agent', 'test phone', 'seconds_to_sign', 41, 'consent_text', 'One signature for 1 document: Investment agreement.',
  'documents', jsonb_build_array(jsonb_build_object('signature_request_id', test.su('signed_ia') ->> 'signature_request_id', 'title', 'Investment agreement', 'consent_text', 'I sign it.'))));
select test.eq('package: recorded with its documents, each with its own signature record, the document''s SHA-256 and its consent',
  (select k.portal || '/' || k.method || '/' || k.seconds_to_sign || '/' || host(k.ip_address) || '/' || count(d.*) || '/' || bool_and(d.document_sha256 = test.su_sha('ia')) || '/' || min(d.consent_text)
     from signing_packages k join signing_package_documents d on d.package_id = k.id where k.id = (test.su('pkg') ->> 'id')::uuid group by k.id),
  'investor/typed/41/203.0.113.9/1/true/I sign it.');
select test.eq('package: the document''s own signature evidence is unchanged (time, IP, typed name, hash)',
  (select r.method || '/' || host(r.ip_address) || '/' || r.typed_name || '/' || (r.document_sha256 = test.su_sha('ia')) || '/' || (r.signed_at is not null)
     from signature_records r where r.id = (test.su('signed_ia') ->> 'signature_record_id')::uuid), 'typed/203.0.113.9/Ivy Su/true/true');
select test.eq('package: an Admin reads the packages a person signed', jsonb_array_length(test.su_read('su_admin', 'signing_packages', jsonb_build_object('user_id', test.id('su_ivy')))), 1);
select test.throws('package: the packages read is an Admin''s', $$select test.su_read('su_cs', 'signing_packages', jsonb_build_object('user_id', test.id('su_ivy')))$$, null);
-- two documents with one signature (the staff agreement and a second one)
insert into su select 'sr_va2', test.su_do('su_admin', 'sign_request_create', jsonb_build_object('doc_type', 'staff_agreement', 'staff_user_id', test.id('su_cs'),
  'title', 'Staff agreement, Su Cs', 'document', jsonb_build_object('path', 'staff/su/cs.pdf', 'sha256', test.su_sha('cs'))));
insert into su select 'signed_va', public.sign_request_sign(test.id('su_fin'), (test.su('sr_va') ->> 'id')::uuid, jsonb_build_object('drawn_signature', 'signatures/su/fin.png',
  'consent_text', 'One signature', 'document_sha256', test.su_sha('va')));
select test.eq('package: a drawn signature', public.server_signing_package_record(test.id('su_fin'), jsonb_build_object('portal', 'staff', 'method', 'drawn',
  'documents', jsonb_build_array(jsonb_build_object('signature_request_id', test.su('signed_va') ->> 'signature_request_id', 'title', 'VA agreement')))) ->> 'documents', '1');

-- ================================================================ 3. the owner's own checklist
select test.ok('checklist: the owner''s signables, without payments, each with where it is signed',
  (select bool_and(i ->> 'how' in ('screen', 'paper', 'banking', 'registry')) and count(*) > 0 and bool_and(i ->> 'status' in ('done', 'open'))
     from jsonb_array_elements(public.server_my_signing_checklist(test.id('su_olga')) -> 'items') i));
select test.eq('checklist: done and total counted', (public.server_my_signing_checklist(test.id('su_olga')) ->> 'total')::integer,
  jsonb_array_length(public.server_my_signing_checklist(test.id('su_olga')) -> 'items'));
select test.eq('checklist: nobody''s without an owner record', public.server_my_signing_checklist(test.id('su_cs')) ->> 'total', '0');
insert into su select 'partner', app.partner_save(test.id('su_admin'), '{"business_name": "Su Car Hire", "contact_name": "Sue Partner", "email": "su.partner@example.test", "insurance_expiry": "2026-01-01"}');
insert into user_roles (user_id, role) values (test.id('su_cs'), 'owner');
update owners set user_id = test.id('su_cs') where id = (test.su('partner') ->> 'owner_id')::uuid;
select test.eq('checklist: a partner signs the partner agreement', public.server_my_signing_checklist(test.id('su_cs')) #>> '{items,0,code}', 'partner_agreement');

-- ================================================================ 4. partner insurance reminders
select app.vehicle_add(test.id('su_admin'), jsonb_build_object('supply_type', 'partner', 'partner_id', test.su('partner') ->> 'id', 'vin', '1SUPARTNER0000001', 'year', 2023, 'make', 'Kia', 'model', 'Rio'));
select test.eq('insurance: an expired policy raises one Admin task', app.partner_insurance_check(), 1);
select test.eq('insurance: the task names the partner, high priority', (select t.queue || '/' || t.priority || '/' || (t.title like 'Su Car Hire%expired%') from tasks t where t.task_type = 'partner_insurance'), 'admin/high/true');
select test.eq('insurance: not raised twice for the same expiry', app.partner_insurance_check(), 0);
select app.partner_save(test.id('su_admin'), jsonb_build_object('id', test.su('partner') ->> 'id', 'insurance_expiry', (app.today() + 10)::text));
select test.eq('insurance: a new expiry closes the old reminder', (select t.status from tasks t where t.task_type = 'partner_insurance' and t.dedupe_key like '%:2026-01-01'), 'done');
select test.eq('insurance: an expiry within the warning days raises a new one (normal priority)', app.partner_insurance_check(), 1);
select test.eq('insurance: the daily check runs it', (select count(*) from tasks t where t.task_type = 'partner_insurance' and t.status = 'open'), 1::bigint);
select app.partner_save(test.id('su_admin'), jsonb_build_object('id', test.su('partner') ->> 'id', 'insurance_expiry', (app.today() + 200)::text));
select test.eq('insurance: far enough ahead, nothing to do', app.partner_insurance_check(), 0);

-- ================================================================ 5. guide upkeep
insert into guide_sections (id, portal, kind, sort_order, slug, title, body_md, published_title, published_md, published_html, published_hidden, published_version, published_at)
values (test.id('gs:su'), 'owner', 'chapter', 900, 'su-upkeep', 'Su chapter', E'1. Press **Save**.\n\n![The screen](/guides/img/su-01-screen-desktop-aaaa.jpg "desktop")',
        'Su chapter', E'1. Press **Save**.\n\n![The screen](/guides/img/su-01-screen-desktop-aaaa.jpg "desktop")', '<img src="/guides/img/su-01-screen-desktop-aaaa.jpg">', false, 1, now());
update guides set version = 3 where portal = 'owner';
insert into su select 'upkeep', public.server_guide_upkeep_apply(jsonb_build_object('run', 'test', 'images', jsonb_build_array(jsonb_build_object(
  'old_url', '/guides/img/su-01-screen-desktop-aaaa.jpg', 'new_url', 'https://photos.example.test/guides/owner/upkeep-1.jpg', 'portal', 'owner', 'diff', 0.12, 'width', 1600, 'height', 900))));
select test.eq('upkeep: the image replaced in the draft, the published text and its HTML', (select (body_md like '%upkeep-1.jpg%')::text || '/' || (published_md like '%upkeep-1.jpg%') || '/'
  || (published_html like '%upkeep-1.jpg%') || '/' || (position('/guides/img/su-01' in body_md) = 0) from guide_sections where id = test.id('gs:su')), 'true/true/true/true');
select test.eq('upkeep: the section flagged for review with the old and new image', (select needs_review || '/' || (review_images #>> '{0,old_url}') || '/' || (review_images #>> '{0,diff}')
  from guide_sections where id = test.id('gs:su')), 'true//guides/img/su-01-screen-desktop-aaaa.jpg/0.12');
select test.eq('upkeep: the guide version goes up (its PDF shows as older); the replacement is recorded', (select version from guides where portal = 'owner') || '/'
  || (select count(*) from guide_images where replaces_url = '/guides/img/su-01-screen-desktop-aaaa.jpg'), '4/1');
select test.ok('upkeep: the run finds the replacement next time', exists (select 1 from jsonb_array_elements(public.server_guide_images_replaced()) x
  where x ->> 'url' = 'https://photos.example.test/guides/owner/upkeep-1.jpg' and x ->> 'replaces_url' = '/guides/img/su-01-screen-desktop-aaaa.jpg'));
select test.eq('upkeep: Admin > Settings > Guides counts the sections to review',
  (select (g ->> 'needs_review')::integer from jsonb_array_elements(test.su_read('su_admin', 'guides_admin', '{}')) g where g ->> 'portal' = 'owner'), 1);
select test.eq('upkeep: the guide''s section carries its review state', (select s ->> 'needs_review' from jsonb_array_elements(test.su_read('su_admin', 'guide_admin', '{"portal": "owner"}') -> 'sections') s
  where s ->> 'slug' = 'su-upkeep'), 'true');
select test.throws('suggestion: an Admin only', format($$select test.su_do('su_cs', 'guide_suggestion_record', jsonb_build_object('id', %L, 'body_md', 'New text here'))$$, test.id('gs:su')), null);
select test.su_do('su_admin', 'guide_suggestion_record', jsonb_build_object('id', test.id('gs:su'), 'body_md', E'1. Press **Save the draft**.\n\n![The screen](https://photos.example.test/guides/owner/upkeep-1.jpg "desktop")', 'model', 'fake-vision-v1'));
select test.eq('suggestion: kept beside the draft', (select (suggestion_md like '%Save the draft%')::text || '/' || suggestion_model || '/' || (body_md not like '%Save the draft%') from guide_sections where id = test.id('gs:su')), 'true/fake-vision-v1/true');
select test.su_do('su_admin', 'guide_review_resolve', jsonb_build_object('id', test.id('gs:su'), 'action', 'apply_suggestion'));
select test.eq('review: applying the suggestion makes it the draft (published with the next publish) and clears the flag',
  (select (body_md like '%Save the draft%')::text || '/' || needs_review || '/' || (suggestion_md is null) || '/' || draft_version || '/' || (published_md not like '%Save the draft%') from guide_sections where id = test.id('gs:su')),
  'true/false/true/2/true');
select test.throws('review: an unknown answer is refused', format($$select test.su_do('su_admin', 'guide_review_resolve', jsonb_build_object('id', %L, 'action', 'later'))$$, test.id('gs:su')), 'Unknown action');
select test.eq('vision: the guide review is an Admin''s, within the day''s allowance', (test.su_read('su_admin', 'ai_vision_gate', '{"purpose": "guide_review"}') ? 'allowed')::text, 'true');
select test.throws('vision: not for assistants', $$select test.su_read('su_cs', 'ai_vision_gate', '{"purpose": "guide_review"}')$$, null);
select test.eq('vision: a guide review call is recorded', test.su_do('su_admin', 'ai_call_record', '{"purpose": "guide_review", "model": "fake", "ok": true, "neurons": 12}') ? 'id', true);

-- the chapters CarmaCars updated: a chapter with the shipped text is replaced and published; an edited one gets a suggestion
insert into guide_sections (id, portal, kind, sort_order, slug, title, body_md, published_title, published_md, published_html, published_hidden, published_version, published_at, draft_version)
values (test.id('gs:su2'), 'investor', 'chapter', 900, 'su-shipped', 'Shipped', 'Old text.', 'Shipped', 'Old text.', '<p>Old text.</p>', false, 1, now() - interval '1 day', 1),
       (test.id('gs:su3'), 'investor', 'chapter', 901, 'su-edited', 'Edited', 'My own words.', 'Edited', 'My own words.', '<p>My own words.</p>', false, 2, now() - interval '1 day', 2);
update guides set version = 5, published_at = now() - interval '1 day' where portal = 'investor';
select test.eq('guide update: a chapter with the shipped text', app.guide_update_published_section('investor', 'su-shipped', md5('Old text.'), 'Shipped', null, 'New text.', '<p>New text.</p>'), 'updated');
select test.eq('guide update: its new text is the draft and the published copy', (select published_md || '/' || body_md || '/' || draft_version || '/' || published_version from guide_sections where id = test.id('gs:su2')), 'New text./New text./2/2');
select test.eq('guide update: a chapter an Admin edited', app.guide_update_published_section('investor', 'su-edited', md5('Original.'), 'Edited', null, 'New text.', '<p>New text.</p>'), 'suggested');
select test.eq('guide update: the Admin''s text is kept, the new one waits as a suggestion', (select published_md || '/' || suggestion_md || '/' || needs_review from guide_sections where id = test.id('gs:su3')), 'My own words./New text./true');
select test.eq('guide update: the guide''s version goes up once', (select version from guides where portal = 'investor'), 6);
select test.eq('guide update: a chapter not there yet is left to the seed', app.guide_update_published_section('investor', 'su-none', md5('x'), 'X', null, 'Y', '<p>Y</p>'), 'missing');

-- ================================================================ 6. the official form sources (0047)
select test.ok('sources: always, the corporation without a RIN and the unit number only', (select bool_and(p in (select x ->> 'path' from jsonb_array_elements(app.registry_sources()) x))
  from unnest(array['always', 'corporation.rin_missing', 'owner.unit', 'owner.legal_name']) p));
update owners set address_line2 = 'Unit 1204', registrant_identification_number = null where id = test.id('owner:su_olga');
select test.eq('context: the unit without its word, always ticked, no RIN yet', (select (c #>> '{owner,unit}') || '/' || (c ->> 'always') || '/' || (c #>> '{corporation,rin_missing}')
  from app.registry_context(test.id('vehicle:su_car')) c), '1204/true/true');
select test.ok('transforms: the registry''s date style is offered', (app.form_templates(test.id('su_admin')) -> 'transforms') ? 'date:YYYY/MM/DD');
select test.ok('forms: every draft names what each form is for and what it leaves blank', (select bool_and(notes like '%Left blank on purpose%') from pdf_templates where is_current));

-- ================================================================ 7. privileges
select test.ok('privileges: the new tables are read by their signer or an Admin only (row-level security on)',
  (select bool_and(relrowsecurity) from pg_class where relname in ('signing_packages', 'signing_package_documents')));
select test.ok('privileges: the server functions are the service role''s', not has_function_privilege('authenticated', 'public.server_signing_package_record(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.server_guide_upkeep_apply(jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_my_signing_checklist(uuid)', 'execute'));
