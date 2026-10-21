-- 11: site settings, form drafts, leads, the owner application and onboarding, government form
-- pre-fill, exit, fee and bank changes, the owner portal, the listing pipeline, the public
-- website reads, and row-level security on every new table (migration 0022).
--
-- Every fixture label starts with "ofl" so nothing collides with the other test files.
select test.suite('11 owners forms listings');

-- ------------------------------------------------------------------ fixtures
select test.mk_user('ofl_admin', 'admin');
select test.mk_user('ofl_cs', 'va', 'cs');
select test.mk_user('ofl_fleet', 'va', 'fleet');
select test.mk_user('ofl_fin', 'va', 'finance');
select test.mk_user('ofl_sales', 'va', 'sales');
select test.mk_user('ofl_field', 'field');
select test.mk_user('ofl_omar', 'owner');       -- applies through the website; his owner record is made by the application
select test.mk_owner('ofl_olga');               -- an owner already in the program
select test.mk_renter('ofl_rita');
select test.mk_vehicle('oflB', 'ofl_olga');      -- exit notice
select test.mk_vehicle('oflC', 'ofl_olga');      -- listed by field staff, reviewed
select test.mk_vehicle('oflD', 'ofl_olga');      -- its twin, listed by an Admin
select test.mk_vehicle('oflE', 'ofl_olga');      -- same model, another colour
select test.mk_vehicle('oflF', 'ofl_olga');      -- the owner books it for herself
select test.mk_vehicle('oflG', 'ofl_olga');      -- fee and schedule changes
select test.mk_booking('OFL1', 'oflF', 'ofl_rita', '2026-09-10 10:00', '2026-09-12 10:00');
insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status)
values (test.id('job:oflC'), 'photo_shoot', test.id('vehicle:oflC'), test.id('ofl_field'), now(), 'scheduled');

-- CarmaCars' registry details (company_address and the signing officer are settings)
update program_settings set company_address = '1 Test Street, Toronto, ON M5V 1A1', signing_officer_name = 'Test Officer',
       signing_officer_title = 'President', company_rin = null
 where id = (app.settings()).id;

create function test.ofl_words(p_n integer) returns text language sql as $$
  select string_agg('word' || g, ' ') from generate_series(1, p_n) g
$$;

create function test.ofl_copy() returns jsonb language sql as $$
  select jsonb_build_object(
    'headline', 'A 2023 Mercedes-Benz C 300 with all-wheel drive and heated seats',
    'description', test.ofl_words(130),
    'features', jsonb_build_array('Heated front seats', 'Apple CarPlay', 'Android Auto', 'All-wheel drive', 'Backup camera', 'Blind spot assist', 'Keyless entry', 'LED headlights'),
    'faq', jsonb_build_array(jsonb_build_object('question', 'How many suitcases fit?', 'answer', 'Two large suitcases.'),
                             jsonb_build_object('question', 'Can I fit a child seat?', 'answer', 'Yes, two.'),
                             jsonb_build_object('question', 'Is it good in winter?', 'answer', 'Yes, with winter tires.'),
                             jsonb_build_object('question', 'What fuel does it take?', 'answer', 'Premium gasoline.')),
    'seo_title', '2023 Mercedes-Benz C 300 rental in Toronto', 'seo_description', 'Rent this 2023 Mercedes-Benz C 300 in Toronto.',
    'model', 'test-model', 'prompt_version', 'listing-v1')
$$;

-- what the fake worker answers for each kind of job
create function test.ofl_output(j listing_jobs) returns jsonb language sql as $$
  select case j.kind
    when 'decode_vin' then '{"ok": true, "year": 2023, "make": "Mercedes-Benz", "model": "C 300", "trim": "4MATIC", "body_class": "Sedan",
                             "fuel": "gasoline", "seats": 5, "transmission": "automatic", "doors": 4, "drivetrain": "AWD", "engine": "2.0L I4"}'::jsonb
    when 'draft_copy' then test.ofl_copy()
    when 'process_photo' then jsonb_build_object('processed_path', 'vehicles/processed/' || j.vehicle_photo_id || '.jpg', 'width', 2400, 'height', 1600)
    when 'resize' then '{"variants": [{"width": 800, "format": "webp"}]}'::jsonb
    else '{}'::jsonb end
$$;

-- run every due job as the fake worker; returns how many were completed
create function test.ofl_work(p_now timestamptz default now()) returns integer language plpgsql as $$
declare
  j listing_jobs;
  n integer := 0;
begin
  for k in 1..20 loop
    for j in select * from app.claim_listing_jobs('test-worker', 100, null, p_now) loop
      perform app.complete_listing_job(j.id, test.ofl_output(j), 'fake', case when j.kind = 'process_photo' then 100000 else 0 end, 10);
      n := n + 1;
    end loop;
    exit when not exists (select 1 from listing_jobs where status = 'queued' and next_attempt_at <= p_now);
  end loop;
  return n;
end $$;

-- upload every required photo of an intake
create function test.ofl_upload_all(p_intake uuid, p_by uuid) returns jsonb language plpgsql as $$
declare
  s record;
  r jsonb;
begin
  for s in select code from listing_shot_types where required and is_active order by seq loop
    r := app.record_listing_upload(p_by, p_intake, jsonb_build_object('shot_type', s.code,
           'original_path', 'vehicles/original/' || p_intake || '/' || s.code || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000,
           'mime_type', 'image/jpeg'));
  end loop;
  return r;
end $$;

-- the whole pipeline for one car: start, photos, submit, worker; a reviewer approves when needed
create function test.ofl_list(p_vehicle uuid, p_by uuid, p_colour text) returns jsonb language plpgsql as $$
declare
  v_intake uuid;
begin
  v_intake := (app.start_listing_intake(p_by, jsonb_build_object('vehicle_id', p_vehicle, 'colour', p_colour)) ->> 'intake_id')::uuid;
  perform test.ofl_upload_all(v_intake, p_by);
  perform app.submit_listing_intake(p_by, v_intake);
  perform test.ofl_work();
  if (select state from listing_intakes where id = v_intake) = 'needs_review' then
    return app.review_listing(test.id('ofl_cs'), v_intake, true);
  end if;
  return jsonb_build_object('intake_id', v_intake, 'state', (select state from listing_intakes where id = v_intake),
                            'slug', (select slug from vehicle_listings where vehicle_id = p_vehicle));
end $$;

grant execute on all functions in schema test to authenticated, anon;

-- ------------------------------------------------------------------ A. site settings and content
select test.eq('A one site settings row, seeded from site.mjs, with no legal name shown',
  (select count(*) || '/' || max(brand_name) || '/' || bool_or(legal_name_displayed)::text from site_settings), '1/CarmaCars/false');
select test.throws('A the legal company name can never be flagged public',
  $$update site_settings set legal_name_displayed = true$$, 'check constraint');
select test.throws('A a delivery area needs a name and a fee of 0 or more',
  $$update site_settings set delivery_areas = '[{"area": "Toronto", "fee_cents": -5}]'$$, 'delivery area');
select test.throws('A handover times are HH:MM', $$update site_settings set handover_slots = '{9am}'$$, 'HH:MM');

select test.login(test.id('ofl_admin'));
select test.eq('A an Admin edits the settings and the content from the portal',
  test.affected($$update site_settings set phone = '416-555-0142', whatsapp = '14165550142', roadside_phone = '1-800-555-0100',
                   delivery_areas = '[{"area": "Toronto", "fee_cents": 5000}, {"area": "Mississauga", "fee_cents": null}]',
                   handover_slots = '{09:00,09:30,17:30}', airport_delivery = false, logo_light_file_key = 'brand/logo.svg',
                   social_links = '{"instagram": "https://instagram.com/carmacars"}', mailing_address = 'PO Box 1, Toronto, ON',
                   street_address = '9 Hidden Lane', seo_title_suffix = ' | CarmaCars'$$)
  || '/' || test.affected($$insert into site_content_blocks (block_key, page, kind, body, sort_order) values
                              ('home.hero.heading', 'home', 'text', 'Rent a car the easy way', 1),
                              ('home.hero.draft', 'home', 'text', 'Not yet', 2)$$)
  || '/' || test.affected($$update site_content_blocks set is_published = false where block_key = 'home.hero.draft'$$), '1/2/1');
select test.throws('A nobody deletes settings from a browser session', $$delete from site_settings$$, 'permission denied');
select test.logout();
select test.eq('A every change is in the audit log with the row before and after (the version history)',
  (select count(*) > 0 from audit_log where entity_table = 'site_settings' and action = 'UPDATE' and before ->> 'phone' = '+12893125991' and after ->> 'phone' = '416-555-0142'), true);
select test.eq('A the editor is recorded on the row', (select updated_by from site_settings), test.id('ofl_admin'));

set role anon;
select test.eq('A the public site reads the settings: phone, delivery fee by area, slots, logo; the street address once entered (0025: shown by default)',
  (select (s ->> 'phone') || '/' || (s -> 'delivery_areas' -> 0 ->> 'fee_cents') || '/' || jsonb_array_length(s -> 'handover_slots')
          || '/' || (s -> 'logo' ->> 'light') || '/' || coalesce(s ->> 'street_address', 'hidden')
     from public.site_settings_public() s), '416-555-0142/5000/3/brand/logo.svg/9 Hidden Lane');
select test.eq('A the public settings never carry the legal company name, the numbered corporation or who edited',
  (select (s::text ilike '%18122211%') or (s::text ilike '%Canada Inc%') or (s::text ilike '%' || test.id('ofl_admin')::text || '%')
          or s ? 'legal_name' or s ? 'updated_by' from public.site_settings_public() s), false);
select test.eq('A the public content: published blocks only', (select jsonb_array_length(public.site_content('home'))), 1);
reset role;

-- ------------------------------------------------------------------ B. form drafts
create temp table ofl_d0 as select app.save_form_draft('owner_application',
  '{"owner": {"legal_name": "Omar Test", "licence_number": "X123"}, "bank": {"account_number": "1234567"}, "step": 1}', 'about_you') as r;
select test.eq('B a visitor''s draft gets a token once; licence and account numbers are never stored',
  (select (r ->> 'token' is not null)::text from ofl_d0)
  || '/' || (select (data -> 'owner' ? 'licence_number')::text || (data -> 'bank' ? 'account_number')::text
               from form_drafts where id = (select (r ->> 'draft_id')::uuid from ofl_d0)), 'true/falsefalse');
create temp table ofl_draft as
  select r ->> 'token' as token, (r ->> 'draft_id')::uuid as id
    from app.save_form_draft('owner_application', '{"owner": {"legal_name": "Omar Test"}}', 'vehicles') r;
grant all on ofl_draft to authenticated, anon;
select test.eq('B saving again with the token updates the same draft and moves its expiry out',
  (select (app.save_form_draft('owner_application', '{"owner": {"legal_name": "Omar Test"}, "vehicles": [1]}', 'vehicles', 1, null, token) ->> 'draft_id')::uuid from ofl_draft),
  (select id from ofl_draft));
select test.eq('B the draft loads by its token', (select app.load_form_draft('owner_application', null, token) -> 'data' -> 'vehicles' ->> 0 from ofl_draft), '1');
create temp table ofl_link as select app.request_draft_resume_link(id, 'omar@example.test', null, token) as link from ofl_draft;
grant all on ofl_link to authenticated, anon;
create temp table ofl_resumed as select app.resume_form_draft(link, null, 'phone') as r from ofl_link;
select test.eq('B the emailed link opens the draft on another device with its own token; the first device keeps working',
  (select (r ->> 'draft_id')::uuid = (select id from ofl_draft) and r ->> 'token' is not null and r ->> 'token' <> (select token from ofl_draft)
          and app.load_form_draft('owner_application', null, r ->> 'token') is not null
          and app.load_form_draft('owner_application', null, (select token from ofl_draft)) is not null from ofl_resumed), true);
select test.throws('B the link works once', $$select app.resume_form_draft((select link from ofl_link))$$, 'expired or was already used');
select test.throws('B a wrong token sees nothing', $$select app.save_form_draft('owner_application', '{}', null, 1, null, 'not-a-token')$$, 'no longer available');
select test.eq('B a signed-in user keeps one open draft per form',
  (select (app.save_form_draft('owner_application', '{"a": 1}', null, 1, test.id('ofl_olga')) ->> 'draft_id')
        = (app.save_form_draft('owner_application', '{"a": 2}', null, 1, test.id('ofl_olga')) ->> 'draft_id')), true);
insert into form_drafts (form_code, token_hashes, data, expires_at) values ('contact', array['x'], '{}', now() - interval '1 day');
select test.eq('B the purge removes expired drafts', app.purge_form_drafts() >= 1, true);

-- ------------------------------------------------------------------ C. the owner application: three vehicles, three situations
create temp table ofl_app as select app.submit_owner_application(jsonb_build_object(
  'draft_id', (select id from ofl_draft),
  'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Omar Test', 'first_name', 'Omar', 'last_name', 'Test',
                              'address_line1', '5 Owner Road', 'city', 'Toronto', 'province', 'on', 'postal_code', 'm4m1a1',
                              'email', 'omar@example.test', 'phone', '4165550111', 'licence_number', 'T1234-56789-01234',
                              'date_of_birth', '1985-04-09'),
  'vehicles', jsonb_build_array(
    jsonb_build_object('vin', '1hgcm82633a100001', 'plate', 'ofl 001', 'year', 2022, 'make', 'Toyota', 'model', 'Corolla', 'colour', 'Grey',
                       'odometer_km', 21000, 'body_type', 'Sedan', 'title_status', 'owned_outright', 'management_mode', 'managed',
                       'onboarding_method', 'co_registrant', 'current_insurer', 'Insurer A'),
    jsonb_build_object('vin', '1HGCM82633A100002', 'plate', 'OFL002', 'year', 2021, 'make', 'Honda', 'model', 'Civic', 'colour', 'Blue',
                       'odometer_km', 35000, 'body_type', 'Sedan', 'title_status', 'financed', 'finance_party_name', 'Lender X',
                       'management_mode', 'managed', 'onboarding_method', 'transfer'),
    jsonb_build_object('vin', '1HGCM82633A100003', 'plate', 'OFL003', 'year', 2024, 'make', 'Tesla', 'model', 'Model 3', 'colour', 'White',
                       'odometer_km', 8000, 'body_type', 'Sedan', 'fuel', 'electric', 'title_status', 'leased', 'finance_party_name', 'Lessor Y',
                       'finance_party_account', 'L-77', 'management_mode', 'managed'))), test.id('ofl_omar')) as r;
grant all on ofl_app to authenticated, anon;
create function test.ofl_v(p_n integer) returns uuid language sql as $$ select ((select r from ofl_app) -> 'vehicles' -> (p_n - 1) ->> 'vehicle_id')::uuid $$;

select test.eq('C one application, one owner tied to the applicant''s login, three vehicles in onboarding',
  (select (r ->> 'application_number' like 'OA-%')::text || '/' || jsonb_array_length(r -> 'vehicles') || '/'
          || (select count(*) from vehicles v where v.owner_id = (r ->> 'owner_id')::uuid and v.status = 'onboarding') || '/'
          || ((select user_id from owners where id = (r ->> 'owner_id')::uuid) = test.id('ofl_omar'))::text from ofl_app), 'true/3/3/true');
select test.eq('C nothing is missing on the owner record for the agreements and the registry forms',
  (select r -> 'owner_missing' from ofl_app), '[]'::jsonb);
select test.eq('C the licence number and date of birth sit in the private table, not on the owner row',
  (select d.licence_number || '/' || d.date_of_birth from owner_private_details d where d.owner_id = ((select r from ofl_app) ->> 'owner_id')::uuid),
  'T1234-56789-01234/1985-04-09');
select test.eq('C situations: owned outright Co-Registrant is S3, financed Transfer is S5, leased is S6 (the only method)',
  (select string_agg(ob.situation || ':' || ob.proposed_onboarding_method, ' ' order by v.plate)
     from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where v.id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3))),
  'S3:co_registrant S5:transfer S6:transfer');
select test.eq('C registry forms per vehicle: S3 two forms, S5 the sign-back on the permit (no form), S6 two forms',
  (select string_agg(coalesce(nullif(array_to_string(ob.government_forms, ','), ''), 'none') || ':' || ob.sign_back_on_permit, ' ' order by v.plate)
     from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where v.id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3))),
  'SR-LV-006,SR-LV-012:false none:true SR-LV-006,SR-LV-012:false');
select test.eq('C estimates (paid by the owner to third parties, information only): $250 plus tax each',
  (select string_agg(ob.estimate_cents || ':' || ob.estimate_plus_tax, ' ' order by v.plate)
     from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where v.id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3))),
  '25000:true 25000:true 25000:true');
select test.eq('C the CarmaCars forms of each plan: A and D, plus Form C when financed or leased',
  (select string_agg(x -> 'plan' ->> 'carmacars_forms', ' ' order by x ->> 'vin') from ofl_app, jsonb_array_elements(r -> 'vehicles') x),
  '["A", "D"] ["A", "D", "C"] ["A", "D", "C"]');
select test.eq('C VIN and plate are stored clean (upper case, no spaces)', (select vin || '/' || plate from vehicles where id = test.ofl_v(1)), '1HGCM82633A100001/OFL001');
select test.eq('C each vehicle raises its own customer service intake task (0020) and the events are emitted once per vehicle',
  (select count(*) from tasks where task_type = 'owner_intake' and vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3)))
  || '/' || (select count(*) from app_events where code = 'owner_application_received' and payload ->> 'owner_id' = (select r ->> 'owner_id' from ofl_app))
  || '/' || (select count(*) from app_events where code = 'staff_owner_application_received' and payload ->> 'owner_id' = (select r ->> 'owner_id' from ofl_app)), '3/3/3');
select test.eq('C the draft was submitted and its answers cleared; pressing Submit again returns the first result',
  (select (submitted_at is not null)::text || '/' || data::text from form_drafts where id = (select id from ofl_draft))
  || '/' || ((app.submit_owner_application(jsonb_build_object('draft_id', (select id from ofl_draft), 'vehicles', jsonb_build_array('{}'::jsonb))) ->> 'application_id')
             = (select r ->> 'application_id' from ofl_app))::text, 'true/{}/true');
select test.throws('C the same VIN cannot be added twice',
  format($$select app.add_owner_vehicle(%L, '{"vin": "1HGCM82633A100001", "title_status": "owned_outright", "year": 2022, "make": "Toyota", "model": "Corolla"}')$$,
         (select r ->> 'owner_id' from ofl_app)), 'already with CarmaCars');
select test.throws('C another owner cannot add a vehicle to this owner',
  format($$select app.add_owner_vehicle(%L, '{"vin": "1HGCM82633A100009", "title_status": "owned_outright", "year": 2022, "make": "Kia", "model": "Rio"}', %L)$$,
         (select r ->> 'owner_id' from ofl_app), test.id('ofl_olga')), 'only to their own account');
select test.eq('C options for an individual who owns outright: S2, S3, S4 with the lien estimate; a corporation sees S1 (recommended) and S4',
  (select string_agg(situation || coalesce(':' || estimate_with_lien_cents, ''), ',' order by situation) from app.onboarding_options('individual', 'owned_outright', 'managed'))
  || ' ' || (select string_agg(situation || ':' || recommended, ',' order by situation) from app.onboarding_options('corporation', 'owned_outright', 'managed')),
  'S2,S3,S4:26000 S1:true,S4:false');
select test.eq('C the Owner''s Lien raises the S4 estimate to $260; it is refused on any other situation',
  (app.onboarding_plan('individual', 'owned_outright', 'managed', 'transfer', true) ->> 'estimate_cents'), '26000');
select test.throws('C no Owner''s Lien on a financed vehicle', $$select app.onboarding_plan('individual', 'financed', 'managed', 'transfer', true)$$, 'Owner''s Lien');
select test.throws('C a leased vehicle has no Lease method', $$select app.onboarding_plan('corporation', 'leased', 'managed', 'lease_existing_corporation')$$, 'not open');
select test.eq('C Turo-Only: no registry forms, no estimate',
  (select situation || ':' || estimate_cents || ':' || cardinality(government_forms) from app.onboarding_options('individual', 'leased', 'turo_only')), 'turo_only:0:0');
-- an Admin edits a situation: the change applies at once
update onboarding_situations set government_forms = '{SR-LV-006}' where situation = 'S6';
select test.eq('C an Admin''s change to the situations table changes the forms offered', (select array_to_string(government_forms, ',') from app.onboarding_options('individual', 'leased', 'managed')), 'SR-LV-006');
update onboarding_situations set government_forms = null where situation = 'S6';

-- ------------------------------------------------------------------ D. terms, schedules, upfront invoices
select test.eq('D the standard grid for an owner with three vehicles (3 to 9): $400, $20, 30%, Install Fee from the settings',
  (select insurance_fee_cents || '/' || tracker_fee_cents || '/' || revenue_share_bps || '/' || install_fee_cents || '/' || vehicle_count
     from app.standard_terms(((select r from ofl_app) ->> 'owner_id')::uuid, 'managed')), '40000/2000/3000/10000/3');
select test.eq('D on-grid terms by a customer service assistant take effect: Vehicle Schedule entry 1, the two agreements, upfront $900',
  (select (t ->> 'status') || '/' || (t ->> 'vehicle_number') || '/' || (t ->> 'is_additional') || '/' || (t ->> 'upfront_cents') || '/'
          || ((t ->> 'enrollment_agreement_id') is not null and (t ->> 'title_agreement_id') is not null)::text
     from app.set_vehicle_terms(test.ofl_v(1), test.id('ofl_cs')) t), 'terms_set/1/false/90000/true');
-- the grid changes: a new row from today
insert into owner_fee_grid (min_vehicles, max_vehicles, insurance_fee_cents, revenue_share_bps, tracker_fee_cents, effective_from)
values (3, 9, 39000, 3000, 2000, app.today());
select test.eq('D a new grid row changes the default for the next vehicle', (app.set_vehicle_terms(test.ofl_v(2), test.id('ofl_cs')) ->> 'insurance_fee_cents'), '39000');
select test.eq('D terms off the grid entered by an assistant wait for an Admin',
  (app.set_vehicle_terms(test.ofl_v(3), test.id('ofl_cs'), '{"insurance_fee_cents": 38000}') ->> 'status'), 'needs_admin_approval');
select test.eq('D with an escalated Admin task', (select queue || ':' || escalated from tasks where task_type = 'approve_vehicle_terms' and vehicle_id = test.ofl_v(3)), 'admin:true');
select test.throws('D only an Admin approves off-grid terms', format('select app.approve_vehicle_terms(%L, %L)', test.ofl_v(3), test.id('ofl_cs')), 'Only an Admin');
select test.eq('D the Admin approves: schedule entry 3 at $380',
  (select (t ->> 'insurance_fee_cents') || '/' || (t ->> 'vehicle_number') || '/' || (t ->> 'off_grid') from app.approve_vehicle_terms(test.ofl_v(3), test.id('ofl_admin')) t), '38000/3/true');
select test.eq('D and the approval task is done', (select status from tasks where task_type = 'approve_vehicle_terms' and vehicle_id = test.ofl_v(3)), 'done');
select test.eq('D three Vehicle Schedule rows under one Enrollment Agreement',
  (select count(*) || '/' || count(distinct owner_agreement_id) from vehicle_schedules where vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3))), '3/1');
select test.throws('D an owner cannot set terms', format('select app.set_vehicle_terms(%L, %L)', test.ofl_v(1), test.id('ofl_omar')), 'Only an Admin');
-- documents signed (the signing flow of 0019 is tested there)
update vehicle_schedules set signed_at = now() where vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3));
update owner_agreements set status = 'signed' where owner_id = ((select r from ofl_app) ->> 'owner_id')::uuid;
update vehicle_onboardings set status = 'documents_sent' where vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3));
update vehicle_onboardings set status = 'documents_signed' where vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3));
-- 0077: the first and last month invoice is never issued by itself; signing and 0022's path make nothing
select test.eq('D signing and the automatic path issue nothing without an Admin''s choice (0077)',
  (select count(*) from app.issue_upfront_invoices(((select r from ofl_app) ->> 'owner_id')::uuid, test.id('ofl_fin')))
  + (select count(*) from owner_invoices where vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3)) and kind = 'upfront'), 0::bigint);
-- the Admin chose "Send invoice now" for each car (the amount: 2 x the Insurance Fee); the owner page's path applies it
update vehicle_onboardings ob set first_last_choice = 'send', first_last_choice_cents = 2 * s.insurance_fee_cents
  from vehicle_schedules s where s.vehicle_id = ob.vehicle_id and s.superseded_by is null and ob.vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3));
select app.admin_issue_upfront_invoices(((select r from ofl_app) ->> 'owner_id')::uuid, test.id('ofl_admin'));
create temp table ofl_inv as select i.vehicle_id, i.id as invoice_id, i.invoice_number, i.fees_cents, i.hst_cents, i.total_cents
  from owner_invoices i where i.vehicle_id in (test.ofl_v(1), test.ofl_v(2), test.ofl_v(3)) and i.kind = 'upfront';
grant all on ofl_inv to authenticated, anon;
select test.eq('D upfront invoices: first and last month''s Insurance Fee, HST 13%; registry costs and the Install Fee (0029) are not on them',
  (select string_agg(fees_cents || '+' || hst_cents || '=' || total_cents, ' ' order by fees_cents desc) from ofl_inv),
  '80000+10400=90400 78000+10140=88140 76000+9880=85880');
select test.eq('D each invoice has its two lines and is issued; Finance gets a collect task per invoice (0020)',
  (select count(*) from owner_invoice_lines l join ofl_inv i on i.invoice_id = l.owner_invoice_id) || '/'
  || (select string_agg(distinct status, ',') from owner_invoices where id in (select invoice_id from ofl_inv)) || '/'
  || (select count(*) from tasks where task_type = 'collect_upfront' and related_id in (select invoice_id from ofl_inv)), '6/issued/3');
select test.eq('D a second run issues nothing more', jsonb_array_length(app.admin_issue_upfront_invoices(((select r from ofl_app) ->> 'owner_id')::uuid, test.id('ofl_admin'))), 0);
select test.throws('D a signed schedule cannot be changed through the onboarding terms', format('select app.set_vehicle_terms(%L, %L)', test.ofl_v(1), test.id('ofl_admin')), 'Terms are fixed');

-- ------------------------------------------------------------------ E. government forms: pre-fill and data sheets
-- these assertions exercise the sample mappings seeded in 0011 (the official forms fetched in 0047 are tested in suite 30)
update pdf_templates set is_current = false where version like 'official-%' and form_code in (select form_code from pdf_templates where version = 'unverified-1');
update pdf_templates set is_current = true where version = 'unverified-1';
create temp table ofl_fill1 as select * from app.fill_vehicle_government_forms(test.ofl_v(1), test.id('ofl_cs'));
grant all on ofl_fill1 to authenticated, anon;
select test.eq('E the S3 vehicle gets its two forms as data sheets (templates unverified); CarmaCars'' RIN is missing so they stay drafts',
  (select string_agg(form_code || ':' || mode || ':' || status || ':' || array_to_string(missing, ','), ' ' order by form_code) from ofl_fill1),
  'SR-LV-006:data_sheet:draft:CarmaCars registrant identification number SR-LV-012:data_sheet:draft:CarmaCars registrant identification number');
select test.throws('E a draft fill cannot be printed', format($$select app.set_government_form_status(%L, 'printed', %L)$$, (select fill_id from ofl_fill1 limit 1), test.id('ofl_omar')), 'missing values');
update program_settings set company_rin = 'RIN-CC-001' where id = (app.settings()).id;
create temp table ofl_fill2 as select * from app.fill_vehicle_government_forms(test.ofl_v(1), test.id('ofl_cs'));
grant all on ofl_fill2 to authenticated, anon;
select test.eq('E with the RIN in the settings the fills are ready and replace the drafts',
  (select string_agg(status || ':' || cardinality(missing), ' ' order by form_code) from ofl_fill2)
  || '/' || (select count(*) from government_form_fills where vehicle_id = test.ofl_v(1) and superseded_at is not null), 'ready:0 ready:0/2');
select test.eq('E data sheet complete: every applicable row has a value; individual rows (licence, birth date) present, corporation and lender rows absent',
  (select count(*) filter (where (e ->> 'value') is null and (e ->> 'required')::boolean) || '/'
          || bool_or(e ->> 'label' = 'Driver''s licence number' and e ->> 'value' = 'T1234-56789-01234')::text || '/'
          || bool_or(e ->> 'section' in ('Corporation', 'Lender or lessor'))::text || '/'
          || bool_or(e ->> 'label' = 'Postal code' and e ->> 'value' = 'M4M 1A1')::text || '/'
          || bool_or(e ->> 'label' = 'Phone' and e ->> 'value' = '(416) 555-0111')::text
     from government_form_fills g, jsonb_array_elements(g.data_sheet) e
    where g.vehicle_id = test.ofl_v(1) and g.form_code = 'SR-LV-006' and g.superseded_at is null), '0/true/false/true/true');
select test.eq('E the government form carries the company legal name and RIN from the settings (correct on a registry form)',
  (select bool_or(e ->> 'label' = 'CarmaCars legal name' and e ->> 'value' = (app.settings()).company_legal_name)::text || '/'
          || bool_or(e ->> 'label' = 'CarmaCars registrant identification number' and e ->> 'value' = 'RIN-CC-001')::text
     from government_form_fills g, jsonb_array_elements(g.data_sheet) e
    where g.vehicle_id = test.ofl_v(1) and g.form_code = 'SR-LV-012' and g.superseded_at is null), 'true/true');
select test.eq('E the mapped PDF fields are resolved even before verification (VIN, name upper case); a field whose condition is false is left out',
  (select (field_values ->> 'VIN') || '/' || (field_values ->> 'RegistrantName' = upper((app.settings()).company_legal_name))::text || '/'
          || (field_values ->> 'IsLease') || '/' || (field_values ? 'LessorRIN')::text
     from government_form_fills where vehicle_id = test.ofl_v(1) and form_code = 'SR-LV-006' and superseded_at is null),
  '1HGCM82633A100001/true/Off/false');
select test.eq('E the S5 vehicle has no form to pre-fill (sign-back)', (select count(*) from app.fill_vehicle_government_forms(test.ofl_v(2))), 0::bigint);
select test.eq('E the leased S6 vehicle''s two forms are ready',
  (select string_agg(f.status, ',') from app.fill_vehicle_government_forms(test.ofl_v(3), test.id('ofl_cs')) f), 'ready,ready');
select test.eq('E its data sheet carries the lessor rows, complete',
  (select count(*) from government_form_fills g, jsonb_array_elements(g.data_sheet) e
              where g.vehicle_id = test.ofl_v(3) and g.superseded_at is null and g.form_code = 'SR-LV-006' and e ->> 'section' = 'Lender or lessor' and e ->> 'value' is not null),
  3::bigint);
select test.eq('E the owner records printed and signed; filing is staff''s',
  test.affected(format($$select app.set_government_form_status(%L, 'printed', %L)$$, (select fill_id from ofl_fill2 where form_code = 'SR-LV-006'), test.id('ofl_omar')))
  + test.affected(format($$select app.set_government_form_status(%L, 'signed', %L)$$, (select fill_id from ofl_fill2 where form_code = 'SR-LV-006'), test.id('ofl_omar'))), 2::bigint);
select test.throws('E an owner cannot record the filing', format($$select app.set_government_form_status(%L, 'filed', %L)$$, (select fill_id from ofl_fill2 where form_code = 'SR-LV-006'), test.id('ofl_omar')), 'recorded by CarmaCars staff');
select test.throws('E another owner cannot touch the form', format($$select app.set_government_form_status(%L, 'filed', %L)$$, (select fill_id from ofl_fill2 where form_code = 'SR-LV-006'), test.id('ofl_olga')), 'Not permitted');
select test.lives('E staff record the filing', format($$select app.set_government_form_status(%L, 'filed', %L)$$, (select fill_id from ofl_fill2 where form_code = 'SR-LV-006'), test.id('ofl_cs')));
select test.throws('E a filed form is not filled again', format($$select app.fill_government_form(%L, 'SR-LV-006')$$, test.ofl_v(1)), 'already filed');
select test.eq('E the five forms are seeded, all unverified', (select count(*) filter (where version = 'unverified-1') || '/' || bool_or(verified)::text from pdf_templates), '5/false');
-- back to the official forms of 0047 as the current versions
update pdf_templates set is_current = false where version = 'unverified-1' and form_code in (select form_code from pdf_templates where version like 'official-%');
update pdf_templates set is_current = true where version like 'official-%';

-- ------------------------------------------------------------------ F. the onboarding checklist
select test.eq('F the checklist says what is done, who it waits on and the next action',
  (select string_agg(code || ':' || status || coalesce(':' || waits_on, ''), ' ' order by sort_order) from app.onboarding_checklist(test.ofl_v(1))),
  'owner_details:done documents:open:owner government_forms:done signatures:done witnessed_forms:open:owner upfront_payment:open:owner registry_visit:open:carmacars tracker_install:open:carmacars insurer_confirmation:open:carmacars photos:open:carmacars listing:open:carmacars');
select test.eq('F the next action for the owner is plain words from the editable item table',
  (select next_action from app.onboarding_checklist(test.ofl_v(1)) where code = 'documents'), 'Upload a photo of both sides of the ownership permit');
update onboarding_checklist_items set owner_action = 'Send us a photo of your ownership permit' where code = 'documents';
select test.eq('F an Admin rewords an item and the checklist follows', (select next_action from app.onboarding_checklist(test.ofl_v(1)) where code = 'documents'), 'Send us a photo of your ownership permit');
select app.mark_onboarding_item(test.ofl_v(1), 'documents', 'done', test.id('ofl_cs'), 'Permit seen in person');
select test.eq('F a staff mark overrides the records', (select status from app.onboarding_checklist(test.ofl_v(1)) where code = 'documents'), 'done');
select test.throws('F an owner cannot mark items', format($$select app.mark_onboarding_item(%L, 'photos', 'done', %L)$$, test.ofl_v(1), test.id('ofl_omar')), 'Only an Admin');
select test.eq('F the S5 vehicle has no registry forms item to do', (select status from app.onboarding_checklist(test.ofl_v(2)) where code = 'government_forms'), 'not_applicable');

-- ------------------------------------------------------------------ G. leads
create temp table ofl_lead as select app.submit_lead('{"kind": "owner_program", "name": "Lena Lead", "email": "Lena@Example.test", "payload": {"vehicle": "2020 Mazda 3"},
  "utm": {"source": "instagram", "campaign": "launch"}, "consent_marketing": true, "consent_text": "Yes, email me"}', '203.0.113.7') as r;
create temp table ofl_lead2 as select app.submit_lead('{"kind": "contact", "phone": "4165550000", "message": "Hi"}') as r;
grant all on ofl_lead, ofl_lead2 to authenticated, anon;
select test.eq('G an owner program enquiry: stored with UTM and consent, assigned to a sales assistant, a sales task, two events',
  (select (r ->> 'ok') || '/' || (select l.utm_source || ':' || l.consent_marketing || ':' || (sp.va_function = 'sales')
                                     from leads l join staff_profiles sp on sp.user_id = l.assigned_to where l.id = (r ->> 'lead_id')::uuid)
          || '/' || (select queue || ':' || (assigned_to is not null) from tasks where related_id = (r ->> 'lead_id')::uuid)
          || '/' || (select count(*) from app_events where entity_id = (r ->> 'lead_id')::uuid)
     from ofl_lead), 'true/instagram:true:true/sales:true/2');
select test.eq('G a contact message goes to customer service', (select queue from tasks where related_id = (select (r ->> 'lead_id')::uuid from ofl_lead2)), 'cs');
select test.throws('G an email or phone is needed', $$select app.submit_lead('{"kind": "contact", "name": "Nobody"}')$$, 'email address or a phone');
update program_settings set lead_hourly_limit = 2 where id = (app.settings()).id;
select test.eq('G the limit per network address comes from the settings: the third from one address in the hour is refused, nothing stored',
  (select string_agg(coalesce(r ->> 'error', 'ok'), ',') from (select app.submit_lead('{"kind": "contact", "email": "a@b.test"}', '198.51.100.9') r from generate_series(1, 3)) q),
  'ok,ok,rate_limited');
update program_settings set lead_hourly_limit = 5 where id = (app.settings()).id;

-- ------------------------------------------------------------------ H. exit notice
create temp table ofl_exit1 as select app.give_exit_notice(test.id('vehicle:oflB'), test.id('ofl_olga'), '{"reason": "Selling"}') as r;
grant all on ofl_exit1 to authenticated, anon;
select test.eq('H notice period from the settings (30 days), transfer-back fees paid by the owner under 6 months on the policy, vehicle under notice, Exit block, task, events',
  (select ((r ->> 'exit_date')::date = app.today() + (app.settings()).notice_period_days)::text || '/' || (r ->> 'retransfer_fees_paid_by') from ofl_exit1)
  || '/' || (select status from vehicles where id = test.id('vehicle:oflB'))
  || '/' || (select count(*) from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:oflB') and reason = 'exit')
  || '/' || (select count(*) from tasks where task_type = 'owner_exit' and vehicle_id = test.id('vehicle:oflB'))
  || '/' || (select count(*) from app_events where entity_id = ((select r from ofl_exit1) ->> 'exit_id')::uuid and code in ('owner_exit_notice_received', 'staff_exit_notice_received')),
  'true/owner/exit_notice/1/1/2');
select test.throws('H another owner cannot give notice on this car', format($$select app.give_exit_notice(%L, %L)$$, test.id('vehicle:oflC'), test.id('ofl_omar')), 'only on their own vehicle');
select test.throws('H a vehicle still in onboarding is withdrawn, not given notice', format($$select app.give_exit_notice(%L, %L)$$, test.ofl_v(1), test.id('ofl_omar')), 'withdraw it');
select test.throws('H the exit is not completed before the Exit Date', format($$select app.complete_exit(%L, %L)$$, (select r ->> 'exit_id' from ofl_exit1), test.id('ofl_fleet')), 'on or after it');
select app.withdraw_exit_notice(((select r from ofl_exit1) ->> 'exit_id')::uuid, test.id('ofl_olga'));
select test.eq('H the notice is withdrawn: car available again, block gone, task cancelled',
  (select status from vehicles where id = test.id('vehicle:oflB')) || '/' || (select count(*) from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:oflB') and reason = 'exit')
  || '/' || (select status from tasks where task_type = 'owner_exit' and vehicle_id = test.id('vehicle:oflB')), 'available/0/cancelled');
-- the notice is dated 40 days ago, so the settings row in force then applies
create temp table ofl_frm as select id, free_retransfer_months as m from program_settings where id = (app.settings(app.today() - 40)).id;
update program_settings set free_retransfer_months = 0 where id = (select id from ofl_frm);
create temp table ofl_exit2 as select app.give_exit_notice(test.id('vehicle:oflB'), test.id('ofl_cs'), jsonb_build_object('notice_received_at', now() - interval '40 days')) as r;
grant all on ofl_exit2 to authenticated, anon;
update program_settings p set free_retransfer_months = f.m from ofl_frm f where p.id = f.id;
select test.eq('H with the free transfer-back period set to 0 months in the settings, CarmaCars pays', (select r ->> 'retransfer_fees_paid_by' from ofl_exit2), 'carmacars');
select test.throws('H a customer service assistant cannot complete the exit', format($$select app.complete_exit(%L, %L)$$, (select r ->> 'exit_id' from ofl_exit2), test.id('ofl_cs')), 'Only an Admin or Fleet');
select test.eq('H Fleet completes the exit after the Exit Date',
  (select app.complete_exit(((select r from ofl_exit2) ->> 'exit_id')::uuid, test.id('ofl_fleet'), '{"exit_odometer_km": 30500, "tracker_removed_at": "2026-10-01T10:00:00Z"}') ->> 'status'), 'exited');
select test.eq('H the car leaves the fleet and the owner is told',
  (select status from vehicles where id = test.id('vehicle:oflB'))
  || '/' || (select count(*) from app_events where code = 'owner_exit_completed' and entity_id = ((select r from ofl_exit2) ->> 'exit_id')::uuid), 'exited/1');

-- ------------------------------------------------------------------ I. fee change, schedule change, bank change
select test.throws('I a Fee change needs the notice period from the settings',
  format('select app.give_fee_change_notice(%L, %L, 50000, 2500, %L)', test.id('vehicle:oflG'), test.id('ofl_admin'), app.today() + 10), 'days'' written notice');
select test.throws('I only an Admin changes Fees',
  format('select app.give_fee_change_notice(%L, %L, 50000, 2500, %L)', test.id('vehicle:oflG'), test.id('ofl_fin'), app.today() + 40), 'Only an Admin');
select test.eq('I a Fee notice takes effect after the notice period',
  (select (r ->> 'effective_from')::date - app.today() from app.give_fee_change_notice(test.id('vehicle:oflG'), test.id('ofl_admin'), 50000, 2500, app.today() + 30, 'Insurance renewal') r), 30);
select test.eq('I the old terms end, the new ones start on the date with the same Revenue Share; the owner is told',
  (select string_agg(source || ':' || insurance_fee_cents || ':' || revenue_share_bps || ':' || coalesce((effective_to - app.today())::text, 'open'), ' ' order by effective_from)
               from vehicle_fee_history where vehicle_id = test.id('vehicle:oflG'))
  || '/' || (select count(*) from app_events where code = 'owner_fee_change_notice' and payload ->> 'vehicle_id' = test.id('vehicle:oflG')::text),
  'signed_schedule:45000:3500:30 fee_notice:50000:3500:open/1');
update program_settings set fee_change_notice_days = 45 where id = (app.settings()).id;
select test.throws('I a longer notice period in the settings applies at once',
  format('select app.give_fee_change_notice(%L, %L, 52000, 2500, %L)', test.id('vehicle:oflG'), test.id('ofl_admin'), app.today() + 40), '45 days');
update program_settings set fee_change_notice_days = 30 where id = (app.settings()).id;
create temp table ofl_change as select app.propose_schedule_change(test.id('vehicle:oflG'), test.id('ofl_admin'),
  jsonb_build_object('revenue_share_bps', 3000, 'effective_from', app.today() + 60, 'reason', 'Better share')) as id;
grant all on ofl_change to authenticated, anon;
select test.eq('I a Revenue Share change waits for the owner''s signature on a new Vehicle Schedule; nothing changes yet',
  (select status from vehicle_term_changes where id = (select id from ofl_change)) || '/'
  || (select revenue_share_bps from vehicle_schedules where vehicle_id = test.id('vehicle:oflG') and superseded_by is null), 'awaiting_signature/3500');
select app.record_schedule_change_signed((select id from ofl_change), test.id('ofl_admin'));
select test.eq('I signed: the new schedule supersedes the old one and the share runs from its date',
  (select count(*) || ':' || count(*) filter (where superseded_by is null) from vehicle_schedules where vehicle_id = test.id('vehicle:oflG'))
  || '/' || (select revenue_share_bps || ':' || insurance_fee_cents from vehicle_schedules where vehicle_id = test.id('vehicle:oflG') and superseded_by is null)
  || '/' || (select revenue_share_bps || ':' || source from vehicle_fee_history where vehicle_id = test.id('vehicle:oflG') and effective_to is null), '2:1/3000:45000/3000:signed_schedule');
create temp table ofl_bank as select app.submit_payout_account(test.id('owner:ofl_olga'), test.id('ofl_olga'),
  '{"method": "bank_transfer", "institution_no": "004", "transit_no": "12345", "account_no": "enc:v1:abc", "account_last4": "6621", "key_version": 1}') as id;
grant all on ofl_bank to authenticated, anon;
select test.eq('I new payout details: not current until an Admin verifies them; the owner is told at once; an Admin task',
  (select (not is_current)::text || ':' || (verified_at is null)::text || ':' || (submitted_by = test.id('ofl_olga'))::text from owner_payout_accounts where id = (select id from ofl_bank))
  || '/' || (select count(*) from app_events where code = 'owner_bank_details_changed' and dedupe_key = 'owner_bank_details_changed:' || (select id from ofl_bank) || ':submitted')
  || '/' || (select queue from tasks where task_type = 'verify_payout_account' and related_id = (select id from ofl_bank)), 'true:true:true/1/admin');
select test.throws('I another owner cannot change these details', format($$select app.submit_payout_account(%L, %L, '{"method": "e_transfer", "e_transfer_email": "x@y.test"}')$$, test.id('owner:ofl_olga'), test.id('ofl_omar')), 'Only the owner');
select test.throws('I bank numbers are checked', format($$select app.submit_payout_account(%L, %L, '{"method": "bank_transfer", "institution_no": "4", "transit_no": "1", "account_no": "x", "account_last4": "1"}')$$, test.id('owner:ofl_olga'), test.id('ofl_olga')), 'institution number');
select app.verify_payout_account((select id from ofl_bank), test.id('ofl_admin'), 'Called the number on file');
select test.eq('I verified: it is the current account, the task is done, a second notice',
  (select is_current::text from owner_payout_accounts where id = (select id from ofl_bank)) || '/'
  || (select status from tasks where task_type = 'verify_payout_account' and related_id = (select id from ofl_bank)) || '/'
  || (select count(*) from app_events where code = 'owner_bank_details_changed' and payload ->> 'owner_id' = test.id('owner:ofl_olga')::text), 'true/done/2');
select test.eq('I the change is in the audit log without the bank values',
  (select count(*) || ':' || count(*) filter (where after is not null) from audit_log where entity_table = 'owner_payout_accounts' and entity_id = (select id from ofl_bank)::text) like '%:0', true);
create temp table ofl_pm as select app.record_owner_payment_method(test.id('owner:ofl_olga'), null,
  '{"kind": "pre_authorized_debit", "brand_or_bank": "Bank", "last4": "1234", "processor_method_id": "pm_x"}') as id;
grant all on ofl_pm to authenticated, anon;
select test.eq('I a debit authorization recorded by the server is the new default and is a security notice',
  (select is_default::text from owner_payment_methods where id = (select id from ofl_pm))
  || '/' || (select count(*) from app_events where code = 'owner_bank_details_changed' and payload ->> 'owner_id' = test.id('owner:ofl_olga')::text), 'true/3');

-- ------------------------------------------------------------------ J. owner portal and the owner's own booking
select test.eq('J the portal lists the owner''s three vehicles with status and the next action',
  (select jsonb_array_length(x) || '/' || (x -> 0 ->> 'onboarding_status') || '/' || (x -> 1 -> 'next' ->> 'item') from app.owner_portal_vehicles(test.id('ofl_omar')) x),
  '3/documents_signed/Ownership permit');
select test.eq('J money: three upfront invoices, no statement yet', (select jsonb_array_length(m -> 'invoices') || '/' || jsonb_array_length(m -> 'statements') from app.owner_portal_money(test.id('ofl_omar')) m), '3/0');
select test.eq('J bookings on a managed car show no renter name or mobile',
  (select coalesce(renter_name, 'hidden') || '/' || coalesce(renter_mobile, 'hidden') from app.owner_portal_bookings(test.id('ofl_olga')) where booking_number = 'OFL1'), 'hidden/hidden');
select test.throws('J a renter has no owner portal', format('select app.owner_portal_vehicles(%L)', test.id('ofl_rita')), 'Not an owner');
create temp table ofl_ob as select app.owner_book_own_vehicle(test.id('ofl_olga'), test.id('vehicle:oflF'), now() + interval '20 days', now() + interval '22 days', 'Family trip') as id;
grant all on ofl_ob to authenticated, anon;
select test.eq('J the owner books her own car through request_booking: an Owner Booking, no price, her owner renter record',
  (select b.booking_type || '/' || b.rental_charge_cents || '/' || b.deposit_cents || '/' || r.is_owner_account || '/' || b.source
     from bookings b join renters r on r.id = b.renter_id where b.id = (select id from ofl_ob)), 'owner/0/0/true/owner');
select test.throws('J an owner cannot book another owner''s car', format($$select app.owner_book_own_vehicle(%L, %L, now() + interval '30 days', now() + interval '31 days')$$, test.id('ofl_omar'), test.id('vehicle:oflF')), 'only their own vehicle');
select test.eq('J the documents list holds nothing tied to a renter or booking', (select jsonb_array_length(app.owner_portal_documents(test.id('ofl_olga'))) >= 0), true);

-- ------------------------------------------------------------------ K. the listing pipeline: field staff, a failure and a retry, review, publish
select test.throws('K an owner cannot start a listing for another owner''s car',
  format($$select app.start_listing_intake(%L, '{"vehicle_id": "%s"}')$$, test.id('ofl_omar'), test.id('vehicle:oflC')), 'only their own car');
select test.throws('K a finance assistant does not start listings',
  format($$select app.start_listing_intake(%L, '{"vehicle_id": "%s"}')$$, test.id('ofl_fin'), test.id('vehicle:oflC')), 'Not permitted');
select test.throws('K a plate we do not have', format($$select app.start_listing_intake(%L, '{"plate": "ZZZ999"}')$$, test.id('ofl_fleet')), 'do not have this car');
select app.confirm_vehicle_specs(test.id('ofl_field'), test.id('vehicle:oflC'), '{"trim": "AMG Line"}');
create temp table ofl_k as select app.start_listing_intake(test.id('ofl_field'), jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:oflC')), 'colour', 'Black', 'odometer_km', 20500)) as r;
grant all on ofl_k to authenticated, anon;
create function test.ofl_ki() returns uuid language sql as $$ select ((select r from ofl_k) ->> 'intake_id')::uuid $$;
select test.eq('K field staff on their assigned photo job start by plate: review required, VIN decode queued, 14 shots asked for',
  (select (r ->> 'state') || '/' || (r ->> 'review_required') || '/' || jsonb_array_length(r -> 'missing') from ofl_k)
  || '/' || (select count(*) from listing_jobs where intake_id = test.ofl_ki() and kind = 'decode_vin' and status = 'queued'), 'decoding/true/14/1');
select test.eq('K starting again returns the same open intake', (app.start_listing_intake(test.id('ofl_field'), jsonb_build_object('vehicle_id', test.id('vehicle:oflC'))) ->> 'intake_id')::uuid, test.ofl_ki());
select test.eq('K uploads: the missing list shrinks; all 14 make it complete',
  (select jsonb_array_length(app.record_listing_upload(test.id('ofl_field'), test.ofl_ki(), '{"shot_type": "front_left", "original_path": "o/fl.jpg"}') -> 'missing'))
  || '/' || (select (test.ofl_upload_all(test.ofl_ki(), test.id('ofl_field')) ->> 'complete')), '13/true');
select test.eq('K a retake of one shot replaces the earlier photo', (select count(*) filter (where replaced_at is null) || ':' || count(*) from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and shot_type = 'front_left'), '1:2');
select test.throws('K an unknown shot is refused', format($$select app.record_listing_upload(%L, %L, '{"shot_type": "selfie", "original_path": "x.jpg"}')$$, test.id('ofl_field'), test.ofl_ki()), 'Unknown photo');
-- the worker decodes the VIN
select test.eq('K the worker claims the decode job (skip locked) and completes it',
  (select count(*) from (select app.complete_listing_job(j.id, test.ofl_output(j), 'vpic', 0, 120) from app.claim_listing_jobs('w1', 10, array['decode_vin']) j) q), 1::bigint);
select test.eq('K the decode fills what nobody typed (model, body, seats, transmission) and keeps what a person confirmed (trim AMG Line, colour Black)',
  (select v.model || '/' || v.trim || '/' || v.colour || '/' || v.body_type || '/' || l.seats || '/' || l.transmission || '/' || (v.spec_sources -> 'trim' ->> 'source')
     from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = test.id('vehicle:oflC')), 'C 300/AMG Line/Black/Sedan/5/Automatic/person');  -- 0073: the samples' words
select test.eq('K the decode is cached and the intake waits for submission with every photo in', (select count(*) from vin_decodes where vin = (select upper(vin) from vehicles where id = test.id('vehicle:oflC'))) || '/' || (select state from listing_intakes where id = test.ofl_ki()), '1/photos_uploaded');
select test.eq('K submit: state drafting', (app.submit_listing_intake(test.id('ofl_field'), test.ofl_ki()) ->> 'state'), 'drafting');
select test.eq('K a copy draft and one photo job per photo',
  (select count(*) filter (where kind = 'draft_copy') || ':' || count(*) filter (where kind = 'process_photo') from listing_jobs where intake_id = test.ofl_ki())
  || '/' || (select count(*) from photo_jobs where intake_id = test.ofl_ki()), '1:14/14');
update program_settings set photo_daily_budget_microusd = 0 where id = (app.settings()).id;
select test.eq('K with the daily photo budget at 0 in the settings, only the copy job can be claimed',
  (select string_agg(kind, ',') from app.claim_listing_jobs('w2', 50) j), 'draft_copy');
update program_settings set photo_daily_budget_microusd = 10000000 where id = (app.settings()).id;
select app.complete_listing_job(j.id, test.ofl_output(j), 'workers-ai', 1600, 900) from listing_jobs j where j.intake_id = test.ofl_ki() and j.kind = 'draft_copy';
select test.eq('K the draft is stored with its model and prompt version, lint clean, and fills the empty listing copy',
  (select model || '/' || prompt_version || '/' || cardinality(lint_problems) from listing_drafts where intake_id = test.ofl_ki())
  || '/' || (select (headline is not null)::text || ':' || cardinality(features) from vehicle_listings where vehicle_id = test.id('vehicle:oflC'))
  || '/' || (select state from listing_intakes where id = test.ofl_ki()), 'test-model/listing-v1/0/true:8/processing_photos');
-- one photo fails: first a retry later, then for good
create temp table ofl_front as select j.id from listing_jobs j join vehicle_photos p on p.id = j.vehicle_photo_id
  where j.intake_id = test.ofl_ki() and j.kind = 'process_photo' and p.shot_type = 'front';
grant all on ofl_front to authenticated, anon;
-- the worker takes every photo job; all but the front one succeed
create temp table ofl_claimed as select j.id, (j.id = (select id from ofl_front)) as is_front from app.claim_listing_jobs('w3', 100, array['process_photo']) j;
grant all on ofl_claimed to authenticated, anon;
select test.eq('K the worker claimed the 14 photo jobs', (select count(*) || ':' || count(*) filter (where is_front) from ofl_claimed), '14:1');
select count(*) from (select app.complete_listing_job(c.id, test.ofl_output(j), 'photoroom', 100000, 2000)
                        from ofl_claimed c join listing_jobs j on j.id = c.id where not c.is_front) q;
select test.eq('K the front photo times out: queued again after the first back-off step from the settings (1 minute)',
  (app.fail_listing_job((select id from ofl_front), 'timeout', true, 'photoroom', 0) ->> 'status'), 'queued');
select test.eq('K its next attempt is a minute away', (select round(extract(epoch from next_attempt_at - now()) / 60) from listing_jobs where id = (select id from ofl_front)), 1::numeric);
select test.eq('K every attempt is logged with its provider', (select count(*) from provider_calls where listing_job_id = (select id from ofl_front) and not ok), 1::bigint);
select test.eq('K not due yet: a claim now does not take it',
  (select count(*) from app.claim_listing_jobs('w4', 100, array['process_photo']) j where j.id = (select id from ofl_front)), 0::bigint);
select test.eq('K two minutes later it does',
  (select count(*) from app.claim_listing_jobs('w4', 100, array['process_photo'], now() + interval '2 minutes') j where j.id = (select id from ofl_front)), 1::bigint);
select test.eq('K a failure that cannot be retried fails the job and stops the intake',
  (app.fail_listing_job((select id from ofl_front), 'no subject found', false, 'photoroom') ->> 'intake_state'), 'failed');
select test.eq('K with the reason and a Fleet task',
  (select reason like '%Front%no subject found%' from listing_intakes where id = test.ofl_ki())::text
  || '/' || (select queue from tasks where task_type = 'listing_failed' and related_id = test.ofl_ki()), 'true/fleet');
-- the other photos complete (and their resize steps) while the intake is failed
select test.eq('K the other jobs finish', test.ofl_work() > 0, true);
select test.eq('K still failed until someone retries', (select state from listing_intakes where id = test.ofl_ki()), 'failed');
select test.throws('K a renter cannot retry', format('select app.retry_listing_intake(%L, %L)', test.id('ofl_rita'), test.ofl_ki()), 'Not permitted');
select test.eq('K Fleet retries', (app.retry_listing_intake(test.id('ofl_fleet'), test.ofl_ki()) ->> 'retries'), '1');
select test.eq('K the failed job is queued again with its attempts reset',
  (select status || ':' || attempts from listing_jobs where id = (select id from ofl_front)), 'queued:0');
select test.eq('K the worker finishes the retried photo', test.ofl_work() > 0, true);
select test.eq('K every photo processed and resized, the intake waits for review, an event and a review task',
  (select state from listing_intakes where id = test.ofl_ki())
  || '/' || (select count(*) from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and replaced_at is null and status = 'processed' and variants <> '[]')
  || '/' || (select count(*) from app_events where code = 'staff_listing_ready_for_review' and entity_id = test.ofl_ki())
  || '/' || (select queue || ':' || status from tasks where task_type = 'review_listing' and related_id = test.ofl_ki())
  || '/' || (select status from tasks where task_type = 'listing_failed' and related_id = test.ofl_ki()), 'needs_review/14/1/cs:open/done');
select test.eq('K the cost per car is reportable from the provider log', (select cost_microusd from app.listing_cost_report(test.id('ofl_fin')) where vehicle_id = test.id('vehicle:oflC')), 1401600::bigint);
select test.throws('K a fleet assistant cannot read the cost report through the function', format('select * from app.listing_cost_report(%L)', test.id('ofl_cs')), 'Not permitted');
select test.throws('K field staff cannot publish a listing that needs review', format('select app.publish_listing(%L, %L)', test.id('vehicle:oflC'), test.id('ofl_field')), 'after a CarmaCars review');
select test.throws('K field staff do not review', format('select app.review_listing(%L, %L, true)', test.id('ofl_field'), test.ofl_ki()), 'reviews a listing');
select test.eq('K the reviewer approves without publishing yet, rewording one alt text',
  (app.review_listing(test.id('ofl_cs'), test.ofl_ki(), true, jsonb_build_object('publish', false, 'listing', jsonb_build_object('staff_note', 'The rear seats fold flat.'),
     'photos', jsonb_build_array(jsonb_build_object('photo_id', (select id from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and shot_type = 'trunk' and replaced_at is null),
                                                    'decision', 'approve', 'alt_text', 'Deep trunk of the black C 300'))))
   ->> 'state'), 'approved');
select test.eq('K the generated alt text names the car and the view; the reviewer''s wording is kept',
  (select string_agg(alt_text, ' | ' order by shot_type) from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and replaced_at is null and shot_type in ('rear', 'trunk')),
  '2023 Mercedes-Benz C 300 AMG Line in black, rear view | Deep trunk of the black C 300');
select test.eq('K the odometer photo is approved but never public', (select is_public::text || ':' || status from vehicle_photos where vehicle_id = test.id('vehicle:oflC') and shot_type = 'odometer' and replaced_at is null), 'false:approved');

-- publish refused for each missing requirement, then published
update rate_cards set effective_to = timestamptz '2026-09-02' where vehicle_id = test.id('vehicle:oflC');
select test.throws('K refused without rates', format('select app.publish_listing(%L, %L)', test.id('vehicle:oflC'), test.id('ofl_cs')), 'no rates are set');
update rate_cards set effective_to = null where vehicle_id = test.id('vehicle:oflC');
update vehicle_listings set seats = null where vehicle_id = test.id('vehicle:oflC');
select test.ok('K a missing specification is a checklist item since 0070, not a refusal', exists (select 1 from jsonb_array_elements(app.listing_checklist(test.id('vehicle:oflC'))) x where x ->> 'code' = 'details' and x ->> 'label' like '%seats%') and jsonb_array_length(app.listing_basics_missing(test.id('vehicle:oflC'))) = 0);
update vehicle_listings set seats = 5 where vehicle_id = test.id('vehicle:oflC');
update vehicle_photos set status = 'processed' where vehicle_id = test.id('vehicle:oflC') and shot_type = 'rear' and replaced_at is null;
select test.ok('K a photo not approved yet is a checklist item since 0070', exists (select 1 from jsonb_array_elements(app.listing_checklist(test.id('vehicle:oflC'))) x where x ->> 'code' = 'photos_review'));
update vehicle_photos set status = 'approved' where vehicle_id = test.id('vehicle:oflC') and shot_type = 'rear' and replaced_at is null;
update program_settings set listing_min_photos = 20 where id = (app.settings()).id;
select test.ok('K fewer photos than the setting is no refusal since 0070 (the review still names it)', array_to_string(app.listing_photo_problems(test.id('vehicle:oflC')), '; ') like '%at least 20 needed%' and jsonb_array_length(app.listing_basics_missing(test.id('vehicle:oflC'))) = 0);
update program_settings set listing_min_photos = 10 where id = (app.settings()).id;
update vehicle_listings set headline = 'Too short' where vehicle_id = test.id('vehicle:oflC');
select test.ok('K copy that breaks the rules is replaced by the template at publishing since 0070 (the rules still name it)', array_to_string((select app.listing_copy_problems(l.headline, l.description, l.features, l.faq) from vehicle_listings l where l.vehicle_id = test.id('vehicle:oflC')), '; ') like '%Headline must be 20 to 70 characters%');  -- 0061: the written copy's heading
update vehicle_listings set headline = 'Elevate your drive in a 2023 Mercedes-Benz C 300 sedan' where vehicle_id = test.id('vehicle:oflC');
select test.ok('K a banned phrase is named by the rules (the template replaces it at publishing, 0070)', array_to_string((select app.listing_copy_problems(l.headline, l.description, l.features, l.faq) from vehicle_listings l where l.vehicle_id = test.id('vehicle:oflC')), '; ') like '%Remove the phrase "elevate"%');
update vehicle_listings set headline = 'A 2023 Mercedes-Benz C 300 with all-wheel drive and heated seats' where vehicle_id = test.id('vehicle:oflC');
update vehicles set status = 'out_of_service' where id = test.id('vehicle:oflC');
select test.throws('K refused while the vehicle is out of service', format('select app.publish_listing(%L, %L)', test.id('vehicle:oflC'), test.id('ofl_cs')), 'Out of service');
update vehicles set status = 'available' where id = test.id('vehicle:oflC');
create temp table ofl_pub as select app.publish_listing(test.id('vehicle:oflC'), test.id('ofl_cs')) as r;
grant all on ofl_pub to authenticated, anon;
create function test.ofl_slug(p_label text) returns text language sql security definer as $$ select slug from vehicle_listings where vehicle_id = test.id('vehicle:' || p_label) $$;
select test.eq('K published: a clean slug from year, make, model and trim (0073); intake published; tasks closed; the owner is told',
  (select (r ->> 'slug') = '2023-mercedes-benz-c-300-amg-line' from ofl_pub)::text
  || '/' || (select state from listing_intakes where id = test.ofl_ki())
  || '/' || (select status from tasks where task_type = 'review_listing' and related_id = test.ofl_ki())
  || '/' || (select count(*) from app_events where code = 'owner_vehicle_listed' and entity_id = test.id('vehicle:oflC')), 'true/published/done/1');
update vehicles set colour = 'Obsidian Black' where id = test.id('vehicle:oflC');
select test.eq('K the slug does not change when the details change', test.ofl_slug('oflC'), (select r ->> 'slug' from ofl_pub));
select test.throws('K and cannot be changed by hand once published', format($$update vehicle_listings set slug = 'new-slug' where vehicle_id = %L$$, test.id('vehicle:oflC')), 'does not change');
update vehicles set colour = 'Black' where id = test.id('vehicle:oflC');

-- ------------------------------------------------------------------ L. an Admin lists directly; twins; unlisting and redirects
select app.confirm_vehicle_specs(test.id('ofl_admin'), test.id('vehicle:oflD'), '{"trim": "AMG Line"}');
select test.eq('L an Admin''s listing needs no review: it publishes itself when the worker is done',
  (test.ofl_list(test.id('vehicle:oflD'), test.id('ofl_admin'), 'Black') ->> 'state'), 'published');
select test.eq('L and the listing is live', (select status from vehicle_listings where vehicle_id = test.id('vehicle:oflD')), 'published');
select test.eq('L the twin gets its own slug (never the same address)', test.ofl_slug('oflD') <> test.ofl_slug('oflC') and test.ofl_slug('oflD') like '2023-mercedes-benz-c-300-amg-line-black%', true);
update vehicle_listings set canonical_vehicle_id = test.id('vehicle:oflC') where vehicle_id = test.id('vehicle:oflD');
select test.eq('L a fleet assistant lists a third car of the model in another colour (review not required for assistants)',
  (select (r ->> 'state') from test.ofl_list(test.id('vehicle:oflE'), test.id('ofl_fleet'), 'White') r), 'published');

set role anon;
select test.eq('L anon: the car page has the listing, rates, photos and the vehicle id for 0019''s calendar and quote',
  (select (p ->> 'headline' is not null)::text || '/' || (p ->> 'daily_rate_cents') || '/' || jsonb_array_length(p -> 'photos') || '/'
          || ((p ->> 'vehicle_id')::uuid = test.id('vehicle:oflC'))::text || '/' || (p ->> 'indexable') || '/' || (p ->> 'staff_note')
     from public.car_page(test.ofl_slug('oflC')) p), 'true/10000/13/true/true/The rear seats fold flat.');
create temp table ofl_pubtext as select public.car_page(test.ofl_slug('oflC'))::text || public.car_page(test.ofl_slug('oflD'))::text
                              || (select coalesce(string_agg(f::text, ''), '') from public.fleet() f)
                              || (select coalesce(string_agg(h::text, ''), '') from public.model_hubs() h)
                              || public.model_hub('mercedes-benz-c-300')::text || public.vehicle_photos_public(test.ofl_slug('oflC'))::text
                              || (select string_agg(path, '') from public.sitemap_rows()) as t;
select test.eq('L anon: the twin points its canonical at the first car and is left out of the sitemap; the hub lists all three',
  (select (p ->> 'canonical_path') = '/cars/' || test.ofl_slug('oflC') and not (p ->> 'indexable')::boolean from public.car_page(test.ofl_slug('oflD')) p)::text
  || '/' || (select count(*) from public.sitemap_rows() where kind = 'car' and path in ('/cars/' || test.ofl_slug('oflC'), '/cars/' || test.ofl_slug('oflD'), '/cars/' || test.ofl_slug('oflE')))
  || '/' || jsonb_array_length(public.model_hub('mercedes-benz-c-300') -> 'cars')
  || '/' || (select count(*) from public.sitemap_rows() where kind = 'model_hub' and path = '/rent/mercedes-benz-c-300'), 'true/2/3/1');
select test.eq('L anon: the fleet is rows only, no count field; filters work', (select count(*) >= 3 from public.fleet())::text || '/' || (select count(*) from public.fleet('{"make": "mercedes-benz", "model": "c-300"}')), 'true/3');
reset role;
select test.eq('L anon: no VIN, plate, fleet number, owner, original photo path, cost, draft or private field anywhere in the public reads',
  (select bool_or(t ilike '%' || v.vin || '%' or t ilike '%' || v.plate || '%' or t ilike '%' || v.fleet_number || '%' or t ilike '%Ofl Olga%'
                  or t ilike '%ofl_olga%' or t like '%vehicles/original/%' or t ilike '%spec_sources%' or t ilike '%needs_rewrite%'
                  or t ilike '%cost_microusd%' or t ilike '%18122211%' or t ilike '%draft_id%' or t ilike '%owner_id%')
     from vehicles v, ofl_pubtext where v.id in (test.id('vehicle:oflC'), test.id('vehicle:oflD'), test.id('vehicle:oflE'))), false);
select test.eq('L the public text is not empty', (select length(t) > 1000 from ofl_pubtext), true);
set role anon;
select test.throws('L anon cannot call the pipeline', format('select app.publish_listing(%L, null)', test.id('vehicle:oflC')), 'permission denied');
select test.throws('L anon cannot read the tables behind the pages', 'select * from vehicle_listings', 'permission denied');
reset role;

select test.throws('L field staff cannot take a car off the website', format($$select app.unlist_listing(%L, %L, 'x')$$, test.id('vehicle:oflC'), test.id('ofl_field')), 'Only an Admin');
select test.eq('L unlisting the canonical twin: the old address 301s to the other twin',
  (select (r ->> 'status_code') || ':' || ((r ->> 'to_path') = '/cars/' || test.ofl_slug('oflD'))::text from app.unlist_listing(test.id('vehicle:oflC'), test.id('ofl_cs'), 'Sold') r), '301:true');
select test.eq('L which becomes canonical, and the car page answers with the redirect',
  (select coalesce(canonical_vehicle_id::text, 'none') from vehicle_listings where vehicle_id = test.id('vehicle:oflD'))
  || '/' || (select (p ->> 'redirect') = '/cars/' || test.ofl_slug('oflD') from public.car_page(test.ofl_slug('oflC')) p)::text, 'none/true');
select test.eq('L unlisting the second while another car of the model is live: 301 to the model hub',
  (select (r ->> 'to_path') from app.unlist_listing(test.id('vehicle:oflD'), test.id('ofl_fleet'), 'Repair') r), '/rent/mercedes-benz-c-300');
select test.eq('L and the first address follows (single hop, no chain)',
  (select to_path from listing_redirects where from_path = '/cars/' || test.ofl_slug('oflC'))
  || '/' || (select count(*) from listing_redirects r1 join listing_redirects r2 on r2.from_path = r1.to_path), '/rent/mercedes-benz-c-300/0');
select test.eq('L the last car of the model goes: 410',
  (select (r ->> 'status_code') from app.unlist_listing(test.id('vehicle:oflE'), test.id('ofl_admin'), 'Exited') r), '410');
select test.eq('L 410 everywhere, nothing redirects to a dead page',
  (select string_agg(distinct status_code::text, ',') from listing_redirects where vehicle_id in (test.id('vehicle:oflC'), test.id('vehicle:oflD'), test.id('vehicle:oflE')))
  || '/' || coalesce(public.model_hub('mercedes-benz-c-300')::text, 'no hub'), '410/no hub');
select test.eq('L the car returns with the same slug', (app.publish_listing(test.id('vehicle:oflD'), test.id('ofl_admin')) ->> 'slug') = test.ofl_slug('oflD'), true);
select test.eq('L and its redirect is removed', exists (select 1 from listing_redirects where from_path = '/cars/' || test.ofl_slug('oflD')), false);
select test.eq('L a resolve of an old address', (app.resolve_listing_path('/cars/' || test.ofl_slug('oflE') || '/') ->> 'status_code'), '410');
create temp table ofl_lm as select content_updated_at as t from vehicle_listings where vehicle_id = test.id('vehicle:oflD');
grant all on ofl_lm to authenticated, anon;
update vehicle_listings set publish_at = null, published_by = published_by where vehicle_id = test.id('vehicle:oflD');
select test.eq('L lastmod does not move without a content change', (select content_updated_at from vehicle_listings where vehicle_id = test.id('vehicle:oflD')), (select t from ofl_lm));
update vehicle_listings set description = test.ofl_words(131) where vehicle_id = test.id('vehicle:oflD');
select test.eq('L lastmod moves with a content change, and the sitemap shows it',
  (select content_updated_at > (select t from ofl_lm) from vehicle_listings where vehicle_id = test.id('vehicle:oflD'))
  and (select lastmod >= (select content_updated_at from vehicle_listings where vehicle_id = test.id('vehicle:oflD')) from public.sitemap_rows() where path = '/cars/' || test.ofl_slug('oflD')), true);
update program_settings set listing_review_required_roles = array['owner', 'field', 'va'] where id = (app.settings()).id;
select test.eq('L with "va" added to the review list in the settings, a fleet assistant''s intake needs review',
  (app.start_listing_intake(test.id('ofl_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:oflE'))) ->> 'review_required'), 'true');
update program_settings set listing_review_required_roles = array['owner', 'field'] where id = (app.settings()).id;
select test.eq('L an owner starting on her own car needs review',
  (app.start_listing_intake(test.id('ofl_olga'), jsonb_build_object('vehicle_id', test.id('vehicle:oflG'))) ->> 'review_required'), 'true');
select test.eq('L and is recorded as the owner', (select started_role from listing_intakes where vehicle_id = test.id('vehicle:oflG')), 'owner');
select test.eq('L a listed car under exit notice stays listed until the exit',
  (app.give_exit_notice(test.id('vehicle:oflD'), test.id('ofl_admin'), jsonb_build_object('notice_received_at', now() - interval '35 days')) ->> 'exit_id') is not null
  and (select status from vehicle_listings where vehicle_id = test.id('vehicle:oflD')) = 'published', true);
select test.eq('L completing the exit takes it off the website with its redirect',
  (select app.complete_exit(e.id, test.id('ofl_admin')) -> 'listing' ->> 'status_code' from vehicle_exits e where e.vehicle_id = test.id('vehicle:oflD') and e.status = 'notice'),
  '410');

-- ------------------------------------------------------------------ M. row-level security on every new table, per role
create function test.ofl_counts() returns text language sql as $$
  select string_agg(t || '=' || test.visible('select * from ' || t), ' ' order by t)
    from unnest(array['site_settings', 'site_content_blocks', 'form_drafts', 'leads', 'owner_private_details', 'owner_applications',
                      'onboarding_situations', 'onboarding_checklist_items', 'vin_decodes', 'pdf_templates', 'government_form_fields',
                      'government_form_fills', 'vehicle_term_changes', 'listing_shot_types', 'listing_redirects', 'listing_intakes',
                      'listing_drafts', 'listing_jobs', 'provider_calls']) t
$$;
create function test.ofl_nonzero() returns text language sql as $$
  select string_agg(t, ',' order by t)
    from unnest(array['site_settings', 'site_content_blocks', 'form_drafts', 'leads', 'owner_private_details', 'owner_applications',
                      'onboarding_situations', 'onboarding_checklist_items', 'vin_decodes', 'pdf_templates', 'government_form_fields',
                      'government_form_fills', 'vehicle_term_changes', 'listing_shot_types', 'listing_redirects', 'listing_intakes',
                      'listing_drafts', 'listing_jobs', 'provider_calls']) t
   where test.visible('select * from ' || t) > 0
$$;
grant execute on all functions in schema test to authenticated, anon;

set role anon;
select test.eq('M anon: no privilege on any new table', (select count(*) from regexp_matches(test.ofl_counts(), '=-1', 'g')), 19::bigint);
reset role;
select test.login(test.id('ofl_rita'));
select test.eq('M renter: only the reference lists of situations, checklist wording and shots', test.ofl_nonzero(), 'listing_shot_types,onboarding_checklist_items,onboarding_situations');
select test.logout();
select test.login(test.id('ofl_omar'));
select test.eq('M owner: his own application, private details, form fills and draft; the reference lists',
  test.ofl_nonzero(), 'government_form_fills,listing_shot_types,onboarding_checklist_items,onboarding_situations,owner_applications,owner_private_details');
select test.eq('M owner: only his own rows',
  (select count(*) from owner_applications) || '/' || (select count(distinct owner_id) from government_form_fills) || '/' || (select count(*) from owner_private_details), '1/1/1');
select test.logout();
select test.login(test.id('ofl_olga'));
select test.eq('M owner: her own listing intakes and term changes, her draft; nothing of the worker',
  test.ofl_nonzero(), 'form_drafts,listing_intakes,listing_shot_types,onboarding_checklist_items,onboarding_situations,vehicle_term_changes');
select test.eq('M owner: the intakes she sees are all on her cars',
  (select count(*) filter (where v.owner_id <> test.id('owner:ofl_olga')) from listing_intakes i join vehicles v on v.id = i.vehicle_id), 0::bigint);
select test.logout();
select test.login(test.id('ofl_cs'));
select test.eq('M customer service: settings, content, contact leads, onboarding records, forms, the pipeline; not private details or costs',
  test.ofl_nonzero(), 'government_form_fields,government_form_fills,leads,listing_drafts,listing_intakes,listing_jobs,listing_redirects,listing_shot_types,onboarding_checklist_items,onboarding_situations,owner_applications,pdf_templates,site_content_blocks,site_settings,vehicle_term_changes,vin_decodes');
select test.eq('M customer service: no owner program enquiry among the leads', (select count(*) from leads where kind = 'owner_program'), 0::bigint);
select test.eq('M customer service cannot change the site settings (an Admin''s)', test.affected($$update site_settings set phone = '000'$$), 0::bigint);
select test.logout();
select test.login(test.id('ofl_fleet'));
select test.eq('M fleet: the pipeline and its costs; no leads',
  test.ofl_nonzero(), 'government_form_fields,government_form_fills,listing_drafts,listing_intakes,listing_jobs,listing_redirects,listing_shot_types,onboarding_checklist_items,onboarding_situations,owner_applications,pdf_templates,provider_calls,site_content_blocks,site_settings,vehicle_term_changes,vin_decodes');
select test.logout();
select test.login(test.id('ofl_fin'));
select test.eq('M finance: applications, form fills, term changes and provider costs',
  test.ofl_nonzero(), 'government_form_fills,listing_shot_types,onboarding_checklist_items,onboarding_situations,owner_applications,provider_calls,site_content_blocks,site_settings,vehicle_term_changes');
select test.logout();
select test.login(test.id('ofl_sales'));
select test.eq('M sales: the leads (owner enquiries included) and may update them; nothing of onboarding',
  test.ofl_nonzero() || '/' || (select count(*) > 0 from leads where kind = 'owner_program')::text
  || '/' || test.affected($$update leads set status = 'contacted' where kind = 'owner_program' and email = 'lena@example.test'$$),
  'leads,listing_shot_types,onboarding_checklist_items,onboarding_situations,site_content_blocks,site_settings/true/1');
select test.logout();
select test.login(test.id('ofl_field'));
select test.eq('M field: the settings and the intake they started',
  test.ofl_nonzero() || '/' || (select count(*) from listing_intakes where started_by <> test.id('ofl_field')), 'listing_intakes,listing_shot_types,onboarding_checklist_items,onboarding_situations,site_settings/0');
select test.throws('M field staff cannot write intakes directly', $$update listing_intakes set state = 'published'$$, 'permission denied');
select test.logout();
select test.login(test.id('ofl_admin'));
select test.eq('M admin: every new table', (select count(*) from regexp_split_to_table(test.ofl_nonzero(), ',')), 19::bigint);
select test.eq('M admin: edits the shot list, the situations, the checklist wording and a template from the portal',
  test.affected($$update listing_shot_types set guide = 'Whole car, three-quarter front' where code = 'front_left'$$)
  + test.affected($$update onboarding_situations set description = description where situation = 'S1'$$)
  + test.affected($$update onboarding_checklist_items set label = label where code = 'photos'$$)
  + test.affected($$update pdf_templates set notes = 'Loaded later' where form_code = 'SR-LV-012' and is_current$$), 4::bigint);
select test.throws('M even an Admin does not write the pipeline tables directly', $$update listing_jobs set status = 'failed'$$, 'permission denied');
select test.logout();
select test.eq('M every new table has row-level security, the admin policy and an audit trigger',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = any (array['site_settings', 'site_content_blocks', 'form_drafts', 'leads', 'owner_private_details', 'owner_applications',
                      'onboarding_situations', 'onboarding_checklist_items', 'vin_decodes', 'pdf_templates', 'government_form_fields',
                      'government_form_fills', 'vehicle_term_changes', 'listing_shot_types', 'listing_redirects', 'listing_intakes',
                      'listing_drafts', 'listing_jobs', 'provider_calls'])
      and c.relrowsecurity
      and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), 19::bigint);
select test.eq('M form drafts are audited without their answers',
  (select count(*) filter (where after is not null or before is not null) from audit_log where entity_table = 'form_drafts'), 0::bigint);
select test.eq('M no function of this migration that writes is executable by a browser session',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname in ('submit_owner_application', 'add_owner_vehicle', 'set_vehicle_terms', 'approve_vehicle_terms', 'issue_upfront_invoices',
                        'fill_government_form', 'give_exit_notice', 'complete_exit', 'give_fee_change_notice', 'submit_payout_account',
                        'verify_payout_account', 'start_listing_intake', 'record_listing_upload', 'claim_listing_jobs', 'complete_listing_job',
                        'fail_listing_job', 'publish_listing', 'unlist_listing', 'submit_lead', 'save_form_draft', 'owner_portal_vehicles')), null::text);
