-- 34: admin access, sample photos, the To do list, search and the owner applications inbox (migration 0054).
-- Fixtures start with "ar".
select test.suite('34 admin redesign');
grant usage on schema test to service_role;
create table test.ar (k text primary key, v jsonb);
grant select on test.ar to service_role, authenticated;
create function test.arv(p text) returns jsonb language sql stable as $$ select v from test.ar where k = p $$;
create function test.ar_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.ar_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;

select test.mk_user('ar_admin', 'admin');
select test.mk_user('ar_cs', 'va', 'cs');

-- ================================================================ 1. admin access: only rent@carmacars.ca (and the automated test account)
select test.eq('access: the setting holds rent@carmacars.ca; the automated test account is listed apart',
  (select array_to_string(admin_allowed_emails, ',') || ' / ' || array_to_string(admin_test_emails, ',') from site_settings where singleton),
  'rent@carmacars.ca / verify-admin@carmacars.ca');
insert into users (id, email, full_name) values (test.id('ar_rent'), 'rent@carmacars.ca', 'CarmaCars Admin') on conflict do nothing;
insert into users (id, email, full_name) values (test.id('ar_mallory'), 'mallory@carmacars.ca', 'Mallory Other');
select test.lives('access: rent@carmacars.ca may hold the Admin role',
  $$insert into user_roles (user_id, role) select id, 'admin' from users where lower(email) = 'rent@carmacars.ca' on conflict do nothing$$);
select test.throws('access: any other address is refused the Admin role, in the database', format($$insert into user_roles (user_id, role) values (%L, 'admin')$$, test.id('ar_mallory')),
  'Admin access is only for rent@carmacars.ca');
select test.throws('access: an invitation into the Admin role for another address is refused too',
  format($$select app.admin_invite_account(%L, %L)$$, test.id('ar_admin'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'someone.else@carmacars.ca', 'full_name', 'Someone Else', 'role', 'admin')), 'Admin access is only for');
select test.throws('access: an Admin''s address cannot be changed to another one',
  $$update users set email = 'rent2@carmacars.ca' where lower(email) = 'rent@carmacars.ca'$$, 'Admin access addresses');
select test.eq('access: Admin > Settings shows who holds the role, each allowed',
  (select bool_and((h ->> 'allowed')::boolean) from jsonb_array_elements(test.ar_read('ar_admin', 'admin_access') -> 'holders') h), true);
select test.throws('access: the list is for Admins', $$select test.ar_read('ar_cs', 'admin_access')$$, '');
select test.throws('access: an address that holds the role stays on the list', $$select test.ar_do('ar_admin', 'admin_access_save', '{"emails":["owner@carmacars.ca"]}')$$, 'stays on the list');
insert into test.ar select 'acc', test.ar_do('ar_admin', 'admin_access_save', '{"emails":["rent@carmacars.ca","abbas@carmacars.ca"]}');
select test.eq('access: adding an address is saved and audited', ((test.arv('acc') -> 'allowed') ? 'abbas@carmacars.ca') || '/' || (select count(*) from audit_log where action = 'admin_access_save'), 'true/1');
select test.ar_do('ar_admin', 'admin_access_save', '{"emails":["rent@carmacars.ca"]}');

-- ================================================================ 2. sample photos
select test.mk_owner('ar_owen');
select test.mk_vehicle('ARS', 'ar_owen');
update vehicles set body_type = 'Sport Utility Vehicle (SUV)' where id = test.id('vehicle:ARS');
select test.eq('samples: the body type is read from the car (an SUV)', app.sample_body_key(test.id('vehicle:ARS')), 'suv');
select test.eq('samples: no real photo: the car uses sample photos, the built-in SUV placeholder',
  app.vehicle_uses_sample_photos(test.id('vehicle:ARS')) || '/' || (app.vehicle_sample_photos(test.id('vehicle:ARS')) -> 0 ->> 'path') || '/' || (app.vehicle_sample_photos(test.id('vehicle:ARS')) -> 0 ->> 'sample'),
  'true//sample-photos/suv.jpg/true');
select test.eq('samples: while publishing, no photo problem for a car that uses samples (the checklist still shows photos to do)',
  (select cardinality(app.listing_photo_problems(test.id('vehicle:ARS'))) > 0) || '/' || (select set_config('app.sample_photos_ok', test.id('vehicle:ARS')::text, true) is not null)
  || '/' || cardinality(app.listing_photo_problems(test.id('vehicle:ARS'))), 'true/true/0');
select set_config('app.sample_photos_ok', '', true);
insert into test.ar select 'intake', app.start_listing_intake(test.id('ar_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:ARS')));
insert into test.ar select 'submit', app.submit_listing_intake(test.id('ar_admin'), coalesce((test.arv('intake') ->> 'intake_id'), (test.arv('intake') ->> 'id'))::uuid);
select test.eq('samples: an intake with no photo at all is submitted as it is, and the copy is still drafted',
  (test.arv('submit') ->> 'sample_photos')
  || '/' || (select count(*) from listing_jobs j where j.intake_id = coalesce((test.arv('intake') ->> 'intake_id'), (test.arv('intake') ->> 'id'))::uuid and j.kind = 'draft_copy'), 'true/1');
insert into test.ar select 'lib', test.ar_do('ar_admin', 'sample_photo_save', jsonb_build_object('make', 'Mercedes-Benz', 'model', (select model from vehicles where id = test.id('vehicle:ARS')),
  'path', 'samples/mb-c300.jpg', 'width', 1600, 'height', 1067));
select test.eq('samples: a library photo for the make and model wins over the built-in one, with its alt text',
  (app.vehicle_sample_photos(test.id('vehicle:ARS')) -> 0 ->> 'path') || '/' || (app.vehicle_sample_photos(test.id('vehicle:ARS')) -> 0 ->> 'alt' like 'Sample photo of a Mercedes-Benz%'), 'samples/mb-c300.jpg/true');
select test.throws('samples: a library photo needs a body type or a make', $$select test.ar_do('ar_admin', 'sample_photo_save', '{"path":"samples/x.jpg"}')$$, 'Choose a body type');
select test.throws('samples: the library is for Admins', $$select test.ar_do('ar_cs', 'sample_photo_save', '{"body_type":"sedan","path":"samples/x.jpg"}')$$, '');
select test.eq('samples: staff see the car in "Using sample photos"', (select count(*) from jsonb_array_elements(test.ar_read('ar_admin', 'sample_photos') -> 'using') u
  where (u ->> 'vehicle_id')::uuid = test.id('vehicle:ARS')), 1::bigint);
insert into vehicle_listings (vehicle_id, status, headline, description, features, faq) values (test.id('vehicle:ARS'), 'draft', 'x', 'x', '{}', '[]'::jsonb) on conflict (vehicle_id) do nothing;
update vehicle_listings set status = 'published', slug = coalesce(slug, 'ar-sample-suv') where vehicle_id = test.id('vehicle:ARS');
select test.eq('samples: the public page and the card show the sample photos, marked as samples (no real photo, no plate check)',
  (app.public_listing_photos(test.id('vehicle:ARS')) -> 0 ->> 'label') || '/' || coalesce(app.public_listing_row(test.id('vehicle:ARS')) ->> 'sample_photos', 'null'),
  'Sample photo/' || coalesce((app.public_listing_row(test.id('vehicle:ARS')) ->> 'sample_photos'), 'null'));
insert into vehicle_photos (vehicle_id, shot_type, angle, status, processed_path, original_path, is_public, is_cover, sort_order, plate_status)
select test.id('vehicle:ARS'), (select code from listing_shot_types where is_public order by seq limit 1), (select code from listing_shot_types where is_public order by seq limit 1), 'approved', 'vehicles/ars/front.jpg', 'vehicles/ars/front-original.jpg', true, true, 1, 'unchecked';
select test.eq('samples: a real photo replaces the samples at once', app.vehicle_uses_sample_photos(test.id('vehicle:ARS')) || '/' || (app.public_listing_photos(test.id('vehicle:ARS')) -> 0 ->> 'path'),
  'false/vehicles/ars/front.jpg');
select test.eq('samples: with a real photo the usual photo rules apply again', cardinality(app.listing_photo_problems(test.id('vehicle:ARS'))) > 0, true);
select test.eq('samples: deleting a library photo returns its file to remove', test.ar_do('ar_admin', 'sample_photo_delete', jsonb_build_object('id', test.arv('lib') ->> 'id')) ->> 'path', 'samples/mb-c300.jpg');

-- ================================================================ 3. To do and search
select test.eq('to do: one list, every item with a count, a button and a page', (select count(*) filter (where i ? 'count' and i ? 'button' and i ->> 'href' like '/admin%')
  from jsonb_array_elements(test.ar_read('ar_admin', 'admin_todo') -> 'items') i), 10::bigint);
select test.eq('to do: the items, in order', (select string_agg(i ->> 'key', ',') from jsonb_array_elements(test.ar_read('ar_admin', 'admin_todo') -> 'items') i),
  'applications,requests,changes,payments,countersign,tolls,listings,plates,insurance,samples');
select test.throws('to do: Admins only', $$select test.ar_read('ar_cs', 'admin_todo')$$, '');
select test.eq('search: a plate finds the car', (select g -> 'rows' -> 0 ->> 'href' from jsonb_array_elements(test.ar_read('ar_admin', 'admin_search', jsonb_build_object('q', (select plate from vehicles where id = test.id('vehicle:ARS')))) -> 'groups') g where g ->> 'key' = 'cars'),
  '/admin/vehicles/' || test.id('vehicle:ARS'));
select test.mk_renter('ARB');
select test.mk_booking('CC-98765', 'ARS', 'ARB', '2027-12-01 10:00', '2027-12-03 10:00', 'requested');
select test.eq('search: a booking number as written, with its dash, finds the booking',
  (select g -> 'rows' -> 0 ->> 'href' from jsonb_array_elements(test.ar_read('ar_admin', 'admin_search', '{"q":"CC-98765"}') -> 'groups') g where g ->> 'key' = 'bookings'),
  '/admin/bookings/CC-98765');
select test.eq('search: only punctuation searches no bookings', (select jsonb_array_length(g -> 'rows') from jsonb_array_elements(test.ar_read('ar_admin', 'admin_search', '{"q":"--"}') -> 'groups') g where g ->> 'key' = 'bookings'), 0);
select test.eq('search: an owner''s name finds the owner', (select jsonb_array_length(g -> 'rows') > 0 from jsonb_array_elements(test.ar_read('ar_admin', 'admin_search', '{"q":"Ar Owen"}') -> 'groups') g where g ->> 'key' = 'owners'), true);
select test.eq('search: results grouped as bookings, cars, owners, partners, renters', (select string_agg(g ->> 'key', ',') from jsonb_array_elements(test.ar_read('ar_admin', 'admin_search', '{"q":"zz"}') -> 'groups') g),
  'bookings,cars,owners,partners,renters');
select test.eq('search: one letter searches nothing', jsonb_array_length(test.ar_read('ar_admin', 'admin_search', '{"q":"a"}') -> 'groups'), 0);

-- ================================================================ 4. owner applications
insert into users (id, email, full_name) values (test.id('ar_ana'), 'ana.ar@example.test', 'Ana Applicant');
insert into test.ar select 'app', public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Ana Applicant', 'first_name', 'Ana', 'last_name', 'Applicant', 'email', 'ana.ar@example.test',
                              'phone', '+16475550133', 'address_line1', '30 King Street West', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1',
                              'licence_number', 'A1234-56789-01234', 'date_of_birth', '1990-01-01'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', upper(substr(md5('ar-vin-1'), 1, 17)), 'plate', 'ARAA101', 'year', 2022, 'make', 'Kia', 'model', 'Sportage', 'colour', 'Grey',
    'odometer_km', 25000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Intact', 'title_brand_clear', true))),
  test.id('ar_ana'));
create function test.ar_app() returns uuid language sql stable as $$ select id from owner_applications where owner_id = (test.arv('app') ->> 'owner_id')::uuid order by created_at desc limit 1 $$;
select test.eq('applications: a submitted application lands in the inbox as New', (select r ->> 'status' from jsonb_array_elements(test.ar_read('ar_admin', 'applications') -> 'rows') r where (r ->> 'id')::uuid = test.ar_app()), 'new');
select test.eq('applications: the To do list counts it', (select (i ->> 'count')::int >= 1 from jsonb_array_elements(test.ar_read('ar_admin', 'admin_todo') -> 'items') i where i ->> 'key' = 'applications'), true);
select test.eq('applications: one page holds the owner, the car with its VIN, the documents, the checks and the notes',
  (select (v #>> '{owner,legal_name}') || '/' || (v #>> '{owner,licence_number}') || '/' || jsonb_array_length(v -> 'vehicles') || '/' || (v #>> '{vehicles,0,vin}' is not null)
          || '/' || jsonb_typeof(v -> 'documents') || '/' || jsonb_typeof(v -> 'notes') || '/' || jsonb_array_length(v -> 'items')
     from (select test.ar_read('ar_admin', 'application', jsonb_build_object('id', test.ar_app())) v) x), 'Ana Applicant/A1234-56789-01234/1/true/array/array/8');
select test.ar_do('ar_admin', 'application_check', jsonb_build_object('id', test.ar_app(), 'check', 'licence', 'status', 'ok', 'note', 'Matches the photo'));
select test.ar_do('ar_admin', 'application_note', jsonb_build_object('id', test.ar_app(), 'body', 'Called the owner: the car is garaged in Etobicoke.'));
select test.eq('applications: a check and a note are kept', (select (a.checks #>> '{licence,status}') || '/' || (select count(*) from owner_application_notes n where n.application_id = a.id)
  from owner_applications a where a.id = test.ar_app()), 'ok/1');
select test.throws('applications: Ask for something needs the items', format($$select test.ar_do('ar_admin', 'application_request', %L)$$, jsonb_build_object('id', test.ar_app(), 'items', '[]'::jsonb)), 'Choose what to ask for');
select test.ar_do('ar_admin', 'application_request', jsonb_build_object('id', test.ar_app(), 'items', '["ownership", "insurance"]'::jsonb, 'message', 'A full photo, please.'));
select test.eq('applications: asked for something: Waiting on owner, the owner''s email, and the task in the owner portal',
  (select a.status from owner_applications a where a.id = test.ar_app()) || '/' || (select count(*) from app_events e where e.code = 'owner_application_info_requested' and e.entity_id = test.ar_app())
  || '/' || jsonb_array_length(public.server_owner_application_task(test.id('ar_ana')) -> 'items'), 'waiting_on_owner/1/2');
select public.server_application_owner_reply(test.id('ar_ana'), jsonb_build_object('id', test.ar_app(), 'reply', 'I uploaded both under my vehicle.'));
select test.eq('applications: the owner''s answer brings it back as New, with a task for an Admin; the portal shows a thank-you, not the task',
  (select a.status || '/' || (a.owner_reply is not null) from owner_applications a where a.id = test.ar_app()) || '/'
  || (select count(*) from tasks t where t.related_id = test.ar_app() and t.task_type = 'owner_application_reply') || '/' || coalesce(public.server_owner_application_task(test.id('ar_ana')) ->> 'answered', 'none'),
  'new/true/1/true');
select test.throws('applications: another person cannot answer for the owner', format($$select public.server_application_owner_reply(%L, %L)$$, test.id('ar_cs'), jsonb_build_object('id', test.ar_app(), 'reply', 'x')), 'Not found');
insert into test.ar select 'approve', test.ar_do('ar_admin', 'application_approve', jsonb_build_object('id', test.ar_app()));
select test.eq('applications: approve: the owner is active, the car has its terms (documents to sign), the first and last month''s invoice, the owner emailed',
  (test.arv('approve') ->> 'status') || '/' || jsonb_array_length(test.arv('approve') -> 'terms') || '/' || jsonb_array_length(test.arv('approve') -> 'invoices')
  || '/' || (select o.status from owners o where o.id = (test.arv('app') ->> 'owner_id')::uuid)
  || '/' || (select string_agg(ob.status::text, ',') from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = (test.arv('app') ->> 'owner_id')::uuid)
  || '/' || (select count(*) from app_events e where e.code = 'owner_application_approved' and e.entity_id = test.ar_app())
  || '/' || (public.owner_portal_home(test.id('ar_ana')) #>> '{signing,needed}'),
  'approved/1/1/active/terms_set/1/true');
select test.eq('applications: approving twice is a replay', test.ar_do('ar_admin', 'application_approve', jsonb_build_object('id', test.ar_app())) ->> 'repeat', 'true');
-- a second application, declined
insert into users (id, email, full_name) values (test.id('ar_dev'), 'dev.ar@example.test', 'Dev Declined');
insert into test.ar select 'app2', public.server_submit_owner_application(jsonb_build_object('source', 'web',
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Dev Declined', 'first_name', 'Dev', 'last_name', 'Declined', 'email', 'dev.ar@example.test',
                              'phone', '+16475550134', 'address_line1', '31 King Street West', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5H 1A1'),
  'vehicles', jsonb_build_array(jsonb_build_object('vin', upper(substr(md5('ar-vin-2'), 1, 17)), 'plate', 'ARAA102', 'year', 2009, 'make', 'Honda', 'model', 'Civic', 'colour', 'Blue',
    'odometer_km', 225000, 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer', 'current_insurer', 'Aviva'))), test.id('ar_dev'));
select test.throws('applications: decline needs the reason the owner reads',
  format($$select test.ar_do('ar_admin', 'application_decline', %L)$$, jsonb_build_object('id', (select id from owner_applications where owner_id = (test.arv('app2') ->> 'owner_id')::uuid))), 'Give the reason');
select test.ar_do('ar_admin', 'application_decline', jsonb_build_object('id', (select id from owner_applications where owner_id = (test.arv('app2') ->> 'owner_id')::uuid), 'reason', 'Our insurer does not accept cars older than 12 years.'));
select test.eq('applications: declined, with the reason, the car declined, the owner emailed',
  (select a.status || '/' || a.decline_reason from owner_applications a where a.owner_id = (test.arv('app2') ->> 'owner_id')::uuid)
  || '/' || (select string_agg(ob.status::text, ',') from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = (test.arv('app2') ->> 'owner_id')::uuid)
  || '/' || (select count(*) from app_events e join vehicle_onboardings ob on ob.id = e.entity_id join vehicles v on v.id = ob.vehicle_id where e.code = 'owner_application_declined' and v.owner_id = (test.arv('app2') ->> 'owner_id')::uuid),
  'declined/Our insurer does not accept cars older than 12 years./declined/1');
select test.eq('applications: the status chips count each status', (select (c ->> 'approved')::int >= 1 and (c ->> 'declined')::int >= 1 from (select test.ar_read('ar_admin', 'applications') -> 'counts' c) x), true);
select test.throws('applications: the inbox is for Admins', $$select test.ar_read('ar_cs', 'applications')$$, '');
select app.process_events(100000);
select test.eq('applications: the request email lists what was asked for', (select jsonb_array_length(payload -> 'requested_items') || '/' || (payload ->> 'request_message')
  from notification_outbox where code = 'owner_application_info_requested' and to_address = 'ana.ar@example.test'), '2/A full photo, please.');

-- ================================================================ privileges
select test.eq('privileges: the new tables have row-level security and are audited',
  (select count(*) from pg_class where relname in ('sample_photos', 'owner_application_notes') and relrowsecurity) || '/'
  || (select count(*) from pg_trigger where tgname in ('audit_sample_photos', 'audit_owner_application_notes')), '2/2');
select test.throws('privileges: a browser session cannot answer for an owner', $$set local role authenticated; select public.server_application_owner_reply(gen_random_uuid(), '{}')$$, 'permission denied');
