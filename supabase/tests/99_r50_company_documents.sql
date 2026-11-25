-- 99: Admin > Company documents (migration 5060, release 50; docs/changes/2026-11-25-r50-company-documents.md).
-- A new document and a new version (every version kept, the latest shown), the kinds, the file of one version, archiving,
-- a document to sign (fill-ins, the signers, sent, signed only by its listed signers, frozen after the first signature, a
-- new version restarts the signing, the signed copy filed and both told), Admins only (every staff function, field staff,
-- an investor, an owner and a renter refused through the door and the tables), the connector's list_company_documents,
-- company_document_upload (a PDF, or a text to sign) and company_document_fields (preview, confirm), the table and function
-- rules. The text signed here is dummy text: the real agreement is never in the repository. Fixtures start with "cdoc_";
-- every address is example.test.
select test.suite('99 r50 company documents');
create temp table cdoc_ps as select id, api_access_enabled e, api_calls_per_minute n, esign_strict x from program_settings;
-- the signing session itself is 99_esign_everywhere's to test: here the signature goes straight to sign_request_sign
update program_settings set api_access_enabled = true, api_calls_per_minute = 600, esign_strict = false where id is not null;
select test.mk_user('cdoc_admin', 'admin');
select test.mk_user('cdoc_admin2', 'admin');
select test.mk_user('cdoc_admin3', 'admin');
select test.mk_user('cdoc_fin', 'va', 'finance');
select test.mk_user('cdoc_fleet', 'va', 'fleet');
select test.mk_user('cdoc_cs', 'va', 'cs');
select test.mk_user('cdoc_sales', 'va', 'sales');
select test.mk_user('cdoc_field', 'field');
select test.mk_user('cdoc_inv', 'renter');
select test.mk_user('cdoc_renter', 'renter');
select test.mk_owner('cdoc_owner');
insert into investors (id, user_id, legal_name, investor_type, status, email) values
  (test.id('cdoc:inv'), test.id('cdoc_inv'), 'Ivy Example', 'individual', 'active', 'cdoc_inv@example.test');
create function test.cdoc_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'admin_do', p_name, p) $$;
create function test.cdoc_read(p_user text) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'admin_read', 'company_documents', '{}') $$;
create function test.cdoc_path(p_folder text, p_file text) returns text language sql as $$
  select 'company-documents/' || test.id(p_folder) || '/' || test.id(p_file) || '.pdf' $$;

-- ================================================================ 1. a new document, then a new version
create temp table cdoc_a as select test.cdoc_do('cdoc_admin', 'company_document_save', jsonb_build_object('kind', 'shareholder_agreement', 'title', 'Shareholder Agreement',
  'notes', 'Signed by both shareholders', 'path', test.cdoc_path('cdoc:doc', 'cdoc:f1'), 'size_bytes', 120000, 'sha256', repeat('a', 64))) as r;
select test.eq('a new document is version 1', (select (r ->> 'version') || '/' || (r ->> 'new') from cdoc_a), '1/true');
create temp table cdoc_b as select test.cdoc_do('cdoc_admin', 'company_document_save', jsonb_build_object('document', (select r ->> 'document' from cdoc_a),
  'path', test.cdoc_path('cdoc:doc', 'cdoc:f2'), 'size_bytes', 130000, 'note', 'Countersigned copy')) as r;
select test.eq('a new version is version 2 of the same document', (select (r ->> 'version') || '/' || (r ->> 'new') || '/' || (r ->> 'document') from cdoc_b),
  '2/false/' || (select r ->> 'document' from cdoc_a));
select test.eq('both versions are kept, never overwritten', (select string_agg(version || ':' || path, ',' order by version) from company_document_versions where document_id = (select (r ->> 'document')::uuid from cdoc_a)),
  '1:' || test.cdoc_path('cdoc:doc', 'cdoc:f1') || ',2:' || test.cdoc_path('cdoc:doc', 'cdoc:f2'));
select test.eq('the notes stay with the document', (select notes from company_documents where id = (select (r ->> 'document')::uuid from cdoc_a)), 'Signed by both shareholders');
select test.eq('the list: six kinds in order', (select string_agg(k ->> 'key', ',') from jsonb_array_elements(test.cdoc_read('cdoc_admin') -> 'kinds') k),
  'shareholder_agreement,articles,franchise_agreement,insurance_policy,lease,other');
select test.eq('the list: the latest version with its history, never a storage path',
  (select (d ->> 'version') || '/' || jsonb_array_length(d -> 'history') || '/' || (d -> 'history' -> 0 ->> 'note') || '/' || (d::text like '%company-documents/%')::text
     from jsonb_array_elements(test.cdoc_read('cdoc_admin') -> 'kinds') k, jsonb_array_elements(k -> 'documents') d where d ->> 'id' = (select r ->> 'document' from cdoc_a)),
  '2/2/Countersigned copy/false');
select test.eq('an Admin opens an earlier version: its bucket and path', (public.door(test.id('cdoc_admin'), 'aal2', 'admin_read', 'company_document_file',
  jsonb_build_object('version', (select id from company_document_versions where version = 1 and document_id = (select (r ->> 'document')::uuid from cdoc_a)))) ->> 'path'),
  test.cdoc_path('cdoc:doc', 'cdoc:f1'));

-- ================================================================ 2. what is refused
select test.throws('a kind outside the list', format($s$select test.cdoc_do('cdoc_admin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'pitch_deck', 'title', 'Deck', 'path', test.cdoc_path('cdoc:doc', 'cdoc:f3'), 'size_bytes', 10)), '%Choose the kind%');
select test.throws('a file outside company-documents/', format($s$select test.cdoc_do('cdoc_admin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'lease', 'title', 'Unit lease', 'path', 'investor-library/x.pdf', 'size_bytes', 10)), '%Upload the PDF%');
select test.throws('a file of 20 MB or more', format($s$select test.cdoc_do('cdoc_admin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'lease', 'title', 'Unit lease', 'path', test.cdoc_path('cdoc:doc', 'cdoc:f4'), 'size_bytes', 20971521)), '%20 MB%');
select test.throws('a title under 3 characters', format($s$select test.cdoc_do('cdoc_admin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'lease', 'title', 'L', 'path', test.cdoc_path('cdoc:doc', 'cdoc:f5'), 'size_bytes', 10)), '%title%');

-- ================================================================ 3. Admins only: the door
select test.throws('Finance cannot list them', $s$select test.cdoc_read('cdoc_fin')$s$);
select test.throws('Fleet cannot list them', $s$select test.cdoc_read('cdoc_fleet')$s$);
select test.throws('customer service cannot list them', $s$select test.cdoc_read('cdoc_cs')$s$);
select test.throws('Sales cannot list them', $s$select test.cdoc_read('cdoc_sales')$s$);
select test.throws('field staff cannot list them', $s$select test.cdoc_read('cdoc_field')$s$);
select test.throws('an investor cannot list them', $s$select test.cdoc_read('cdoc_inv')$s$);
select test.throws('an owner cannot list them', $s$select test.cdoc_read('cdoc_owner')$s$);
select test.throws('a renter cannot list them', $s$select test.cdoc_read('cdoc_renter')$s$);
select test.throws('Finance cannot open a file', format($s$select public.door(%L, 'aal2', 'admin_read', 'company_document_file', %L)$s$, test.id('cdoc_fin'),
  jsonb_build_object('version', (select id from company_document_versions where version = 1 and document_id = (select (r ->> 'document')::uuid from cdoc_a)))));
select test.throws('an investor cannot open a file', format($s$select public.door(%L, 'aal2', 'admin_read', 'company_document_file', %L)$s$, test.id('cdoc_inv'),
  jsonb_build_object('version', (select id from company_document_versions where version = 1 and document_id = (select (r ->> 'document')::uuid from cdoc_a)))));
select test.throws('Finance cannot upload one', format($s$select test.cdoc_do('cdoc_fin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'other', 'title', 'Not allowed', 'path', test.cdoc_path('cdoc:doc', 'cdoc:f6'), 'size_bytes', 10)));
select test.throws('an owner cannot archive one', format($s$select test.cdoc_do('cdoc_owner', 'company_document_archive', %L)$s$, jsonb_build_object('document', (select r ->> 'document' from cdoc_a))));

-- ================================================================ 4. Admins only: the tables (row-level security)
select test.login(test.id('cdoc_admin'));
select test.eq('an Admin reads the tables', test.visible('select * from company_documents') > 0 and test.visible('select * from company_document_versions') > 0, true);
select test.logout();
create function test.cdoc_rows(p_user text) returns text language plpgsql as $$
declare n1 bigint; n2 bigint; n3 bigint;
begin
  perform test.login(test.id(p_user));
  n1 := test.visible('select * from company_documents');
  n2 := test.visible('select * from company_document_versions');
  n3 := test.visible('select * from company_document_signers');
  perform test.logout();
  return n1 || '/' || n2 || '/' || n3;
end $$;
create function test.cdoc_rows_docs(p_user text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform test.login(test.id(p_user));
  n := test.visible('select * from documents where kind::text = ''company_document''');
  perform test.logout();
  return n;
end $$;
create function test.cdoc_rows_sig(p_user text) returns text language plpgsql as $$
declare a bigint; b bigint; c bigint;
begin
  perform test.login(test.id(p_user));
  a := test.visible('select * from sign_requests where doc_type = ''company_document''');
  b := test.visible('select * from signature_requests x where exists (select 1 from sign_requests r where r.signature_request_id = x.id and r.doc_type = ''company_document'')');
  c := test.visible('select * from signature_records where signer_role = ''company_signer''');
  perform test.logout();
  return a || '/' || b || '/' || c;
end $$;
select test.eq('Finance reads no row of the tables', test.cdoc_rows('cdoc_fin'), '0/0/0');
select test.eq('Fleet reads no row', test.cdoc_rows('cdoc_fleet'), '0/0/0');
select test.eq('customer service reads no row', test.cdoc_rows('cdoc_cs'), '0/0/0');
select test.eq('Sales reads no row', test.cdoc_rows('cdoc_sales'), '0/0/0');
select test.eq('field staff read no row', test.cdoc_rows('cdoc_field'), '0/0/0');
select test.eq('an investor reads no row', test.cdoc_rows('cdoc_inv'), '0/0/0');
select test.eq('an owner reads no row', test.cdoc_rows('cdoc_owner'), '0/0/0');
select test.eq('a renter reads no row', test.cdoc_rows('cdoc_renter'), '0/0/0');
select test.ok('the anonymous role has no grant on either table',
  not has_table_privilege('anon', 'company_documents', 'select') and not has_table_privilege('anon', 'company_document_versions', 'select'));
select test.login(test.id('cdoc_fin'));
select test.throws('Finance cannot insert a row directly', format($s$insert into company_documents (kind, title) values ('other', 'Sneaky')$s$));
select test.logout();

-- ================================================================ 5. archiving
select test.lives('an Admin archives the document', format($s$select test.cdoc_do('cdoc_admin', 'company_document_archive', %L)$s$, jsonb_build_object('document', (select r ->> 'document' from cdoc_a), 'archived', true)));
select test.eq('...it stays listed as archived, its versions kept', (select (d ->> 'archived') || '/' || jsonb_array_length(d -> 'history')
  from jsonb_array_elements(test.cdoc_read('cdoc_admin') -> 'kinds') k, jsonb_array_elements(k -> 'documents') d where d ->> 'id' = (select r ->> 'document' from cdoc_a)), 'true/2');
select test.lives('...and is brought back', format($s$select test.cdoc_do('cdoc_admin', 'company_document_archive', %L)$s$, jsonb_build_object('document', (select r ->> 'document' from cdoc_a), 'archived', false)));
select test.eq('...not archived', (select archived_at is null from company_documents where id = (select (r ->> 'document')::uuid from cdoc_a)), true);

-- ================================================================ 6. a document to sign
create function test.cdoc_csha(p_version text) returns text language sql as $$ select app.company_document_content_sha(body_md, fields) from company_document_versions where id = p_version::uuid $$;
create temp table cdoc_body as select E'### 1. Parties\n\nThis dummy agreement is between {{holdco_a}} and {{holdco_b}}.\n\n### 2. Money\n\nEach puts in {{amount}}.\n' as b;
select test.throws('a signer must be an Admin', format($s$select test.cdoc_do('cdoc_admin', 'company_document_save', %L)$s$,
  jsonb_build_object('kind', 'shareholder_agreement', 'title', 'Dummy agreement', 'body_md', (select b from cdoc_body), 'signers', jsonb_build_array(jsonb_build_object('user_id', test.id('cdoc_fin'), 'role_label', 'Side A')))), '%active Admin%');
create temp table cdoc_s1 as select test.cdoc_do('cdoc_admin', 'company_document_save', jsonb_build_object('kind', 'shareholder_agreement', 'title', 'Dummy agreement',
  'body_md', (select b from cdoc_body), 'fields', jsonb_build_object('holdco_a', 'Example Holdco A Inc.'),
  'signers', jsonb_build_array(jsonb_build_object('user_id', test.id('cdoc_admin'), 'role_label', 'Principal of Side A, and for Holdco A'),
                               jsonb_build_object('user_id', test.id('cdoc_admin2'), 'role_label', 'Principal of Side B, and for Holdco B')))) as r;
select test.eq('a text to sign is a draft with the fill-ins still missing', (select (r ->> 'status') || '/' || (r -> 'missing')::text || '/' || (r ->> 'ready') from cdoc_s1), 'draft/["holdco_b", "amount"]/false');
select test.throws('it is not sent while a fill-in is missing', format($s$select test.cdoc_do('cdoc_admin', 'company_document_send', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1), 'path', test.cdoc_path((select r ->> 'document' from cdoc_s1), 'cdoc:p1'), 'sha256', repeat('c', 64),
  'content_sha256', test.cdoc_csha((select r ->> 'version_id' from cdoc_s1)))), '%Fill in first: holdco_b, amount%');
create function test.cdoc_dpath(p_doc text, p_file text) returns text language sql as $$ select 'company-documents/' || p_doc || '/' || test.id(p_file) || '.pdf' $$;
select test.eq('the fill-ins complete it', test.cdoc_do('cdoc_admin', 'company_document_fields', jsonb_build_object('document', (select r ->> 'document' from cdoc_s1),
  'fields', jsonb_build_object('holdco_b', 'Example Holdco B Inc.', 'amount', '$10')))->> 'ready', 'true');
select test.throws('a PDF rendered before the text or fill-ins changed is refused', format($s$select test.cdoc_do('cdoc_admin', 'company_document_send', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1), 'path', test.cdoc_dpath((select r ->> 'document' from cdoc_s1), 'cdoc:p1'), 'sha256', repeat('c', 64),
    'content_sha256', repeat('0', 64))), '%changed while the PDF was made%');
create temp table cdoc_send as select test.cdoc_do('cdoc_admin', 'company_document_send', jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1),
  'path', test.cdoc_dpath((select r ->> 'document' from cdoc_s1), 'cdoc:p1'), 'sha256', repeat('c', 64), 'content_sha256', test.cdoc_csha((select r ->> 'version_id' from cdoc_s1)))) as r;
select test.eq('sent: one request per signer, to sign', (select (r ->> 'status') || '/' || (r ->> 'signers') from cdoc_send), 'to_sign/2');
select test.eq('each signer is told once, in Admin and by email', (select count(distinct payload ->> 'recipient_user_id') || '/' || count(*) from app_events
  where code = 'admin_company_document_to_sign' and entity_id = (select (r ->> 'document')::uuid from cdoc_s1)), '2/2');
select test.eq('the requests are the platform''s own (sign_requests, signature_requests, the documents row of kind company_document)',
  (select count(*) from sign_requests r join signature_requests x on x.id = r.signature_request_id join documents d on d.id = r.document_id
    where r.doc_type = 'company_document' and d.kind::text = 'company_document' and r.extra ->> 'company_document_version_id' = (select r2.r ->> 'version_id' from cdoc_s1 r2)), 2::bigint);
select app.process_events();
select test.eq('...the two emails are built for the two signers, sent on their own (not the digest), nothing missing', (select count(distinct recipient_user_id) || '/' || count(*) filter (where missing_variables is null or cardinality(missing_variables) = 0)
  from notification_outbox where code = 'admin_company_document_to_sign' and entity_id = (select (r ->> 'document')::uuid from cdoc_s1) and coalesce(channel, 'email') = 'email' and status = 'queued'), '2/2');
select test.eq('...and the Admin portal''s notice (the bell), one each', (select count(distinct user_id) || '/' || count(*) from notifications where code = 'admin_company_document_to_sign'
  and url like '%/admin/company-documents/' || (select r ->> 'document' from cdoc_s1)), '2/2');
create function test.cdoc_req(p_user text) returns uuid language sql as $$
  select s.sign_request_id from company_document_signers s where s.user_id = test.id(p_user) and s.version_id = (select (r ->> 'version_id')::uuid from cdoc_s1) $$;
create function test.cdoc_sign(p_user text, p_req uuid, p_ack boolean default true) returns jsonb language sql as $$
  select public.sign_request_sign(test.id(p_user), p_req, jsonb_build_object('typed_name', (select full_name from users where id = test.id(p_user)), 'consent_text', 'I sign this dummy agreement',
    'document_sha256', repeat('c', 64), 'company_ack', p_ack, 'ip', '203.0.113.7', 'user_agent', 'test')) $$;
select test.throws('an Admin who is not a listed signer cannot sign another''s request', format($s$select test.cdoc_sign('cdoc_admin3', %L)$s$, test.cdoc_req('cdoc_admin')), '%Not found%');
select test.throws('Finance cannot sign it', format($s$select test.cdoc_sign('cdoc_fin', %L)$s$, test.cdoc_req('cdoc_admin')), '%Not found%');
select test.throws('a signer ticks "I have read it and had the chance to get legal advice" first', format($s$select test.cdoc_sign('cdoc_admin', %L, false)$s$, test.cdoc_req('cdoc_admin')), '%legal advice%');
select test.lives('the first signer signs', format($s$select test.cdoc_sign('cdoc_admin', %L)$s$, test.cdoc_req('cdoc_admin')));
select test.eq('...recorded as the platform records every signature: name, role, time, IP, device, the document''s hash',
  (select x.signer_role || '/' || x.signer_name || '/' || (x.signed_at is not null)::text || '/' || host(x.ip_address) || '/' || x.user_agent || '/' || x.document_sha256
     from sign_requests r join signature_records x on x.id = r.signature_record_id where r.id = test.cdoc_req('cdoc_admin')),
  'company_signer/Cdoc Admin/true/203.0.113.7/test/' || repeat('c', 64));
select test.eq('...the version still waits for the other signer', (select status from company_document_versions where id = (select (r ->> 'version_id')::uuid from cdoc_s1)), 'to_sign');
select test.throws('after the first signature the fill-ins are frozen', format($s$select test.cdoc_do('cdoc_admin', 'company_document_fields', %L)$s$,
  jsonb_build_object('document', (select r ->> 'document' from cdoc_s1), 'fields', jsonb_build_object('amount', '$20'))), '%new version%');
select test.throws('...and so is the body, in the table itself', format($s$update company_document_versions set body_md = 'changed' where id = %L$s$, (select r ->> 'version_id' from cdoc_s1)), '%new version%');
select test.throws('...and the signers', format($s$delete from company_document_signers where version_id = %L$s$, (select r ->> 'version_id' from cdoc_s1)), '%new version%');
select test.throws('the signed copy waits for everyone', format($s$select test.cdoc_do('cdoc_admin', 'company_document_attach_signed', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1))), '%Not everyone%');
select test.lives('the second signer signs', format($s$select test.cdoc_sign('cdoc_admin2', %L)$s$, test.cdoc_req('cdoc_admin2')));
select test.eq('...the version is signed', (select status || '/' || (signed_at is not null)::text from company_document_versions where id = (select (r ->> 'version_id')::uuid from cdoc_s1)), 'signed/true');
select test.eq('the facts of the signed copy: both signers with their records',
  (select string_agg((x ->> 'role_label') || ':' || (x ->> 'status') || ':' || (x ->> 'ip_address'), ', ' order by x ->> 'role_label')
     from jsonb_array_elements(public.door(test.id('cdoc_admin'), 'aal2', 'admin_read', 'company_document_sign_facts', jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1))) -> 'signers') x),
  'Principal of Side A, and for Holdco A:signed:203.0.113.7, Principal of Side B, and for Holdco B:signed:203.0.113.7');
select test.lives('the signed copy is filed as the version''s PDF', format($s$select test.cdoc_do('cdoc_admin2', 'company_document_attach_signed', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1), 'path', 'company-documents/' || (select r ->> 'document' from cdoc_s1) || '/' || (select r ->> 'version_id' from cdoc_s1) || '-signed.pdf',
                     'sha256', repeat('d', 64), 'size_bytes', 5000)));
select test.eq('...both signers are told, once each, with the version to open', (select count(distinct payload ->> 'recipient_user_id') || '/' || count(*) || '/' || bool_and(payload ->> 'company_document_version_id' = (select r ->> 'version_id' from cdoc_s1))::text
  from app_events where code = 'admin_company_document_signed' and entity_id = (select (r ->> 'document')::uuid from cdoc_s1)), '2/2/true');
select app.process_events();
select test.eq('...their two emails are built, pointing at the signed copy in Admin, never a link that works without sign-in',
  (select count(distinct recipient_user_id) || '/' || bool_and(payload ->> 'company_document_version_id' = (select r ->> 'version_id' from cdoc_s1) and not (payload ? 'signed_agreement_url'))::text
  from notification_outbox where code = 'admin_company_document_signed' and entity_id = (select (r ->> 'document')::uuid from cdoc_s1) and coalesce(channel, 'email') = 'email' and status = 'queued'), '2/true');
select test.eq('...and an Admin opens it from the agreements bucket', (public.door(test.id('cdoc_admin3'), 'aal2', 'admin_read', 'company_document_file', jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1))) ->> 'bucket'), 'agreements');
-- a new version restarts the signing
create temp table cdoc_s2 as select test.cdoc_do('cdoc_admin', 'company_document_save', jsonb_build_object('document', (select r ->> 'document' from cdoc_s1),
  'body_md', (select b from cdoc_body) || E'\nA dummy change.', 'fields', jsonb_build_object('holdco_a', 'A', 'holdco_b', 'B', 'amount', '$1'),
  'signers', jsonb_build_array(jsonb_build_object('user_id', test.id('cdoc_admin'), 'role_label', 'Side A'), jsonb_build_object('user_id', test.id('cdoc_admin2'), 'role_label', 'Side B')))) as r;
select test.eq('a change is version 2, a draft again, ready to send', (select (r ->> 'version') || '/' || (r ->> 'status') || '/' || (r ->> 'ready') from cdoc_s2), '2/draft/true');
select test.eq('...version 1 stays signed', (select status from company_document_versions where id = (select (r ->> 'version_id')::uuid from cdoc_s1)), 'signed');
select test.lives('version 2 is sent', format($s$select test.cdoc_do('cdoc_admin', 'company_document_send', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s2), 'path', test.cdoc_dpath((select r ->> 'document' from cdoc_s1), 'cdoc:p2'), 'sha256', repeat('e', 64),
  'content_sha256', test.cdoc_csha((select r ->> 'version_id' from cdoc_s2)))));
create function test.cdoc_req2(p_user text) returns uuid language sql as $$
  select s.sign_request_id from company_document_signers s where s.user_id = test.id(p_user) and s.version_id = (select (r ->> 'version_id')::uuid from cdoc_s2) $$;
select test.lives('one signer signs version 2', format($s$select public.sign_request_sign(%L, %L, %L)$s$, test.id('cdoc_admin'), test.cdoc_req2('cdoc_admin'),
  jsonb_build_object('typed_name', 'Cdoc Admin', 'consent_text', 'I sign this dummy agreement', 'document_sha256', repeat('e', 64), 'company_ack', true)));
create temp table cdoc_s3 as select test.cdoc_do('cdoc_admin', 'company_document_save', jsonb_build_object('document', (select r ->> 'document' from cdoc_s1),
  'body_md', 'Dummy text, version 3.', 'signers', jsonb_build_array(jsonb_build_object('user_id', test.id('cdoc_admin'), 'role_label', 'Side A')))) as r;
select test.eq('version 3 voids only the open request of version 2', (select string_agg(r.status, ',' order by r.status) from sign_requests r
  where r.extra ->> 'company_document_version_id' = (select x.r ->> 'version_id' from cdoc_s2 x)), 'signed,voided');
select test.eq('...the signature already in stays linked to its signer; the voided request is unlinked',
  (select string_agg(u.full_name || ':' || coalesce(r.status, 'unlinked'), ', ' order by u.full_name) from company_document_signers s join users u on u.id = s.user_id
     left join sign_requests r on r.id = s.sign_request_id where s.version_id = (select (x.r ->> 'version_id')::uuid from cdoc_s2 x)), 'Cdoc Admin:signed, Cdoc Admin2:unlinked');
select test.throws('...and version 2''s text stays frozen', format($s$update company_document_versions set fields = '{}' where id = %L$s$, (select r ->> 'version_id' from cdoc_s2)), '%new version%');
select test.throws('an earlier version''s fill-ins cannot be edited', format($s$select test.cdoc_do('cdoc_admin', 'company_document_fields', %L)$s$,
  jsonb_build_object('version', (select r ->> 'version_id' from cdoc_s1), 'fields', jsonb_build_object('amount', '$99'))), '%Only the latest version%');
select test.eq('...and version 2 is no longer waiting for signatures', (select status from company_document_versions where id = (select (r ->> 'version_id')::uuid from cdoc_s2)), 'draft');
select test.eq('the list never carries the body', (test.cdoc_read('cdoc_admin')::text like '%dummy agreement is between%'), false);
select test.eq('the page of one document does, for an Admin', (public.door(test.id('cdoc_admin3'), 'aal2', 'admin_read', 'company_document', jsonb_build_object('document', (select r ->> 'document' from cdoc_s1))) #>> '{current,body_md}'), 'Dummy text, version 3.');
select test.throws('Finance cannot read the page of one document', format($s$select public.door(%L, 'aal2', 'admin_read', 'company_document', %L)$s$, test.id('cdoc_fin'), jsonb_build_object('document', (select r ->> 'document' from cdoc_s1))));
select test.eq('with signers and requests in place, Finance still reads no row of the tables', test.cdoc_rows('cdoc_fin'), '0/0/0');
select test.eq('...nor does an investor, an owner or field staff', test.cdoc_rows('cdoc_inv') || ' ' || test.cdoc_rows('cdoc_owner') || ' ' || test.cdoc_rows('cdoc_field'), '0/0/0 0/0/0 0/0/0');
select test.login(test.id('cdoc_admin3'));
select test.eq('an Admin who does not sign still reads the signers', test.visible('select * from company_document_signers') > 0, true);
select test.logout();
select test.eq('Finance does not see the documents rows of a company document (the VA read policy)', test.cdoc_rows_docs('cdoc_fin'), 0::bigint);
select test.eq('...nor its sign requests or signature records', test.cdoc_rows_sig('cdoc_fin'), '0/0/0');

-- ================================================================ 7. the connector
create function test.cdoc_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('cdoc_admin'), test.id('cdoc_admin'), 'Laptop', array['admin:read', 'admin:write'], test.cdoc_h('cc_live_cdoc_full'), 'cc_live_cdoc');
select app.api_key_create(test.id('cdoc_admin'), test.id('cdoc_admin'), 'Read', array['admin:read'], test.cdoc_h('cc_live_cdoc_read'), 'cc_live_cdor');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('cdoc_fin'), kind, 'Not allowed', 'cc_live_cdof', test.cdoc_h('cc_live_cdoc_fin'), scopes, test.id('cdoc_admin') from api_keys where key_hash = test.cdoc_h('cc_live_cdoc_full');
create function test.cdoc_api(p_key text, p_tool text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.cdoc_h(p_key), p_tool, a, 'test') $$;
create temp table cdoc_args as select jsonb_build_object('title', 'Signed Shareholder Agreement', 'kind', 'shareholder_agreement', 'pdf_base64', 'JVBERi0xLjQKJSBjZG9j', 'notes', 'The signed copy') as a;

select test.eq('list_company_documents with a read key: the kinds', jsonb_array_length(test.cdoc_api('cc_live_cdoc_read', 'list_company_documents', '{}') #> '{result,kinds}'), 6);
select test.eq('list_company_documents for a key whose person is not an Admin is refused', test.cdoc_api('cc_live_cdoc_fin', 'list_company_documents', '{}') ->> 'ok', 'false');
select test.eq('a read key cannot upload', test.cdoc_api('cc_live_cdoc_read', 'company_document_upload', (select a from cdoc_args)) ->> 'status', '403');
create temp table cdoc_pv as select test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a from cdoc_args)) as r;
select test.eq('the preview changes nothing and says it is a new document', (select (r #>> '{result,preview}') || '/' || (r #>> '{result,will_do}') from cdoc_pv),
  'true/Add "Signed Shareholder Agreement" (Shareholder agreement) to Admin > Company documents as a new document, version 1. Only Admins can open it.');
select test.eq('...the bytes never reach the log, only their fingerprint', (select bool_and(not (args ? 'pdf_base64') and (args ? 'pdf_sha256' or tool = 'company_document_upload' and not ok)) from api_calls where tool like 'company_document_upload%'), true);
select test.eq('a confirm with other arguments is refused', test.cdoc_api('cc_live_cdoc_full', 'company_document_upload',
  (select a || jsonb_build_object('title', 'Other title', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cdoc_pv)) from cdoc_args)) ->> 'error', 'The arguments differ from the preview: preview again with these');
create temp table cdoc_cf as select test.cdoc_api('cc_live_cdoc_full', 'company_document_upload',
  (select a || jsonb_build_object('confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cdoc_pv)) from cdoc_args)) as r;
select test.eq('the confirm hands the checked arguments to the web layer', (select (r #>> '{result,run}') || '/' || (r #>> '{result,params,kind}') || '/' || ((r #> '{result,params}') ? 'pdf_base64')::text from cdoc_cf),
  'company_doc/shareholder_agreement/false');
create temp table cdoc_rec as select public.server_api_company_document_record(test.cdoc_h('cc_live_cdoc_full'), (select (r #>> '{result,preview_id}')::uuid from cdoc_pv),
  test.cdoc_path('cdoc:api', 'cdoc:g1'), 2048, repeat('b', 64), 'test') as r;
select test.eq('the stored PDF is recorded as a new document, version 1', (select (r ->> 'done') || '/' || (r ->> 'version') || '/' || (r ->> 'new') || '/' || (r ->> 'admin_path') from cdoc_rec),
  'true/1/true//admin/company-documents/' || (select r ->> 'document' from cdoc_rec));
select test.eq('...with its kind, title and notes', (select kind || '/' || title || '/' || notes from company_documents where id = (select (r ->> 'document')::uuid from cdoc_rec)),
  'shareholder_agreement/Signed Shareholder Agreement/The signed copy');
select test.throws('it is recorded once only', format($s$select public.server_api_company_document_record(%L, %L, %L, 2048, %L, 'test')$s$,
  test.cdoc_h('cc_live_cdoc_full'), (select r #>> '{result,preview_id}' from cdoc_pv), test.cdoc_path('cdoc:api', 'cdoc:g2'), repeat('b', 64)), '%Already stored%');
select test.throws('a preview never confirmed cannot be recorded', format($s$select public.server_api_company_document_record(%L, %L, %L, 2048, %L, 'test')$s$,
  test.cdoc_h('cc_live_cdoc_full'), (test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a from cdoc_args)) #>> '{result,preview_id}'), test.cdoc_path('cdoc:api', 'cdoc:g3'), repeat('b', 64)), '%Not a confirmed%');
select test.eq('the same title and kind again: the preview says a new version', test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a from cdoc_args)) #>> '{result,will_do}',
  'Save version 2 of "Signed Shareholder Agreement" (Shareholder agreement) in Admin > Company documents; the earlier versions are kept. Only Admins can open it.');
select test.eq('an unknown kind is refused', test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a || '{"kind": "deck"}' from cdoc_args)) ->> 'status', '400');
select test.eq('a key whose person is not an Admin cannot upload', test.cdoc_api('cc_live_cdoc_fin', 'company_document_upload', (select a from cdoc_args)) ->> 'ok', 'false');
select test.eq('pdf_base64 and body_md together are refused', test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a || '{"body_md": "x"}' from cdoc_args)) ->> 'status', '400');
-- a text to sign through the connector (dummy text)
create temp table cdoc_targs as select jsonb_build_object('title', 'Dummy connector agreement', 'kind', 'shareholder_agreement',
  'body_md', E'### Parties\n\n{{side_a}} and {{side_b}} agree to this dummy text.', 'fields', jsonb_build_object('side_a', 'Example A Inc.'),
  'signers', jsonb_build_array(jsonb_build_object('email', 'cdoc_admin@example.test', 'role', 'Side A'), 'cdoc_admin2@example.test')) as a;
select test.eq('a signer who is not an Admin is refused', test.cdoc_api('cc_live_cdoc_full', 'company_document_upload',
  (select a || jsonb_build_object('signers', jsonb_build_array('cdoc_fin@example.test')) from cdoc_targs)) ->> 'error', 'signers: cdoc_fin@example.test is not an active Admin');
create temp table cdoc_tpv as select test.cdoc_api('cc_live_cdoc_full', 'company_document_upload', (select a from cdoc_targs)) as r;
select test.eq('the preview of a text to sign names what is still to fill in', (select r #>> '{result,will_do}' from cdoc_tpv),
  'Add "Dummy connector agreement" (Shareholder agreement) to Admin > Company documents as a new document, version 1. It is a document to sign; still to fill in (company_document_fields): side_b.');
select test.eq('...the fill-ins'' values never reach the previews or the log: their names and a hash only',
  (select bool_and(not (x.args ? 'fields') and x.args::text not like '%Example A Inc.%' and coalesce(x.before::text, '') not like '%Example A Inc.%') from api_calls x where x.target = 'Dummy connector agreement')
  and (select bool_and(not (p.args ? 'fields') and p.args ? 'fields_sha256' and p.args -> 'field_keys' = '["side_a"]'::jsonb) from api_previews p where p.tool = 'company_document_upload' and p.args ->> 'title' = 'Dummy connector agreement'), true);
select test.eq('...the body never reaches the log, only its fingerprint', (select bool_and(not (args ? 'body_md')) and bool_or(args ? 'body_sha256') from api_calls where tool like 'company_document_upload%' and target = 'Dummy connector agreement'), true);
create temp table cdoc_tcf as select test.cdoc_api('cc_live_cdoc_full', 'company_document_upload',
  (select a || jsonb_build_object('confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cdoc_tpv)) from cdoc_targs)) as r;
select test.eq('the confirm saves a draft with the signers', (select (r #>> '{result,done}') || '/' || (r #>> '{result,status}') || '/' || (r #> '{result,missing}')::text from cdoc_tcf), 'true/draft/["side_b"]');
select test.eq('...the second signer''s role defaults to Signer', (select string_agg(role_label, ', ' order by sort_order) from company_document_signers where version_id = (select (r #>> '{result,version_id}')::uuid from cdoc_tcf)), 'Side A, Signer');
create temp table cdoc_fpv as select test.cdoc_api('cc_live_cdoc_full', 'company_document_fields', jsonb_build_object('document', (select r #>> '{result,document}' from cdoc_tcf), 'fields', jsonb_build_object('side_b', 'Example B Inc.'))) as r;
select test.eq('company_document_fields previews that the signers will be asked', (select r #>> '{result,will_do}' from cdoc_fpv),
  'Set the fill-ins of "Dummy connector agreement", version 1. Every fill-in is there: the document is rendered and each signer is asked to sign in Admin (an in-app notice and an email).');
create temp table cdoc_fcf as select test.cdoc_api('cc_live_cdoc_full', 'company_document_fields', jsonb_build_object('document', (select r #>> '{result,document}' from cdoc_tcf),
  'fields', jsonb_build_object('side_b', 'Example B Inc.'), 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cdoc_fpv))) as r;
select test.eq('...the confirm hands the web layer the version to render and send', (select (r #>> '{result,run}') || '/' || (r #>> '{result,params,ready}') from cdoc_fcf), 'company_doc_send/true');
select test.eq('a read key cannot set fill-ins', test.cdoc_api('cc_live_cdoc_read', 'company_document_fields', jsonb_build_object('document', (select r #>> '{result,document}' from cdoc_tcf), 'fields', '{}'::jsonb)) ->> 'status', '403');

-- ================================================================ 8. the table and function rules
select test.ok('row-level security, admin_all and the audit trigger on the three tables',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('company_documents', 'company_document_versions', 'company_document_signers'))
  and (select count(*) from pg_policies where tablename in ('company_documents', 'company_document_versions', 'company_document_signers')) = 3
  and (select count(*) from pg_policies where tablename in ('company_documents', 'company_document_versions', 'company_document_signers') and policyname = 'admin_all') = 3
  and (select count(*) from pg_trigger where tgname in ('audit_company_documents', 'audit_company_document_versions', 'audit_company_document_signers')) = 3);
select test.ok('the new functions are the server''s alone, with pg_temp last on the search path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where (p.proname like 'company\_document%' or p.proname in ('api_company_document_record', 'server_api_company_document_record', 'door_pre5060', 'api_call_pre5060', 'sign_request_sign_pre5060'))
                 and p.prosecdef
                 and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                      or not has_function_privilege('service_role', p.oid, 'execute')
                      or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg\_temp'))));
select test.ok('the foreign keys have indexes', exists (select 1 from pg_indexes where tablename = 'company_document_versions' and indexdef like '%(document_id, version)%'));

update program_settings s set api_access_enabled = p.e, api_calls_per_minute = p.n, esign_strict = p.x from cdoc_ps p where s.id = p.id;

-- the audit log keeps the change, never the text or the fill-ins (redact)
select test.eq('the audit log of the versions holds no text and no fill-ins', (select count(*) from audit_log where entity_table = 'company_document_versions'
  and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(dummy|Example Holdco|Example A Inc)'), 0::bigint);
select test.ok('...and it did log the changes', exists (select 1 from audit_log where entity_table = 'company_document_versions'));
