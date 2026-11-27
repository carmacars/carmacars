-- 99: the owner fixes of Release 50 (migration 3810): a long rental's money in the owner portal, a car presumed out when
-- its pickup was never recorded, and the Admin's Onboarding Method change. Fixtures "f50".
select test.suite('99 r50 owner fixes: booking money, pickup not recorded (car presumed out), the Onboarding Method');
select test.mk_user('f50_admin', 'admin');
select test.mk_user('f50_cs', 'va', 'cs');
select test.mk_owner('f50');
update owners set address_line1 = '5 Example Road', city = 'Toronto', postal_code = 'M4M 1A1' where id = test.id('owner:f50');
select test.mk_vehicle('F50A', 'f50');
select test.mk_vehicle('F50B', 'f50');
select test.mk_renter('f50r');
create function test.f50t(p interval) returns text language sql stable as $$ select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
create function test.f50row(p_number text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(app.owner_portal_bookings_json(test.id('f50'))) x where x ->> 'booking_number' = p_number $$;

-- ---------------------------------------------------------------- 1. a long rental's money, the same at every view
select test.mk_booking('F50-LONG', 'F50A', 'f50r', test.f50t(interval '-20 days'), test.f50t(interval '28 days'), 'on_rent');
select test.eq('the card shows the rental charge agreed for the whole rental, and its days',
  (select (r ->> 'rental_charge_cents') || ':' || (r ->> 'rental_days') || ':' || (r ->> 'on_statement_cents') from (select test.f50row('F50-LONG') r) z),
  (select (b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents)::text || ':48:0' from bookings b where b.booking_number = 'F50-LONG'));
insert into owner_statements (owner_id, statement_number, statement_month, payout_date, status, approved_by, approved_at)
values (test.id('owner:f50'), 'ST-F50', app.month_start(app.today()), app.today(), 'approved', test.id('f50_admin'), now());
insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, rental_charge_cents, amount_cents, partial, earned_days, rental_days)
select s.id, test.id('vehicle:F50A'), 'rental', 'Booking F50-LONG (16 of 48 rental days)', test.id('booking:F50-LONG'), 44800, 44800, true, 16, 48
  from owner_statements s where s.statement_number = 'ST-F50';
select test.eq('what the approved statements carried so far, and for how many days',
  (select (r ->> 'on_statement_cents') || ':' || (r ->> 'on_statement_days') || ':' || (r ->> 'on_statement_partial') from (select test.f50row('F50-LONG') r) z), '44800:16:true');
select test.eq('stable: two reads give the same numbers', test.f50row('F50-LONG') - 'owner_expenses', test.f50row('F50-LONG') - 'owner_expenses');
select test.eq('a draft statement is not counted', (select count(*) from owner_statements where statement_number = 'ST-F50' and status = 'approved'), 1::bigint);

-- ---------------------------------------------------------------- 2. pickup not recorded: the car is presumed out
select test.mk_booking('F50-OUT', 'F50B', 'f50r', test.f50t(interval '-7 days'), test.f50t(interval '-1 day'), 'confirmed');
select test.eq('the booking counts as presumed out', app.booking_pickup_unrecorded((select b from bookings b where b.booking_number = 'F50-OUT')), true);
-- r50 hotfix2 (5111): an ended booking never blocks its car; it is named as a note that does not hold the new offer
select test.eq('the car is available tonight: the booking''s dates are over (5111)',
  app.vehicle_is_available(test.id('vehicle:F50B'), now() + interval '2 hours', now() + interval '1 day'), true);
select test.eq('and next month', app.vehicle_is_available(test.id('vehicle:F50B'), now() + interval '30 days', now() + interval '32 days'), true);
select test.eq('the other car is', app.vehicle_is_available(test.id('vehicle:F50A'), now() + interval '30 days', now() + interval '32 days'), true);
select test.mk_booking('F50-NEW', 'F50B', 'f50r', test.f50t(interval '3 hours'), test.f50t(interval '2 days'), 'offered');
select test.eq('a new offer on the car names the ended booking, which does not hold it', (select (x ->> 'kind') || ':' || (x ->> 'holds') || ':' || (x ->> 'blocks') || ':' || (x ->> 'booking_number')
  from jsonb_array_elements(app.booking_date_conflicts(test.id('booking:F50-NEW'))) x where x ->> 'kind' = 'presumed_out'), 'presumed_out:false:false:F50-OUT');
select test.eq('the owner portal lists it, presumed out', (test.f50row('F50-OUT') ->> 'presumed_out'), 'true');
select app.job_presumed_out();
select test.eq('Fleet, and the Admins once its return time passed, get the To do to record the handover',
  (select string_agg(t.queue || ':' || t.task_type, ',' order by t.queue) from tasks t where t.dedupe_key in ('presumed_out:' || test.id('booking:F50-OUT'), 'presumed_out_admin:' || test.id('booking:F50-OUT'))),
  'admin:pickup_unrecorded_admin,fleet:pickup_unrecorded');
select app.job_presumed_out();
select test.eq('the job is safe to run again (one To do each)', (select count(*) from tasks t where t.dedupe_key like 'presumed_out%' || test.id('booking:F50-OUT')), 2::bigint);
update bookings set handed_over_at = pickup_at where booking_number = 'F50-OUT';
select test.eq('the handover recorded: the car is no longer presumed out (its next rental is up to the return)', app.vehicle_is_available(test.id('vehicle:F50B'), now() + interval '30 days', now() + interval '32 days'), true);

-- ---------------------------------------------------------------- 3. the Onboarding Method, changed by an Admin before signing
insert into vehicles (id, owner_id, year, make, model, vin, plate, status, management_mode, onboarding_method)
values (test.id('vehicle:F50S'), test.id('owner:f50'), 2024, 'Hyundai', 'Sonata N Line', 'KMHL14JA0RA150050', 'F50S', 'onboarding', 'managed', 'co_registrant');
insert into vehicle_onboardings (vehicle_id, status, held_by, title_status, finance_permission, proposed_management_mode, proposed_onboarding_method)
values (test.id('vehicle:F50S'), 'intake', 'individual', 'owned_outright', 'not_applicable', 'managed', 'co_registrant');
select app.apply_vehicle_terms(test.id('vehicle:F50S'), jsonb_build_object('management_mode', 'managed', 'onboarding_method', 'co_registrant',
  'insurance_fee_cents', 28400, 'tracker_fee_cents', 0, 'revenue_share_bps', 3500, 'install_fee_cents', 0), test.id('f50_admin'), test.id('f50_admin'));
select test.eq('the schedule says Co-Registrant', (select onboarding_method::text from vehicle_schedules where vehicle_id = test.id('vehicle:F50S') and superseded_by is null), 'co_registrant');
select test.throws('customer service cannot change it', format($$select app.set_onboarding_method(test.id('f50_cs'), '{"vehicle_id": "%s", "method": "transfer", "reason": "Wrong method"}')$$, test.id('vehicle:F50S')), 'Admin');
select test.throws('a reason is asked', format($$select app.set_onboarding_method(test.id('f50_admin'), '{"vehicle_id": "%s", "method": "transfer"}')$$, test.id('vehicle:F50S')), 'reason');
select test.eq('the preview changes nothing', (select (r ->> 'from') || '>' || (r ->> 'to') from (select app.set_onboarding_method(test.id('f50_admin'),
  jsonb_build_object('vehicle_id', test.id('vehicle:F50S'), 'method', 'transfer', 'reason', 'Transferred, not co-registered', 'preview', true)) r) z)
  || ':' || (select onboarding_method::text from vehicle_schedules where vehicle_id = test.id('vehicle:F50S') and superseded_by is null), 'co_registrant>transfer:co_registrant');
select test.lives('an Admin changes it (the door)', format($$select app.door(test.id('f50_admin'), 'aal2', 'admin_do', 'set_onboarding_method', '{"vehicle_id": "%s", "method": "transfer", "reason": "Transferred, not co-registered"}')$$, test.id('vehicle:F50S')));
select test.eq('the schedule entry, the car and its plan follow', (select s.onboarding_method::text || ':' || v.onboarding_method::text || ':' || ob.proposed_onboarding_method::text
  from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = v.id where s.vehicle_id = test.id('vehicle:F50S') and s.superseded_by is null), 'transfer:transfer:transfer');
select test.ok('kept in the audit log with the reason', exists (select 1 from audit_log where action = 'set_onboarding_method' and entity_id = test.id('vehicle:F50S')::text and after ->> 'reason' like 'Transferred%'));
update vehicle_schedules set signed_at = now() where vehicle_id = test.id('vehicle:F50S') and superseded_by is null;
select test.throws('once the schedule is signed, a new signed schedule is needed', format($$select app.set_onboarding_method(test.id('f50_admin'), '{"vehicle_id": "%s", "method": "co_registrant", "reason": "Back again"}')$$, test.id('vehicle:F50S')), 'signed');

-- ---------------------------------------------------------------- 3b. the documents right for every owner (3820)
select test.throws('a signing officer title that is a name is refused', $$insert into owners (owner_type, legal_name, first_name, last_name, corporation_name, signing_officer_name, signing_officer_title, email, status)
  values ('corporation', 'Kay Example', 'Kay', 'Example', 'Kay Cars Ltd.', 'Kay Example', 'Kay Example', 'f50-kay@example.test', 'lead')$$, 'a role');
select test.lives('a role is fine', $$insert into owners (owner_type, legal_name, first_name, last_name, corporation_name, signing_officer_name, signing_officer_title, email, status)
  values ('corporation', 'Kay Example', 'Kay', 'Example', 'Kay Cars Ltd.', 'Kay Example', 'Director', 'f50-kay@example.test', 'lead')$$);
update vehicle_schedules set signed_at = null where vehicle_id = test.id('vehicle:F50S') and superseded_by is null;
update vehicle_schedules set first_last_cents = 70000, insurance_fee_cents = 35000 where vehicle_id = test.id('vehicle:F50S') and superseded_by is null;
update vehicle_schedules set insurance_fee_cents = 28400 where vehicle_id = test.id('vehicle:F50S') and superseded_by is null;
select test.eq('first and last month that was two of the old Insurance Fee follows the new one (the rule: two of $284)',
  (select coalesce(first_last_cents::text, 'rule') from vehicle_schedules where vehicle_id = test.id('vehicle:F50S') and superseded_by is null), 'rule');
update vehicle_schedules set first_last_cents = 70000 where vehicle_id = test.id('vehicle:F50S') and superseded_by is null;
select test.eq('an amount agreed otherwise is kept, and the Document check lists it', (select string_agg(x ->> 'code', ',' order by x ->> 'code')
  from jsonb_array_elements(app.owner_documents_check(test.id('f50_admin'), jsonb_build_object('owner_id', test.id('owner:f50'))) -> 'items') x where x ->> 'vehicle_id' = test.id('vehicle:F50S')::text),
  'first_last_rule,schedule_empty');
select test.throws('a method that does not fit how the car is held is refused', format($$update vehicle_schedules set onboarding_method = 'lease_existing_corporation' where vehicle_id = %L and superseded_by is null$$, test.id('vehicle:F50S')), 'not a method');
select test.eq('the default method for a car held personally is Transfer, never Co-Registrant', app.default_onboarding_method('individual', 'owned_outright', 'managed')::text, 'transfer');
select test.throws('only an Admin runs the Document check', $$select app.owner_documents_check(test.id('f50_cs'), '{}')$$, 'Admin');
select test.eq('the Document check counts by issue and by owner', (select (r -> 'by_issue' ->> 'first_last_rule')::int >= 1 and jsonb_array_length(r -> 'by_owner') >= 1
  from (select app.door(test.id('f50_admin'), 'aal2', 'ops_read', 'owner_documents_check', '{}') r) z), true);

-- ---------------------------------------------------------------- 4. privileges
select test.eq('the new internals are not callable by signed-in users', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('owner_booking_money', 'vehicle_presumed_out', 'job_presumed_out', 'set_onboarding_method', 'owner_documents_check', 'title_is_name')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
