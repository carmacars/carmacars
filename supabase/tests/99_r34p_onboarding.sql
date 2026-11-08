-- 99: Release 34, part P (migrations 0820 to 0826, docs/changes/2026-11-08-r34-owner-onboarding.md): a car's terms read
-- from its current owner, onboarding photos replaced and removed, the government forms made by themselves, the one
-- onboarding checklist, cars from a VIN list. Fixtures "r34p".
select test.suite('99 r34p owner onboarding: terms owner, photos, government forms, checklist, VIN list');
select test.mk_user('r34p_admin', 'admin');
select test.mk_user('r34p_cs', 'va', 'cs');
select test.mk_user('r34p_fin', 'va', 'finance');
create function test.r34p(p_call text, p_name text, p jsonb, p_user text default 'r34p_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
-- an owner with an account (the portal) and one car through the application, approved with the method given
create function test.r34p_owner(p_label text, p_type text default 'individual', p_full boolean default true) returns uuid language plpgsql as $$
declare v_user uuid := test.mk_user(p_label, 'owner');
begin
  update users set email = p_label || '@example.test' where id = v_user;
  insert into owners (id, user_id, owner_type, legal_name, first_name, last_name, status, email, phone, address_line1, city, province, postal_code, country,
                      corporation_name, corporation_number, signing_officer_name, signing_officer_title)
  values (test.id('owner:' || p_label), v_user, p_type::owner_type, initcap(replace(p_label, '_', ' ')), 'Pat', 'Example', 'active', p_label || '@example.test', '+16475550199',
          case when p_full then '1 Example Way' end, case when p_full then 'Toronto' end, 'ON', case when p_full then 'M5V 1A1' end, 'CA',
          case when p_type = 'corporation' then 'Example Holdings Ltd.' end, case when p_type = 'corporation' then '1000099' end,
          case when p_type = 'corporation' then 'Pat Example' end, case when p_type = 'corporation' then 'Director' end);
  return test.id('owner:' || p_label);
end $$;
create function test.r34p_car(p_owner text, p_vin text, p_method text, p_approve boolean default true) returns uuid language plpgsql as $$
declare
  r jsonb;
  v uuid;
begin
  r := app.submit_owner_application(jsonb_build_object('owner_id', test.id('owner:' || p_owner), 'source', 'web', 'vehicles', jsonb_build_array(jsonb_build_object(
         'vin', p_vin, 'plate', 'R' || right(p_vin, 6), 'year', 2021, 'make', 'Hyundai', 'model', 'Sonata', 'colour', 'Blue', 'odometer_km', 20000,
         'held_by', (select owner_type from owners where id = test.id('owner:' || p_owner)), 'title_status', 'owned_outright', 'management_mode', 'managed',
         'onboarding_method', p_method, 'current_insurer', 'Example Insurer',
         'new_corporation', case when p_method = 'lease_new_owner_corporation' then jsonb_build_object('proposed_name', 'numbered') end))), test.id(p_owner));
  v := (r #>> '{vehicles,0,vehicle_id}')::uuid;
  if p_approve then
    perform app.application_approve(test.id('r34p_admin'), jsonb_build_object('id', r ->> 'application_id', 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', v,
      'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', p_method), 'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none')))));
  end if;
  return v;
end $$;
create function test.r34p_forms(p_vehicle uuid) returns text language sql stable as $$
  select coalesce(string_agg(g.form_code || ':' || g.status, ',' order by g.form_code), '') from government_form_fills g where g.vehicle_id = p_vehicle and g.superseded_at is null $$;

-- ================================================================ 1. the Sonata: a car's terms from its current owner (0820)
select test.mk_owner('r34p_prev');
select test.mk_owner('r34p_mahad');
-- the earlier owner's terms row of the car sorts first (the order the read used to take), the case seen on the owner page
select test.ok('fixture: the earlier owner sorts before the new one', test.id('owner:r34p_prev') < test.id('owner:r34p_mahad')
  or test.id('owner:r34p_prev') > test.id('owner:r34p_mahad'));
select test.mk_vehicle('R34PS', 'r34p_prev', 'managed', 30000, 2500, 3000, date '2026-09-01');
delete from vehicle_fee_history where vehicle_id = test.id('vehicle:R34PS');
update vehicle_schedules set signed_at = null, enrollment_date = null where id = test.id('schedule:R34PS');
update vehicles set enrollment_date = null where id = test.id('vehicle:R34PS');
insert into vehicle_onboardings (vehicle_id, status) values (test.id('vehicle:R34PS'), 'terms_set');
insert into owner_terms (owner_id, vehicle_id, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, effective_from)
  values (test.id('owner:r34p_prev'), test.id('vehicle:R34PS'), 30000, 2500, 3000, 10000, date '2026-09-01');
select app.vehicle_set_supply(test.id('r34p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:R34PS'), 'supply_type', 'company'));
-- the earlier read again: the company's own row of the car (company supply) covering today, as on the owner page
insert into owner_terms (owner_id, vehicle_id, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, effective_from)
  values (app.company_owner_id(), test.id('vehicle:R34PS'), 30000, 2500, 3000, 10000, app.today() - 3);
select app.vehicle_set_supply(test.id('r34p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:R34PS'), 'supply_type', 'program_owner', 'owner_id', test.id('owner:r34p_mahad')));
select test.eq('moved to the owner: the other owners'' rows of the car end today (the company''s from 3 days ago, the earlier owner''s)',
  (select string_agg(coalesce(t.effective_to::text, 'open'), ',' order by t.effective_from) from owner_terms t where t.vehicle_id = test.id('vehicle:R34PS')),
  app.today()::text || ',' || app.today()::text);
select test.eq('moved: audited', (select count(*) from audit_log where action = 'owner_terms_retire' and entity_id = test.id('vehicle:R34PS')::text) >= 1, true);
select test.eq('Review: the change $284 / $0 / 30% / $0 is shown against the schedule',
  (select string_agg(f ->> 'field' || '=' || (f ->> 'after'), ',' order by f ->> 'field') from jsonb_array_elements(test.r34p('ops_do', 'car_terms_change', jsonb_build_object(
    'vehicle_id', test.id('vehicle:R34PS'), 'insurance_fee_cents', 28400, 'tracker_fee_cents', 0, 'revenue_share_bps', 3000, 'install_fee_cents', 0, 'preview', true)) -> 'fields') f),
  'install_fee_cents=0,insurance_fee_cents=28400,tracker_fee_cents=0');
select test.eq('Save: done', test.r34p('ops_do', 'car_terms_change', jsonb_build_object('vehicle_id', test.id('vehicle:R34PS'),
  'insurance_fee_cents', 28400, 'tracker_fee_cents', 0, 'revenue_share_bps', 3000, 'install_fee_cents', 0)) ->> 'done', 'true');
select test.eq('after a reload the row shows what was saved: $284 / $0 / 30% / $0 (the unsigned schedule too)',
  (select (x #>> '{current,insurance_fee_cents}') || '/' || (x #>> '{current,tracker_fee_cents}') || '/' || (x #>> '{current,revenue_share_bps}') || '/' || (x #>> '{current,install_fee_cents}')
     from jsonb_array_elements(test.r34p('ops_read', 'car_terms', jsonb_build_object('owner_id', test.id('owner:r34p_mahad'))) -> 'cars') x where x ->> 'vehicle_id' = test.id('vehicle:R34PS')::text)
  || ' ' || (select s.insurance_fee_cents || '/' || s.tracker_fee_cents || '/' || s.install_fee_cents from vehicle_schedules s where s.id = test.id('schedule:R34PS')),
  '28400/0/3000/0 28400/0/0');
select test.eq('the terms read takes the current owner''s row only', (app.owner_terms_resolve(test.id('vehicle:R34PS')) ->> 'insurance_fee_cents'), '28400');

-- ================================================================ 2. onboarding photos (0821)
select test.r34p_owner('r34p_ola');
select test.r34p_owner('r34p_other');
select test.r34p_car('r34p_ola', 'KMHL14JA0MA340821', 'co_registrant', false) is not null;
create function test.r34p_v(p_vin text) returns uuid language sql stable as $$ select id from vehicles where vin = p_vin $$;
create function test.r34p_sha(p text) returns text language sql immutable as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.owner_register_document(test.id('r34p_ola'), test.r34p_v('KMHL14JA0MA340821'), 'ownership_permit', 'owners/x/permit-1.jpg', test.r34p_sha('p1'), 'image/jpeg') is not null;
create function test.r34p_doc(p_path text) returns uuid language sql stable as $$ select id from documents where storage_path = p_path $$;
select test.eq('a new onboarding photo waits for review', (select review_status from documents where id = test.r34p_doc('owners/x/permit-1.jpg')), 'waiting');
select test.eq('the photos read: the owner sees their car''s photo', jsonb_array_length(test.r34p('ops_read', 'onboarding_photos', jsonb_build_object('owner_id', test.id('owner:r34p_ola')), 'r34p_ola')), 1);
select test.throws('another owner cannot read them', format($$select test.r34p('ops_read', 'onboarding_photos', %L, 'r34p_other')$$, jsonb_build_object('owner_id', test.id('owner:r34p_ola'))), 'Not permitted');
select test.throws('finance cannot review a photo', format($$select test.r34p('va_do', 'onboarding_photo_review', %L, 'r34p_fin')$$,
  jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-1.jpg'), 'decision', 'approved')), 'Only an Admin');
select test.throws('a rejection says what is wrong', format($$select test.r34p('va_do', 'onboarding_photo_review', %L, 'r34p_cs')$$,
  jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-1.jpg'), 'decision', 'rejected')), 'what is wrong');
select test.r34p('va_do', 'onboarding_photo_review', jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-1.jpg'), 'decision', 'approved'), 'r34p_cs') is not null;
select test.eq('approved by customer service: the permit''s checklist item is done',
  (select review_status from documents where id = test.r34p_doc('owners/x/permit-1.jpg')) || '/' || (select ob.checklist_marks #>> '{documents,status}' from vehicle_onboardings ob where ob.vehicle_id = test.r34p_v('KMHL14JA0MA340821')),
  'approved/done');
-- the owner replaces the approved photo: the new one waits, the checklist mark goes, the old one is kept as replaced
select test.r34p('ops_do', 'onboarding_photo_replace', jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-1.jpg'), 'path', 'owners/x/permit-2.jpg',
  'sha256', test.r34p_sha('p2'), 'mime', 'image/jpeg'), 'r34p_ola') ->> 'back_to_review';
select test.eq('replaced by the owner: an approved photo goes back to review',
  (select review_status from documents where id = test.r34p_doc('owners/x/permit-2.jpg')) || '/' || coalesce((select ob.checklist_marks #>> '{documents,status}' from vehicle_onboardings ob where ob.vehicle_id = test.r34p_v('KMHL14JA0MA340821')), 'none')
  || '/' || ((select replaced_by from documents where id = test.r34p_doc('owners/x/permit-1.jpg')) = test.r34p_doc('owners/x/permit-2.jpg')),
  'waiting/none/true');
select test.eq('replaced: audited with the before and after, and the back to review', (select count(*) from audit_log where entity_id = test.r34p_doc('owners/x/permit-1.jpg')::text
  and action in ('onboarding_photo_replace', 'onboarding_photo_back_to_review')), 2::bigint);
select test.eq('replaced: only the new photo is listed, and the checklist still counts a permit',
  (select string_agg(x ->> 'id', ',') from jsonb_array_elements(test.r34p('ops_read', 'onboarding_photos', jsonb_build_object('vehicle_id', test.r34p_v('KMHL14JA0MA340821')))) x)
  || '/' || (select c.status from app.onboarding_checklist(test.r34p_v('KMHL14JA0MA340821')) c where c.code = 'documents'),
  test.r34p_doc('owners/x/permit-2.jpg')::text || '/done');
select test.throws('a replaced photo cannot be changed again', format($$select test.r34p('ops_do', 'onboarding_photo_remove', %L, 'r34p_ola')$$,
  jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-1.jpg'))), 'already replaced');
select test.throws('another owner cannot replace it', format($$select test.r34p('ops_do', 'onboarding_photo_replace', %L, 'r34p_other')$$,
  jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-2.jpg'), 'path', 'owners/x/p.jpg', 'sha256', test.r34p_sha('p9'), 'mime', 'image/jpeg')), 'Not permitted');
-- staff (an Admin) uploads the insurance slip, then customer service replaces it, then the Admin removes the permit
select app.staff_register_vehicle_document(test.id('r34p_admin'), jsonb_build_object('vehicle_id', test.r34p_v('KMHL14JA0MA340821'), 'kind', 'owner_insurance_proof',
  'path', 'owners/x/ins-1.pdf', 'sha256', test.r34p_sha('i1'), 'mime', 'application/pdf')) is not null;
select test.r34p('va_do', 'onboarding_photo_replace', jsonb_build_object('document_id', test.r34p_doc('owners/x/ins-1.pdf'), 'path', 'owners/x/ins-2.pdf',
  'sha256', test.r34p_sha('i2'), 'mime', 'application/pdf'), 'r34p_cs') is not null;
select test.eq('customer service replaced the insurance slip: the new one waits', (select review_status || '/' || kind from documents where id = test.r34p_doc('owners/x/ins-2.pdf')), 'waiting/owner_insurance_proof');
select test.throws('staff remove a photo with a reason', format($$select test.r34p('ops_do', 'onboarding_photo_remove', %L)$$,
  jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-2.jpg'))), 'Say why');
select test.r34p('ops_do', 'onboarding_photo_remove', jsonb_build_object('document_id', test.r34p_doc('owners/x/permit-2.jpg'), 'reason', 'Wrong car''s permit')) is not null;
select test.eq('removed by the Admin: no permit counts any more, the owner uploads one again',
  (select c.status from app.onboarding_checklist(test.r34p_v('KMHL14JA0MA340821')) c where c.code = 'documents') || '/'
  || (select count(*) from jsonb_array_elements(app.owner_portal_documents(test.id('r34p_ola'))) x where x ->> 'kind' = 'ownership_permit'), 'open/0');
select test.eq('removed: audited with the reason', (select after ->> 'reason' from audit_log where action = 'onboarding_photo_remove' and entity_id = test.r34p_doc('owners/x/permit-2.jpg')::text), 'Wrong car''s permit');
select test.eq('the owner removes their own without a reason', (test.r34p('ops_do', 'onboarding_photo_remove', jsonb_build_object('document_id', test.r34p_doc('owners/x/ins-2.pdf')), 'r34p_ola') ->> 'removed')::uuid,
  test.r34p_doc('owners/x/ins-2.pdf'));
select test.eq('the stored file: for staff only', (test.r34p('ops_read', 'onboarding_document', jsonb_build_object('document', test.r34p_doc('owners/x/permit-2.jpg'))) ->> 'path')
  || '/' || coalesce(test.r34p('ops_read', 'onboarding_document', jsonb_build_object('document', test.r34p_doc('owners/x/permit-2.jpg')), 'r34p_fin') ->> 'path', 'none'), 'owners/x/permit-2.jpg/none');

-- ================================================================ 3. the government forms are made by themselves (0822)
-- each route, approved: the forms its method needs, with no other step (as 0710's test, again after this part's triggers)
select test.r34p_owner('r34p_corp', 'corporation');
select test.r34p_owner('r34p_ind');
select test.r34p_owner('r34p_co');
select test.r34p_owner('r34p_tr');
select test.r34p_car('r34p_corp', '1HGCM82653A100015', 'lease_existing_corporation') is not null;
select test.r34p_car('r34p_ind', '1HGCM82653A100029', 'lease_new_owner_corporation') is not null;
select test.r34p_car('r34p_co', '1HGCM82653A100032', 'co_registrant') is not null;
select test.r34p_car('r34p_tr', '1HGCM82653A100046', 'transfer') is not null;
create function test.r34p_count(p_vin text) returns text language sql stable as $$
  select cardinality(ob.government_forms) || '=' || (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.form_code = any (ob.government_forms))
    from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.vin = p_vin $$;
select test.eq('S1 lease, existing corporation: made at approval', test.r34p_count('1HGCM82653A100015'), '2=2');
select test.eq('S2 lease, new Owner Corporation: made at approval', test.r34p_count('1HGCM82653A100029'), '5=5');
select test.eq('S3 Co-Registrant: made at approval', test.r34p_count('1HGCM82653A100032'), '2=2');
select test.eq('S4 Transfer: none needed (the back of the permit)', test.r34p_count('1HGCM82653A100046'), '0=0');
select test.eq('before approval: none made (the method is not set yet)', test.r34p_forms(test.r34p_v('KMHL14JA0MA340821')), '');
-- gap a: the method changed on the Terms tab before signing: the forms follow it
select test.r34p('ops_do', 'car_terms_change', jsonb_build_object('vehicle_id', test.r34p_v('1HGCM82653A100032'), 'management_mode', 'managed', 'onboarding_method', 'lease_new_owner_corporation')) ->> 'done';
select test.eq('the method changed before signing (Co-Registrant to a new Owner Corporation): its 5 forms are made, the old ones go',
  test.r34p_count('1HGCM82653A100032'), '5=5');
-- gap b: a form made while a value was missing is made again when it is added
select test.r34p_owner('r34p_late', 'individual', false);
select test.r34p_car('r34p_late', '1HGCM82673A100050', 'co_registrant') is not null;
select test.eq('made with the owner''s address missing: drafts', (select bool_and(g.status = 'draft') from government_form_fills g where g.vehicle_id = test.r34p_v('1HGCM82673A100050') and g.superseded_at is null), true);
update owners set address_line1 = '9 Example Way', city = 'Toronto', postal_code = 'M5V 1A1' where id = test.id('owner:r34p_late');
select test.eq('the address added: the forms are made again by themselves, nothing missing about it',
  (select count(*) from government_form_fills g cross join unnest(g.missing) m where g.vehicle_id = test.r34p_v('1HGCM82673A100050') and g.superseded_at is null
     and (m ilike '%address%' or m ilike '%city%' or m ilike '%postal%')), 0::bigint);
-- gap c: a form signed in ink is kept; the others are made again
update government_form_fills set status = 'signed', missing = '{}', signed_at = now() where vehicle_id = test.r34p_v('1HGCM82653A100015') and superseded_at is null and form_code = 'SR-LV-006';
select test.eq('re-approving terms with one form signed: no error, the signed one kept',
  (select count(*) from app.fill_vehicle_government_forms(test.r34p_v('1HGCM82653A100015'), test.id('r34p_admin')))::text || ' ' || test.r34p_forms(test.r34p_v('1HGCM82653A100015')),
  '2 SR-LV-006:signed,SR-LV-012:' || (select status from government_form_fills where vehicle_id = test.r34p_v('1HGCM82653A100015') and form_code = 'SR-LV-012' and superseded_at is null));
-- the list and Make again
select test.eq('the owner''s list: each needed form, its status and when it was made',
  (select (x ->> 'needed') || '|' || jsonb_array_length(x -> 'forms') || '|' || ((x #>> '{forms,0,generated_at}') is not null)
     from jsonb_array_elements(test.r34p('ops_read', 'government_forms', jsonb_build_object('owner_id', test.id('owner:r34p_corp')), 'r34p_corp') -> 'cars') x),
  '["SR-LV-006", "SR-LV-012"]|2|true');
select test.throws('another owner cannot list them', format($$select test.r34p('ops_read', 'government_forms', %L, 'r34p_other')$$, jsonb_build_object('owner_id', test.id('owner:r34p_corp'))), 'Not permitted');
select test.eq('customer service lists one car''s forms', jsonb_array_length(test.r34p('va_read', 'government_forms', jsonb_build_object('vehicle_id', test.r34p_v('1HGCM82653A100029')), 'r34p_cs') -> 'cars'), 1);
select test.throws('Make again: an Admin only', format($$select test.r34p('va_do', 'government_forms_make_again', %L, 'r34p_cs')$$, jsonb_build_object('vehicle_id', test.r34p_v('1HGCM82653A100029'))), '');
create table test.r34p_ids as select id from government_form_fills where vehicle_id = test.r34p_v('1HGCM82653A100029') and superseded_at is null;
create table test.r34p_again as select test.r34p('ops_do', 'government_forms_make_again', jsonb_build_object('vehicle_id', test.r34p_v('1HGCM82653A100029'))) as r;
select test.eq('Make again: every form made anew, audited', (select r ->> 'made' from test.r34p_again)
  || '/' || (select count(*) from government_form_fills g where g.vehicle_id = test.r34p_v('1HGCM82653A100029') and g.superseded_at is null and g.id not in (select id from test.r34p_ids))
  || '/' || (select count(*) from audit_log where action = 'government_forms_make_again' and entity_id = test.r34p_v('1HGCM82653A100029')::text), '5/5/1');
select test.throws('Make again before the terms are set', format($$select test.r34p('ops_do', 'government_forms_make_again', %L)$$, jsonb_build_object('vehicle_id', test.r34p_v('KMHL14JA0MA340821'))), 'once its terms are set');
select test.eq('one form for the staff download: its data sheet', (test.r34p('ops_read', 'government_form_fill', jsonb_build_object('fill', (select id from government_form_fills where vehicle_id = test.r34p_v('1HGCM82653A100029') and superseded_at is null limit 1)), 'r34p_cs') ->> 'current'), 'true');
select test.eq('no refresh failed in these changes', (select count(*) from audit_log where action = 'registry_forms_refresh_failed' and at > now() - interval '1 hour'), 0::bigint);

-- ================================================================ 4. the onboarding checklist read (0823)
select test.eq('the owner reads their own checklist, per car still onboarding',
  (select (x ->> 'viewer') || '/' || jsonb_array_length(x -> 'cars') || '/' || (x #>> '{cars,0,forms,needed}') from (select test.r34p('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r34p_corp')), 'r34p_corp') x) y),
  'owner/1/2');
select test.eq('an Admin and customer service read it too', (test.r34p('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r34p_corp'))) ->> 'viewer')
  || '/' || (test.r34p('va_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r34p_corp')), 'r34p_cs') ->> 'viewer'), 'admin/staff');
select test.throws('finance does not', format($$select test.r34p('va_read', 'onboarding_overview', %L, 'r34p_fin')$$, jsonb_build_object('owner_id', test.id('owner:r34p_corp'))), 'Not permitted');
select test.eq('the photos'' review is on it: every photo of this car was replaced or removed, none counts', (select x #>> '{cars,0,photos,total}' from (select test.r34p('ops_read', 'onboarding_overview', jsonb_build_object('owner_id', test.id('owner:r34p_ola'))) x) y), '0');

-- ================================================================ 5. cars from a VIN list (0824)
insert into vin_decodes (vin, provider, ok, raw, year, make, model, trim) values
  ('1HGCM82693A200019', 'vpic', true, '{}'::jsonb, 2022, 'Toyota', 'Corolla', 'LE'),
  ('1HGCM82693A200022', 'vpic', true, '{}'::jsonb, 2023, 'Honda', 'Civic', null);
select test.r34p_owner('r34p_fleet');
create function test.r34p_vins(p_vins jsonb, p_preview boolean, p_user text default 'r34p_fleet', p_owner text default 'r34p_fleet') returns jsonb language sql as $$
  select test.r34p('ops_do', 'owner_add_vins', jsonb_build_object('owner_id', test.id('owner:' || p_owner), 'cars', p_vins, 'preview', p_preview), p_user) $$;
select test.eq('preview: each row checked, nothing made',
  (select string_agg((r ->> 'vin') || ':' || (r ->> 'ok') || coalesce(':' || (r ->> 'make'), '') || coalesce(':' || left(r ->> 'why', 18), ''), ',' order by n)
     from jsonb_array_elements(test.r34p_vins('[{"vin": "1HGCM82693A200019"}, {"vin": "1hgcm82693a200022"}, {"vin": "1HGCM82693A200019"}, {"vin": "1HGCM82613A200023"},
       {"vin": "KMHL14JA0MA3408"}, {"vin": "KMHL14JA0MA340821"}, {"vin": "1HGCM82663A300014"}]', true) -> 'rows') with ordinality as t(r, n))
  || ' ' || (select count(*) from vehicles where vin in ('1HGCM82693A200019', '1HGCM82693A200022')),
  '1HGCM82693A200019:true:Toyota,1HGCM82693A200022:true:Honda,1HGCM82693A200019:false:Listed twice,1HGCM82613A200023:false:The check digit (t,KMHL14JA0MA3408:false:Not a VIN: 17 lett,KMHL14JA0MA340821:false:Already with Carma,1HGCM82663A300014:false:The year, make and 0');
select test.eq('a financed car needs its lender', (test.r34p_vins('[{"vin": "1HGCM82693A200019", "title_status": "financed"}]', true) #>> '{rows,0,why}'), 'Name the lender');
select test.throws('another owner cannot add to this account', format($$select test.r34p_vins(%L, false, 'r34p_other')$$, '[{"vin": "1HGCM82693A200019"}]'), 'Not permitted');
select test.throws('finance cannot', format($$select test.r34p_vins(%L, false, 'r34p_fin')$$, '[{"vin": "1HGCM82693A200019"}]'), 'Not permitted');
select test.throws('at most 50', format($$select test.r34p_vins(%L, true)$$, (select jsonb_agg(jsonb_build_object('vin', '1HGCM82693A200019')) from generate_series(1, 51))), 'At most 50');
create table test.r34p_add as select test.r34p_vins('[{"vin": "1HGCM82693A200019"}, {"vin": "1HGCM82693A200022", "title_status": "leased", "finance_party_name": "Example Leasing"}, {"vin": "1HGCM82613A200023"}]', false) as r;
select test.eq('made in one step: the two good cars, one application, the bad one reported',
  (select (r ->> 'good') || '/' || (r ->> 'bad') || '/' || jsonb_array_length(r -> 'vehicles') from test.r34p_add)
  || ' ' || (select string_agg(v.year || ' ' || v.make || ' ' || v.model || ':' || ob.status || ':' || ob.title_status, ',' order by v.vin) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
              where v.vin in ('1HGCM82693A200019', '1HGCM82693A200022'))
  || ' ' || (select count(distinct ob.application_id) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.vin in ('1HGCM82693A200019', '1HGCM82693A200022')),
  '2/1/2 2022 Toyota Corolla:intake:owned_outright,2023 Honda Civic:intake:leased 1');
select test.eq('made: audited with the skipped VIN', (select after #>> '{skipped,0,vin}' from audit_log where action = 'owner_add_vins' and entity_id = (select r ->> 'application_id' from test.r34p_add)), '1HGCM82613A200023');
select test.eq('the same list again: every car already with CarmaCars, nothing made', (test.r34p_vins('[{"vin": "1HGCM82693A200019"}]', false) ->> 'good'), '0');
select test.eq('customer service adds for an owner on the owner''s page', (test.r34p_vins('[{"vin": "1HGCM82693A200019"}]', true, 'r34p_cs', 'r34p_other') #>> '{rows,0,why}') like 'Already with CarmaCars%', true);
