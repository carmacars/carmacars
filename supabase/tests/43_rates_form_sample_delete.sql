-- 43: the owner's reports of October 19, 2026 (migration 0064). A. The rates and the kilometre terms in one step: the
-- defaults (Program settings and Fee defaults by class), the check by field, the examples priced with
-- public.calc_rental_charge(), a first rate card in one pass (before 0064 it was refused for kilometres, and the
-- kilometres form for rates of zero), Add a car with rates for the three supply types, Fleet, bulk changes keep the
-- kilometres, the suggestion from similar cars. B. Deleting a car whose bookings are only requests that never confirmed
-- or took money (one car, and Delete all sample cars), the archive, the renters kept; requests whose pickup time passed
-- expire with a note and no email unless the setting says so. C. Add a rental for a car whose listing is not finished:
-- the picker's tag, no rates (a price typed with its reason), the fleet policy confirmation by an Admin, clashes.
-- Fixtures start with "rf".
select test.suite('43 rates form, sample delete, rentals before listing');

select test.mk_user('rf_admin', 'admin');
select test.mk_user('rf_fleet', 'va', 'fleet');
select test.mk_user('rf_cs', 'va', 'cs');
select test.mk_owner('rf_olive');
select test.mk_owner('rf_sam');
select test.mk_owner('rf_stan');
select test.mk_renter('rf_rita');
select test.mk_renter('rf_ron');
select test.mk_vehicle('rfcar', 'rf_olive');
delete from rate_cards where vehicle_id = test.id('vehicle:rfcar');
create temp table s43 (k text primary key, v jsonb);
grant all on s43 to public;
create or replace function test.s43(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s43 where k = p_k $$;
create or replace function test.rf(p_name text, p jsonb, p_user text default 'rf_admin', p_call text default 'ops_do') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create or replace function test.err_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then return sqlerrm;
end $$;
create or replace function test.rfchk(p jsonb) returns jsonb language sql as $$ select test.rf('rate_card_check', p, 'rf_admin', 'ops_read') $$;

-- ================================================================ A1. what was broken: two forms, each needing the other
select test.eq('A the default kilometres a day are in Program settings (200), the overage in Fee defaults (35 cents; luxury 75 to 150)',
  (select default_km_allowance_per_day from app.settings())
  || '/' || (app.rate_card_defaults(null, '{"class": "standard"}') ->> 'overage_cents') || '/' || (app.rate_card_defaults(null, '{"class": "standard"}') ->> 'deposit_cents')
  || '/' || (app.rate_card_defaults(null, '{"class": "luxury"}') ->> 'overage_cents') || '/' || (app.rate_card_defaults(null, '{"class": "luxury"}') ->> 'overage_max_cents'),
  '200/35/50000/75/150');
select test.eq('A the km choices offered stay 400, 300, 200 and 150', app.rate_card_defaults(null, '{}') -> 'km_choices', '[400, 300, 200, 150]'::jsonb);
-- the Rates tab's first form (rates only) on a car with no rate card: saved with the defaults (0063: "A first rate card needs the kilometres per day")
insert into s43 select 'first', test.rf('rate_card', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily_rate_cents', 8900, 'weekend_rate_cents', 9900,
  'weekly_rate_cents', 50000, 'monthly_rate_cents', 180000), 'rf_admin', 'admin_do');
select test.eq('A a first rate card from the rates alone: the kilometres and overage are the defaults, marked as such',
  (select format('%s %s %s %s %s', daily_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, km_uses_defaults) from rate_cards where id = (test.s43('first') ->> 'id')::uuid),
  '8900 200 35 100000 t');
-- the kilometres form alone on a car with rates: kept (it was refused for rates of zero when the car had none)
delete from rate_cards where vehicle_id = test.id('vehicle:rfcar');
select test.throws('A the kilometres alone on a car with no rates: refused on the daily rate, by name (never "rates cannot be zero" for kilometres)',
  $$select test.rf('rate_card', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'other', jsonb_build_object('km_allowance_per_day', 300)), 'rf_admin', 'admin_do')$$,
  'Check the rates. Daily rate: Enter the daily rate%');

-- ================================================================ A2. the check, field by field
select test.eq('A check: nothing typed names the daily rate only', test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'))) -> 'errors',
  '{"daily": "Enter the daily rate. It is needed to post the car."}'::jsonb);
select test.eq('A check: a rate of zero, text, kilometres of 0 and an overage outside the class range, each on its field',
  (select string_agg(k || '=' || (c -> 'errors' ->> k), ' | ' order by k) from (select test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 0, 'weekend', 'ninety',
     'km_mode', 'custom', 'km_per_day', 0, 'overage', 500)) c) x, jsonb_object_keys(c -> 'errors') k),
  'daily=The daily rate must be above zero. | km_per_day=Enter the kilometres included a day, from 1 to 5,000. | weekend=Enter an amount in dollars, like 89 or 89.50.');
update vehicles set class = 'luxury' where id = test.id('vehicle:rfcar');
select test.eq('A check: a luxury car''s overage must be within $0.75 to $1.50', test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 20000, 'km_mode', 'custom', 'overage', 50)) -> 'errors' ->> 'overage',
  'For a luxury car the extra kilometre rate is $0.75 to $1.50 a km (Fee defaults).');
select test.eq('A check: a luxury car on the defaults takes the lowest overage of its range', test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 20000)) -> 'values' ->> 'overage', '75');
update vehicles set class = 'premium' where id = test.id('vehicle:rfcar');
insert into s43 select 'chk', test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900));
select test.eq('A check: the daily rate alone is enough; the others follow from it and say so',
  format('%s %s %s %s %s %s', test.s43('chk') ->> 'ok', test.s43('chk') -> 'values' ->> 'weekend', test.s43('chk') -> 'values' ->> 'weekly', test.s43('chk') -> 'values' ->> 'monthly',
         test.s43('chk') -> 'derived', test.s43('chk') ->> 'km_text'),
  'true 8900 53400 195800 ["weekend", "weekly", "monthly"] 200 km included a day, then $0.35 for each extra km.');
select test.ok('A check: a weekly rate above 7 days at the daily rate is a warning, not an error',
  (select (c ->> 'ok')::boolean and c -> 'warnings' ->> 0 like 'The weekly rate is more than 7 days%' from (select test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900, 'weekly', 90000)) c) x));
select test.throws('A check: Fleet and Admins only', $$select test.rf('rate_card_check', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900), 'rf_cs', 'ops_read')$$, 'Rates are set by an Admin or Fleet');

-- ================================================================ A3. the preview is the booking pricing function
insert into s43 select 'pv', test.rfchk(jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900, 'weekend', 9900, 'weekly', 50000, 'monthly', 180000));
create or replace function test.rfex(p_code text) returns jsonb language sql stable as $$ select e from jsonb_array_elements(test.s43('pv') -> 'examples') e where e ->> 'code' = p_code $$;
select test.eq('A preview: Friday to Sunday is 2 days at the weekend rate (a price per day)', test.rfex('friday_sunday') ->> 'text',
  'Friday 10 am to Sunday 10 am: $198 before tax (2 days at the weekend rate), 400 km included.');
select test.eq('A preview: Monday to Thursday is 3 days at the daily rate', test.rfex('monday_thursday') ->> 'cents', '26700');
select test.eq('A preview: Friday to Monday is 2 weekend days and Sunday at the daily rate', test.rfex('friday_monday') ->> 'text',
  'Friday 10 am to Monday 10 am: $287 before tax (2 at the weekend rate, 1 at the daily rate), 600 km included.');
select test.eq('A preview: 7 days is the weekly rate, 30 days the monthly rate', (test.rfex('week') ->> 'cents') || '/' || (test.rfex('month') ->> 'cents'), '50000/180000');
select test.ok('A preview: every example is exactly public.calc_rental_charge() for its days from the next Friday or Monday at 10 am',
  not exists (select 1 from jsonb_array_elements(test.s43('pv') -> 'examples') e,
                lateral public.calc_rental_charge(
                  (date_trunc('week', now() at time zone 'America/Toronto') + interval '4 days 10 hours' + case when e ->> 'code' like 'friday%' then interval '0' else interval '3 days' end
                   + case when (date_trunc('week', now() at time zone 'America/Toronto') + interval '4 days 10 hours') at time zone 'America/Toronto' < now() then interval '7 days' else interval '0' end) at time zone 'America/Toronto',
                  (e ->> 'days')::integer, 8900, 9900, 50000, 180000) c
               where c.rental_charge_cents <> (e ->> 'cents')::bigint));

-- ================================================================ A4. one pass: rates and kilometres saved together
insert into s43 select 'save', test.rf('rate_card_save', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900, 'weekend', 9900, 'weekly', 50000, 'monthly', 180000,
  'km_mode', 'custom', 'km_per_day', 300, 'overage', 45, 'deposit', 100000));
select test.eq('A one pass: the rates and custom kilometres in one card',
  (select format('%s/%s/%s/%s %s km %s c %s %s', daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, km_uses_defaults)
     from rate_cards where vehicle_id = test.id('vehicle:rfcar') and effective_to is null), '8900/9900/50000/180000 300 km 45 c 100000 f');
select test.throws('A one pass: a bad field refuses the whole save, by name', $$select test.rf('rate_card_save', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 8900, 'monthly', 0))$$,
  'Check the rates. Monthly rate: The monthly rate must be above zero%');
select test.eq('A a bulk change applies', app.apply_bulk_rate_change(jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:rfcar'))),
  '{"percent_bps": 1000, "round_to_cents": 100}', test.id('rf_admin'), now() + interval '1 second'), 1);
select test.eq('A a bulk change keeps the car''s own kilometres',
  (select format('%s %s %s', daily_rate_cents, km_allowance_per_day, overage_cents_per_km) from rate_cards where vehicle_id = test.id('vehicle:rfcar') and effective_to is null), '9800 300 45');
select test.eq('A Fleet saves through its door', test.rf('rate_card_save', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 9000, 'km_mode', 'default',
  'effective_from', now() + interval '2 seconds'), 'rf_fleet', 'va_do') -> 'card' ->> 'km_allowance_per_day', '200');
select test.throws('A customer service does not set rates', $$select test.rf('rate_card_save', jsonb_build_object('vehicle', test.id('vehicle:rfcar'), 'daily', 9000), 'rf_cs', 'va_do')$$, 'Rates are set by an Admin or Fleet');
select test.ok('A the Fleet form reads the defaults and the card in force', (select (f ->> 'km_per_day')::integer = 200 and f -> 'current' ->> 'daily_rate_cents' = '8900'
  from (select test.rf('rate_card_form', jsonb_build_object('vehicle', test.id('vehicle:rfcar')), 'rf_fleet', 'va_read') f) x));
select test.eq('A the suggestion: similar cars of the same model (real cars only)', (app.rate_card_defaults(null, jsonb_build_object('class', 'premium', 'make', 'Mercedes-Benz', 'model', 'C 300 rfcar')) -> 'suggestion' ->> 'text'),
  'Similar cars (same model: Mercedes-Benz C 300 Rfcar, 1 on file): daily $89, weekend $99, weekly $500, monthly $1,800.');

-- ================================================================ A5. Add a car with its rates, for the three supply types
insert into s43 select 'partner', app.partner_save(test.id('rf_admin'), '{"business_name": "Rf Rentals Inc", "email": "rf.partner@example.test",
  "contact_name": "Pat Partner", "insurance_company": "Rf Mutual", "insurance_policy": "P-1", "insurance_expiry": "2027-06-30"}');
insert into s43 select 'add_company', app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1RFCXMPANY0000001', 'plate', 'RFC001', 'year', 2024,
  'make', 'Toyota', 'model', 'Corolla', 'class', 'economy', 'rates', jsonb_build_object('daily', 6500, 'weekend', 7500, 'km_mode', 'default')));
insert into s43 select 'add_partner', app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'partner', 'partner_id', test.s43('partner') ->> 'id', 'vin', '1RFPARTNER0000001',
  'plate', 'RFP001', 'year', 2024, 'make', 'Honda', 'model', 'Civic', 'rates', jsonb_build_object('daily', 7000, 'km_mode', 'custom', 'km_per_day', 400, 'overage', 30)));
insert into s43 select 'add_owner', app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'program_owner', 'owner_id', test.id('owner:rf_olive'), 'vin', '1RFXWNERCAR000001',
  'plate', 'RFO001', 'year', 2023, 'make', 'Mazda', 'model', 'CX-5', 'title_status', 'owned_outright', 'management_mode', 'managed', 'rates', jsonb_build_object('daily', 8000, 'deposit', 50000)));
select test.eq('A Add a car: company, partner and program owner cars each get their rate card in the same step',
  (select string_agg(format('%s %s %s/%s %skm %sc', x.k, (test.s43(x.k) ->> 'rates_set'), r.daily_rate_cents, r.weekend_rate_cents, r.km_allowance_per_day, r.overage_cents_per_km), ', ' order by x.k)
     from (values ('add_company'), ('add_owner'), ('add_partner')) x(k) join rate_cards r on r.vehicle_id = (test.s43(x.k) ->> 'vehicle_id')::uuid),
  'add_company true 6500/7500 200km 35c, add_owner true 8000/8000 200km 35c, add_partner true 7000/7000 400km 30c');
select test.throws('A Add a car: a bad rate refuses before anything is added', $$select app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1RFCXMPANY0000002',
  'year', 2024, 'make', 'Toyota', 'model', 'Camry', 'rates', jsonb_build_object('daily', 6500, 'weekend', 0)))$$, 'Check the rates. Weekend rate%');
select test.ok('A Add a car: nothing was added by the refused call', not exists (select 1 from vehicles where vin = '1RFCXMPANY0000002'));
select test.ok('A Add a car: no rates typed is still allowed (set them on the Rates tab)', (app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1RFCXMPANY0000003',
  'year', 2024, 'make', 'Toyota', 'model', 'Camry')) ->> 'rates_set')::boolean = false);
select test.throws('A the publish gate still names missing rates', $$select app.publish_listing((select id from vehicles where vin = '1RFCXMPANY0000003'), test.id('rf_admin'))$$, '%no rates are set%');
select test.ok('A after the one-pass save the publish gate is past the rates (it names what is still missing)',
  (select x not like '%no rates%' from (select test.err_of($$select app.publish_listing((test.s43('add_company') ->> 'vehicle_id')::uuid, test.id('rf_admin'))$$) x) y));

-- ================================================================ B1. delete: requests that never confirmed or took money do not block
select test.mk_vehicle('rfsample', 'rf_sam');
select test.mk_vehicle('rfsample2', 'rf_sam');
select test.mk_booking('RF-10001', 'rfsample', 'rf_rita', '2031-03-02 10:00', '2031-03-04 10:00', 'declined', 0);
select test.mk_booking('RF-10002', 'rfsample', 'rf_ron', '2031-03-12 10:00', '2031-03-14 10:00', 'requested', 0);
select test.mk_booking('RF-10003', 'rfsample', 'rf_rita', '2031-03-20 10:00', '2031-03-22 10:00', 'expired', 0);
select test.mk_booking('RF-20001', 'rfsample2', 'rf_rita', '2031-04-02 10:00', '2031-04-04 10:00', 'expired', 0);
select test.mk_booking('RF-20002', 'rfsample2', 'rf_ron', '2026-09-02 10:00', '2026-09-04 10:00', 'closed');
-- the bookings are from before the cars were marked samples (0065: no booking is created on a sample car)
update vehicles set is_sample = true where id in (test.id('vehicle:rfsample'), test.id('vehicle:rfsample2'));
insert into booking_events (booking_id, kind, from_status, to_status, note, actor_type) values (test.id('booking:RF-10002'), 'requested', null, 'requested', 'test request', 'renter');
select test.eq('B nothing blocks a car whose bookings are only requests, declined and expired with no money', to_jsonb(app.vehicle_delete_blockers(test.id('vehicle:rfsample'))), '[]'::jsonb);
select test.eq('B the confirmation lists exactly the requests that go',
  (select string_agg(x ->> 'booking_number' || ' ' || (x ->> 'status'), ', ') from jsonb_array_elements(app.vehicle_delete_removes(test.id('vehicle:rfsample'))) x),
  'RF-10001 declined, RF-10002 requested, RF-10003 expired');
select test.eq('B a completed booking still blocks, named by number, and its expired request does not',
  to_jsonb(app.vehicle_delete_blockers(test.id('vehicle:rfsample2'))) ->> 0, '1 confirmed or paid booking (RF-20002)');
select test.eq('B the preview through the door', (test.rf('vehicle_delete_preview', jsonb_build_object('vehicle_id', test.id('vehicle:rfsample')), 'rf_admin', 'ops_read') -> 'removes' -> 1 ->> 'text') like 'RF-10002, requested, %', true);
select test.throws('B the preview is for an Admin', $$select test.rf('vehicle_delete_preview', jsonb_build_object('vehicle_id', test.id('vehicle:rfsample')), 'rf_cs', 'ops_read')$$, '%dmin%');
-- a request with a payment is not a throwaway
select test.mk_booking('RF-30001', 'rfcar', 'rf_rita', '2031-05-02 10:00', '2031-05-04 10:00', 'requested');
select test.eq('B a request that took money blocks a delete', app.booking_never_confirmed(test.id('booking:RF-30001')), false);
select test.eq('B the sample cars list shows what goes with each', (select jsonb_array_length(c -> 'removes') from jsonb_array_elements(test.rf('sample_cars', '{}', 'rf_admin', 'ops_read')) c
  where c ->> 'id' = test.id('vehicle:rfsample')::text), 3);
insert into s43 select 'bulk', app.vehicles_delete_samples(test.id('rf_admin'), '{"confirm": "DELETE SAMPLE CARS"}');
select test.ok('B Delete all sample cars: the car with only requests goes, the one with a completed booking stays, with why',
  not exists (select 1 from vehicles where id = test.id('vehicle:rfsample')) and exists (select 1 from vehicles where id = test.id('vehicle:rfsample2'))
  and (select k ->> 'why' from jsonb_array_elements(test.s43('bulk') -> 'kept') k where k ->> 'vehicle_id' = test.id('vehicle:rfsample2')::text) like '1 confirmed or paid booking (RF-20002)%');
select test.eq('B the requests are archived with their history; the renters stay',
  (select string_agg(booking_number || ':' || status || ':' || jsonb_array_length(events), ', ' order by booking_number) from deleted_booking_requests where vehicle_id = test.id('vehicle:rfsample'))
  || ' ' || (select count(*) from renters where id in (test.id('renter:rf_rita'), test.id('renter:rf_ron'))) || ' ' || jsonb_array_length(test.s43('bulk') -> 'requests_removed'),
  'RF-10001:declined:0, RF-10002:requested:1, RF-10003:expired:0 2 3');
select test.ok('B the bookings are gone and the history tables only grow again',
  not exists (select 1 from bookings where booking_number in ('RF-10001', 'RF-10002', 'RF-10003'))
  and (select bool_and(t.tgenabled = 'O') from pg_trigger t where t.tgname in ('booking_events_append_only', 'messages_append_only')));
insert into booking_events (booking_id, kind, from_status, to_status, note, actor_type) values (test.id('booking:RF-30001'), 'requested', null, 'requested', 'test request', 'renter');
select test.throws('B booking history stays append-only after a delete', $$delete from booking_events where booking_id = test.id('booking:RF-30001')$$, '%append-only%');

-- ================================================================ B2. requests whose pickup time passed expire
select test.mk_vehicle('rfstale', 'rf_stan');
select test.mk_booking('RF-40001', 'rfstale', 'rf_rita', '2026-10-01 10:00', '2026-10-03 10:00', 'requested', 0, p_booked => '2026-09-20 10:00');
select test.mk_booking('RF-40002', 'rfstale', 'rf_ron', '2031-06-01 10:00', '2031-06-03 10:00', 'requested', 0);
select test.eq('B the offers job also expires requests whose pickup time passed', app.job_offers_expire(now()), 'succeeded');
select test.eq('B the stale request expired, the future one did not', (select string_agg(booking_number || ' ' || status, ', ' order by booking_number) from bookings where booking_number like 'RF-4000%'),
  'RF-40001 expired, RF-40002 requested');
select test.ok('B with a note for staff in the booking history, and no email to the renter',
  (select note like 'The pickup time (2026-10-01 10:00, Toronto) passed before an offer was sent%The renter was not emailed.' from booking_events where booking_id = test.id('booking:RF-40001') and kind = 'request_expired')
  and not exists (select 1 from app_events where entity_id = test.id('booking:RF-40001') and code like 'renter_%'));
select test.eq('B the job records what it did', (select (summary ->> 'requests_expired') from job_runs where job_name = 'offers-expire' order by started_at desc limit 1), '1');
update program_settings set stale_request_email_renter = true;
select test.mk_booking('RF-40003', 'rfstale', 'rf_ron', '2026-10-05 10:00', '2026-10-06 10:00', 'requested', 0, p_booked => '2026-09-20 10:00');
select app.expire_stale_requests(now());
select test.ok('B with the setting on, the renter gets the request declined email', exists (select 1 from app_events where entity_id = test.id('booking:RF-40003') and code = 'renter_request_declined'));
update program_settings set stale_request_email_renter = false;

-- ================================================================ C. Add a rental before the listing is finished
-- (0079: every new car gets its draft listing at once, with the decoded details and its copy queued)
insert into s43 select 'unl', app.vehicle_add(test.id('rf_admin'), jsonb_build_object('supply_type', 'program_owner', 'owner_id', test.id('owner:rf_olive'), 'vin', '1RFUNLXSTED000001',
  'plate', 'RFU001', 'year', 2024, 'make', 'Kia', 'model', 'Sportage', 'class', 'suv', 'title_status', 'owned_outright', 'management_mode', 'managed', 'onboarding_method', 'transfer'));
create or replace function test.unl() returns uuid language sql stable as $$ select (test.s43('unl') ->> 'vehicle_id')::uuid $$;
create or replace function test.rfr(p jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', test.unl(), 'pickup_at', date_trunc('hour', now()) + interval '3 days', 'return_at', date_trunc('hour', now()) + interval '5 days',
    'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:rf_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'e_transfer', 'reference', 'RF-ET-1'), 'sales_choice', 'for_carmacars') || p $$;
select test.eq('C a new owner''s car: onboarding, a draft listing, no rates, not on the fleet policy',
  (select format('%s %s %s %s', v.status, coalesce(l.status, 'none'), exists (select 1 from rate_cards r where r.vehicle_id = v.id), v.on_fleet_policy) from vehicles v left join vehicle_listings l on l.vehicle_id = v.id where v.id = test.unl()),
  'onboarding draft f f');
select test.eq('C the Add a rental picker lists it, tagged',
  (select format('%s %s %s %s', c ->> 'bookable', c ->> 'listing_finished', c ->> 'has_rates', c ->> 'needs_policy_confirm') from jsonb_array_elements(test.rf('manual_rental_vehicles', '{}', 'rf_admin', 'ops_read')) c where c ->> 'id' = test.unl()::text),
  'true false false true');
select test.ok('C an assistant sees it too', exists (select 1 from jsonb_array_elements(test.rf('manual_rental_vehicles', '{}', 'rf_cs', 'ops_read')) c where c ->> 'id' = test.unl()::text));
insert into s43 select 'q', test.rf('manual_rental_quote', test.rfr(), 'rf_admin', 'ops_read');
select test.ok('C the quote says: no rates yet, listing not finished, Available before the handover, the fleet policy',
  test.s43('q') ->> 'has_rates' = 'false' and test.s43('q') ->> 'rate_sheet_cents' is null and test.s43('q') ->> 'needs_policy_confirm' = 'true'
  and (test.s43('q') -> 'notes')::text like '%no rates yet%Listing not finished%Before the handover the car must be Available (it is onboarding now)%not on the fleet insurance policy yet%');
select test.ok('C the quote''s stand-in rates are rolled back', not exists (select 1 from rate_cards where vehicle_id = test.unl()));
select test.eq('C the quote prices the rental at the price typed', ((test.rf('manual_rental_quote', test.rfr('{"rental_charge_cents": 30000}'), 'rf_admin', 'ops_read') -> 'quote' ->> 'rental_charge_cents')::bigint), 30000::bigint);
select test.throws('C an owner''s car needs its Revenue Share first', $$select test.rf('manual_rental_create', test.rfr('{"rental_charge_cents": 30000, "price_reason": "New car", "fleet_policy_confirmed": true}'))$$,
  'This owner''s car has no Revenue Share yet%');
select public.admin_set_vehicle_terms(test.unl(), test.id('rf_admin'), '{}');
select test.eq('C with its terms set the owner''s car may take a rental', app.vehicle_needs_terms(test.unl()), false);
select test.throws('C an assistant cannot add a rental for a car not on the fleet policy', $$select test.rf('manual_rental_create', test.rfr('{"rental_charge_cents": 30000, "price_reason": "New car", "sales_choice": "sourced"}'), 'rf_cs')$$,
  'This car is not on the fleet insurance policy yet: only an Admin%');
select test.throws('C an Admin confirms it is insured', $$select test.rf('manual_rental_create', test.rfr('{"rental_charge_cents": 30000, "price_reason": "New car"}'))$$, '%Tick "I checked that this car is insured for this rental"%');
select test.throws('C no rates: a price typed is needed', $$select test.rf('manual_rental_create', test.rfr('{"fleet_policy_confirmed": true}'))$$, 'This car has no rates yet%');
insert into s43 select 'r1', test.rf('manual_rental_create', test.rfr('{"rental_charge_cents": 30000, "price_reason": "New car, no rate sheet yet", "fleet_policy_confirmed": true}'));
select test.eq('C added and paid another way: confirmed, at the price typed, with the default kilometres and the class deposit',
  (select format('%s %s %s km %s c %s', b.status, b.rental_charge_cents, b.km_allowance_per_day, b.overage_cents_per_km, b.deposit_cents = (app.rate_card_defaults(test.unl()) ->> 'deposit_cents')::bigint) from bookings b where b.id = (test.s43('r1') ->> 'booking_id')::uuid),
  'confirmed 30000 200 km 35 c t');
select test.ok('C the price typed and the insurance confirmation are recorded', exists (select 1 from audit_log a where a.action = 'manual_rental_unlisted_car' and a.entity_id = test.s43('r1') ->> 'booking_id'
  and (a.after ->> 'fleet_policy_confirmed')::boolean) and (select notes like 'Price set by hand: New car%' from bookings where id = (test.s43('r1') ->> 'booking_id')::uuid));
select test.ok('C the car stays off the public site', not exists (select 1 from public_vehicle_listings l where l.vehicle_id = test.unl()));
select test.throws('C the calendar still applies: the same dates are refused', $$select test.rf('manual_rental_create', test.rfr('{"rental_charge_cents": 30000, "price_reason": "x", "fleet_policy_confirmed": true, "renter_id": null, "renter": {"full_name": "Rf Other", "email": "rf.other@example.test", "mobile": "4165550100", "date_of_birth": "1990-01-01"}}'))$$,
  'The car is not free for these dates%');
select test.eq('C handover rules are unchanged: the car is still onboarding until an Admin makes it Available', (select status::text from vehicles where id = test.unl()), 'onboarding');
-- a CarmaCars-owned car with a draft listing and no rates: an assistant adds it with a price typed
insert into s43 select 'r2', test.rf('manual_rental_create', jsonb_build_object('vehicle_id', (select id from vehicles where vin = '1RFCXMPANY0000003'), 'pickup_at', date_trunc('hour', now()) + interval '3 days',
  'return_at', date_trunc('hour', now()) + interval '4 days', 'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:rf_ron'), 'payment', jsonb_build_object('mode', 'link'),
  'rental_charge_cents', 9000, 'price_reason', 'Walk-in, rate sheet not set yet', 'sales_choice', 'sourced'), 'rf_cs');
select test.eq('C an assistant adds a rental for a company car whose listing is not finished, with a payment link', (select status::text from bookings where id = (test.s43('r2') ->> 'booking_id')::uuid) in ('requested', 'offered', 'pending_payment'), true);
