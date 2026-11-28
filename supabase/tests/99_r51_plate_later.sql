-- 99: the plate is asked after the car is registered, not at the owner application (5212, REQ-141). Fixtures start
-- with "pl". Its own owners, cars and booking only; it changes no setting.
select test.suite('99 r51 plate later');
select test.mk_user('plt_admin', 'admin');
select test.mk_user('plt_fleet', 'va', 'fleet');
select test.mk_user('plt_sales', 'va', 'sales');
select test.mk_owner('plt_olive');
select test.mk_owner('plt_omar');
select test.mk_renter('plt_rita');
create function test.pl_do(p_user text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', 'vehicle_plate_set', p) $$;
create function test.pl_open(p_vehicle uuid) returns bigint language sql stable as $$
  select count(*) from tasks where vehicle_id = p_vehicle and task_type = 'plate_needed' and status in ('open', 'in_progress', 'waiting') $$;
create function test.pl_mails(p_vehicle uuid) returns bigint language sql stable as $$
  select count(*) from app_events where code = 'owner_plate_needed' and payload ->> 'vehicle_id' = p_vehicle::text $$;

-- ================================================================ 1. what a missing plate is
select test.eq('empty, blank, X only, zeros and placeholder words are missing',
  (select string_agg(app.plate_missing(x)::text, ',' order by n) from unnest(array[null, '', '  ', 'XXXXXXXX', 'xx-xx', 'TBD', 'n/a', '0000', 'Pending']) with ordinality t(x, n)),
  'true,true,true,true,true,true,true,true,true');
select test.eq('a real plate is not', (select string_agg(app.plate_missing(x)::text, ',' order by n) from unnest(array['ABCD 123', 'X1', 'CXXX123', '1234AB']) with ordinality t(x, n)),
  'false,false,false,false');

-- ================================================================ 2. the application never asks the plate
select test.ok('the fleet supplier route no longer refuses a car without its plate',
  position('Enter each car''s plate' in pg_get_functiondef('app.submit_owner_application_pre3800(jsonb, uuid)'::regprocedure)) = 0);
select test.ok('the VIN list no longer refuses a row without its plate', position('Enter its plate' in pg_get_functiondef('app.owner_add_vins(uuid, jsonb)'::regprocedure)) = 0);
create temp table pl_car as select (app.add_owner_vehicle(test.id('owner:plt_olive'),
  '{"vin": "2PLTE5211RA000141", "title_status": "owned_outright", "year": 2021, "make": "Honda", "model": "Accord", "colour": "Grey", "odometer_km": 41000}'::jsonb, null, null) ->> 'vehicle_id')::uuid id;
select test.ok('an owner applies with no plate', exists (select 1 from vehicles v join pl_car c on c.id = v.id where v.plate is null and v.status = 'onboarding'));

-- ================================================================ 3. the step: the email to the owner and the To do for Fleet
select test.eq('Fleet has the To do "Plate needed"', (select test.pl_open(id) from pl_car), 1::bigint);
select test.ok('in the Fleet queue, titled with the car', exists (select 1 from tasks t join pl_car c on c.id = t.vehicle_id
  where t.task_type = 'plate_needed' and t.queue = 'fleet' and t.title like 'Plate needed: %Honda Accord%'));
select test.eq('the owner is emailed once', (select test.pl_mails(id) from pl_car), 1::bigint);
select test.ok('the email links to the car''s plate step in the portal', exists (select 1 from app_events e join pl_car c on e.payload ->> 'vehicle_id' = c.id::text
  where e.code = 'owner_plate_needed' and e.entity_id = test.id('owner:plt_olive') and e.payload ->> 'plate_url' like '%/owner/vehicles/' || c.id || '#plate'
    and e.payload ->> 'first_name' is not null and e.payload ->> 'vehicle_name' like '%Honda Accord%'));
select test.eq('the email goes by email only (no text template)', (select count(*) from notification_catalogue where code = 'owner_plate_needed' and audience = 'owner'), 1::bigint);
update vehicles set status = 'ready_to_list' where id = (select id from pl_car);
select test.eq('a status change neither repeats the email nor the To do', (select test.pl_open(id) || ':' || test.pl_mails(id) from pl_car), '1:1');

-- ================================================================ 4. a placeholder plate in real data: XXXXXXXX
select test.mk_vehicle('PL1', 'plt_olive');
select test.eq('a car with its plate has no step', test.pl_open(test.id('vehicle:PL1')), 0::bigint);
update vehicles set plate = 'XXXXXXXX' where id = test.id('vehicle:PL1');
select test.eq('XXXXXXXX counts as missing: the To do', test.pl_open(test.id('vehicle:PL1')), 1::bigint);
select test.eq('not published, and says why', app.listing_auto_publish(test.id('vehicle:PL1')) ->> 'reason', 'Plate needed');
select test.throws('a listing cannot go published', $$insert into vehicle_listings (vehicle_id, status) values (test.id('vehicle:PL1'), 'published')$$, 'Plate needed: add the plate%published%');
select test.mk_booking('CC-PL1', 'PL1', 'plt_rita', '2031-03-02 10:00', '2031-03-05 10:00', 'confirmed');
select test.ok('the pickup checklist names the missing plate',
  app.handover_blockers(test.id('plt_admin'), test.id('booking:CC-PL1'), 'pickup') @> '[{"code": "plate"}]');
select test.throws('an override cannot skip it', format($$select app.handover_override(%L, '{"booking": "CC-PL1", "kind": "pickup", "reason": "Renter is waiting"}')$$, test.id('plt_admin')),
  '%cannot be overridden%');
select test.throws('the car is not handed over, and says why', $$update bookings set status = 'on_rent', handed_over_at = now() where id = test.id('booking:CC-PL1')$$, 'Plate needed: add the plate%handed over%');

-- ================================================================ 5. adding the plate clears the step
select test.throws('another owner cannot add it', $$select test.pl_do('plt_omar', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'PLAB123'))$$, 'Only the car''s owner%');
select test.throws('Sales cannot add it', $$select test.pl_do('plt_sales', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'PLAB123'))$$, 'Only the car''s owner%');
select test.throws('a placeholder is refused', $$select test.pl_do('plt_olive', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'xxx xxx'))$$, '%not a placeholder%');
select test.throws('a plate of 9 characters is refused', $$select test.pl_do('plt_olive', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'PLAB12345'))$$, '%2 to 8%');
select test.mk_vehicle('PL2', 'plt_omar');
select test.throws('a plate on another car is refused', format($$select test.pl_do('plt_olive', jsonb_build_object('vehicle_id', %L, 'plate', %L))$$,
  test.id('vehicle:PL1'), (select plate from vehicles where id = test.id('vehicle:PL2'))), 'Plate % is on another car%');
select test.eq('the owner adds it in the portal', test.pl_do('plt_olive', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'plab 123')) ->> 'plate', 'PLAB123');
select test.eq('the To do closed by itself', test.pl_open(test.id('vehicle:PL1')), 0::bigint);
select test.ok('audited', exists (select 1 from audit_log where action = 'vehicle_plate_set' and entity_id = test.id('vehicle:PL1')::text and after ->> 'plate' = 'PLAB123'));
select test.ok('the pickup checklist no longer names it', not (app.handover_blockers(test.id('plt_admin'), test.id('booking:CC-PL1'), 'pickup') @> '[{"code": "plate"}]'));
select test.ok('nothing blocks publishing or the handover for the plate', app.plate_block(test.id('vehicle:PL1'), 'published') is null);
select test.throws('the owner cannot change a real plate', $$select test.pl_do('plt_olive', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'PLAB124'))$$, 'This car has its plate%');
select test.eq('Fleet corrects it on the car page', test.pl_do('plt_fleet', jsonb_build_object('vehicle_id', test.id('vehicle:PL1'), 'plate', 'PLAB124')) ->> 'plate', 'PLAB124');
select test.eq('the applied car: the owner adds it once registered', (select test.pl_do('plt_olive', jsonb_build_object('vehicle_id', id, 'plate', 'PLCD555')) ->> 'plate' from pl_car), 'PLCD555');
select test.eq('and its To do closed by itself', (select test.pl_open(id) from pl_car), 0::bigint);

-- ================================================================ 6. privileges
select test.ok('the plate functions are the server''s only', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('plate_block', 'plate_step_sync', 'vehicle_plate_set') and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))));
