-- 99: the fleet supplier route (migration 0710, docs/changes/2026-11-07-r33-fleet-supplier.md). Fixtures "q33".
select test.suite('99 r33 fleet supplier route: signup, lease structure, tier lock, no fees, portal signing');
-- 0720 refuses new paper signatures; this file's fixtures signed on paper before it (a superuser session only)
select set_config('app.paper_fixture', 'on', false);
select test.mk_user('q33_admin', 'admin');
select test.mk_user('q33_cs', 'va', 'cs');
select test.mk_user('q33_sales', 'va', 'sales');
insert into users (id, email, full_name) values (test.id('q33_web'), 'q33-north@example.test', 'Nora Example');
create function test.q33do(p_name text, p jsonb, p_user text default 'q33_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function test.q33owner() returns uuid language sql stable as $$ select id from owners where email = 'q33-north@example.test' $$;
create function test.q33app(p_owner jsonb, p_cars jsonb) returns jsonb language sql as $$
  select app.submit_owner_application(jsonb_build_object('source', 'web', 'owner', p_owner, 'vehicles', p_cars), test.id('q33_web')) $$;
create function test.q33corp() returns jsonb language sql immutable as $$
  select jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation', 'legal_name', 'Nora Example', 'first_name', 'Nora', 'last_name', 'Example',
    'corporation_name', 'Northshore Holdings Ltd.', 'corporation_number', '1000001', 'signing_officer_name', 'Nora Example', 'signing_officer_title', 'Director',
    'address_line1', '1 Example Way', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5V 1A1', 'country', 'CA', 'email', 'q33-north@example.test', 'phone', '+16475550142') $$;
create function test.q33car(p_vin text, p_plate text, p_tier text, p_transfer jsonb default '{"registered_to": "corporation"}') returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('vin', p_vin, 'plate', p_plate, 'year', 2021, 'make', 'Toyota', 'model', 'Camry', 'colour', 'Grey', 'lease_tier', p_tier,
    'onboarding_method', 'transfer', 'title_status', 'financed', 'finance_party_name', 'Should be ignored', 'fleet_transfer', p_transfer)) $$;
create function test.q33officer() returns jsonb language sql immutable as $$
  select '{"registered_to": "officer", "name": "Nora Example", "address": "1 Example Way, Toronto, ON M5V 1A1", "date": "2026-11-01"}'::jsonb $$;
create function test.q33forms(p_plate text) returns text language sql stable as $$
  select array_to_string(ob.government_forms, ',') || '|' || coalesce((select string_agg(g.form_code || ':' || g.status, ',' order by g.form_code) from government_form_fills g
    where g.vehicle_id = v.id and g.superseded_at is null), '') from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.plate = p_plate $$;

-- ---------------------------------------------------------------- 1. the lawyer approved the text
select test.eq('the Fleet Supplier Lease Agreement is final: no "awaiting lawyer OK"', (app.settings()).fleet_lease_agreements_awaiting_lawyer, false);

-- ---------------------------------------------------------------- 2. signup on the route
select test.throws('the route is for a corporation', format($$select test.q33app(%L, %L)$$, test.q33corp() || '{"owner_type": "individual"}',
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular'))), 'for a corporation');
select test.throws('the corporation number is asked', format($$select test.q33app(%L, %L)$$, test.q33corp() - 'corporation_number',
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular'))), 'corporation number');
select test.throws('the signing officer''s title is asked', format($$select test.q33app(%L, %L)$$, test.q33corp() - 'signing_officer_title',
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular'))), 'title');
select test.throws('each car needs its tier', format($$select test.q33app(%L, %L)$$, test.q33corp(),
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', null))), 'Regular or Troubled');
select test.throws('each car needs its plate', format($$select test.q33app(%L, %L)$$, test.q33corp(),
  jsonb_build_array(test.q33car('1HGCM82633A133001', null, 'regular'))), 'plate');
select test.throws('a tier is for the route only', format($$select test.q33app(%L, %L)$$, test.q33corp() - 'route',
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular'))), 'fleet supplier route only');
select test.throws('each car says who it is registered to now', format($$select test.q33app(%L, %L)$$, test.q33corp(),
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular', '{}'))), 'registered to now');
select test.throws('a car moved in from a person needs the transfer date', format($$select test.q33app(%L, %L)$$, test.q33corp(),
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular', test.q33officer() - 'date'))), 'transfer date');
select test.throws('a car bought from a seller needs the seller''s name', format($$select test.q33app(%L, %L)$$, test.q33corp(),
  jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular', '{"registered_to": "seller", "address": "2 Example Road, Toronto", "date": "2026-10-30"}'))), 'seller''s name');
create temp table q33_app as select test.q33app(test.q33corp(), jsonb_build_array(test.q33car('1HGCM82633A133001', 'Q33A', 'regular'), test.q33car('1HGCM82633A133002', 'Q33B', 'troubled', test.q33officer()))) as r;
select test.eq('the application went in on the route', (select (r ->> 'fleet_supplier')::boolean from q33_app), true);
select test.eq('the owner is a corporation on the fleet supplier route, signed in as the applicant',
  (select owner_type || ':' || onboarding_route || ':' || corporation_name || ':' || (user_id = test.id('q33_web')) from owners where id = test.q33owner()),
  'corporation:fleet_supplier:Northshore Holdings Ltd.:true');
select test.eq('the default lease terms are on the record at once (Program settings)',
  (select regular_cents || '/' || troubled_cents || '/' || claim_profit_bps || '/' || early_writeoff_bps || '/' || writeoff_months || '/' || later_writeoff_bps || '/' || effective_from
     from owner_fleet_lease_terms where owner_id = test.q33owner()), '58000/20000/2000/10000/18/5000/' || app.month_start(app.today()));
select test.eq('the default Upkeep Table', (select string_agg(cost_type || '=' || party, ',' order by cost_type) from owner_upkeep_split where owner_id = test.q33owner()),
  'ball_joints=company,brakes=company,engine=supplier,oil_change=company,refurbishment=supplier,rustproofing=supplier,shocks=supplier,tires=company,transmission=supplier');
select test.eq('each car keeps the tier he chose, Managed, held by the corporation, leased to CarmaCars as an existing corporation',
  (select string_agg(ob.lease_tier || ':' || ob.held_by || ':' || ob.title_status || ':' || v.management_mode || ':' || ob.proposed_onboarding_method, ',' order by v.plate)
     from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = test.q33owner()),
  'regular:corporation:owned_outright:managed:lease_existing_corporation,troubled:corporation:owned_outright:managed:lease_existing_corporation');
select test.eq('a car registered to his corporation: the lease forms only, pre-filled at once', test.q33forms('Q33A'), 'SR-LV-006,SR-LV-012|SR-LV-006:draft,SR-LV-012:draft');
select test.eq('a car an officer moves into the corporation: the lease and the transfer forms, pre-filled at once', test.q33forms('Q33B'),
  'SR-LV-006,SR-LV-012,ON00453,013-0169,013-1155|013-0169:draft,013-1155:draft,ON00453:draft,SR-LV-006:draft,SR-LV-012:draft');
select test.eq('SR-LV-006: his corporation is the registrant, signed by the signing officer; SR-LV-012: CarmaCars holds the plates (the lease)',
  (select (g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[2]') || ' / ' || (g.field_values ->> 'form1[0].page1[0].body[0].businessInfo7[0].esoName[0]')
     from government_form_fills g join vehicles v on v.id = g.vehicle_id where v.plate = 'Q33A' and g.form_code = 'SR-LV-006' and g.superseded_at is null)
  || ' | ' || ((select g.field_values ->> 'form1[0].page1[0].body[0].personalInfo[0].#subform[0].lastName[3]' from government_form_fills g join vehicles v on v.id = g.vehicle_id
     where v.plate = 'Q33A' and g.form_code = 'SR-LV-012' and g.superseded_at is null) is not null),
  'NORTHSHORE HOLDINGS LTD. / NORA EXAMPLE | true');
select test.eq('013-1155: the officer (the current registered owner) to his corporation; the car from the VIN',
  (select concat_ws(' / ', g.field_values ->> 'nameDonor', g.field_values ->> 'nameRecipient', g.field_values ->> 'vehicleID', g.field_values ->> 'make') from government_form_fills g join vehicles v on v.id = g.vehicle_id
    where v.plate = 'Q33B' and g.form_code = '013-1155' and g.superseded_at is null), 'NORA EXAMPLE / NORTHSHORE HOLDINGS LTD. / 1HGCM82633A133002 / Toyota');
select test.ok('the RIN form is for his corporation', exists (select 1 from government_form_fills g join vehicles v on v.id = g.vehicle_id, jsonb_each_text(g.field_values) e
    where v.plate = 'Q33B' and g.form_code = 'ON00453' and g.superseded_at is null and e.value = 'NORTHSHORE HOLDINGS LTD.'));
select test.eq('what is still missing is listed as on the other routes (draft until the RINs and the odometer are in)', (select 'Odometer (km)' = any (g.missing) from government_form_fills g join vehicles v on v.id = g.vehicle_id
    where v.plate = 'Q33A' and g.form_code = 'SR-LV-006' and g.superseded_at is null), true);
select test.eq('the portal lists the 7 forms; Form D only (0720: in his packet after all, signed on screen), no Form C, no upfront payment on the checklist',
  jsonb_array_length(app.owner_portal_forms(test.id('q33_web'))) || '/' || jsonb_array_length(app.owner_witnessed_forms(test.q33owner())) || '/'
  || (select count(*) from app.onboarding_checklist((select id from vehicles where plate = 'Q33A')) c where c.code = 'upfront_payment'),
  '7/1/0');
select test.eq('the portal shows his lease before approval: both cars waiting, at their tier''s rate',
  (select string_agg(c ->> 'tier' || '=' || (c ->> 'monthly_cents') || ':' || (c ->> 'status'), ',' order by c ->> 'plate')
     from jsonb_array_elements(app.owner_portal_home(test.id('q33_web')) #> '{fleet_lease,cars}') c), 'regular=58000:waiting_approval,troubled=20000:waiting_approval');
select test.eq('the portal home knows the route', (app.owner_portal_home(test.id('q33_web')) ->> 'fleet_supplier')::boolean, true);

-- ---------------------------------------------------------------- 3. the tier is locked; only an Admin corrects it before approval
select test.throws('the tier cannot be changed directly', format($$update vehicle_onboardings set lease_tier = 'regular' where vehicle_id = %L$$,
  (select id from vehicles where plate = 'Q33B')), 'does not change');
select test.throws('customer service cannot correct it', format($$select test.q33do('fleet_onboarding_tier_correct', '{"vehicle_id": "%s", "tier": "regular", "reason": "Typed the wrong one"}', 'q33_cs')$$,
  (select id from vehicles where plate = 'Q33B')), 'Admin');
select test.throws('the supplier cannot correct it', format($$select app.fleet_onboarding_tier_correct(test.id('q33_web'), '{"vehicle_id": "%s", "tier": "regular", "reason": "Typed the wrong one"}')$$,
  (select id from vehicles where plate = 'Q33B')), 'Admin');
select test.lives('an Admin corrects a mistake before approval', format($$select test.q33do('fleet_onboarding_tier_correct', '{"vehicle_id": "%s", "tier": "regular", "reason": "Entered as Troubled by mistake"}')$$,
  (select id from vehicles where plate = 'Q33B')));
select test.ok('kept in the audit log', exists (select 1 from audit_log where action = 'fleet_onboarding_tier_corrected' and entity_id = (select id from vehicles where plate = 'Q33B')::text));
select test.lives('and back (the tests below use Troubled)', format($$select test.q33do('fleet_onboarding_tier_correct', '{"vehicle_id": "%s", "tier": "troubled", "reason": "Undo the test correction"}')$$,
  (select id from vehicles where plate = 'Q33B')));

-- ---------------------------------------------------------------- 4. no paper signing for a supplier
select test.throws('no paper signature is recorded for a supplier''s agreements', format($$select app.record_paper_signature(test.id('q33_admin'),
  '{"doc_type": "owner_agreement", "target_id": "%s", "signer_name": "Nora Example", "signed_on": "2026-11-07"}')$$, test.q33owner()), 'owner portal only');

-- ---------------------------------------------------------------- 5. Admin approves: each car on the lease at its tier, no fees
select test.eq('the approval page knows the route and each car''s tier and lease',
  (select (p ->> 'fleet_supplier') || ':' || (select string_agg((c ->> 'lease_tier') || '=' || (c ->> 'lease_cents'), ',' order by c ->> 'lease_tier') from jsonb_array_elements(p -> 'cars') c)
     from (select app.application_approve_plan(test.id('q33_admin'), jsonb_build_object('id', (select r ->> 'application_id' from q33_app))) p) z),
  'true:regular=58000,troubled=20000');
select test.throws('customer service cannot approve', format($$select app.application_approve(test.id('q33_cs'), '{"id": "%s"}')$$, (select r ->> 'application_id' from q33_app)), 'Admin');
select test.lives('an Admin approves the application', format($$select app.application_approve(test.id('q33_admin'), '{"id": "%s", "delivered_on": "%s"}')$$,
  (select r ->> 'application_id' from q33_app), app.today()));
select test.eq('each car is on the lease at the tier he chose, from the delivery date',
  (select string_agg(a.lease_tier || '=' || a.monthly_cents || '@' || (a.starts_on = app.today()), ',' order by v.plate) from vehicle_owner_arrangements a join vehicles v on v.id = a.vehicle_id
    where a.owner_id = test.q33owner() and a.cancelled_at is null), 'regular=58000@true,troubled=20000@true');
select test.eq('the pay model is the fleet lease; he signs the Fleet Supplier Lease Agreement with the Title-Holding Agreement it relies on',
  app.owner_pay_model(test.q33owner()) || ':' || (select string_agg(kind || '/' || variant || '/' || status, ',' order by kind) from owner_agreements where owner_id = test.q33owner() and status <> 'void'),
  'fleet_lease:enrollment/fleet_lease/draft,title_holding/standard/draft');
select test.eq('after approval, Form B (the lease summary) is to sign on screen; the forms are filled again', coalesce((select string_agg(x ->> 'code', ',') from jsonb_array_elements(app.owner_screen_forms(test.q33owner())) x), '-')
  || ' ' || test.q33forms('Q33A'), 'B SR-LV-006,SR-LV-012|SR-LV-006:draft,SR-LV-012:draft');
select test.eq('no fee invoice and no debit was made', (select count(*) from owner_invoices where owner_id = test.q33owner() and status <> 'void')
  + (select count(*) from owner_debit_attempts d join owner_invoices i on i.id = d.owner_invoice_id where i.owner_id = test.q33owner()), 0::bigint);
select test.throws('and none can be made', format($$insert into owner_invoices (owner_id, vehicle_id, kind, status) values (%L, %L, 'custom', 'draft')$$,
  test.q33owner(), (select id from vehicles where plate = 'Q33A')), 'fleet lease');
select test.eq('the monthly run passes his cars by', (select count(app.generate_owner_invoice(v.id, (app.month_start(app.today()) + interval '1 month')::date, test.id('q33_admin'))) from vehicles v where v.owner_id = test.q33owner()), 0::bigint);
select test.eq('approval kept the tier', (select string_agg(ob.lease_tier, ',' order by v.plate) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = test.q33owner()), 'regular,troubled');
select test.eq('the portal: on the lease, the next payment is the first Payout Date one full month after delivery',
  (select string_agg((c ->> 'status') || '@' || ((c ->> 'next_payment_on')::date = app.payout_date(app.fleet_first_pay_month(app.today()))), ',' order by c ->> 'plate')
     from jsonb_array_elements(app.owner_portal_home(test.id('q33_web')) #> '{fleet_lease,cars}') c), 'on_lease@true,on_lease@true');
select test.ok('the portal''s next payment date', (app.owner_portal_home(test.id('q33_web')) #>> '{fleet_lease,next_payment_on}')::date >= app.today());
select test.throws('after approval the onboarding correction is closed (the lease correction applies)', format($$select test.q33do('fleet_onboarding_tier_correct', '{"vehicle_id": "%s", "tier": "regular", "reason": "Typed the wrong one"}')$$,
  (select id from vehicles where plate = 'Q33B')), 'on the lease');
select test.eq('the Admin Fleet lease card shows the route and each car''s tier', (select (x ->> 'route') || ':' || jsonb_array_length(x -> 'cars')
  || ':' || (x #>> '{cars,0,requested_tier}') from (select app.door(test.id('q33_admin'), 'aal2', 'ops_read', 'fleet_lease', jsonb_build_object('owner', test.q33owner())) x) z), 'fleet_supplier:2:regular');

-- ---------------------------------------------------------------- 6. a second car later, from the portal: the route is kept
create temp table q33_more as select app.submit_owner_application(jsonb_build_object('source', 'web', 'owner_id', test.q33owner(),
  'vehicles', jsonb_build_array(test.q33car('1HGCM82633A133003', 'Q33C', 'troubled', '{"registered_to": "seller", "name": "Sam Seller", "address": "2 Example Road, Toronto, ON M4M 1A1", "date": "2026-10-30"}'))), test.id('q33_web')) as r;
select test.eq('the next car is on the route with its tier; bought from a seller: the lease forms and the RIN form (the transfer itself is on the back of the permit)',
  (select ob.lease_tier || ':' || (ob.fleet_transfer ->> 'registered_to') || ':' || (ob.fleet_transfer ->> 'date') from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.plate = 'Q33C') || ' ' || test.q33forms('Q33C'),
  'troubled:seller:2026-10-30 SR-LV-006,SR-LV-012,ON00453|ON00453:draft,SR-LV-006:draft,SR-LV-012:draft');
select test.throws('and needs a tier', format($$select app.submit_owner_application(%L, test.id('q33_web'))$$, jsonb_build_object('source', 'web', 'owner_id', test.q33owner(),
  'vehicles', jsonb_build_array(test.q33car('1HGCM82633A133004', 'Q33D', null)))), 'Regular or Troubled');

-- ---------------------------------------------------------------- 7. staff offer the same route
select test.throws('staff choose "signs on paper": refused for a supplier', $$select app.staff_add_owner_car(test.id('q33_cs'), jsonb_build_object('signing', 'paper',
  'owner', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation', 'legal_name', 'Sam Example', 'corporation_name', 'Lakeview Fleet Ltd.', 'email', 'q33-lake@example.test', 'phone', '+16475550143'),
  'vehicle', jsonb_build_object('vin', '1HGCM82633A133005', 'plate', 'Q33E', 'year', 2020, 'make', 'Honda', 'model', 'Accord'), 'fleet', jsonb_build_object('tier', 'regular')))$$, 'owner portal only');
select test.throws('staff need the tier', $$select app.staff_add_owner_car(test.id('q33_cs'), jsonb_build_object('signing', 'email',
  'owner', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation', 'legal_name', 'Sam Example', 'corporation_name', 'Lakeview Fleet Ltd.', 'email', 'q33-lake@example.test', 'phone', '+16475550143'),
  'vehicle', jsonb_build_object('vin', '1HGCM82633A133005', 'plate', 'Q33E', 'year', 2020, 'make', 'Honda', 'model', 'Accord')))$$, 'tier');
select test.lives('customer service adds a supplier and a car on the route', $$select app.staff_add_owner_car(test.id('q33_cs'), jsonb_build_object('signing', 'email',
  'owner', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation', 'legal_name', 'Sam Example', 'corporation_name', 'Lakeview Fleet Ltd.', 'email', 'q33-lake@example.test', 'phone', '+16475550143'),
  'vehicle', jsonb_build_object('vin', '1HGCM82633A133005', 'plate', 'Q33E', 'year', 2020, 'make', 'Honda', 'model', 'Accord'), 'fleet', jsonb_build_object('tier', 'regular'),
  'plan', jsonb_build_object('invoices', jsonb_build_array(jsonb_build_object('type', 'first_last', 'amount_cents', 100000, 'action', 'send')))))$$);
select test.eq('the supplier has the lease structure; the car waits for an Admin (not on the lease yet), with its tier',
  (select o.onboarding_route || ':' || (select count(*) from owner_fleet_lease_terms t where t.owner_id = o.id) || ':' || ob.lease_tier || ':' || ob.status || ':' || app.fleet_car(v.id)
     from owners o join vehicles v on v.owner_id = o.id join vehicle_onboardings ob on ob.vehicle_id = v.id where o.email = 'q33-lake@example.test'), 'fleet_supplier:1:regular:intake:false');
select test.eq('no invoice was made from the proposal', (select count(*) from owner_invoices i join owners o on o.id = i.owner_id where o.email = 'q33-lake@example.test' and i.status <> 'void'), 0::bigint);
select test.lives('an Admin approves it', format($$select app.application_approve(test.id('q33_admin'), '{"id": "%s"}')$$,
  (select a.id from owner_applications a join owners o on o.id = a.owner_id where o.email = 'q33-lake@example.test')));
select test.eq('the car is on the lease; staff left who it is registered to: his corporation, the lease forms filled; Form D only (0720)', (select app.fleet_car(v.id) || ':' || array_to_string(ob.government_forms, ',') || ':'
  || (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null) || ':' || jsonb_array_length(app.owner_witnessed_forms(o.id))
  from owners o join vehicles v on v.owner_id = o.id join vehicle_onboardings ob on ob.vehicle_id = v.id where o.email = 'q33-lake@example.test'), 'true:SR-LV-006,SR-LV-012:2:1');
select test.lives('Owners > Add an owner offers the route (customer service)', $$select test.q33do('owner_add', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation',
  'legal_name', 'Kim Example', 'corporation_name', 'Harbour Cars Ltd.', 'email', 'q33-harbour@example.test'), 'q33_cs')$$);
select test.eq('with the lease structure at once', (select o.onboarding_route || ':' || (select count(*) from owner_fleet_lease_terms t where t.owner_id = o.id) || ':' || (select count(*) from owner_upkeep_split s where s.owner_id = o.id)
  from owners o where o.email = 'q33-harbour@example.test'), 'fleet_supplier:1:9');
select test.throws('the route is for a corporation (Add an owner)', $$select test.q33do('owner_add', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'individual',
  'legal_name', 'Lee Example', 'email', 'q33-lee@example.test'), 'q33_cs')$$, 'corporation');
select test.throws('Sales cannot use Add an owner (as before)', $$select test.q33do('owner_add', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation',
  'legal_name', 'Lee Example', 'corporation_name', 'Lee Fleet Ltd.', 'email', 'q33-lee@example.test'), 'q33_sales')$$, null);
select test.mk_owner('q33_std');
update owners set owner_type = 'corporation', corporation_name = 'Example Standard Cars Inc.' where id = test.id('owner:q33_std');
select test.mk_vehicle('Q33S', 'q33_std', 'managed', 45000, 2500, 3000, date '2026-08-01');
select test.throws('a standard owner with cars cannot switch to the route', $$select app.fleet_supplier_setup(test.id('owner:q33_std'), test.id('q33_admin'))$$, 'standard terms');

-- ---------------------------------------------------------------- 8. privileges
select test.eq('the new internals are not callable by signed-in users', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('fleet_supplier_setup', 'fleet_onboarding_tier_correct', 'owner_fleet_lease_view', 'fleet_supplier_car_clear')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);

-- ---------------------------------------------------------------- 9. an Admin's own entry is approved at once, on the lease
select test.lives('an Admin adds a supplier and a car on the route', $$select app.staff_add_owner_car(test.id('q33_admin'), jsonb_build_object('signing', 'email',
  'owner', jsonb_build_object('route', 'fleet_supplier', 'owner_type', 'corporation', 'legal_name', 'Ari Example', 'corporation_name', 'Bayside Autos Ltd.', 'email', 'q33-bay@example.test', 'phone', '+16475550144'),
  'vehicle', jsonb_build_object('vin', '1HGCM82633A133006', 'plate', 'Q33F', 'year', 2022, 'make', 'Kia', 'model', 'Forte'), 'fleet', jsonb_build_object('tier', 'troubled', 'delivered_on', app.today()::text),
  'plan', jsonb_build_object('invoices', '[]'::jsonb)))$$);
select test.eq('approved, on the lease at Troubled, no invoice, the lease forms', (select ob.status || ':' || a.lease_tier || '=' || a.monthly_cents || ':' || (select count(*) from owner_invoices i where i.owner_id = o.id and i.status <> 'void') || ':' || cardinality(ob.government_forms)
  from owners o join vehicles v on v.owner_id = o.id join vehicle_onboardings ob on ob.vehicle_id = v.id join vehicle_owner_arrangements a on a.vehicle_id = v.id and a.cancelled_at is null where o.email = 'q33-bay@example.test'), 'terms_set:troubled=20000:0:2');

-- ---------------------------------------------------------------- 10. every route makes its forms by itself (no staff step beyond approval)
create function test.q33route(p_n integer, p_type text, p_method text, p_title text default 'owned_outright') returns text language plpgsql as $$
declare
  r jsonb;
  v uuid;
begin
  r := app.submit_owner_application(jsonb_build_object('source', 'web', 'owner', jsonb_build_object('owner_type', p_type, 'legal_name', 'Route Example ' || p_n, 'first_name', 'Route', 'last_name', 'Example',
    'corporation_name', case when p_type = 'corporation' then 'Route Example ' || p_n || ' Ltd.' end, 'corporation_number', '200000' || p_n, 'signing_officer_name', 'Route Example', 'signing_officer_title', 'Director',
    'address_line1', p_n || ' Example Way', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5V 1A1', 'email', 'q33-route' || p_n || '@example.test', 'phone', '+1647555020' || p_n,
    'licence_number', 'E1234-56789-0123' || p_n, 'date_of_birth', '1980-01-01'),
    'vehicles', jsonb_build_array(jsonb_build_object('vin', '1HGCM82633A13310' || p_n, 'plate', 'Q33R' || p_n, 'year', 2021, 'make', 'Honda', 'model', 'Civic', 'colour', 'Blue', 'odometer_km', 1000,
      'held_by', p_type, 'title_status', p_title, 'finance_party_name', case when p_title <> 'owned_outright' then 'Example Lender' end, 'management_mode', 'managed', 'onboarding_method', p_method,
      'current_insurer', 'Example Insurer', 'new_corporation', case when p_method = 'lease_new_owner_corporation' then jsonb_build_object('proposed_name', 'numbered') end))), null);
  perform app.application_approve(test.id('q33_admin'), jsonb_build_object('id', r ->> 'application_id', 'cars', jsonb_build_array(jsonb_build_object('vehicle_id', r #>> '{vehicles,0,vehicle_id}',
    'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', p_method), 'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none')))));
  v := (r #>> '{vehicles,0,vehicle_id}')::uuid;
  return (select cardinality(ob.government_forms) || '=' || (select count(*) from government_form_fills g where g.vehicle_id = v and g.superseded_at is null and g.form_code = any (ob.government_forms))
            from vehicle_onboardings ob where ob.vehicle_id = v);
end $$;
select test.eq('S1 a corporation''s car leased to CarmaCars: its forms are filled at approval', test.q33route(1, 'corporation', 'lease_existing_corporation'), '2=2');
select test.eq('S2 through a new Owner Corporation: its forms are filled at approval', test.q33route(2, 'individual', 'lease_new_owner_corporation'), '5=5');
select test.eq('S3 Co-Registrant: its forms are filled at approval', test.q33route(3, 'individual', 'co_registrant'), '2=2');
select test.eq('S4 Transfer: no registry form is needed (the back of the permit)', test.q33route(4, 'individual', 'transfer'), '0=0');
select test.eq('S5 Transfer of a financed car: no registry form is needed', test.q33route(5, 'individual', 'transfer', 'financed'), '0=0');
