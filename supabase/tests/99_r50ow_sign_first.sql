-- 99: sign first, then cars (migration 3800, docs/changes/2026-11-24-r50-sign-first.md). Fixtures "s50".
select test.suite('99 r50 sign first: the master agreement at signup, Schedule A per car, the gates, reminders, the connector');
select test.mk_user('s50_admin', 'admin');
select test.mk_user('s50_fleet', 'va', 'fleet');
select test.mk_user('s50_cs', 'va', 'cs');
select test.mk_user('s50_sales', 'va', 'sales');
select test.mk_user('s50_web', 'owner');
select test.mk_user('s50_other', 'owner');
create table test.s50 (k text primary key, v jsonb);
create function test.s50v(p text) returns jsonb language sql stable as $$ select v from test.s50 where k = p $$;
create function test.s50o() returns uuid language sql stable as $$ select id from owners where email = 's50-north@example.test' $$;
create function test.s50ea(p_owner uuid) returns text language sql stable as $$
  select string_agg(kind || '/' || variant || '/' || status, ',' order by kind) from owner_agreements where owner_id = p_owner and status <> 'void' $$;
create function test.s50car(p_vin text, p_plate text, p_tier text) returns jsonb language sql immutable as $$
  select jsonb_build_object('vin', p_vin, 'plate', p_plate, 'year', 2021, 'make', 'Toyota', 'model', 'Camry', 'colour', 'Grey', 'lease_tier', p_tier,
    'fleet_transfer', '{"registered_to": "corporation"}'::jsonb) $$;
create function test.s50vin(p_n integer) returns text language plpgsql immutable as $$
declare c text; v text;
begin
  foreach c in array array['0','1','2','3','4','5','6','7','8','9','X'] loop
    v := '1HGCM8263' || c || 'A' || lpad((150000 + p_n)::text, 6, '0');
    if app.vin_check_ok(v) then return v; end if;
  end loop;
  return null;
end $$;
create function test.s50v_id(p_plate text) returns uuid language sql stable as $$ select id from vehicles where plate = p_plate $$;
create function test.s50events(p_code text, p_owner uuid) returns bigint language sql stable as $$
  select count(*) from app_events where code = p_code and (entity_id = p_owner or payload ->> 'owner_id' = p_owner::text) $$;
create function test.s50sign(p_owner uuid) returns void language plpgsql as $$
begin
  -- the e-signature itself is tested by 99_esign_everywhere; here its effect: the agreements and schedule entries signed
  update owner_agreements set status = 'signed', agreement_date = app.today() where owner_id = p_owner and status in ('draft', 'sent');
  update vehicle_schedules s set signed_at = now() from vehicles v where v.id = s.vehicle_id and v.owner_id = p_owner and s.signed_at is null and s.superseded_by is null;
end $$;

-- ---------------------------------------------------------------- 1. the setting
select test.eq('sign first is on by default', (app.settings()).owner_sign_first, true);

-- ---------------------------------------------------------------- 2. the master agreement at signup, no car needed
-- a supplier's corporation signs up (the owner account) and chooses the fleet supplier route: nothing about a car yet
insert into owners (user_id, owner_type, legal_name, first_name, last_name, corporation_name, corporation_number, signing_officer_name, signing_officer_title,
                    address_line1, city, province, postal_code, email, phone, status)
values (test.id('s50_web'), 'corporation', 'Nora Example', 'Nora', 'Example', 'Northshore Fifty Ltd.', '5000001', 'Nora Example', 'Director',
        '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', 's50-north@example.test', '+16475550150', 'lead');
update owners set onboarding_route = 'fleet_supplier' where email = 's50-north@example.test';
select test.eq('a supplier with a complete profile has the Fleet Supplier Lease Agreement and the Title-Holding and Lease Agreement at once, no car needed',
  test.s50ea(test.s50o()) || ' cars:' || (select count(*) from vehicles where owner_id = test.s50o()), 'enrollment/fleet_lease/draft,title_holding/standard/draft cars:0');
select test.eq('the corporation''s signing officer signs it', (select corporate_signatory_name || ', ' || corporate_signatory_title from owner_agreements where owner_id = test.s50o() and kind = 'enrollment'),
  'Nora Example, Director');
select test.eq('the default lease terms of Program settings are on the record (the agreement shows them)',
  (select regular_cents || '/' || troubled_cents from owner_fleet_lease_terms where owner_id = test.s50o()),
  (select fleet_lease_default_regular_cents || '/' || fleet_lease_default_troubled_cents from program_settings limit 1));
select test.eq('the owner is told that it is ready to sign (once the route is chosen, the notice of the other set is not sent)', (select count(*) from app_events where code = 'owner_master_agreement_ready' and entity_id = test.s50o() and processed_at is null), 1::bigint);
select test.eq('the notice names the agreement and the signing page',
  (select payload ->> 'agreement_title' || ' | ' || (payload ->> 'sign_url' like '%/owner/sign') from app_events where code = 'owner_master_agreement_ready' and entity_id = test.s50o() and processed_at is null),
  'Fleet Supplier Lease Agreement | true');
select test.eq('the agreement facts open with no car (Schedule A empty)', jsonb_array_length(app.owner_agreement_facts(test.s50o(), test.id('s50_web')) -> 'schedules'), 0);
select test.lives('the owner opens the master agreement for signature with no car',
  format($$select app.owner_open_agreements(%L, test.id('s50_web'), '[{"key": "enrollment", "template_version": "t", "sha256": "%s", "storage_path": "x/ea.pdf"}]')$$,
    test.s50o(), repeat('a', 64)));
select test.eq('it is sent for signature', (select status from owner_agreements where owner_id = test.s50o() and kind = 'enrollment'), 'sent');
select test.eq('what is missing: the two agreements, for the owner',
  (select string_agg(x ->> 'code' || ':' || (x ->> 'who'), ',') from jsonb_array_elements(app.owner_sign_missing(test.s50o())) x), 'master:owner,title_holding:owner');

-- an owner whose profile is not complete gets the agreement once it is
insert into owners (owner_type, legal_name, first_name, email, phone, status) values ('individual', 'Ian Example', 'Ian', 's50-ian@example.test', '+16475550151', 'lead');
select test.eq('no address yet: no agreement; the missing values are named',
  coalesce(test.s50ea((select id from owners where email = 's50-ian@example.test')), 'none') || ' | ' ||
  (select x ->> 'label' from jsonb_array_elements(app.owner_sign_missing((select id from owners where email = 's50-ian@example.test'))) x limit 1),
  'none | Complete the profile: Street address, City, Postal code');
update owners set address_line1 = '2 Example Road', city = 'Toronto', postal_code = 'M4M 1A1' where email = 's50-ian@example.test';
select test.eq('a program owner gets the Vehicle Enrollment Agreement once the profile is complete (the title agreement waits for a car that needs it)',
  test.s50ea((select id from owners where email = 's50-ian@example.test')), 'enrollment/standard/draft');
update owners set city = 'Toronto' where email = 's50-ian@example.test';
select test.eq('saving the profile again makes nothing new', (select count(*) from owner_agreements where owner_id = (select id from owners where email = 's50-ian@example.test')), 1::bigint);

-- ---------------------------------------------------------------- 3. cars go on Schedule A when added
insert into test.s50 select 'app1', app.submit_owner_application(jsonb_build_object('source', 'web', 'owner_id', test.s50o(),
  'vehicles', jsonb_build_array(test.s50car(test.s50vin(1), 'S50A', 'regular'), test.s50car(test.s50vin(2), 'S50B', 'troubled'))), test.id('s50_web'));
select test.eq('each car the supplier adds gets its numbered Schedule A entry at once, in the master agreement (not signed yet)',
  (select string_agg(v.plate || '#' || s.vehicle_number || ':' || s.is_additional || ':' || (a.kind = 'enrollment'), ',' order by v.plate)
     from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join owner_agreements a on a.id = s.owner_agreement_id where v.owner_id = test.s50o()), 'S50A#1:false:true,S50B#2:false:true');
select test.eq('Managed, no fees: the lease at its tier', (select string_agg(s.management_mode || ':' || s.insurance_fee_cents || ':' || s.revenue_share_bps, ',' order by v.plate)
  from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = test.s50o()), 'managed:0:0,managed:0:0');
select test.eq('the ServiceOntario forms of each car are made at that point',
  (select string_agg(v.plate || '=' || (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null), ',' order by v.plate) from vehicles v where v.owner_id = test.s50o()),
  'S50A=2,S50B=2');
select test.eq('the agreement set stays the fleet lease (no car on the lease yet)', app.owner_pay_model(test.s50o()) || ':' || test.s50ea(test.s50o()),
  'fleet_lease:enrollment/fleet_lease/sent,title_holding/standard/draft');

-- ---------------------------------------------------------------- 4. the gates
select test.throws('a car is not delivered (on the lease) before the owner signs', format($$select app.fleet_lease_car_set(test.id('s50_admin'), '{"vehicle_id": "%s", "tier": "regular"}')$$,
  test.s50v_id('S50A')), 'waits for the owner''s signature');
select test.throws('a car is not rented (live) before the owner signs', format($$update vehicles set status = 'available' where id = %L$$, test.s50v_id('S50A')), 'waits for the owner''s signature');
insert into test.s50 select 'ap1', app.application_approve(test.id('s50_admin'), jsonb_build_object('id', test.s50v('app1') ->> 'application_id', 'delivered_on', app.today()));
select test.eq('an Admin''s approval before the signature waits for it and says what is missing',
  (test.s50v('ap1') ->> 'waiting_for_signature') || ' | ' || (select status from owner_applications where id = (test.s50v('app1') ->> 'application_id')::uuid)
  || ' | ' || (select count(*) from vehicle_owner_arrangements a join vehicles v on v.id = a.vehicle_id where v.owner_id = test.s50o()),
  'true | new | 0');
select test.ok('the wait is kept on the application, with who approved', (select sign_wait_at is not null and sign_wait_by = test.id('s50_admin') from owner_applications where id = (test.s50v('app1') ->> 'application_id')::uuid));
select test.eq('the approval page shows what is missing', jsonb_array_length(app.application_approve_plan(test.id('s50_admin'), jsonb_build_object('id', test.s50v('app1') ->> 'application_id')) -> 'sign_missing') > 0, true);

-- ---------------------------------------------------------------- 5. the status and Send reminder
select test.eq('the owner reads their own status', (app.owner_sign_status(test.id('s50_web'), jsonb_build_object('owner_id', test.s50o())) ->> 'viewer'), 'owner');
select test.eq('Fleet reads it, and may remind', (select (s ->> 'viewer') || ':' || (s ->> 'can_remind') from (select app.owner_sign_status(test.id('s50_fleet'), jsonb_build_object('owner_id', test.s50o())) s) z), 'staff:true');
select test.throws('another owner cannot read it', format($$select app.owner_sign_status(test.id('s50_other'), '{"owner_id": "%s"}')$$, test.s50o()), 'Not permitted');
select test.throws('Sales cannot read an owner they did not bring', format($$select app.owner_sign_status(test.id('s50_sales'), '{"owner_id": "%s"}')$$, test.s50o()), 'Not permitted');
select test.eq('each car: on Schedule A, not signed, not approved, and why it cannot move',
  (select string_agg((c ->> 'plate') || ':' || (c ->> 'scheduled') || ':' || (c ->> 'schedule_signed') || ':' || (c ->> 'approved') || ':' || (c ->> 'waiting_approval') || ':' || (c ->> 'gate' is not null), ',' order by c ->> 'plate')
     from jsonb_array_elements(app.owner_sign_status(test.id('s50_admin'), jsonb_build_object('owner_id', test.s50o())) -> 'cars') c),
  'S50A:true:false:false:true:true,S50B:true:false:false:true:true');
select test.throws('Sales cannot send a reminder', format($$select app.owner_sign_reminder(test.id('s50_sales'), '{"owner_id": "%s"}')$$, test.s50o()), 'Admin, customer service or Fleet');
select test.eq('a preview sends nothing', (select (r ->> 'preview') || ':' || test.s50events('owner_sign_reminder', test.s50o())
  from (select app.owner_sign_reminder(test.id('s50_fleet'), jsonb_build_object('owner_id', test.s50o(), 'preview', true)) r) z), 'true:0');
select test.lives('Fleet sends the reminder', format($$select app.door(test.id('s50_fleet'), 'aal1', 'va_do', 'owner_sign_reminder', '{"owner_id": "%s"}')$$, test.s50o()));
select test.eq('the owner gets it (email, in-app, push) with every missing step', (select (payload ->> 'missing_text') like '%Fleet Supplier Lease Agreement%Confirm%S50A%'
  from app_events where code = 'owner_sign_reminder' and entity_id = test.s50o()), true);
select test.throws('not twice within 10 minutes', format($$select app.owner_sign_reminder(test.id('s50_admin'), '{"owner_id": "%s"}')$$, test.s50o()), '10 minutes');
select test.eq('the Admin''s agreements checklist names a missing profile', (select i ->> 'why' from jsonb_array_elements(app.owner_agreements_checklist(test.id('s50_admin'),
  '{}'::jsonb)) r, jsonb_array_elements(r -> 'items') i where r ->> 'owner_id' = (select id::text from owners where email = 's50-ian@example.test') and i ->> 'status' = 'missing' limit 1), null);

-- ---------------------------------------------------------------- 6. the owner signs: the approval goes through by itself
select test.lives('the supplier signs the master agreement, the title agreement and Schedule A', format($$select test.s50sign(%L)$$, test.s50o()));
select test.eq('the approval that waited went through: approved, each car on the lease at its tier from the delivery date',
  (select status from owner_applications where id = (test.s50v('app1') ->> 'application_id')::uuid) || ' | ' ||
  (select string_agg(a.lease_tier || '=' || a.monthly_cents || '@' || (a.starts_on = app.today()), ',' order by v.plate) from vehicle_owner_arrangements a join vehicles v on v.id = a.vehicle_id
    where a.owner_id = test.s50o() and a.cancelled_at is null), 'approved | regular=' || (select fleet_lease_default_regular_cents from program_settings limit 1)
    || '@true,troubled=' || (select fleet_lease_default_troubled_cents from program_settings limit 1) || '@true');
select test.ok('the wait is cleared', (select sign_wait_at is null from owner_applications where id = (test.s50v('app1') ->> 'application_id')::uuid));
select test.eq('Fleet and the Admins hear it, with the next step', (select payload ->> 'next_step' like 'Approved by itself%' from app_events where code = 'staff_owner_signed' and entity_id = test.s50o() order by id desc limit 1), true);
select test.eq('the owner hears each car is on the lease', test.s50events('owner_car_delivered', test.s50o()), 2::bigint);
select test.eq('nothing is missing any more', jsonb_array_length(app.owner_sign_missing(test.s50o())), 0);
select test.lives('a signed car may go live', format($$update vehicles set status = 'available' where id = %L$$, test.s50v_id('S50A')));

-- ---------------------------------------------------------------- 7. a car added after signing: a schedule confirmation
insert into test.s50 select 'app2', app.submit_owner_application(jsonb_build_object('source', 'web', 'owner_id', test.s50o(),
  'vehicles', jsonb_build_array(test.s50car(test.s50vin(5), 'S50C', 'regular'))), test.id('s50_web'));
select test.eq('the new car is the next numbered Schedule A entry, by an Additional Vehicle Schedule',
  (select s.vehicle_number || ':' || s.is_additional || ':' || (s.signed_at is null) from vehicle_schedules s where s.vehicle_id = test.s50v_id('S50C') and s.superseded_by is null), '3:true:true');
select test.eq('the owner is asked to confirm the batch', (select payload ->> 'car_list' from app_events where code = 'owner_schedule_ready' and entity_id = test.s50o()), '2021 Toyota Camry (S50C)');
select test.eq('the master stays signed; only the confirmation is missing',
  (select string_agg(x ->> 'code', ',') from jsonb_array_elements(app.owner_sign_missing(test.s50o())) x), 'schedule');
select test.throws('the new car is not delivered before its confirmation', format($$select app.fleet_lease_car_set(test.id('s50_admin'), '{"vehicle_id": "%s", "tier": "regular"}')$$,
  test.s50v_id('S50C')), 'Confirm 2021 Toyota Camry');

-- ---------------------------------------------------------------- 8. the VIN list for a supplier: a tier and a plate per row
insert into vin_decodes (vin, provider, ok, raw, year, make, model) values (test.s50vin(4), 'test', true, '{}', 2020, 'Honda', 'Civic');
select test.eq('the preview reads it (the tier and plate are asked per row)', (select (r ->> 'fleet') || ':' || (r -> 'rows' -> 0 ->> 'ok')
  from (select app.owner_add_vins(test.id('s50_web'), jsonb_build_object('owner_id', test.s50o(), 'preview', true, 'cars', jsonb_build_array(jsonb_build_object('vin', test.s50vin(4))))) r) z), 'true:true');
select test.eq('without a tier the row is not added', (select r -> 'rows' -> 0 ->> 'why'
  from (select app.owner_add_vins(test.id('s50_web'), jsonb_build_object('owner_id', test.s50o(), 'cars', jsonb_build_array(jsonb_build_object('vin', test.s50vin(4), 'plate', 'S50D')))) r) z), 'Mark it Regular or Troubled');
select test.lives('with its tier and plate it is added', format($$select app.owner_add_vins(test.id('s50_web'), jsonb_build_object('owner_id', %L, 'cars', jsonb_build_array(jsonb_build_object('vin', test.s50vin(4), 'plate', 's50d', 'lease_tier', 'troubled'))))$$, test.s50o()));
select test.eq('on Schedule A with its tier, plate and forms', (select ob.lease_tier || ':' || v.plate || ':' || (s.id is not null) || ':' || ((select count(*) from government_form_fills g where g.vehicle_id = v.id) > 0)
  from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null where v.vin = test.s50vin(4)), 'troubled:S50D:true:true');

-- ---------------------------------------------------------------- 9. the connector
create function test.s50h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
create temp table s50_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select app.api_key_create(test.id('s50_admin'), test.id('s50_admin'), 'Laptop', array['admin:read', 'admin:write'], test.s50h('cc_live_s50_full'), 'cc_live_s50_');
insert into test.s50 select 'oa', app.api_call(test.s50h('cc_live_s50_full'), 'owner_agreements', jsonb_build_object('owner_id', test.s50o()), 'test');
select test.eq('owner_agreements: the status, the cars and the links', (select (r #>> '{result,owners,0,master,status}') || ':' || jsonb_array_length(r #> '{result,owners,0,cars}')
  || ':' || (r #>> '{result,owners,0,sign_url}' like '%/owner/sign') from (select test.s50v('oa') r) z), 'signed:4:true');
update owner_agreement_sends set sent_at = sent_at - interval '1 hour' where owner_id = test.s50o();
insert into test.s50 select 'pv', app.api_call(test.s50h('cc_live_s50_full'), 'send_owner_agreement_reminder', jsonb_build_object('owner_id', test.s50o()), 'test');
select test.eq('send_owner_agreement_reminder previews first and sends nothing', (test.s50v('pv') #>> '{result,preview}') || ':' || test.s50events('owner_sign_reminder', test.s50o()), 'true:1');
insert into test.s50 select 'cf', app.api_call(test.s50h('cc_live_s50_full'), 'send_owner_agreement_reminder', jsonb_build_object('owner_id', test.s50o(), 'confirm', true,
  'preview_id', test.s50v('pv') #>> '{result,preview_id}'), 'test');
select test.eq('then sends on confirm', (test.s50v('cf') #>> '{result,sent}') || ':' || test.s50events('owner_sign_reminder', test.s50o()), 'true:2');
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from s50_ps s where s.id = p.id;

-- ---------------------------------------------------------------- 10. privileges
select test.eq('the new internals are not callable by signed-in users', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('owner_master_ensure', 'owner_sign_missing', 'owner_sign_gate', 'owner_sign_status', 'owner_sign_reminder', 'fleet_schedule_cars', 'sign_first_release')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
