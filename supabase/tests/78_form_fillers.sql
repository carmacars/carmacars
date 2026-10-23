-- 78: the form fillers (migration 0120, docs/changes/2026-10-23-form-fillers.md). The registry context in the shape the
-- official ServiceOntario forms ask for (addresses in their boxes, the registry's name order, who is the vehicle's
-- registrant and who holds the plates by onboarding method), the checked mappings of the five forms, the phone format, and
-- the company's legal name in the owner agreements' facts. Fixtures start with "ff".
select test.suite('75 form fillers');

-- ---------------------------------------------------------------- helpers
select test.eq('split address: street, unit, city, province, postal code', app.split_ca_address('2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2'),
  '{"address_line1": "2967 Dundas St W", "unit": "208B", "city": "Toronto", "province": "ON", "postal_code": "M6P 1Z2"}'::jsonb);
select test.eq('split address: no unit, the postal code without its space, the province spelled out',
  app.split_ca_address('1570 Midland Ave, Toronto, Ontario m1p3c2') ->> 'address_line1' || '/' || coalesce(app.split_ca_address('1570 Midland Ave, Toronto, Ontario m1p3c2') ->> 'unit', 'none') || '/'
  || (app.split_ca_address('1570 Midland Ave, Toronto, Ontario m1p3c2') ->> 'city') || '/' || (app.split_ca_address('1570 Midland Ave, Toronto, Ontario m1p3c2') ->> 'province') || '/'
  || (app.split_ca_address('1570 Midland Ave, Toronto, Ontario m1p3c2') ->> 'postal_code'), '1570 Midland Ave/none/Toronto/ON/M1P 3C2');
select test.eq('split address: nothing to split', app.split_ca_address(null) ->> 'address_line1', null::text);
select test.eq('street parts: number and name', app.street_parts('1204 Bay Street'), '{"number": "1204", "name": "Bay Street"}'::jsonb);
select test.eq('street parts: a rural route has no number', app.street_parts('RR 2 Concession 4') ->> 'name', 'RR 2 Concession 4');
select test.eq('registry name: LAST, FIRST M', app.registry_person_name('Tremblay', 'Olivia', 'Margaret', 'Olivia Margaret Tremblay'), 'TREMBLAY, OLIVIA M');
select test.eq('registry name: no parts, the legal name in capitals', app.registry_person_name(null, null, null, 'Olivia Tremblay'), 'OLIVIA TREMBLAY');
select test.eq('phone: with its country code, like ten digits', app.apply_transform('+14165550142', 'phone') || '/' || app.apply_transform('416 555 0142', 'phone') || '/' || app.apply_transform('+44 20 7946 0958', 'phone'),
  '(416) 555-0142/(416) 555-0142/+44 20 7946 0958');

-- ---------------------------------------------------------------- fixtures: an individual and a corporation, a car per method
update program_settings set company_rin = 'R1234-56789', company_address = '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', signing_officer_name = 'Abbas Al-Mashita'
 where id = (select id from app.settings());
select test.mk_user('ff_admin', 'admin');
select test.mk_owner('ff_olivia');
update owners set first_name = 'Olivia', middle_name = 'Margaret', last_name = 'Tremblay', legal_name = 'Olivia Margaret Tremblay', address_line1 = '1204 Bay Street',
       address_line2 = 'Unit 1807', city = 'Toronto', province = 'ON', postal_code = 'M5R 2A5', phone = '+14165550142', corporation_name = 'Tremblay Mobility Inc.',
       corporation_number = '1001234567' where id = test.id('owner:ff_olivia');
insert into owner_private_details (owner_id, licence_number, licence_province, date_of_birth) values (test.id('owner:ff_olivia'), 'T6512-48390-85421', 'ON', date '1985-02-03');
select test.mk_owner('ff_north');
update owners set owner_type = 'corporation', legal_name = 'Northshore Auto Holdings Ltd.', corporation_name = 'Northshore Auto Holdings Ltd.', registrant_identification_number = 'C9876-54321',
       signing_officer_name = 'Daniel Okafor', signing_officer_title = 'Secretary', address_line1 = '88 Queens Quay W', address_line2 = 'Suite 2500', city = 'Toronto', province = 'ON',
       postal_code = 'M5J 0B8' where id = test.id('owner:ff_north');
select test.mk_vehicle('ff_s2', 'ff_olivia');
select test.mk_vehicle('ff_s3', 'ff_olivia');
select test.mk_vehicle('ff_s1', 'ff_north');
select test.mk_vehicle('ff_s6', 'ff_north');
update vehicle_schedules set onboarding_method = 'lease_new_owner_corporation' where vehicle_id = test.id('vehicle:ff_s2');
update vehicle_schedules set onboarding_method = 'co_registrant' where vehicle_id = test.id('vehicle:ff_s3');
update vehicle_schedules set onboarding_method = 'lease_existing_corporation', held_by = 'corporation' where vehicle_id = test.id('vehicle:ff_s1');
update vehicle_schedules set onboarding_method = 'transfer', held_by = 'corporation', title_status = 'leased', finance_party_name = 'BMW Financial Services', finance_permission = 'attached' where vehicle_id = test.id('vehicle:ff_s6');
insert into vehicle_onboardings (vehicle_id, government_forms)
select v.id, i.government_forms from vehicles v join vehicle_schedules s on s.vehicle_id = v.id join onboarding_method_info i on i.method = s.onboarding_method
 where v.id in (test.id('vehicle:ff_s1'), test.id('vehicle:ff_s2'), test.id('vehicle:ff_s3'), test.id('vehicle:ff_s6'));

-- ---------------------------------------------------------------- the context, by method
select test.eq('CarmaCars: its address in the forms'' boxes, its legal name in capitals',
  (select (c #>> '{registrant,address_line1}') || '/' || (c #>> '{registrant,unit}') || '/' || (c #>> '{registrant,city}') || '/' || (c #>> '{registrant,postal_code}') || '/' || (c #>> '{registrant,registry_name}')
     from app.registry_context(test.id('vehicle:ff_s2')) c), '2967 Dundas St W/208B/Toronto/M6P 1Z2/18122211 CANADA INC.');
select test.eq('Lease (new corporation): the corporation is the vehicle''s registrant, at the owner''s address; CarmaCars holds the plates; the owner signs',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{vehicle_registrant,unit}') || '/' || coalesce(c #>> '{vehicle_registrant,date_of_birth}', 'no birth date') || '/'
          || (c #>> '{method,plates_other}') || '/' || (c #>> '{method,two_registrants}') || '/' || (c #>> '{plate_owner,name}') || '/' || (c #>> '{vehicle_registrant,owner_signs}')
     from app.registry_context(test.id('vehicle:ff_s2')) c), 'TREMBLAY MOBILITY INC./1807/no birth date/true/false/18122211 CANADA INC./true');
select test.eq('Lease (existing corporation): the corporation''s RIN, its signing officer signs',
  (select (c #>> '{vehicle_registrant,rin}') || '/' || (c #>> '{vehicle_registrant,signer_name}') from app.registry_context(test.id('vehicle:ff_s1')) c), 'C9876-54321/Daniel Okafor');
select test.eq('Co-Registrant: the owner in the registry''s name order, licence and birth date; two registrants; plates not someone else''s',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{vehicle_registrant,rin}') || '/' || (c #>> '{vehicle_registrant,date_of_birth}') || '/' || (c #>> '{method,two_registrants}') || '/' || (c #>> '{method,plates_other}')
     from app.registry_context(test.id('vehicle:ff_s3')) c), 'TREMBLAY, OLIVIA M/T6512-48390-85421/1985-02-03/true/false');
select test.eq('Transfer of a leased car: the lessor keeps the vehicle, CarmaCars holds the plates and signs, not the owner',
  (select (c #>> '{vehicle_registrant,name}') || '/' || (c #>> '{method,plates_other}') || '/' || (c #>> '{vehicle_registrant,signer_name}') || '/' || (c #>> '{vehicle_registrant,owner_signs}')
     from app.registry_context(test.id('vehicle:ff_s6')) c), 'BMW FINANCIAL SERVICES/true/Abbas Al-Mashita/false');
select test.eq('the owner: street number and name apart', (select (c #>> '{owner,street_number}') || '|' || (c #>> '{owner,street_name}') from app.registry_context(test.id('vehicle:ff_s2')) c), '1204|Bay Street');
select test.ok('the sources list every new path, and every path of every mapping is a source',
  (select bool_and(p in (select x ->> 'path' from jsonb_array_elements(app.registry_sources()) x))
     from (select coalesce(e.value ->> 'source', 'always') p from pdf_templates t, jsonb_each(t.field_map) e where t.is_current and t.notes like '%Mapping checked%'
           union select e.value ->> 'when' from pdf_templates t, jsonb_each(t.field_map) e where t.is_current and e.value ? 'when') x));

-- ---------------------------------------------------------------- the checked mappings, filled
select test.eq('the five official forms carry the checked mapping (no Admin had saved one)',
  (select count(*) from pdf_templates where is_current and notes like '%Mapping checked against the official PDF%'), 5::bigint);
select test.lives('the checked mappings pass the mapping checks of 0042', $$select app.form_template_map(test.id('ff_admin'), jsonb_build_object('template', t.id, 'field_map', t.field_map)) from pdf_templates t where t.is_current$$);
-- form_template_map saved them in an Admin's name: a second run of the remap leaves an Admin's mapping alone
select test.eq('an Admin''s own mapping is never replaced', (select sum(app.official_form_remap(t.form_code, t.sha256, t.field_names, '{}'::jsonb, 'x')) from pdf_templates t where t.is_current), 0::bigint);
-- filled in one statement, read in the next (a statement does not see the rows it inserts through a function)
create temp table ff_ids as select s.label, f.fill_id from (values ('ff_s1', 'S1'), ('ff_s2', 'S2'), ('ff_s3', 'S3'), ('ff_s6', 'S6')) s(car, label)
  cross join lateral app.fill_vehicle_government_forms(test.id('vehicle:' || s.car)) f;
create temp table ff_fill as select g.form_code, i.label, g.field_values v from ff_ids i join government_form_fills g on g.id = i.fill_id;
select test.eq('SR-LV-006, Lease: the corporation and its address in four boxes; the plates box ticked; the VIN in section 7',
  (select (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[2]') || '/' || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].streetName[0]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].apt[0]') || '/' || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].city[0]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].postalCode[0]') || '/' || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[2].#field[13]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].businessInfo6[0].#field[0]') = 'TREMBLAY MOBILITY INC./1204 Bay Street/1807/Toronto/M5R 2A5/Yes/' || (select upper(vin) from vehicles where id = test.id('vehicle:ff_s2'))
     from ff_fill where form_code = 'SR-LV-006' and label = 'S2'), true);
select test.eq('SR-LV-006, Lease: the owner signs section 8 (the signature box is kept for this car)',
  (select v ? 'form1[0].page1[0].body[0].businessInfo7[0].signature[0]' from ff_fill where form_code = 'SR-LV-006' and label = 'S2') || '/'
  || (select v ? 'form1[0].page1[0].body[0].businessInfo7[0].signature[0]' from ff_fill where form_code = 'SR-LV-006' and label = 'S6'), 'true/false');
select test.eq('SR-LV-012, Lease: CarmaCars in section 1 with its street line alone; section 2 empty; no signature for the owner',
  (select (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[3]') || '/' || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].streetName[0]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].postalCode[0]') || '/' || (v ? 'form1[0].page1[0].body[0].businessInfo[0].#subform[0].lastName[3]') || '/'
          || (v ? 'form1[0].page1[0].body[0].businessInfo[0].signature[0]')
     from ff_fill where form_code = 'SR-LV-012' and label = 'S1'), '18122211 CANADA INC./2967 Dundas St W/M6P 1Z2/false/false');
select test.eq('SR-LV-012, Co-Registrant: section 1 empty; the owner and CarmaCars in section 2; the owner signs the first line',
  (select (v ? 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[3]') || '/' || (v ->> 'form1[0].page1[0].body[0].businessInfo[0].#subform[0].lastName[3]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].businessInfo[0].#subform[4].lastName[7]') || '/' || (v ->> 'form1[0].page1[0].body[0].businessInfo[0].#subform[4].city[1]') || '/'
          || (v ? 'form1[0].page1[0].body[0].businessInfo[0].signature[0]')
     from ff_fill where form_code = 'SR-LV-012' and label = 'S3'), 'false/TREMBLAY, OLIVIA M/18122211 CANADA INC./Toronto/true');
select test.eq('013-0169: street number and name apart, the phone as written, the province for the drop-down',
  (select (v ->> 'form1[0].page1[0].body[0].SectionB[0].#subform[1].busStreetNo[0]') || '/' || (v ->> 'form1[0].page1[0].body[0].SectionB[0].#subform[1].busStreetName[0]') || '/'
          || (v ->> 'form1[0].page1[0].body[0].SectionB[0].#subform[1].TelephoneNo[0]') || '/' || (v ->> 'form1[0].page1[0].body[0].SectionB[0].#subform[1].busProvince[0]')
     from ff_fill where form_code = '013-0169' and label = 'S2'), '1204/Bay Street/(416) 555-0142/ON');

-- ---------------------------------------------------------------- a form already in use for owners is filled again from the checked mapping
update pdf_templates set field_map = '{"form1[0].page1[0].body[0].personalInfo[0].#subform[0].streetName[0]": {"source": "registrant.address"}}'::jsonb, mapped_by = null, verified = true,
       verified_by = test.id('ff_admin'), verified_at = now() where form_code = 'SR-LV-006' and is_current;
select test.eq('in use and untouched by an Admin: remapped, and every unsigned form of the kind filled again',
  (select app.official_form_remap('SR-LV-006', t.sha256, t.field_names, (select field_map from pdf_templates where id = t.id) || '{"form1[0].page1[0].body[0].personalInfo[0].#subform[0].city[0]": {"source": "vehicle_registrant.city"}}'::jsonb, t.notes)
     from pdf_templates t where t.form_code = 'SR-LV-006' and t.is_current) >= 4, true);
select test.eq('the forms filled again carry the city in its box', (select g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].city[0]' from government_form_fills g
  where g.vehicle_id = test.id('vehicle:ff_s2') and g.form_code = 'SR-LV-006' and g.superseded_at is null), 'Toronto');

-- ---------------------------------------------------------------- the owner agreements name the company by its legal name
select test.eq('owner agreement facts: the company''s legal name', public.server_owner_agreement_facts(test.id('owner:ff_north'), test.id('ff_admin')) #>> '{company,legal_name}',
  (select company_legal_name from app.settings()));
select test.ok('privileges: the new functions are the service role''s', not has_function_privilege('authenticated', 'public.server_sign_request_document(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.server_sign_request_document(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.registry_context(uuid)', 'execute')
  and not has_function_privilege('anon', 'app.official_form_remap(text, text, jsonb, jsonb, text)', 'execute'));
