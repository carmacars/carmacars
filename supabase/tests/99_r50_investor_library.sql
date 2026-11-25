-- 99: the investor Documents library (migrations 4300 and 4301, release 50; docs/changes/2026-11-24-r50-investor-library.md).
-- The four sections and a section an Admin adds, a new document and a replacement (the history kept, the latest shown with
-- its date), a link to a deck, the notice to every active investor once per version, who may read a file, archiving, the
-- table rules. Fixtures start with "xil"; every address is example.test.
select test.suite('99 r50 investor library');
select test.mk_user('xil_admin', 'admin');
select test.mk_user('xil_fin', 'va', 'finance');
select test.mk_user('xil_inv', 'renter');
select test.mk_user('xil_gone', 'renter');
select test.mk_user('xil_renter', 'renter');
insert into investors (id, user_id, legal_name, investor_type, status, email) values
  (test.id('xil:inv'), test.id('xil_inv'), 'Ila Example', 'individual', 'active', 'xil_inv@example.test'),
  (test.id('xil:gone'), test.id('xil_gone'), 'Gus Example', 'individual', 'refused', 'xil_gone@example.test');
create function test.xil_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'admin_do', p_name, p) $$;
create function test.xil_lib(p_user text) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'investor_read', 'library', '{}') $$;

-- ================================================================ 1. sections
select test.eq('the four sections, in order', (select string_agg(label, ', ' order by sort_order) from investor_library_kinds where key in ('business_plan', 'financial_forecast', 'pitch_deck', 'feature_decks')),
  'Business plan, Financial forecast, Pitch deck, Feature decks');
select test.eq('an empty library shows investors no section', jsonb_array_length(test.xil_lib('xil_inv') -> 'kinds'), 0);
select test.eq('Admins see every section, even empty', jsonb_array_length(public.door(test.id('xil_admin'), 'aal2', 'admin_read', 'investor_library', '{}') -> 'kinds') >= 4, true);

-- ================================================================ 2. a new document, then a replacement
create temp table xil_a as select test.xil_do('xil_admin', 'investor_library_save', jsonb_build_object('kind', 'business_plan', 'title', 'CarmaCars business plan', 'file_kind', 'pdf',
  'path', 'investor-library/' || test.id('xil:item') || '/' || test.id('xil:f1') || '.pdf', 'size_bytes', 1200, 'sha256', repeat('a', 64))) as r;
select test.eq('a new document is version 1, and the active investors are told (other suites may leave active investors too)', (select (r ->> 'version') || '/' || (r ->> 'new') || '/' || ((r ->> 'told')::int >= 1)::text from xil_a), '1/true/true');
select test.eq('one notice per active investor told', (select count(*) from app_events where code = 'investor_document_updated' and entity_id = (select (r ->> 'item')::uuid from xil_a)), (select (r ->> 'told')::bigint from xil_a));
select test.eq('...its words: New document, the kind', (select string_agg(distinct payload ->> 'document_change' || '/' || (payload ->> 'document_kind'), ',') from app_events where code = 'investor_document_updated' and entity_id = (select (r ->> 'item')::uuid from xil_a)),
  'New document/Business plan');
create temp table xil_b as select test.xil_do('xil_admin', 'investor_library_save', jsonb_build_object('item', (select r ->> 'item' from xil_a), 'file_kind', 'pdf',
  'path', 'investor-library/' || test.id('xil:item') || '/' || test.id('xil:f2') || '.pdf', 'size_bytes', 2400, 'note', 'Updated forecast figures')) as r;
select test.eq('a replacement is version 2 of the same document', (select (r ->> 'version') || '/' || (r ->> 'new') from xil_b), '2/false');
select test.eq('the history keeps both versions', (select count(*) from investor_library_versions where item_id = (select (r ->> 'item')::uuid from xil_a)), 2::bigint);
select test.eq('investors see the latest version with its date, never the history or the path',
  (select (i ->> 'version') || '/' || (i ? 'updated_on')::text || '/' || (i ? 'history')::text || '/' || (i::text like '%investor-library/%')::text
     from jsonb_array_elements(test.xil_lib('xil_inv') -> 'kinds') k, jsonb_array_elements(k -> 'items') i), '2/true/false/false');
select test.eq('the replacement is told as a new version, once per investor told', (select count(*) from app_events where code = 'investor_document_updated' and payload ->> 'document_change' = 'New version' and entity_id = (select (r ->> 'item')::uuid from xil_a)), (select (r ->> 'told')::bigint from xil_a));
select test.eq('the file for an investor is the latest version''s', (public.door(test.id('xil_inv'), 'aal2', 'investor_read', 'library_file', jsonb_build_object('item', (select r ->> 'item' from xil_a))) ->> 'path'),
  'investor-library/' || test.id('xil:item') || '/' || test.id('xil:f2') || '.pdf');
select test.eq('Admins can open an earlier version', (public.door(test.id('xil_admin'), 'aal2', 'admin_read', 'investor_library_file',
  jsonb_build_object('version', (select id from investor_library_versions where version = 1 and item_id = (select (r ->> 'item')::uuid from xil_a)))) ->> 'version'), '1');

-- ================================================================ 3. a deck link, and a section an Admin adds
select test.lives('a pitch deck given as a link', format($s$select test.xil_do('xil_admin', 'investor_library_save', '{"kind": "pitch_deck", "title": "CarmaCars pitch deck", "file_kind": "link", "link_url": "https://carmacars.ca/investor/deck"}')$s$));
select test.lives('a new section named by an Admin', format($s$select test.xil_do('xil_admin', 'investor_library_save', '{"kind_label": "Market research", "title": "Toronto rental demand", "file_kind": "link", "link_url": "https://carmacars.ca/investor/deck#demand"}')$s$));
select test.eq('...is a section with its key', (select label from investor_library_kinds where key = 'market_research'), 'Market research');
select test.eq('investors see three sections now', jsonb_array_length(test.xil_lib('xil_inv') -> 'kinds'), 3);
select test.throws('a link must be https', format($s$select test.xil_do('xil_admin', 'investor_library_save', '{"kind": "pitch_deck", "title": "Bad link", "file_kind": "link", "link_url": "http://example.test"}')$s$), '%https%');
select test.throws('a PDF must be uploaded to the library''s place', format($s$select test.xil_do('xil_admin', 'investor_library_save', '{"kind": "business_plan", "title": "Bad path", "file_kind": "pdf", "path": "owners/x.pdf"}')$s$), '%Upload the PDF%');

-- ================================================================ 4. who may
select test.throws('Finance cannot add a document', format($s$select test.xil_do('xil_fin', 'investor_library_save', '{"kind": "pitch_deck", "title": "Nope", "file_kind": "link", "link_url": "https://carmacars.ca"}')$s$));
select test.throws('an investor cannot add a document', format($s$select test.xil_do('xil_inv', 'investor_library_save', '{"kind": "pitch_deck", "title": "Nope", "file_kind": "link", "link_url": "https://carmacars.ca"}')$s$));
select test.throws('a renter cannot read the library', format($s$select test.xil_lib('xil_renter')$s$), '%investors%');
select test.throws('a refused investor cannot open a file', format($s$select public.door(%L, 'aal2', 'investor_read', 'library_file', %L)$s$, test.id('xil_gone'), jsonb_build_object('item', (select r ->> 'item' from xil_a))), '%investors%');
select test.throws('an investor cannot open an earlier version', format($s$select public.door(%L, 'aal2', 'admin_read', 'investor_library_file', %L)$s$, test.id('xil_inv'),
  jsonb_build_object('version', (select id from investor_library_versions where version = 1 and item_id = (select (r ->> 'item')::uuid from xil_a)))));

-- ================================================================ 5. archiving
select test.lives('an Admin archives the business plan', format($s$select test.xil_do('xil_admin', 'investor_library_archive', %L)$s$, jsonb_build_object('item', (select r ->> 'item' from xil_a), 'archived', true)));
select test.eq('...investors no longer see it', (select count(*) from jsonb_array_elements(test.xil_lib('xil_inv') -> 'kinds') k where k ->> 'key' = 'business_plan'), 0::bigint);
select test.throws('...nor open its file', format($s$select public.door(%L, 'aal2', 'investor_read', 'library_file', %L)$s$, test.id('xil_inv'), jsonb_build_object('item', (select r ->> 'item' from xil_a))), '%No such%');

-- ================================================================ 6. the table rules
select test.ok('row-level security, admin_all and the audit trigger on the three tables',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('investor_library_kinds', 'investor_library_items', 'investor_library_versions'))
  and (select count(*) from pg_policies where tablename in ('investor_library_kinds', 'investor_library_items', 'investor_library_versions') and policyname = 'admin_all') = 3
  and (select count(*) from pg_trigger where tgname in ('audit_investor_library_kinds', 'audit_investor_library_items', 'audit_investor_library_versions')) = 3);
select test.ok('the new functions are the server''s alone, with pg_temp last on the search path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.proname ~ '^investor_library_' and n.nspname = 'app'
               and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                    or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg\_temp'))));
select test.eq('the email is in the catalogue, for investors, never a text', (select audience || '/' || no_text::text || '/' || push_topic from notification_catalogue where code = 'investor_document_updated'), 'investor/true/documents');
