-- 99: the field staff portal (migrations 0930 and 0931, release 35, part X, docs/changes/2026-11-08-r35-field-portal.md): the work
-- list of a day, the add-ons that stop a pickup, the clean check, money spent and a service record with their automations, clock
-- out with work open, onboarding prep, shifts given up, claimed and swapped, the pay details (SIN) and Sales for field staff.
-- Fixtures "r35x"; example.test only.
select test.suite('99 r35x field portal');
grant usage on schema test to service_role;

update program_settings set field_jobs_auto = false, field_jobs_auto_assign = 'none', academy_gate = true, company_latitude = null, company_longitude = null;
select test.mk_user('r35x_admin', 'admin');
select test.mk_user('r35x_fleet', 'va', 'fleet');
select test.mk_user('r35x_fin', 'va', 'finance');
select test.mk_user('r35x_cs', 'va', 'cs');
select test.mk_user('r35x_a', 'field');
select test.mk_user('r35x_b', 'field');
select test.mk_user('r35x_c', 'field');
select test.mk_owner('r35x_o');
select test.mk_vehicle('R35XA', 'r35x_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_vehicle('R35XB', 'r35x_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
update vehicles set fleet_number = 'A0 R35X-' || plate, status = 'available' where id in (test.id('vehicle:R35XA'), test.id('vehicle:R35XB'));
update vehicles set supply_type = 'company', owner_id = null where id = test.id('vehicle:R35XB');
select test.mk_renter('r35x_r');
create function test.r35x_fd(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_do', p_name, p) $$;
create function test.r35x_fr(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_read', p_name, p) $$;
create function test.r35x_op(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_do', p_name, p) $$;
create function test.r35x_or(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_read', p_name, p) $$;
create function test.r35x_photo() returns jsonb language sql as $$ select jsonb_build_object('storage_path', 'field/2026/' || gen_random_uuid() || '.jpg', 'mime_type', 'image/jpeg', 'sha256', repeat('a', 64)) $$;

-- a shift today covering now for a and b, one tomorrow for c
create temp table r35x_t as select greatest(app.local_midnight(app.today()), now() - interval '1 hour') as s;
grant select on r35x_t to public;
select test.r35x_op('r35x_fleet', 'field_slot_publish', jsonb_build_object('starts_at', (select s from r35x_t), 'ends_at', (select s from r35x_t) + interval '15 hours', 'capacity', 3));
select test.r35x_op('r35x_fleet', 'field_slot_publish', jsonb_build_object('starts_at', (select s from r35x_t) + interval '2 days', 'ends_at', (select s from r35x_t) + interval '2 days 8 hours', 'capacity', 1));
select test.r35x_fd('r35x_a', 'shift_take', jsonb_build_object('slot', (select id from field_shift_slots where starts_at = (select s from r35x_t))));
select test.r35x_fd('r35x_b', 'shift_take', jsonb_build_object('slot', (select id from field_shift_slots where starts_at = (select s from r35x_t))));

-- ================================================================ 1. the work list
select test.mk_booking('R35X-1', 'R35XA', 'r35x_r', to_char((now() + interval '20 minutes') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed', 30000);
insert into booking_addons (booking_id, addon_id, quantity, name, fee_type_code, pricing_unit, unit_price_cents, hst_applies, status, added_via, confirmed_at)
select test.id('booking:R35X-1'), a.id, 1, a.name, a.fee_type_code, a.pricing_unit, coalesce(a.price_cents, 0), a.hst_applies, 'confirmed', 'staff', now() from addons a where a.code = 'baby_seat';
create temp table r35x_job as select app.create_field_job('handover', test.id('vehicle:R35XA'), now() + interval '20 minutes', test.id('r35x_fleet'), test.id('booking:R35X-1'), test.id('r35x_a')) as id;
grant select on r35x_job to public;
update vehicles set status = 'out_of_service' where id = test.id('vehicle:R35XB');
create temp table r35x_today as select test.r35x_fr('r35x_a', 'today') as t;
grant select on r35x_today to public;
select test.eq('today: the pickup is one card with its add-on and its clean check', (select (c ->> 'leg') || '/' || (c ->> 'addons_open') || '/' || (c #>> '{clean,moment}') || '/' || (c ->> 'done')
  from r35x_today, jsonb_array_elements(t -> 'cards') c where c ->> 'key' = 'job:' || (select id from r35x_job)), 'pickup/1/before_pickup/false');
select test.eq('today: the add-on by name', (select c -> 'addons' -> 0 ->> 'name' from r35x_today, jsonb_array_elements(t -> 'cards') c where c ->> 'type' = 'job'), (select name from addons where code = 'baby_seat'));
select test.eq('today: the car out of service is a service card', (select count(*) from r35x_today, jsonb_array_elements(t -> 'cards') c where c ->> 'type' = 'service' and c #>> '{vehicle,id}' = test.id('vehicle:R35XB')::text), 1::bigint);
select test.eq('today: the car with no clean check in 7 days and no job today is a cleaning card; the car of the job is not',
  (select string_agg(c #>> '{vehicle,id}', ',') from r35x_today, jsonb_array_elements(t -> 'cards') c where c ->> 'type' = 'clean' and c #>> '{vehicle,id}' in (test.id('vehicle:R35XA')::text, test.id('vehicle:R35XB')::text)),
  null::text);
select test.eq('today: the jobs come first, then the other cards', (select c ->> 'type' from r35x_today, jsonb_array_elements(t -> 'cards') with ordinality x(c, o) order by o limit 1), 'job');
select test.eq('today: one must-do, none done', (select (t -> 'counts' ->> 'must') || '/' || (t -> 'counts' ->> 'done') from r35x_today), '1/0');
select test.eq('today: on shift', (select (t ->> 'on_shift')::boolean from r35x_today), true);
select test.throws('today: customer service has no field list', $$select test.r35x_fr('r35x_cs', 'today')$$);
-- the second car becomes available and has not been cleaned: a cleaning card for the people on shift
update vehicles set status = 'available' where id = test.id('vehicle:R35XB');
select test.eq('today: the clean car-less card appears once the car is back', (select count(*) from jsonb_array_elements(test.r35x_fr('r35x_b', 'today') -> 'cards') c
  where c ->> 'type' = 'clean' and c #>> '{vehicle,id}' = test.id('vehicle:R35XB')::text), 1::bigint);

-- ================================================================ 2. the add-ons stop the pickup
select test.eq('blockers: the add-on not ticked is listed for the override', (select count(*) from jsonb_array_elements(app.handover_blockers(test.id('r35x_admin'), test.id('booking:R35X-1'), 'pickup', '{}')) x
  where x ->> 'code' = 'addons'), 1::bigint);
select test.eq('blockers: in plain words', app.override_label('addons'), 'The add-ons are not ticked as in the car');
select test.throws('handover: refused until each add-on is ticked', format($$select test.r35x_fd('r35x_a', 'complete_handover', jsonb_build_object('job', %L, 'report', '{}'::jsonb))$$, (select id from r35x_job)), 'Tick each add-on');
select test.throws('add-on: someone without the booking cannot tick it', format($$select test.r35x_fd('r35x_b', 'addon_tick', jsonb_build_object('id', %L))$$, (select id from booking_addons where booking_id = test.id('booking:R35X-1'))), 'not on your list');
select test.eq('add-on: ticked by the person with the job', (test.r35x_fd('r35x_a', 'addon_tick', jsonb_build_object('id', (select id from booking_addons where booking_id = test.id('booking:R35X-1')))) ->> 'open')::int, 0);
select test.eq('blockers: none for the add-ons once ticked', (select count(*) from jsonb_array_elements(app.handover_blockers(test.id('r35x_admin'), test.id('booking:R35X-1'), 'pickup', '{}')) x where x ->> 'code' = 'addons'), 0::bigint);
create function test.r35x_err(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
select test.eq('handover: past the add-ons now (another check may still stop it, never the add-ons)',
  test.r35x_err(format($q$select test.r35x_fd('r35x_a', 'complete_handover', jsonb_build_object('job', %L, 'report', '{}'::jsonb))$q$, (select id from r35x_job))) like '%Tick each add-on%', false);

-- ================================================================ 3. the clean check
select test.throws('clean check: a photo is required', format($$select test.r35x_fd('r35x_a', 'clean_check', jsonb_build_object('job', %L))$$, (select id from r35x_job)), 'photo');
select test.throws('clean check: not clean needs a note', format($$select test.r35x_fd('r35x_a', 'clean_check', jsonb_build_object('job', %L, 'clean', false, 'photo', test.r35x_photo()))$$, (select id from r35x_job)), 'not clean');
select test.eq('clean check: saved before the pickup', test.r35x_fd('r35x_a', 'clean_check', jsonb_build_object('job', (select id from r35x_job), 'photo', test.r35x_photo())) ->> 'moment', 'before_pickup');
select test.eq('clean check: the card shows it done', (select (c #>> '{clean,done}') from jsonb_array_elements(test.r35x_fr('r35x_a', 'today') -> 'cards') c where c ->> 'type' = 'job'), 'true');
select test.throws('clean check: an upload that is not ours is refused', $$select test.r35x_fd('r35x_b', 'clean_check', jsonb_build_object('vehicle', test.id('vehicle:R35XB'), 'photo', jsonb_build_object('storage_path', 'elsewhere/x.jpg')))$$, 'not one of ours');
select test.eq('clean check: a routine clean of a car on the list, by a person on shift', test.r35x_fd('r35x_b', 'clean_check', jsonb_build_object('vehicle', test.id('vehicle:R35XB'), 'photo', test.r35x_photo())) ->> 'moment', 'routine');
select test.eq('clean check: the cleaned car leaves the cleaning cards', (select count(*) from jsonb_array_elements(test.r35x_fr('r35x_b', 'today') -> 'cards') c
  where c ->> 'type' = 'clean' and c #>> '{vehicle,id}' = test.id('vehicle:R35XB')::text), 0::bigint);
select test.throws('clean check: a person with no shift today and no job on the car is refused', $$select test.r35x_fd('r35x_c', 'clean_check', jsonb_build_object('vehicle', test.id('vehicle:R35XB'), 'photo', test.r35x_photo()))$$, 'not on your list');

-- ================================================================ 4. money spent
select test.throws('spend: the amount is required', $$select test.r35x_fd('r35x_a', 'spend_add', jsonb_build_object('kind', 'gas', 'description', 'Gas'))$$, 'amount');
create temp table r35x_sp as select (test.r35x_fd('r35x_a', 'spend_add', jsonb_build_object('kind', 'gas', 'description', 'Gas before the pickup', 'amount_cents', 4500, 'hst_cents', 585,
  'vehicle', test.id('vehicle:R35XA'), 'booking', test.id('booking:R35X-1'))) ->> 'id')::uuid as id;
grant select on r35x_sp to public;
select test.eq('spend: waits for Finance', (select status from field_spends where id = (select id from r35x_sp)), 'submitted');
select test.eq('spend: Finance has a To do', (select queue from tasks where dedupe_key = 'field_spend_review:' || (select id from r35x_sp) and status = 'open'), 'finance');
select test.eq('spend: the person has a To do for the missing receipt', (select assigned_to from tasks where dedupe_key = 'field_receipt_missing:' || (select id from r35x_sp) and status = 'open'), test.id('r35x_a'));
select test.eq('spend: the To do is on their Today', (select count(*) from jsonb_array_elements(test.r35x_fr('r35x_a', 'today') -> 'todo') x where x ->> 'type' = 'field_receipt_missing'), 1::bigint);
select test.ok('spend: the receipt added later', test.r35x_fd('r35x_a', 'spend_receipt', jsonb_build_object('id', (select id from r35x_sp), 'receipt', test.r35x_photo())) is not null);
select test.eq('spend: the receipt To do is done', (select status from tasks where dedupe_key = 'field_receipt_missing:' || (select id from r35x_sp)), 'done');
select test.throws('spend: someone else cannot add a receipt to it', format($$select test.r35x_fd('r35x_b', 'spend_receipt', jsonb_build_object('id', %L, 'receipt', test.r35x_photo()))$$, (select id from r35x_sp)), 'not your spending');

select test.throws('Finance list: Fleet cannot read it', $$select test.r35x_or('r35x_fleet', 'field_spends')$$, 'Finance or an Admin');
select test.eq('Finance list: the spending waits, with its receipt', (select (x ->> 'receipt_path') like 'field/%' from jsonb_array_elements(test.r35x_or('r35x_fin', 'field_spends')) x where x ->> 'id' = (select id::text from r35x_sp)), true);
select test.throws('Finance: refusing needs a reason', format($$select test.r35x_op('r35x_fin', 'field_spend_decide', jsonb_build_object('id', %L, 'approve', false))$$, (select id from r35x_sp)), 'Say why');
create temp table r35x_dec as select test.r35x_op('r35x_fin', 'field_spend_decide', jsonb_build_object('id', (select id from r35x_sp), 'approve', true)) as r;
grant select on r35x_dec to public;
select test.eq('Finance: approved, a company expense under fuel for that car and person', (select ce.category || '/' || (ce.staff_user_id = test.id('r35x_a'))::text || '/' || (ce.amount_cents + ce.hst_cents)::text
  from company_expenses ce where ce.id = (select (r ->> 'company_expense_id')::uuid from r35x_dec)), 'field_fuel/true/5085');
select test.eq('Finance: the review To do is done', (select status from tasks where dedupe_key = 'field_spend_review:' || (select id from r35x_sp)), 'done');
select test.eq('Finance: paid back', test.r35x_op('r35x_fin', 'field_spend_paid_back', jsonb_build_object('id', (select id from r35x_sp))) ->> 'status', 'reimbursed');
select test.eq('the person sees it paid back', (select x ->> 'status' from jsonb_array_elements(test.r35x_fr('r35x_a', 'my_spends')) x where x ->> 'id' = (select id::text from r35x_sp)), 'reimbursed');

-- ================================================================ 5. a service record
create temp table r35x_sv as select test.r35x_fd('r35x_b', 'service_add', jsonb_build_object('vehicle', test.id('vehicle:R35XB'), 'what', 'Oil change and filter', 'items', jsonb_build_array('oil_filter'),
  'shop', 'Example Auto, 1 Test Road', 'odometer_km', 46000, 'cost_cents', 8900, 'hst_cents', 1157, 'paid_with', 'own', 'invoice', test.r35x_photo())) as r;
grant select on r35x_sv to public;
select test.eq('service: recorded on the car with the item reset', (select count(*) from vehicle_service_record_items where record_id = (select (r ->> 'id')::uuid from r35x_sv) and item_code = 'oil_filter'), 1::bigint);
select test.eq('service: the car expense line was made at once (a company car)', (select billing_status || '/' || (company_expense_id is not null)::text from vehicle_service_records where id = (select (r ->> 'id')::uuid from r35x_sv)), 'billed/true');
select test.eq('service: the expense amount', (select amount_cents + hst_cents from company_expenses where id = (select (r ->> 'company_expense_id')::uuid from r35x_sv)), 10057::bigint);
select test.eq('service: on Finance''s spending list, linked to the expense, paid with their own money', (select paid_with || '/' || (company_expense_id = (select (r ->> 'company_expense_id')::uuid from r35x_sv))::text
  from field_spends where id = (select (r ->> 'spend_id')::uuid from r35x_sv)), 'own/true');
select test.eq('service: Fleet has a To do', (select count(*) from tasks where task_type = 'field_service_fleet' and related_id = (select (r ->> 'id')::uuid from r35x_sv)), 1::bigint);
select test.eq('service: Finance has a To do', (select count(*) from tasks where dedupe_key = 'field_spend_review:' || (select r ->> 'spend_id' from r35x_sv)), 1::bigint);
select test.ok('service: Fleet and Finance alerted', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' in ('field_service', 'field_spend') and entity_id in ((select (r ->> 'id')::uuid from r35x_sv), (select (r ->> 'spend_id')::uuid from r35x_sv))) = 2);
select test.throws('service: what, where and the odometer are required', $$select test.r35x_fd('r35x_b', 'service_add', jsonb_build_object('vehicle', test.id('vehicle:R35XB'), 'what', 'Brakes'))$$, 'where');

-- ================================================================ 6. clock out with work open
select test.r35x_op('r35x_a', 'field_clock_in', jsonb_build_object('location_reason', 'Test phone'));
select test.throws('clock out: the open pickup needs a reason', $$select test.r35x_op('r35x_a', 'field_clock_out', jsonb_build_object('location_reason', 'Test phone'))$$, 'Still open');
select test.ok('clock out: with a reason for each open must-do', test.r35x_op('r35x_a', 'field_clock_out', jsonb_build_object('location_reason', 'Test phone',
  'open_reasons', (select jsonb_object_agg(o ->> 'key', 'Renter is late, Fleet knows') from jsonb_array_elements(app.fx_open_musts(test.id('r35x_a'), app.today())) o))) is not null);
select test.eq('clock out: the reasons are kept', (select count(*) from field_clock_open_items where staff_id = test.id('r35x_a') and reason = 'Renter is late, Fleet knows'), 1::bigint);
select test.eq('clock out: Fleet has a To do', (select count(*) from tasks where task_type = 'field_clock_open' and status = 'open' and created_by = test.id('r35x_a')), 1::bigint);
select test.eq('Fleet: each person''s list with its completion', (select (p ->> 'must') || '/' || (p ->> 'done') || '/' || jsonb_array_length(p -> 'left_open')
  from jsonb_array_elements(test.r35x_or('r35x_fleet', 'field_work_lists') -> 'people') p where p ->> 'id' = test.id('r35x_a')::text), '1/0/1');
select test.throws('Fleet lists: customer service cannot read them', $$select test.r35x_or('r35x_cs', 'field_work_lists')$$);

-- ================================================================ 7. onboarding prep
insert into vehicle_onboardings (vehicle_id, status) select test.id('vehicle:R35XA'), 'intake' where not exists (select 1 from vehicle_onboardings where vehicle_id = test.id('vehicle:R35XA'));
select test.throws('prep: a day without a shift for the person is refused', format($$select test.r35x_op('r35x_fleet', 'field_prep_assign', jsonb_build_object('vehicle', %L, 'staff', %L, 'day', %L, 'items', '["plates_permit"]'::jsonb))$$,
  test.id('vehicle:R35XA'), test.id('r35x_c'), app.today()), 'has no shift');
select test.throws('prep: customer service cannot give prep', format($$select test.r35x_op('r35x_cs', 'field_prep_assign', jsonb_build_object('vehicle', %L, 'staff', %L, 'day', %L, 'items', '["plates_permit"]'::jsonb))$$,
  test.id('vehicle:R35XA'), test.id('r35x_b'), app.today()), 'Fleet or an Admin');
create temp table r35x_prep as select (test.r35x_op('r35x_fleet', 'field_prep_assign', jsonb_build_object('vehicle', test.id('vehicle:R35XA'), 'staff', test.id('r35x_b'), 'day', app.today(),
  'items', '["plates_permit", "safety_certificate", "cleaning"]'::jsonb, 'note', 'Plates at the registry on Example Street')) ->> 'id')::uuid as id;
grant select on r35x_prep to public;
select test.eq('prep: on the person''s Today as one card with its items', (select jsonb_array_length(c -> 'items') from jsonb_array_elements(test.r35x_fr('r35x_b', 'today') -> 'cards') c where c ->> 'type' = 'prep'), 3);
select test.eq('prep: the person was alerted', (select count(*) from app_events where payload ->> 'rule' = 'field_prep' and payload ->> 'assigned_to' = test.id('r35x_b')::text), 1::bigint);
select test.ok('prep: plates and permit done', test.r35x_fd('r35x_b', 'prep_item', jsonb_build_object('id', (select id from r35x_prep), 'code', 'plates_permit', 'document', test.r35x_photo())) is not null);
select test.eq('prep: the onboarding checklist''s registry visit is marked done', (select checklist_marks -> 'registry_visit' ->> 'status' from vehicle_onboardings where vehicle_id = test.id('vehicle:R35XA')), 'done');
select test.eq('prep: the checklist reads it', (select c.status from app.onboarding_checklist(test.id('vehicle:R35XA')) c where c.code = 'registry_visit'), 'done');
select test.throws('prep: the safety certificate needs its upload', format($$select test.r35x_fd('r35x_b', 'prep_item', jsonb_build_object('id', %L, 'code', 'safety_certificate'))$$, (select id from r35x_prep)), 'safety certificate');
select test.ok('prep: the safety certificate with its expiry', test.r35x_fd('r35x_b', 'prep_item', jsonb_build_object('id', (select id from r35x_prep), 'code', 'safety_certificate', 'document', test.r35x_photo(),
  'expires_on', (app.today() + 365)::text)) is not null);
select test.eq('prep: the certificate is on the car''s maintenance', (select expires_on from vehicle_service_items where vehicle_id = test.id('vehicle:R35XA') and item_code = 'safety_certificate'), app.today() + 365);
select test.ok('prep: money spent on the prep is linked to it', test.r35x_fd('r35x_b', 'spend_add', jsonb_build_object('kind', 'parts', 'description', 'Wiper fluid', 'amount_cents', 1200,
  'vehicle', test.id('vehicle:R35XA'), 'prep', (select id from r35x_prep), 'receipt', test.r35x_photo())) is not null);
select test.eq('prep: Fleet sees the progress and the money', (select (t ->> 'done_count') || '/' || (t ->> 'total') || '/' || (t ->> 'spent_cents')
  from jsonb_array_elements(test.r35x_or('r35x_fleet', 'field_prep', jsonb_build_object('vehicle', test.id('vehicle:R35XA'))) -> 'tasks') t), '2/3/1200');
select test.ok('prep: cleaning done', test.r35x_fd('r35x_b', 'prep_item', jsonb_build_object('id', (select id from r35x_prep), 'code', 'cleaning', 'document', test.r35x_photo())) is not null);
select test.eq('prep: all items done finishes it, with a To do for Fleet', (select status || '/' || (select count(*) from tasks where task_type = 'field_prep_done' and related_id = (select id from r35x_prep))::text
  from field_prep_tasks where id = (select id from r35x_prep)), 'done/1');
select test.throws('prep: someone else cannot tick it', format($$select test.r35x_fd('r35x_a', 'prep_item', jsonb_build_object('id', %L, 'code', 'cleaning'))$$, (select id from r35x_prep)), 'not yours');

-- ================================================================ 8. shifts given up, claimed, swapped
create function test.r35x_slot(p_from interval, p_len interval) returns uuid language plpgsql as $$
begin
  perform test.r35x_op('r35x_fleet', 'field_slot_publish', jsonb_build_object('starts_at', date_trunc('minute', now()) + p_from, 'ends_at', date_trunc('minute', now()) + p_from + p_len, 'capacity', 1));
  return (select id from field_shift_slots where starts_at = date_trunc('minute', now()) + p_from order by created_at desc limit 1);
end $$;
create temp table r35x_s (k text, id uuid);
grant select on r35x_s to public;
insert into r35x_s select 'two', id from field_shift_slots where starts_at = (select s from r35x_t) + interval '2 days';
-- c takes the shift in two days, then gives it up a day and a half ahead (not late)
select test.r35x_fd('r35x_c', 'shift_take', jsonb_build_object('slot', (select id from r35x_s where k = 'two')));
create temp table r35x_off as select test.r35x_fd('r35x_c', 'shift_cancel', jsonb_build_object('id', (select id from field_shift_plans where staff_id = test.id('r35x_c') and cancelled_at is null), 'reason', 'Doctor appointment')) as r;
grant select on r35x_off to public;
select test.eq('give up: offered to the people free then (at least the two here), not flagged late', (select ((r ->> 'offered_to')::int >= 2)::text || '/' || (r ->> 'late') from r35x_off), 'true/false');
select test.eq('give up: each was alerted, the giver not', (select count(*) filter (where payload ->> 'assigned_to' in (test.id('r35x_a')::text, test.id('r35x_b')::text)) || '/' || count(*) filter (where payload ->> 'assigned_to' = test.id('r35x_c')::text)
  from app_events where payload ->> 'rule' = 'field_shift_offer' and entity_id = (select (r ->> 'offer')::uuid from r35x_off)), '2/0');
select test.eq('give up: the offer is on the others'' My shifts', (select count(*) from jsonb_array_elements(test.r35x_fr('r35x_a', 'my_shifts') -> 'offers') o where o ->> 'id' = (select r ->> 'offer' from r35x_off)), 1::bigint);
select test.eq('claim: the first to claim takes it', (test.r35x_fd('r35x_a', 'offer_claim', jsonb_build_object('id', (select r ->> 'offer' from r35x_off))) ->> 'offer') is not null, true);
select test.eq('claim: the offer is closed with who took it', (select status || '/' || (claimed_by = test.id('r35x_a'))::text from field_shift_offers where id = (select (r ->> 'offer')::uuid from r35x_off)), 'claimed/true');
select test.throws('claim: the second is told it is gone', format($$select test.r35x_fd('r35x_b', 'offer_claim', jsonb_build_object('id', %L))$$, (select r ->> 'offer' from r35x_off)), 'already claimed');
-- a shift starting in 17 hours, given up late
insert into r35x_s select 'late', test.r35x_slot(interval '17 hours', interval '3 hours');
select test.r35x_fd('r35x_c', 'shift_take', jsonb_build_object('slot', (select id from r35x_s where k = 'late')));
create temp table r35x_late as select id from field_shift_plans where staff_id = test.id('r35x_c') and cancelled_at is null and slot_id = (select id from r35x_s where k = 'late');
grant select on r35x_late to public;
select test.throws('give up: the reason is required', format($$select test.r35x_fd('r35x_c', 'shift_cancel', jsonb_build_object('id', %L))$$, (select id from r35x_late)), 'Say why');
select test.throws('give up: a started shift goes through Fleet', format($$select test.r35x_fd('r35x_a', 'shift_cancel', jsonb_build_object('id', %L, 'reason', 'Sick'))$$,
  (select id from field_shift_plans where staff_id = test.id('r35x_a') and cancelled_at is null and starts_at <= now() limit 1)), 'has started');
select test.eq('give up under 24 hours: flagged late on the record', (test.r35x_fd('r35x_c', 'shift_cancel', jsonb_build_object('id', (select id from r35x_late), 'reason', 'Car broke down')) ->> 'late')::boolean, true);
select test.eq('late: on the board', (select (s ->> 'late_cancels')::int from jsonb_array_elements(app.field_staff_board()) s where s ->> 'id' = test.id('r35x_c')::text), 1);
update program_settings set field_offer_alert_hours = 18;
select test.eq('watch: nothing alerted before the watch runs', (select count(*) from tasks where task_type = 'field_shift_unclaimed' and related_id = (select id from field_shift_offers where plan_id = (select id from r35x_late))), 0::bigint);
select app.job_field_shift_offers();
select test.eq('watch: the unclaimed shift close to its start alerts Fleet and Admin with a To do', (select count(*) from tasks where task_type = 'field_shift_unclaimed' and related_id = (select id from field_shift_offers where plan_id = (select id from r35x_late))), 1::bigint);
select app.job_field_shift_offers();
select test.eq('watch: once only', (select count(*) from tasks where task_type = 'field_shift_unclaimed' and related_id = (select id from field_shift_offers where plan_id = (select id from r35x_late))), 1::bigint);
update program_settings set field_offer_alert_hours = 12;
-- a swap: b takes a shift in three days; a (holding the one in two days) asks b to swap
insert into r35x_s select 'three', test.r35x_slot(interval '3 days', interval '8 hours');
select test.r35x_fd('r35x_b', 'shift_take', jsonb_build_object('slot', (select id from r35x_s where k = 'three')));
create temp table r35x_sw as select (test.r35x_fd('r35x_a', 'swap_ask', jsonb_build_object('mine', (select id from field_shift_plans where staff_id = test.id('r35x_a') and cancelled_at is null and slot_id = (select id from r35x_s where k = 'two')),
  'theirs', (select id from field_shift_plans where staff_id = test.id('r35x_b') and cancelled_at is null and slot_id = (select id from r35x_s where k = 'three')))) ->> 'id')::uuid as id;
grant select on r35x_sw to public;
select test.eq('swap: asked of the other person, on their My shifts', (select (o ->> 'incoming')::boolean from jsonb_array_elements(test.r35x_fr('r35x_b', 'my_shifts') -> 'swaps') o where o ->> 'id' = (select id::text from r35x_sw)), true);
select test.throws('swap: only the person asked accepts', format($$select test.r35x_fd('r35x_c', 'swap_answer', jsonb_build_object('id', %L, 'accept', true))$$, (select id from r35x_sw)), 'not asked of you');
select test.eq('swap: accepted', (test.r35x_fd('r35x_b', 'swap_answer', jsonb_build_object('id', (select id from r35x_sw), 'accept', true)) ->> 'status'), 'swapped');
select test.eq('swap: each holds the other''s shift', (select string_agg(k || '=' || (select split_part(u.full_name, ' ', 2) from users u where u.id = x.staff_id), ',' order by k)
  from field_shift_plans x join r35x_s on r35x_s.id = x.slot_id where x.cancelled_at is null and r35x_s.k in ('two', 'three')), 'three=A,two=B');

-- ================================================================ 9. pay details
select test.eq('pay details: missing at first', (select jsonb_array_length(test.r35x_fr('r35x_a', 'my_pay_identity') -> 'missing')), 3);
select app.fx_pay_details_todo(test.id('r35x_a'));
select test.eq('pay details: a To do for the field person', (select assigned_to from tasks where dedupe_key = 'field_pay_details:' || test.id('r35x_a') and status = 'open'), test.id('r35x_a'));
select test.throws('pay details: a SIN not encrypted by the website is refused', $$select test.r35x_fd('r35x_a', 'my_pay_identity_save', jsonb_build_object('sin_enc', '046454286', 'sin_last3', '286'))$$, 'enter it again');
select test.throws('pay details: a cheque upload outside their folder is refused', $$select test.r35x_fd('r35x_a', 'my_pay_identity_save', jsonb_build_object('cheque', jsonb_build_object('storage_path', 'staff-pay/' || test.id('r35x_b') || '/' || gen_random_uuid() || '.jpg')))$$, 'not yours');
select test.eq('pay details: saved, the SIN shown as its last 3 digits', (test.r35x_fd('r35x_a', 'my_pay_identity_save', jsonb_build_object('legal_name', 'R35x A Example', 'email', 'r35x_a@example.test', 'phone', '416 555 0100',
  'sin_enc', 'v1.aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'sin_last3', '286', 'key_version', 1,
  'cheque', jsonb_build_object('storage_path', 'staff-pay/' || test.id('r35x_a') || '/' || gen_random_uuid() || '.jpg', 'mime_type', 'image/jpeg'))) ->> 'sin'), '***-***-286');
select test.eq('pay details: complete, the To do closed', (select status from tasks where dedupe_key = 'field_pay_details:' || test.id('r35x_a')), 'done');
select test.eq('pay details: the audit log never holds the SIN', (select count(*) from audit_log where entity_table = 'staff_pay_identity' and (coalesce(after::text, '') like '%bbbbbbbb%' or coalesce(before::text, '') like '%bbbbbbbb%')), 0::bigint);
select test.eq('Finance list: who is missing details', (select string_agg(x ->> 'name' || '=' || (x ->> 'complete'), ',' order by x ->> 'name')
  from jsonb_array_elements(test.r35x_or('r35x_fin', 'pay_identity_list')) x where x ->> 'name' ilike 'r35x %'), 'R35x A=true,R35x B=false,R35x C=false');
select test.eq('Finance list: the SIN masked', (select x ->> 'sin' from jsonb_array_elements(test.r35x_or('r35x_fin', 'pay_identity_list')) x where x ->> 'user_id' = test.id('r35x_a')::text), '***-***-286');
select test.throws('reveal: customer service is refused', format($$select test.r35x_op('r35x_cs', 'pay_identity_reveal', jsonb_build_object('user', %L, 'what', 'sin', 'reason', 'payroll'))$$, test.id('r35x_a')), 'Finance or an Admin');
select test.throws('reveal: Fleet is refused', format($$select test.r35x_or('r35x_fleet', 'pay_identity_list')$$), 'Finance or an Admin');
select test.throws('reveal: a reason is required', format($$select test.r35x_op('r35x_fin', 'pay_identity_reveal', jsonb_build_object('user', %L, 'what', 'sin'))$$, test.id('r35x_a')), 'Say why');
select test.eq('reveal: Finance gets the sealed value for the website to open', test.r35x_op('r35x_fin', 'pay_identity_reveal', jsonb_build_object('user', test.id('r35x_a'), 'what', 'sin', 'reason', 'Payroll setup')) ->> 'sin_enc',
  'v1.aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbb');
select test.eq('reveal: the cheque for an Admin', (test.r35x_op('r35x_admin', 'pay_identity_reveal', jsonb_build_object('user', test.id('r35x_a'), 'what', 'cheque', 'reason', 'Payroll setup')) ->> 'path') like 'staff-pay/%', true);
select test.eq('reveal: every view audited', (select count(*) from audit_log where action in ('staff_sin_view', 'staff_cheque_view') and entity_id = test.id('r35x_a')::text), 2::bigint);
select test.eq('reveal: in the data access log too', (select count(*) from data_access_log where query like 'staff pay %' || test.id('r35x_a')), 2::bigint);
select test.eq('pay details: no browser reads the table', has_table_privilege('authenticated', 'staff_pay_identity', 'select'), false);

-- ================================================================ 10. Sales for field staff
select test.eq('sales: not opted in', coalesce((public.door(test.id('r35x_c'), null, 'roles', null, '{}') ->> 'sales_opt_in')::boolean, false), false);
select test.eq('sales: opting in adds the Sales path, not the Sales function yet', (select (x ->> 'opted_in') || '/' || (x ->> 'sales') from (select test.r35x_fd('r35x_c', 'sales_optin', '{"on": true}') x) q), 'true/false');
select test.eq('sales: the path is on their academy', 'sales_in_person' = any (app.academy_paths_of(test.id('r35x_c'))), true);
select test.eq('sales: the Sales path never holds their field work', app.academy_locked(test.id('r35x_c')), false);
select test.eq('sales: no Sales pages yet (no office function)', (public.door(test.id('r35x_c'), null, 'roles', null, '{}') ->> 'va') is null, true);
select test.eq('sales: no Sales permissions yet', app.user_va_has(test.id('r35x_c'), 'sales'), false);
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('r35x_c'), ps.section_id, 5, 5, 10000, true from academy_path_sections ps where ps.path_code = 'sales_in_person';
select test.eq('sales: the path passed adds the Sales function', (select 'sales' = any (functions) from staff_profiles where user_id = test.id('r35x_c')), true);
select test.eq('sales: the portal shows the Sales tab, ready', (public.door(test.id('r35x_c'), null, 'roles', null, '{}') ->> 'sales_ready')::boolean, true);
select test.eq('sales: still field staff', app.is_field_person(test.id('r35x_c')), true);
select test.eq('sales: opting out takes the function away', (test.r35x_fd('r35x_c', 'sales_optin', '{"on": false}') ->> 'sales')::boolean, false);

-- ================================================================ 11. renter help
select test.eq('help: a booking found by number', (select x ->> 'number' from jsonb_array_elements(test.r35x_fr('r35x_b', 'help_find', '{"q": "R35X-1"}')) x), 'R35X-1');
select test.eq('help: each search is logged', (select count(*) from data_access_log where user_id = test.id('r35x_b') and query like 'field help:%'), 1::bigint);
select test.eq('help: the booking facts', (select (x ->> 'signed') is not null and (x ->> 'open_cents') is not null from (select test.r35x_fr('r35x_b', 'help_booking', '{"booking": "R35X-1"}') x) q), true);
select test.eq('help: field staff may collect (the existing rule)', app.card_collect_allowed(test.id('r35x_b')), true);
select test.eq('help: refunds stay Finance and Admin', app.user_runs_finance(test.id('r35x_b')), false);

-- ================================================================ 12. row-level security
set role authenticated;
select set_config('request.jwt.claim.sub', test.id('r35x_b')::text, false);
select test.eq('rls: a field person sees only their own spending', (select count(*) from field_spends where staff_id <> test.id('r35x_b')), 0::bigint);
select test.eq('rls: and none of the clean checks table', (select count(*) from vehicle_clean_checks), 0::bigint);
reset role;
-- the alerts of this suite are sent now, not by a later suite's run
select app.process_events(5000);
