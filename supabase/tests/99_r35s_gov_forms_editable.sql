-- 99: the government forms are as editable as the rental agreements (migration 0870,
-- docs/changes/2026-11-08-r35-gov-forms-editable.md): a box's value changed on one form with a reason, as a new version,
-- earlier versions kept; the mapping saved by an Admin or fleet, kept and previewed on a sample car; Make again keeps the
-- changes unless discarded; owners see the current version only; only the publisher's PDF is filled. Fixtures "r35s".
select test.suite('99 r35s government forms editable');
select test.mk_user('r35s_admin', 'admin');
select test.mk_user('r35s_fleet', 'va', 'fleet');
select test.mk_user('r35s_cs', 'va', 'cs');
select test.mk_user('r35s_fin', 'va', 'finance');
create function test.r35s(p_call text, p_name text, p jsonb, p_user text default 'r35s_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.r35s_owner(p_label text) returns uuid language plpgsql as $$
declare v_user uuid := test.mk_user(p_label, 'owner');
begin
  update users set email = p_label || '@example.test' where id = v_user;
  insert into owners (id, user_id, owner_type, legal_name, first_name, last_name, status, email, phone, address_line1, city, province, postal_code, country)
  values (test.id('owner:' || p_label), v_user, 'individual', 'Pat Example', 'Pat', 'Example', 'active', p_label || '@example.test', '+16475550199',
          '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', 'CA');
  return test.id('owner:' || p_label);
end $$;
select test.r35s_owner('r35s_ola');
select test.r35s_owner('r35s_other');
create table test.r35s_app as select app.submit_owner_application(jsonb_build_object('owner_id', test.id('owner:r35s_ola'), 'source', 'web', 'vehicles', jsonb_build_array(jsonb_build_object(
  'vin', '1HGCM82633A870001', 'plate', 'R35S001', 'year', 2021, 'make', 'Hyundai', 'model', 'Sonata', 'colour', 'Blue', 'odometer_km', 20000, 'held_by', 'individual',
  'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'co_registrant', 'current_insurer', 'Example Insurer'))), test.id('r35s_ola')) as r;
create function test.r35s_v() returns uuid language sql stable as $$ select ((select r from test.r35s_app) #>> '{vehicles,0,vehicle_id}')::uuid $$;
select app.application_approve(test.id('r35s_admin'), jsonb_build_object('id', (select r ->> 'application_id' from test.r35s_app), 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', test.r35s_v(),
  'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', 'co_registrant'), 'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none')))));
create function test.r35s_cur(p_code text) returns government_form_fills language sql stable as $$
  select * from government_form_fills where vehicle_id = test.r35s_v() and form_code = p_code and superseded_at is null $$;

-- ================================================================ a test form that is the publisher's PDF (an Admin's upload)
insert into pdf_templates (id, form_code, version, title, kind, file_key, sha256, page_count, field_names, field_map, verified, verified_by, verified_at, is_current, uploaded_by, mapped_by, mapped_at)
values (test.id('tpl:r35s'), 'R35S-TEST', 'official-r35s-1', 'R35S-TEST: test form', 'acroform', 'forms/templates/R35S-TEST/official-r35s.pdf', repeat('a', 64), 1,
        '[{"name": "vin_box", "type": "text", "label": "Vehicle Identification Number", "max_length": 17}, {"name": "name_box", "type": "text", "label": "Name"},
          {"name": "tick", "type": "checkbox", "label": "Leased"}]'::jsonb,
        '{"vin_box": {"source": "vehicle.vin", "transform": "upper", "required": true}, "name_box": {"source": "owner.legal_name", "transform": "upper"}}'::jsonb,
        true, test.id('r35s_admin'), now(), true, test.id('r35s_admin'), test.id('r35s_admin'), now());
create table test.r35s_f1 as select app.fill_government_form(test.r35s_v(), 'R35S-TEST', null) as id;
select test.eq('the publisher''s PDF: filled as the official form', (test.r35s_cur('R35S-TEST')).mode || '/' || ((test.r35s_cur('R35S-TEST')).field_values ->> 'name_box'), 'pdf/PAT EXAMPLE');

-- a template that is not the publisher's (a copy saved again, no upload): the data sheet, never a look-alike
insert into pdf_templates (id, form_code, version, kind, file_key, sha256, field_names, field_map, verified, verified_by, verified_at, is_current)
values (test.id('tpl:r35s:copy'), 'R35S-COPY', 'copy-1', 'acroform', 'forms/templates/R35S-COPY/copy.pdf', repeat('b', 64), '[{"name": "vin_box", "type": "text"}]'::jsonb,
        '{"vin_box": {"source": "vehicle.vin"}}'::jsonb, true, test.id('r35s_admin'), now(), true);
create table test.r35s_copy as select app.fill_government_form(test.r35s_v(), 'R35S-COPY', null) as id;
select test.eq('a copy that is not the publisher''s PDF gives the data sheet', (select mode from government_form_fills where id = (select id from test.r35s_copy)), 'data_sheet');
select test.eq('a laid-out copy (overlay) is never the publisher''s PDF', coalesce((select bool_or(app.official_form_is_publisher(id)) from pdf_templates where kind = 'overlay'), false), false);
select test.eq('no current fill in use as a PDF is filled from a template that is not the publisher''s',
  (select count(*) from government_form_fills g where g.superseded_at is null and g.mode = 'pdf' and not app.official_form_is_publisher(g.pdf_template_id)), 0::bigint);

-- ================================================================ 1. a box's value changed, with a reason, as a new version
select test.throws('a reason is needed', format($$select test.r35s('va_do', 'government_form_edit', %L, 'r35s_fleet')$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'value', 'PAT Q EXAMPLE', 'reason', '')), 'reason');
select test.throws('customer service reads but does not change', format($$select test.r35s('va_do', 'government_form_edit', %L, 'r35s_cs')$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'value', 'X', 'reason', 'test')), 'Not permitted');
select test.throws('finance does not', format($$select test.r35s('va_do', 'government_form_edit', %L, 'r35s_fin')$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'value', 'X', 'reason', 'test')), 'Not permitted');
select test.throws('the owner does not', format($$select test.r35s('ops_do', 'government_form_edit', %L, 'r35s_ola')$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'value', 'X', 'reason', 'test')), 'Not permitted');
select test.throws('a checkbox is ticked by hand at the counter', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'tick', 'value', 'Yes', 'reason', 'ticked')), 'Only the text boxes');
select test.throws('a box that is not on the form', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'nope', 'value', 'Yes', 'reason', 'nope')), 'has no box');
select test.throws('no more characters than the box takes', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'vin_box', 'value', repeat('X', 18), 'reason', 'long')), 'At most 17');
create table test.r35s_e1 as select test.r35s('va_do', 'government_form_edit', jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box',
  'value', 'EXAMPLE, PAT Q', 'reason', 'The registry writes the last name first'), 'r35s_fleet') as r;
select test.eq('fleet changes the value: version 2, the value on the official form, the earlier version kept',
  (select r ->> 'version' from test.r35s_e1) || '/' || ((test.r35s_cur('R35S-TEST')).field_values ->> 'name_box') || '/'
  || (select superseded_at is not null from government_form_fills where id = (select id from test.r35s_f1)), '2/EXAMPLE, PAT Q/true');
select test.eq('audited with the reason, the box and the value before',
  (select (before ->> 'value') || '|' || (after ->> 'reason') || '|' || (before ->> 'field') from audit_log where action = 'government_form_edit' and entity_id = (select r ->> 'fill' from test.r35s_e1)),
  'PAT EXAMPLE|The registry writes the last name first|name_box');
select test.eq('the staff read: version, each version, the box marked changed with the value from the records',
  (select (x ->> 'version') || '/' || jsonb_array_length(x -> 'versions') || '/' || (x ->> 'can_edit') || '/'
     || (select (f ->> 'edited') || ':' || (f ->> 'records') from jsonb_array_elements(x -> 'fields') f where f ->> 'name' = 'name_box')
     || '/' || (x #>> '{edits,0,reason}')
   from (select test.r35s('ops_read', 'government_form_fill', jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id)) x) y),
  '2/2/true/true:PAT EXAMPLE/The registry writes the last name first');
select test.eq('an earlier version stays downloadable for staff (marked earlier, not editable)',
  (select (x ->> 'current') || '/' || (x ->> 'can_edit') || '/' || (x -> 'field_values' ->> 'name_box')
     from (select test.r35s('va_read', 'government_form_fill', jsonb_build_object('fill', (select id from test.r35s_f1)), 'r35s_cs') x) y), 'false/false/PAT EXAMPLE');
select test.throws('the earlier version is not changed', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (select id from test.r35s_f1), 'field', 'name_box', 'value', 'X', 'reason', 'old one')), 'earlier version');
select test.eq('the owner gets the current version only', (select (app.owner_form_official(test.id('r35s_ola'), (test.r35s_cur('R35S-TEST')).id) -> 'field_values' ->> 'name_box')
  || '/' || coalesce(app.owner_form_official(test.id('r35s_ola'), (select id from test.r35s_f1))::text, 'none')), 'EXAMPLE, PAT Q/none');
select test.eq('another owner gets nothing', app.owner_form_official(test.id('r35s_other'), (test.r35s_cur('R35S-TEST')).id) is null, true);
create table test.r35s_refill as select app.fill_government_form(test.r35s_v(), 'R35S-TEST', null) as id;
select test.eq('made again from the records (a value changed on the car): the change stays',
  (select field_values ->> 'name_box' from government_form_fills where id = (select id from test.r35s_refill)), 'EXAMPLE, PAT Q');
select test.lives('back to the records, with a reason', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'restore', true, 'reason', 'Written as the records say after all')));
select test.eq('the value from the records again; the change ended with the reason',
  ((test.r35s_cur('R35S-TEST')).field_values ->> 'name_box') || '/' || (select end_reason from government_form_overrides where vehicle_id = test.r35s_v() and form_code = 'R35S-TEST' and field = 'name_box'),
  'PAT EXAMPLE/Back to the records: Written as the records say after all');
select test.throws('back to the records with nothing changed', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'name_box', 'restore', true, 'reason', 'again')), 'already comes from the records');
-- a required box emptied: the form waits again
select test.r35s('ops_do', 'government_form_edit', jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'vin_box', 'value', '', 'reason', 'The VIN is checked at the counter'));
select test.eq('a needed box emptied: the form shows it missing; given again, ready',
  (test.r35s_cur('R35S-TEST')).status || ':' || ('PDF field vin_box' = any ((test.r35s_cur('R35S-TEST')).missing)) || '/'
  || (select not (x -> 'missing' ? 'PDF field vin_box') from (select test.r35s('ops_do', 'government_form_edit', jsonb_build_object('fill', (test.r35s_cur('R35S-TEST')).id, 'field', 'vin_box', 'value', '1HGCM82633A870001', 'reason', 'Read at the counter')) x) y),
  'draft:true/true');

-- ================================================================ the data sheet of a form not in use as a PDF; Make again keeps or discards
-- the box or row to change: a filled text box of the official form when SR-LV-006 is in use as a PDF, else a data sheet row
create table test.r35s_row as
  select case when g.mode = 'pdf' then 'pdf' else 'sheet' end as target,
         case when g.mode = 'pdf' then (select e.key from jsonb_each_text(g.field_values) e join jsonb_array_elements(t.field_names) f on f ->> 'name' = e.key
                                         where e.value is not null and coalesce(f ->> 'type', 'text') = 'text' and coalesce((f ->> 'max_length')::int, 99) >= 15 order by e.key limit 1)
              else (select r ->> 'label' from jsonb_array_elements(g.data_sheet) r where r ->> 'value' is not null limit 1) end as label
    from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id where g.id = (test.r35s_cur('SR-LV-006')).id;
alter table test.r35s_row add column value text;
update test.r35s_row x set value = case when x.target = 'pdf' then (test.r35s_cur('SR-LV-006')).field_values ->> x.label
  else (select r ->> 'value' from jsonb_array_elements((test.r35s_cur('SR-LV-006')).data_sheet) r where r ->> 'label' = x.label) end;
create function test.r35s_val() returns text language sql stable as $$
  select case when x.target = 'pdf' then (test.r35s_cur('SR-LV-006')).field_values ->> x.label
    else (select r ->> 'value' from jsonb_array_elements((test.r35s_cur('SR-LV-006')).data_sheet) r where r ->> 'label' = x.label) end from test.r35s_row x $$;
select test.ok('fixture: a value to change on SR-LV-006', (select label is not null and value is not null from test.r35s_row));
select test.r35s('va_do', 'government_form_edit', jsonb_build_object('fill', (test.r35s_cur('SR-LV-006')).id, 'target', (select target from test.r35s_row), 'field', (select label from test.r35s_row), 'value', 'CHANGED BY HAND', 'reason', 'Corrected at the registry'), 'r35s_fleet');
select test.eq('the value changed (a box of the official form, or a data sheet row)', test.r35s_val(), 'CHANGED BY HAND');
create table test.r35s_again as select test.r35s('va_do', 'government_forms_make_again', jsonb_build_object('vehicle_id', test.r35s_v()), 'r35s_fleet') as r;
select test.eq('Make again (fleet): the change is kept',
  (select r ->> 'kept' from test.r35s_again) || '/' || test.r35s_val(),
  '2/CHANGED BY HAND');
select test.throws('Make again: customer service does not', format($$select test.r35s('va_do', 'government_forms_make_again', %L, 'r35s_cs')$$, jsonb_build_object('vehicle_id', test.r35s_v())), 'Not permitted');
create table test.r35s_again2 as select test.r35s('ops_do', 'government_forms_make_again', jsonb_build_object('vehicle_id', test.r35s_v(), 'discard_edits', true)) as r;
select test.eq('Make again, discarding the changes: the value from the records again',
  (select r ->> 'discarded' from test.r35s_again2) || '/' || test.r35s_val()
  || '/' || (select count(*) from government_form_overrides where vehicle_id = test.r35s_v() and end_reason = 'Discarded at Make again'),
  '2/' || (select value from test.r35s_row) || '/2');
-- a form signed in ink is never changed
update government_form_fills set status = 'signed', missing = '{}', signed_at = now() where id = (test.r35s_cur('SR-LV-006')).id;
select test.throws('a form signed in ink is kept as it is', format($$select test.r35s('ops_do', 'government_form_edit', %L)$$,
  jsonb_build_object('fill', (test.r35s_cur('SR-LV-006')).id, 'target', (select target from test.r35s_row), 'field', (select label from test.r35s_row), 'value', 'X', 'reason', 'too late')), 'signed in ink');
select test.eq('the staff list: each form''s version and changes; the owner''s list has neither',
  (select (x ->> 'can_edit') || '/' || ((x #>> '{cars,0,forms,0,version}') is not null) from (select test.r35s('va_read', 'government_forms', jsonb_build_object('vehicle_id', test.r35s_v()), 'r35s_fleet') x) y)
  || '/' || (select coalesce(x ->> 'can_edit', 'none') || '/' || coalesce(x #>> '{cars,0,forms,0,version}', 'none') from (select test.r35s('ops_read', 'government_forms', jsonb_build_object('owner_id', test.id('owner:r35s_ola')), 'r35s_ola') x) y),
  'true/true/none/none');

-- ================================================================ 2. the mapping: fleet maps, every save kept, preview on a sample car
select test.throws('finance does not read the forms settings', format('select app.form_templates(%L)', test.id('r35s_fin')), null);
select test.eq('fleet reads the registry forms (not the per-booking ones), with the sample car first, and cannot upload',
  (select (x ->> 'can_upload') || '/' || (x #>> '{vehicles,0,id}') || '/' || exists (select 1 from jsonb_array_elements(x -> 'forms') f where f ->> 'form_code' = 'R35S-TEST')
     || '/' || not exists (select 1 from jsonb_array_elements(x -> 'forms') f join pdf_templates t on t.form_code = f ->> 'form_code' and t.kind = 'booking_overlay')
   from (select test.r35s('ops_read', 'form_templates', '{}'::jsonb, 'r35s_fleet') x) y), 'false/sample/true/true');
-- (Make again set aside the test form, which the car does not need: made once more for the mapping)
create table test.r35s_f3 as select app.fill_government_form(test.r35s_v(), 'R35S-TEST', null) as id;
select test.r35s('ops_do', 'form_template_map', jsonb_build_object('template', test.id('tpl:r35s'), 'verify', true, 'note', 'The name in capitals, the VIN as it is',
  'field_map', jsonb_build_object('vin_box', jsonb_build_object('source', 'vehicle.vin', 'required', true), 'name_box', jsonb_build_object('source', 'owner.registry_name'))), 'r35s_fleet');
select test.eq('fleet saved the mapping: kept with the note, audited, the open forms made again',
  (select note from pdf_template_map_history where template_id = test.id('tpl:r35s') order by saved_at desc limit 1) || '/'
  || (select count(*) from audit_log where action = 'form_template_map' and entity_id = test.id('tpl:r35s')::text) || '/'
  || ((test.r35s_cur('R35S-TEST')).field_values ->> 'name_box'),
  'The name in capitals, the VIN as it is/1/' || (app.registry_context(test.r35s_v()) #>> '{owner,registry_name}'));
select test.eq('the mapping history lists each save (the one before and this one)',
  (select jsonb_array_length(f -> 'history') >= 2 from jsonb_array_elements(test.r35s('ops_read', 'form_templates', '{}'::jsonb) -> 'forms') f where f ->> 'form_code' = 'R35S-TEST'), true);
select test.eq('the preview on the sample car, with the mapping on screen (not saved)',
  (select (x ->> 'sample') || '/' || (x -> 'values' ->> 'vin_box') || '/' || (x -> 'values' ->> 'name_box')
     from (select test.r35s('ops_read', 'form_template_preview', jsonb_build_object('template', test.id('tpl:r35s'), 'vehicle', 'sample',
            'field_map', jsonb_build_object('vin_box', jsonb_build_object('source', 'vehicle.vin'), 'name_box', jsonb_build_object('source', 'owner.city', 'transform', 'upper'))), 'r35s_fleet') x) y),
  'true/2HGFC2F59MH000001/TORONTO');
select test.eq('the sample car''s values are made up (example.test)', app.registry_sample_context() #>> '{owner,email}', 'sample.owner@example.test');
select test.throws('customer service does not map', format($$select test.r35s('ops_do', 'form_template_map', %L, 'r35s_cs')$$,
  jsonb_build_object('template', test.id('tpl:r35s'), 'field_map', '{}'::jsonb)), null);
select test.ok('privileges: the service role only', has_function_privilege('service_role', 'app.government_form_edit(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.government_form_edit(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.registry_sample_context()', 'execute'));
-- leave the shared catalogue as it was
update government_form_fills set superseded_at = now() where form_code in ('R35S-TEST', 'R35S-COPY') and superseded_at is null;
update pdf_templates set is_current = false where form_code in ('R35S-TEST', 'R35S-COPY');
