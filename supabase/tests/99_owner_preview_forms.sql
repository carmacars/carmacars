-- 99: the owner's agreements before approval and the ServiceOntario form fixes (migration 0181,
-- docs/changes/2026-10-27-owner-preview-form-fixes.md). The preview of the two agreements filled from the application,
-- with no fee and no number, while signing stays closed; addresses split into the forms' boxes (a district dropped, a
-- unit taken out of the street line, no commas, the separate columns first); names in the registry's order when the
-- parts were never stored; a registrant for every method, and none empty; the forms each method needs. Fictional people
-- and addresses only. Fixtures start with "pf".
select test.suite('99 owner preview and form fixes');

-- ---------------------------------------------------------------- addresses
select test.eq('split: a district between the street and the city is dropped, the street kept',
  app.split_ca_address('123 Example St, Scarborough, Toronto, ON M1J 1W6'),
  '{"address_line1": "123 Example St", "unit": null, "city": "Toronto", "province": "ON", "postal_code": "M1J 1W6"}'::jsonb);
select test.eq('split: a unit in the street line, the city and province with no comma, the postal code with no space',
  app.split_ca_address('45 Sample Ave Unit 5, Toronto ON M5V1A1'),
  '{"address_line1": "45 Sample Ave", "unit": "5", "city": "Toronto", "province": "ON", "postal_code": "M5V 1A1"}'::jsonb);
select test.eq('split: no commas at all, the city after the street type and its direction',
  app.split_ca_address('45 Sample Rd W Toronto ON M5V 1A1'),
  '{"address_line1": "45 Sample Rd W", "unit": null, "city": "Toronto", "province": "ON", "postal_code": "M5V 1A1"}'::jsonb);
select test.eq('split: the unit first, the province spelled out, the country at the end',
  app.split_ca_address('Unit 5, 123 Example St, Toronto, Ontario, Canada'),
  '{"address_line1": "123 Example St", "unit": "5", "city": "Toronto", "province": "ON", "postal_code": null}'::jsonb);
select test.eq('split: "5-123" is unit 5 at number 123; "#12" after the street is the unit',
  (app.split_ca_address('5-123 Example St, Toronto, ON M5V 1A1') ->> 'unit') || '/' || (app.split_ca_address('5-123 Example St, Toronto, ON M5V 1A1') ->> 'address_line1') || '/'
  || (app.split_ca_address('1 Sample Ave E #12, North York, ON') ->> 'unit') || '/' || (app.split_ca_address('1 Sample Ave E #12, North York, ON') ->> 'address_line1'),
  '5/123 Example St/12/1 Sample Ave E');
select test.eq('split: a street whose name starts like a unit word is not a unit',
  coalesce(app.split_ca_address('1 University Ave, Toronto, ON') ->> 'unit', 'none') || '/' || coalesce(app.split_ca_address('Steeles Plaza, 20 Example Rd, Toronto') ->> 'unit', 'none')
  || '/' || (app.split_ca_address('Steeles Plaza, 20 Example Rd, Toronto') ->> 'address_line1'), 'none/none/20 Example Rd');
select test.eq('split: 0122''s company address still splits the same way', app.split_ca_address('2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2'),
  '{"address_line1": "2967 Dundas St W", "unit": "208B", "city": "Toronto", "province": "ON", "postal_code": "M6P 1Z2"}'::jsonb);
select test.eq('columns: a district in the second line goes in no box; the columns win',
  app.address_parts('123 Example St', 'Scarborough', 'Toronto', 'Ontario', 'm1j1w6'),
  '{"address_line1": "123 Example St", "unit": null, "city": "Toronto", "province": "ON", "postal_code": "M1J 1W6"}'::jsonb);
select test.eq('columns: the district in the first line and the street in the second: the street',
  app.address_parts('Scarborough', '123 Example St', 'Toronto', 'ON', 'M1J 1W6') ->> 'address_line1', '123 Example St');
select test.eq('columns: a whole address typed in the street line, the city column empty',
  app.address_parts('45 Sample Ave Unit 5, Toronto ON M5V1A1', null, null, 'ON', null),
  '{"address_line1": "45 Sample Ave", "unit": "5", "city": "Toronto", "province": "ON", "postal_code": "M5V 1A1"}'::jsonb);
select test.eq('columns: the unit from "Apt 1807", "#1807" or "1807" alone in the second line, or inside the street line',
  (app.address_parts('10 Example St', 'Apt 1807', 'Toronto', 'ON', null) ->> 'unit') || '/' || (app.address_parts('10 Example St', '#1807', 'Toronto', 'ON', null) ->> 'unit') || '/'
  || (app.address_parts('10 Example St', '1807', 'Toronto', 'ON', null) ->> 'unit') || '/' || (app.address_parts('10 Example St Suite 300', null, 'Toronto', 'ON', null) ->> 'unit'),
  '1807/1807/1807/300');

-- ---------------------------------------------------------------- names
select test.eq('names: first, middle and last from a legal name', app.person_name_parts('Jordan Avery Example'), '{"first": "Jordan", "middle": "Avery", "last": "Example"}'::jsonb);
select test.eq('names: "Last, First M" and a particle', (app.person_name_parts('Example, Jordan A') ->> 'last') || '/' || (app.person_name_parts('Ana de Sample') ->> 'last'), 'Example/de Sample');
select test.ok('names: a corporation''s name is not a person''s', app.looks_like_company('Sample Fleet Holdings Inc.') and app.looks_like_company('1001234 Ontario Inc.')
  and not app.looks_like_company('Jordan Avery Example'));

-- ---------------------------------------------------------------- fixtures
select test.mk_user('pf_admin', 'admin');
-- an individual with no name parts stored, a district in the second address line
select test.mk_owner('pf_ind');
update owners set legal_name = 'Jordan Avery Example', first_name = null, middle_name = null, last_name = null, address_line1 = '123 Example St',
       address_line2 = 'Scarborough', city = 'Toronto', province = 'ON', postal_code = 'm1j1w6' where id = test.id('owner:pf_ind');
insert into owner_private_details (owner_id, licence_number, licence_province, date_of_birth) values (test.id('owner:pf_ind'), 'E1234-56789-01234', 'ON', date '1990-01-02');
select test.mk_vehicle('pf_co', 'pf_ind');
update vehicle_schedules set onboarding_method = 'co_registrant' where vehicle_id = test.id('vehicle:pf_co');
insert into vehicle_onboardings (vehicle_id, government_forms) values (test.id('vehicle:pf_co'), array['SR-LV-006', 'SR-LV-012', '013-1155']);
-- the whole address typed in the street line
select test.mk_owner('pf_line');
update owners set legal_name = 'Riley Sample', address_line1 = '45 Sample Ave Unit 5, Toronto ON M5V1A1', address_line2 = null, city = null, postal_code = null
 where id = test.id('owner:pf_line');
select test.mk_vehicle('pf_line_car', 'pf_line');
update vehicle_schedules set onboarding_method = 'co_registrant' where vehicle_id = test.id('vehicle:pf_line_car');
insert into vehicle_onboardings (vehicle_id) values (test.id('vehicle:pf_line_car'));
-- a corporation whose legal name is the corporation's, no corporation name, no name parts; under a Lease
select test.mk_owner('pf_corp');
update owners set owner_type = 'corporation', legal_name = 'Sample Fleet Holdings Inc.', corporation_name = null, signing_officer_name = 'Casey Morgan Sample',
       address_line1 = '88 Example Quay W', address_line2 = 'Suite 2500', city = 'Toronto', province = 'ON', postal_code = 'M5J 0B8' where id = test.id('owner:pf_corp');
select test.mk_vehicle('pf_lease', 'pf_corp');
update vehicle_schedules set onboarding_method = 'lease_existing_corporation', held_by = 'corporation' where vehicle_id = test.id('vehicle:pf_lease');
insert into vehicle_onboardings (vehicle_id) values (test.id('vehicle:pf_lease'));
-- cars whose method is on no schedule, onboarding or vehicle: one with its situation (Co-Registrant), one with nothing
insert into vehicles (id, owner_id, year, make, model, vin, plate, management_mode, onboarding_method)
values (test.id('vehicle:pf_sit'), test.id('owner:pf_ind'), 2021, 'Sample', 'Sedan', 'PFSIT000000000001', null, 'managed', null),
       (test.id('vehicle:pf_none'), test.id('owner:pf_ind'), 2021, 'Sample', 'Hatch', 'PFNONE00000000001', null, 'managed', null),
       (test.id('vehicle:pf_new'), test.id('owner:pf_ind'), 2022, 'Sample', 'Wagon', 'PFNEW000000000001', null, 'managed', 'lease_new_owner_corporation');
insert into vehicle_onboardings (vehicle_id, situation, status) values (test.id('vehicle:pf_sit'), 'S3', 'terms_set'), (test.id('vehicle:pf_none'), null, 'terms_set');
insert into vehicle_onboardings (vehicle_id, status, new_corporation) values (test.id('vehicle:pf_new'), 'terms_set', '{"proposed_name": "Sample Mobility Inc."}');

-- ---------------------------------------------------------------- the registry context
select test.eq('an individual with no name parts: LAST, FIRST M; the street kept, the district in no box',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{vehicle_registrant,address_line1}') || '/' || coalesce(c #>> '{vehicle_registrant,unit}', 'no unit') || '/'
          || (c #>> '{vehicle_registrant,city}') || '/' || (c #>> '{vehicle_registrant,postal_code}') || '/' || (c #>> '{owner,street_number}') || '|' || (c #>> '{owner,street_name}')
     from app.registry_context(test.id('vehicle:pf_co')) c), 'EXAMPLE, JORDAN A/123 Example St/no unit/Toronto/M1J 1W6/123|Example St');
select test.eq('a whole address in the street line: street, unit, city and postal code in their boxes',
  (select (c #>> '{vehicle_registrant,address_line1}') || '/' || (c #>> '{vehicle_registrant,unit}') || '/' || (c #>> '{vehicle_registrant,city}') || '/' || (c #>> '{vehicle_registrant,postal_code}')
          || '/' || (c #>> '{vehicle_registrant,name}')
     from app.registry_context(test.id('vehicle:pf_line_car')) c), '45 Sample Ave/5/Toronto/M5V 1A1/SAMPLE, RILEY');
select test.eq('a corporation owner: its own name in the company box, its RIN-less registrant at its address; its person is the signing officer',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{vehicle_registrant,unit}') || '/' || (c #>> '{vehicle_registrant,signer_name}') || '/'
          || (c #>> '{owner,first_name}') || ' ' || (c #>> '{owner,last_name}') || '/' || (c #>> '{owner,registry_name}')
     from app.registry_context(test.id('vehicle:pf_lease')) c), 'SAMPLE FLEET HOLDINGS INC./2500/Casey Morgan Sample/Casey Sample/SAMPLE FLEET HOLDINGS INC.');
select test.eq('the method from the ownership situation when nothing else has it',
  (select (c #>> '{method,code}') || '/' || (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{method,two_registrants}') from app.registry_context(test.id('vehicle:pf_sit')) c),
  'co_registrant/EXAMPLE, JORDAN A/true');
select test.eq('no method at all: the owner is the vehicle''s registrant, never an empty section 1',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{vehicle_registrant,address_line1}') || '/' || (c #>> '{vehicle_registrant,signer_name}')
     from app.registry_context(test.id('vehicle:pf_none')) c), 'EXAMPLE, JORDAN A/123 Example St/Jordan Avery Example');
select test.eq('a new Owner Corporation: the name proposed on the application until the real one is recorded',
  (select (c #>> '{corporation,registry_name}') || '/' || (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{corporation,applies}') from app.registry_context(test.id('vehicle:pf_new')) c),
  'SAMPLE MOBILITY INC./SAMPLE MOBILITY INC./true');
update program_settings set company_legal_name = '' where id = (select id from app.settings());
select test.eq('CarmaCars with no legal name set: its trade name, never an empty name box',
  (select c #>> '{registrant,registry_name}' from app.registry_context(test.id('vehicle:pf_co')) c), upper((select company_trade_name from app.settings())));
update program_settings set company_legal_name = '18122211 Canada Inc.' where id = (select id from app.settings());

-- ---------------------------------------------------------------- the forms each method needs
select test.eq('013-1155 and 013-0169 only for a Lease through a new Owner Corporation; none for a Transfer of an owned car',
  array_to_string(app.vehicle_registry_forms(test.id('vehicle:pf_co')), ',') || '|' || array_to_string(app.vehicle_registry_forms(test.id('vehicle:pf_new')), ',') || '|'
  || coalesce(nullif(array_to_string(app.vehicle_registry_forms(test.id('vehicle:pf_none')), ','), ''), 'none') || '|'
  || coalesce(nullif(array_to_string(app.vehicle_registry_forms(test.id('vehicle:pf_sit')), ','), ''), 'none'),
  'SR-LV-006,SR-LV-012|SR-LV-006,SR-LV-012,ON00453,013-0169,013-1155|none|SR-LV-006,SR-LV-012');
-- the checked mappings on the current templates (earlier suites save their own in an Admin's name)
update pdf_templates t set field_map = o.field_map from official_form_originals o
 where o.form_code = t.form_code and t.is_current and t.form_code in ('SR-LV-006', '013-1155')
   and not exists (select 1 from jsonb_object_keys(o.field_map) k where not exists (select 1 from jsonb_array_elements(t.field_names) x where x ->> 'name' = k));
-- an earlier list asked the Co-Registrant car for 013-1155
create temp table pf_old as select app.fill_government_form(test.id('vehicle:pf_co'), '013-1155', null) id;
create temp table pf_fills as select f.* from app.fill_vehicle_government_forms(test.id('vehicle:pf_co')) f;
select test.eq('filling the car''s forms keeps to its method: two forms, the onboarding''s list corrected',
  (select string_agg(form_code, ',' order by form_code) from pf_fills) || '|' || (select array_to_string(government_forms, ',') from vehicle_onboardings where vehicle_id = test.id('vehicle:pf_co')),
  'SR-LV-006,SR-LV-012|SR-LV-006,SR-LV-012');
select test.ok('the 013-1155 the method does not need is superseded, not the owner''s to do', (select superseded_at is not null from government_form_fills where id = (select id from pf_old))
  and not exists (select 1 from jsonb_array_elements(app.owner_signables(test.id('owner:pf_ind'))) i where i ->> 'code' = 'registry_form' and i ->> 'label' like '%013-1155%'));
select test.eq('SR-LV-006 for the Co-Registrant car: the name, the street and the city in their boxes',
  (select (g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[2]') || '/' || (g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].streetName[0]')
          || '/' || (g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].city[0]')
     from government_form_fills g where g.vehicle_id = test.id('vehicle:pf_co') and g.form_code = 'SR-LV-006' and g.superseded_at is null
       and g.field_values ? 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[2]'),
  'EXAMPLE, JORDAN A/123 Example St/Toronto');
create temp table pf_new_fills as select f.* from app.fill_vehicle_government_forms(test.id('vehicle:pf_new')) f;
select test.eq('013-1155 where it is needed: the recipient corporation and the owner as donor',
  (select (g.field_values ->> 'nameRecipient') || '/' || (g.field_values ->> 'nameDonor') from government_form_fills g
    where g.vehicle_id = test.id('vehicle:pf_new') and g.form_code = '013-1155' and g.superseded_at is null and g.field_values ? 'nameRecipient'),
  'SAMPLE MOBILITY INC./JORDAN AVERY EXAMPLE');

-- ---------------------------------------------------------------- the owner's agreements before approval
select test.mk_user('pf_new_owner', 'owner');
insert into owners (id, user_id, owner_type, legal_name, first_name, last_name, status, email, phone, address_line1, city, province, postal_code)
values (test.id('owner:pf_new_owner'), test.id('pf_new_owner'), 'individual', 'Morgan Example', 'Morgan', 'Example', 'lead', 'pf_new_owner@example.test', '416-555-0101',
        '10 Example St', 'Toronto', 'ON', 'M5V 1A1');
insert into vehicles (id, owner_id, year, make, model, vin, management_mode, onboarding_method)
values (test.id('vehicle:pf_intake'), test.id('owner:pf_new_owner'), 2023, 'Sample', 'Coupe', 'PFINTAKE000000001', 'managed', null),
       (test.id('vehicle:pf_intake_turo'), test.id('owner:pf_new_owner'), 2020, 'Sample', 'Minivan', 'PFINTAKE000000002', 'turo_only', 'none');
insert into vehicle_onboardings (vehicle_id, status, held_by, title_status, proposed_management_mode, proposed_onboarding_method)
values (test.id('vehicle:pf_intake'), 'intake', 'individual', 'owned_outright', 'managed', 'co_registrant'),
       (test.id('vehicle:pf_intake_turo'), 'intake', 'individual', 'owned_outright', 'turo_only', null);
create temp table pf_prev as select public.server_owner_agreement_preview_facts(test.id('owner:pf_new_owner'), test.id('pf_new_owner')) f;
select test.eq('the preview: both cars from the application, no fee, no number, marked pending',
  (select (f ->> 'preview') || '/' || (f ->> 'pending_vehicles') || '/' || jsonb_array_length(f -> 'schedules') || '/'
          || (select string_agg(coalesce(s ->> 'insurance_fee_cents', 'pending') || ':' || coalesce(s ->> 'revenue_share_bps', 'pending') || ':' || coalesce(s ->> 'schedule_number', 'none')
                                || ':' || (s ->> 'onboarding_method') || ':' || (s ->> 'vehicle_number'), ',' order by s ->> 'vehicle_number') from jsonb_array_elements(f -> 'schedules') s)
     from pf_prev),
  'true/2/2/pending:pending:none:co_registrant:1,pending:pending:none:none:2');
select test.eq('the preview: the two agreements, with no number, not open for signature',
  (select string_agg((a ->> 'kind') || ':' || (a ->> 'status') || ':' || coalesce(a ->> 'agreement_number', 'no number'), ',' order by a ->> 'kind') from pf_prev, jsonb_array_elements(f -> 'agreements') a),
  'enrollment:preview:no number,title_holding:preview:no number');
select test.eq('the owner''s own name and address are in it', (select (f #>> '{owner,signer_name}') || '/' || (f #>> '{owner,address}') from pf_prev), 'Morgan Example/10 Example St, Toronto, ON M5V 1A1');
select test.eq('the signing facts are unchanged: nothing to sign before approval',
  jsonb_array_length(public.server_owner_agreement_facts(test.id('owner:pf_new_owner'), test.id('pf_new_owner')) -> 'schedules'), 0);
select test.throws('signing stays closed until an Admin sets the terms',
  format($$select app.owner_open_agreements(%L, %L, '[{"key": "enrollment", "template_version": "v", "sha256": "%s", "storage_path": "owners/x/a.pdf"}]'::jsonb)$$,
         test.id('owner:pf_new_owner'), test.id('pf_new_owner'), repeat('a', 64)), 'no enrollment agreement yet');
select test.throws('another person cannot read the preview', format('select app.owner_agreement_preview_facts(%L, %L)', test.id('owner:pf_new_owner'), test.id('pf_line')), 'Only the owner');
select test.eq('the owner''s checklist points to the preview', (select i ->> 'detail' from jsonb_array_elements(app.my_signing_checklist(test.id('pf_new_owner')) -> 'items') i where i ->> 'code' = 'enrollment'),
  'Filled in for you to read now. You sign once CarmaCars approves your terms.');
select test.eq('an owner with every car approved: no preview', public.server_owner_agreement_preview_facts(test.id('owner:pf_ind'), test.id('pf_ind')) ->> 'preview', 'false');
select test.ok('privileges: the preview and the new functions are the service role''s',
  not has_function_privilege('authenticated', 'public.server_owner_agreement_preview_facts(uuid, uuid)', 'execute')
  and has_function_privilege('service_role', 'public.server_owner_agreement_preview_facts(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'app.vehicle_registry_forms(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.address_parts(text, text, text, text, text)', 'execute'));
