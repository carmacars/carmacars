-- 85: the partner CRM link (migration 0136). THE RULE first: only CarmaCars' own cars and program owners' cars go to a
-- partner, never a partner car (01 Motors' own or another partner's), whatever the link's settings; enforced in the
-- function, again when a run's records come back. Then the partner price, the availability, the token in the vault (never
-- returned, never through the door), the door's reads and saves (Admins only), the job (due, busy, done, the run log),
-- their cars coming in (matched, added, blocks, gone, photos), leads both ways, the feed, the referral link, the cron
-- gate and the on-change trigger. Fixtures start "pc".
select test.suite('85 partner CRM link');

select test.mk_user('pc_admin', 'admin');
select test.mk_user('pc_cs', 'va', 'cs');
select test.mk_owner('pc_own');
select test.mk_renter('pc_rita');

-- two cars of ours on the site (a company car, a program owner's car), one hidden, one sample, and a second partner's car
insert into partners (id, owner_id, business_name, status) values (test.id('partner:pc_other'), test.id('owner:pc_own'), 'Other Partner Rentals', 'active');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, vin, class, status, management_mode, onboarding_method, body_type, supply_type, partner_id, is_sample)
values (test.id('vehicle:PC1'), test.id('owner:pc_own'), 2024, 'BMW', 'X5', 'xDrive40i', 'Black', 'PC1AAA', 'PCVIN0000000000A1', 'suv', 'available', 'managed', 'transfer', 'SUV', 'company', null, false),
       (test.id('vehicle:PC2'), test.id('owner:pc_own'), 2023, 'Audi', 'Q7', 'Progressiv', 'White', 'PC2AAA', 'PCVIN0000000000A2', 'suv', 'available', 'managed', 'transfer', 'SUV', 'program_owner', null, false),
       (test.id('vehicle:PC3'), test.id('owner:pc_own'), 2022, 'Kia', 'K5', 'GT', 'Red', 'PC3AAA', 'PCVIN0000000000A3', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'company', null, false),
       (test.id('vehicle:PC4'), test.id('owner:pc_own'), 2022, 'Kia', 'K5', 'EX', 'Grey', 'PC4AAA', 'PCVIN0000000000A4', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'company', null, true),
       (test.id('vehicle:PC5'), test.id('owner:pc_own'), 2025, 'Ferrari', 'Roma', null, 'Red', null, null, 'exotic', 'available', 'managed', 'transfer', 'Coupe', 'partner', test.id('partner:pc_other'), false);
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select v.id, p, p, p * 6, p * 20, 200, 35, 50000, 5000, 5000, now() - interval '1 day'
  from (values (test.id('vehicle:PC1'), 18900), (test.id('vehicle:PC2'), 16500), (test.id('vehicle:PC3'), 7900), (test.id('vehicle:PC4'), 7900), (test.id('vehicle:PC5'), 150000)) x(id, p) join vehicles v on v.id = x.id;
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, 'pc-' || lower(coalesce(v.plate, 'roma')), 'x', case when v.id = test.id('vehicle:PC3') then 'draft' else 'published' end, now(), 5, 'Automatic', v.body_type from vehicles v
 where v.id in (test.id('vehicle:PC1'), test.id('vehicle:PC2'), test.id('vehicle:PC3'), test.id('vehicle:PC4'), test.id('vehicle:PC5'))
on conflict (vehicle_id) do update set status = excluded.status, published_at = now(), slug = excluded.slug;

create function test.pc_link() returns uuid language sql stable as $$
  select c.id from partner_crm_connections c join partners p on p.id = c.partner_id where p.business_name = '01 Motors' $$;
create function test.pc_partner() returns uuid language sql stable as $$ select id from partners where business_name = '01 Motors' $$;
create function test.pc_out() returns jsonb language sql stable as $$ select app.partner_crm_outbound_cars(test.pc_link()) $$;
create function test.pc_ids() returns uuid[] language sql stable as $$ select coalesce(array_agg((x ->> 'vehicle_id')::uuid), '{}') from jsonb_array_elements(test.pc_out()) x $$;

-- ================================================================ 1. the link row, ready for their token
select test.eq('01 Motors has its link row: not connected, nothing sent, leads off, its booking link code',
  (select format('%s %s %s %s %s %s', token_ref is null, enabled, share_cars, leads_enabled, referral_code, feed_version) from partner_crm_connections where id = test.pc_link()),
  't t t f 01-motors 1');
select test.eq('not connected: never due', jsonb_array_length(public.server_partner_crm_due()), 0);

-- ================================================================ 2. THE RULE: never a partner car
select test.ok('the 62 partner cars of 01 Motors are on the site (so the rule has something to refuse)',
  (select count(*) from vehicles v where v.partner_id = test.pc_partner() and app.public_listing_row(v.id) is not null) = 62);
select test.ok('the second partner''s car is on the site too', app.public_listing_row(test.id('vehicle:PC5')) is not null);
select test.eq('outbound: no partner car at all, by supply type',
  (select count(*) from jsonb_array_elements(test.pc_out()) x where x ->> 'supply_type' not in ('company', 'program_owner')), 0::bigint);
select test.eq('outbound: no car that has a partner',
  (select count(*) from vehicles v where v.id = any (test.pc_ids()) and (v.partner_id is not null or v.supply_type = 'partner')), 0::bigint);
select test.ok('outbound: 01 Motors'' own cars are not in it, nor the other partner''s Ferrari',
  not exists (select 1 from vehicles v where v.id = any (test.pc_ids()) and v.partner_id = test.pc_partner()) and not (test.id('vehicle:PC5') = any (test.pc_ids())));
select test.ok('outbound: the company car and the program owner''s car are in it', test.id('vehicle:PC1') = any (test.pc_ids()) and test.id('vehicle:PC2') = any (test.pc_ids()));
select test.ok('outbound: never a car off the site, never a sample car', not (test.id('vehicle:PC3') = any (test.pc_ids())) and not (test.id('vehicle:PC4') = any (test.pc_ids())));
-- every setting turned on still never lets a partner car through
update partner_crm_connections set share_owner_cars = true, share_cars = true, share_rates = true, share_availability = true, share_photos = true, price_mode = 'percent', price_adjust_bps = -1000 where id = test.pc_link();
select test.eq('outbound with every setting on: still no partner car',
  (select count(*) from jsonb_array_elements(test.pc_out()) x join vehicles v on v.id = (x ->> 'vehicle_id')::uuid where v.supply_type = 'partner' or v.partner_id is not null), 0::bigint);
select test.eq('the feed (the same cars): no partner car',
  (select count(*) from jsonb_array_elements(public.server_partner_feed(test.pc_partner()) -> 'cars') x where x ->> 'supply_type' = 'partner'), 0::bigint);
update partner_crm_connections set share_owner_cars = false where id = test.pc_link();
select test.ok('program owners'' cars can be left out; CarmaCars'' own still go',
  not exists (select 1 from jsonb_array_elements(test.pc_out()) x where x ->> 'supply_type' <> 'company') and test.id('vehicle:PC1') = any (test.pc_ids()) and not (test.id('vehicle:PC2') = any (test.pc_ids())));
update partner_crm_connections set share_owner_cars = true where id = test.pc_link();

-- ================================================================ 3. the partner price, the details, availability
select test.eq('partner price: the site''s rates less 10%, to the nearest dollar (day, week, month)',
  (select format('%s %s %s', x ->> 'daily_cents', x ->> 'weekly_cents', x ->> 'monthly_cents') from jsonb_array_elements(test.pc_out()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:PC1')),
  '17000 102100 340200');
update partner_crm_connections set price_mode = 'site', price_adjust_bps = 0 where id = test.pc_link();
select test.eq('partner price: the site''s rates', (select x ->> 'daily_cents' from jsonb_array_elements(test.pc_out()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:PC1')), '18900');
select test.eq('the price rule rounds half a dollar up', app.partner_crm_price(17550, 'percent', 0), 17600::bigint);
select test.ok('each car: car code, name, class, seats, its booking link with the partner code',
  (select x ->> 'book_url' = 'https://carmacars.ca/p/01-motors/pc-pc1aaa' and x ? 'car_code' and x ->> 'class' = 'suv' and x ->> 'seats' = '5'
     from jsonb_array_elements(test.pc_out()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:PC1')));
select test.mk_booking('PC-B1', 'PC1', 'pc_rita', (app.today() + 2)::text || ' 10:00', (app.today() + 4)::text || ' 10:00', 'confirmed');
update bookings set blocks_calendar = true where booking_number = 'PC-B1';
select test.eq('availability: today free, the booked run (pickup day to return day), free days in 30',
  (select format('%s %s %s %s', a ->> 'available_today', a -> 'booked' -> 0 ->> 'from' = (app.today() + 2)::text, a -> 'booked' -> 0 ->> 'to' = (app.today() + 4)::text, a ->> 'free_days_30')
     from (select app.partner_crm_availability(test.id('vehicle:PC1'), 60) a) x), 'true t t 27');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at) values (test.id('vehicle:PC1'), 'service', now() - interval '1 hour', (app.today() + 1)::timestamp at time zone 'America/Toronto' + interval '12 hours');
select test.eq('availability: a block today: not free today, next free day after it', (select format('%s %s', a ->> 'available_today', a ->> 'next_free_date' = (app.today() + 1)::text) from (select app.partner_crm_availability(test.id('vehicle:PC1'), 60) a) x), 'false f');
select test.eq('availability: the next free day is after the block and before the booking', (select (a ->> 'next_free_date')::date - app.today() from (select app.partner_crm_availability(test.id('vehicle:PC1'), 60) a) x), 5);
update partner_crm_connections set share_rates = false, share_availability = false, share_photos = false where id = test.pc_link();
select test.eq('rates, availability and photos can be left out',
  (select format('%s %s %s', x ->> 'daily_cents', x ->> 'availability', x -> 'photos') from jsonb_array_elements(test.pc_out()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:PC1')), '  []');
update partner_crm_connections set share_rates = true, share_availability = true, share_photos = true where id = test.pc_link();

-- ================================================================ 4. the token: the vault, never returned, never through the door
select test.throws('the token: Admins only', $$select public.server_partner_crm_token(test.id('pc_cs'), jsonb_build_object('partner_id', test.pc_partner(), 'token', 'pit-11111111-2222-3333-4444-555555555555', 'location_id', 'loc01motorsFAKE'))$$);
select test.throws('the token: one that does not look like one is refused', $$select public.server_partner_crm_token(test.id('pc_admin'), jsonb_build_object('partner_id', test.pc_partner(), 'token', 'hello', 'location_id', 'loc01motorsFAKE'))$$, '%Private Integration token%');
select test.throws('the token: a location ID that is not one is refused', $$select public.server_partner_crm_token(test.id('pc_admin'), jsonb_build_object('partner_id', test.pc_partner(), 'token', 'pit-11111111-2222-3333-4444-555555555555', 'location_id', 'bad id!'))$$, '%location ID%');
select test.eq('the token saved: only its last four characters come back',
  public.server_partner_crm_token(test.id('pc_admin'), jsonb_build_object('partner_id', test.pc_partner(), 'token', 'pit-11111111-2222-3333-4444-555555555555', 'location_id', 'loc01motorsFAKE')) - 'store',
  '{"ok": true, "token_hint": "5555", "location_id": "loc01motorsFAKE"}'::jsonb);
select test.ok('the row keeps the vault id and the hint, never the token',
  (select token_ref is not null and token_hint = '5555' and not (to_jsonb(c)::text like '%pit-1111%') from partner_crm_connections c where id = test.pc_link()));
select test.eq('the stand-in holds it where there is no vault (local and test databases)', (select token_store from partner_crm_connections where id = test.pc_link()), case when app.crm_vault() then 'vault' else 'database' end);
select test.eq('the server reads it for the call', public.server_partner_crm_secret(test.pc_link()), 'pit-11111111-2222-3333-4444-555555555555');
select test.ok('the Admin''s read never has it',
  not (app.door(test.id('pc_admin'), 'aal2', 'admin_read', 'partner_crm', jsonb_build_object('partner_id', test.pc_partner()))::text like '%pit-1111%')
  and not (app.door(test.id('pc_admin'), 'aal2', 'admin_read', 'partner_crm', jsonb_build_object('partner_id', test.pc_partner())) -> 'link' ? 'token_ref'));
select test.ok('the audit line has the hint, not the token', not exists (select 1 from audit_log where entity_table = 'partner_crm_connections' and after::text like '%pit-1111%')
  and exists (select 1 from audit_log where action = 'partner_crm_token' and after ->> 'token_hint' = '5555'));
select test.ok('the stand-in table and the secret functions are not for visitors or signed-in users',
  not has_table_privilege('authenticated', 'app.crm_secrets', 'select') and not has_function_privilege('authenticated', 'public.server_partner_crm_secret(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.server_partner_crm_token(uuid, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.crm_secret_get(uuid)', 'execute'));
select test.throws('the door refuses a token as a setting', $$select app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'token', 'pit-x'))$$, '%Not a setting%');
select test.ok('saved: due for its first sync', test.pc_link() = any (array(select jsonb_array_elements_text(public.server_partner_crm_due())::uuid)));

-- ================================================================ 5. the door: reads and saves, Admins only
select test.throws('an assistant cannot read the link', $$select app.door(test.id('pc_cs'), 'aal2', 'admin_read', 'partner_crm', '{}')$$);
select test.ok('the list: every partner and its link', (select jsonb_array_length(app.door(test.id('pc_admin'), 'aal2', 'admin_read', 'partner_crm', '{}') -> 'partners')) >= 2);
select test.eq('the detail: what they see (ours by supply type), their cars here (62)',
  (select format('%s %s %s', d #>> '{shared,company}', d #>> '{shared,program_owner}', d ->> 'partner_cars') from (select app.door(test.id('pc_admin'), 'aal2', 'admin_read', 'partner_crm', jsonb_build_object('partner_id', test.pc_partner())) d) x),
  (select format('%s %s 62', count(*) filter (where x ->> 'supply_type' = 'company'), count(*) filter (where x ->> 'supply_type' = 'program_owner')) from jsonb_array_elements(test.pc_out()) x));
select test.ok('save: the price rule, leads need a pipeline and a stage',
  (app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'price_mode', 'percent', 'price_adjust_bps', -500)) ->> 'price_adjust_bps') = '-500');
select test.throws('save: leads without their pipeline', $$select app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'leads_enabled', true))$$, '%pipeline%');
select test.throws('save: our own object as theirs is refused', $$select app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'inbound_object_key', 'carmacars_vehicles'))$$, '%we fill with our cars%');
select test.throws('save: a feed must be https', $$select app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'inbound_feed_url', 'http://x.example.test'))$$);
select test.throws('save: an assistant cannot', $$select app.door(test.id('pc_cs'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'share_cars', false))$$);
select test.eq('save: back to the site''s rates resets the adjustment',
  app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(), 'price_mode', 'site', 'price_adjust_bps', -500)) ->> 'price_adjust_bps', '0');
select test.eq('feed key: New key raises the version', app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_feed_rotate', jsonb_build_object('partner_id', test.pc_partner())) ->> 'feed_version', '2');
select test.eq('the feed: its version and the same cars', (select format('%s %s', f ->> 'feed_version', jsonb_array_length(f -> 'cars')) from (select public.server_partner_feed(test.pc_partner()) f) x), '2 ' || jsonb_array_length(test.pc_out()));

-- ================================================================ 6. the job
create temp table pc_job as select public.server_partner_crm_job(test.pc_link(), null, 'sync') j;
select test.ok('a sync starts: the run marked, our cars, no token in it', (select (j ->> 'ok')::boolean and jsonb_array_length(j -> 'cars') = jsonb_array_length(test.pc_out()) and jsonb_array_length(j -> 'cars') >= 2 and not (j::text like '%pit-1111%') from pc_job));
select test.eq('THE RULE in the job''s payload: no partner car',
  (select count(*) from pc_job, jsonb_array_elements(j -> 'cars') x join vehicles v on v.id = (x ->> 'vehicle_id')::uuid where v.supply_type = 'partner' or v.partner_id is not null or x ->> 'supply_type' = 'partner'), 0::bigint);
select test.eq('a second sync while one runs is refused', public.server_partner_crm_job(test.pc_link(), null, 'sync') ->> 'busy', 'true');
select test.eq('running: not due', test.pc_link() = any (array(select jsonb_array_elements_text(public.server_partner_crm_due())::uuid)), false);
create temp table pc_d1 as select public.server_partner_crm_done(jsonb_build_object('run_id', (select id from partner_crm_runs where connection_id = test.pc_link() and kind = 'sync' order by started_at desc limit 1),
     'connection_id', test.pc_link(), 'kind', 'sync', 'ok', true, 'target', 'custom_object', 'counts', jsonb_build_object('cars', 2, 'created', 2),
     'records', jsonb_build_array(
        jsonb_build_object('vehicle_id', test.id('vehicle:PC1'), 'remote_kind', 'object_record', 'remote_id', 'rec-pc1', 'payload_hash', 'h1'),
        jsonb_build_object('vehicle_id', test.id('vehicle:PC2'), 'remote_kind', 'object_record', 'remote_id', 'rec-pc2', 'payload_hash', 'h2'),
        jsonb_build_object('vehicle_id', test.id('vehicle:PC5'), 'remote_kind', 'object_record', 'remote_id', 'rec-ferrari', 'payload_hash', 'h5')))) r;
select test.eq('done: the records kept (a partner car in the report is dropped), the result, the run closed',
  (select r ->> 'ok' from pc_d1)
  || (select format(' %s %s %s %s', count(*), bool_and(not (vehicle_id = test.id('vehicle:PC5'))), (select last_sync_ok from partner_crm_connections where id = test.pc_link()),
       (select detected_target from partner_crm_connections where id = test.pc_link())) from partner_crm_records where connection_id = test.pc_link()),
  'true 2 t t custom_object');
select test.eq('THE RULE in the records: no partner car ever has a record in a partner''s CRM',
  (select count(*) from partner_crm_records r join vehicles v on v.id = r.vehicle_id where v.supply_type = 'partner' or v.partner_id is not null), 0::bigint);
select test.ok('the run log: finished, ok, counts', (select ok and finished_at is not null and counts ->> 'created' = '2' from partner_crm_runs where connection_id = test.pc_link() and kind = 'sync' order by started_at desc limit 1));
select test.eq('just synced: not due', test.pc_link() = any (array(select jsonb_array_elements_text(public.server_partner_crm_due())::uuid)), false);
select test.eq('the cron gate: nothing for crm', (app.server_jobs_due() ->> 'crm'), 'false');
update rate_cards set daily_rate_cents = 19900 where vehicle_id = test.id('vehicle:PC1');
select test.ok('a rate changed: a sync is asked for (on change)', (select sync_requested_at > last_sync_at from partner_crm_connections where id = test.pc_link()));
select test.eq('the cron gate says crm', (app.server_jobs_due() ->> 'crm'), 'true');
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', true,
  'removed', jsonb_build_array(jsonb_build_object('vehicle_id', test.id('vehicle:PC2'), 'remote_kind', 'object_record'))));
select test.ok('removed records go', not exists (select 1 from partner_crm_records where connection_id = test.pc_link() and vehicle_id = test.id('vehicle:PC2')));
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', false, 'error', 'Our cars: The token was refused'));
select test.ok('a failed sync: failing since, the error kept', (select failing_since is not null and last_error like '%refused%' and running_since is null from partner_crm_connections where id = test.pc_link()));
update partner_crm_connections set failing_since = now() - interval '2 hours' where id = test.pc_link();
select test.ok('Admin > Today: a link failing for an hour', exists (select 1 from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'partner_crm' and x ->> 'message' like '%01 Motors%'));
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'test', 'ok', true, 'target', 'custom_object',
  'test', jsonb_build_object('objects', jsonb_build_array(jsonb_build_object('key', 'custom_objects.vehicles', 'label', 'Vehicles')))));
select test.ok('a test run records what it found', (select last_test -> 'objects' -> 0 ->> 'key' = 'custom_objects.vehicles' and (last_test ->> 'ok')::boolean from partner_crm_connections where id = test.pc_link()));

-- ================================================================ 7. their cars coming in
create function test.pc_items(p_g63_base bigint, p_all boolean default true) returns jsonb language sql stable as $$
  select jsonb_build_array(
      jsonb_build_object('remote_kind', 'object_record', 'remote_id', 'rec-new', 'name', '2025 Mercedes-Benz CLE 53 AMG Cabriolet', 'make', 'Mercedes-Benz', 'model', 'CLE', 'trim', '53 AMG Cabriolet', 'year', 2025, 'base_cents', 45000, 'seats', 4,
                         'photos', jsonb_build_array('https://images.example.test/cle-1.jpg', 'http://not-https.example.test/x.jpg'))) ||
    case when p_all then jsonb_build_array(
      jsonb_build_object('remote_kind', 'object_record', 'remote_id', 'rec-g63', 'name', 'G Wagon', 'make', 'Mercedes-Benz', 'model', 'G-Class', 'trim', 'G63 AMG',
                         'base_cents', p_g63_base, 'photos', jsonb_build_array('https://images.example.test/g63-1.jpg'), 'booked', jsonb_build_array(jsonb_build_object('from', (app.today() + 10)::text, 'to', (app.today() + 12)::text))),
      jsonb_build_object('remote_kind', 'object_record', 'remote_id', 'rec-norate', 'name', 'Mystery car')) else '[]'::jsonb end $$;
create temp table pc_in1 as select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', true, 'inbound', test.pc_items(110000))) r;
select test.eq('inbound: their G63 matched by make, model and trim; a new car added; one without a rate waits; a block for their booking',
  (select r -> 'counts' -> 'inbound' from pc_in1), '{"gone": 0, "blocks": 1, "linked": 1, "review": 1, "created": 1}'::jsonb);
select test.eq('matched: their rates are the car''s sheet rates now (the renter''s follow, 10% markup)',
  (select format('%s %s', r.base_cents, rc.daily_rate_cents) from partner_rates r join vehicles v on v.id = r.vehicle_id
     join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
    where v.partner_id = test.pc_partner() and v.partner_sheet_name = 'Mercedes G63 AMG'), '110000 121000');
select test.ok('their booked dates: a calendar block on their car, external', exists (select 1 from vehicle_calendar_blocks b join partner_crm_blocks k on k.block_id = b.id
  join vehicles v on v.id = b.vehicle_id where v.partner_sheet_name = 'Mercedes G63 AMG' and v.partner_id = test.pc_partner() and b.reason = 'external_booking' and b.source = 'external' and b.removed_at is null));
select test.eq('added: their partner car, not on the site until reviewed, with its sheet rates and year',
  (select format('%s %s %s %s %s', v.supply_type, v.partner_id = test.pc_partner(), r.base_cents, coalesce(l.status, 'none'), v.year)
     from partner_crm_inbound i join vehicles v on v.id = i.vehicle_id join partner_rates r on r.vehicle_id = v.id left join vehicle_listings l on l.vehicle_id = v.id
    where i.remote_id = 'rec-new'), 'partner t 45000 draft 2025');
select test.ok('a car added from their CRM is never sent back out (it is a partner car)', not exists (select 1 from jsonb_array_elements(test.pc_out()) x join partner_crm_inbound i on i.vehicle_id = (x ->> 'vehicle_id')::uuid));
select test.eq('waits: needs a make, a model and a rate', (select status || ': ' || message from partner_crm_inbound where remote_id = 'rec-norate'), 'review: Needs a make, a model and a daily rate before it can be added');
select test.eq('photos to copy: https only, for their cars with no photos of their own',
  (select string_agg(p ->> 'urls', ' ' order by p ->> 'urls') from pc_in1, jsonb_array_elements(r -> 'photos') p),
  '["https://images.example.test/cle-1.jpg"] ["https://images.example.test/g63-1.jpg"]');
select test.eq('a photo copied: approved, public, the cover; the same address never twice',
  (select format('%s %s', public.server_partner_crm_photo(jsonb_build_object('vehicle_id', i.vehicle_id, 'url', 'https://images.example.test/cle-1.jpg', 'path', 'partners/x/1.jpg', 'mime', 'image/jpeg')) ->> 'ok',
                 public.server_partner_crm_photo(jsonb_build_object('vehicle_id', i.vehicle_id, 'url', 'https://images.example.test/cle-1.jpg', 'path', 'partners/x/1.jpg', 'mime', 'image/jpeg')) ->> 'duplicate')
     from partner_crm_inbound i where i.remote_id = 'rec-new'), 'true true');
select test.ok('the photo row', (select ph.status = 'approved' and ph.is_public and ph.is_cover from vehicle_photos ph join partner_crm_inbound i on i.vehicle_id = ph.vehicle_id where i.remote_id = 'rec-new'));
select test.eq('copied photos do not stop more of theirs; a copied address is not asked for again',
  (select string_agg(p ->> 'urls', ' ') from jsonb_array_elements(app.partner_crm_inbound_apply(test.pc_link(), test.pc_items(110000)) -> 'photos') p where (p ->> 'vehicle_id')::uuid = (select vehicle_id from partner_crm_inbound where remote_id = 'rec-new')),
  '[]');
select test.throws('photos only for partner cars', $$select public.server_partner_crm_photo(jsonb_build_object('vehicle_id', test.id('vehicle:PC1'), 'url', 'https://x.example.test/a.jpg', 'path', 'p.jpg'))$$, '%Not a partner car%');
update partner_crm_connections set sync_requested_at = null, enabled = true where id = test.pc_link();
select app.partner_crm_inbound_apply(test.pc_link(), test.pc_items(115000));
select test.eq('their rate changed: applied, and it never asks for a sync of ours (their own cars are not shared)',
  (select format('%s %s', (select r.base_cents from partner_rates r join vehicles v on v.id = r.vehicle_id where v.partner_sheet_name = 'Mercedes G63 AMG' and v.partner_id = test.pc_partner()),
                 (select sync_requested_at is null from partner_crm_connections where id = test.pc_link()))), '115000 t');
create temp table pc_gone as select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', true, 'inbound', test.pc_items(115000, false))) r;
select test.eq('a car no longer in their list: gone, its blocks lifted (the car stays)',
  (select r #>> '{counts,inbound,gone}' from pc_gone)
  || (select format(' %s %s %s', i.status, (select count(*) from vehicle_calendar_blocks b join partner_crm_blocks k on k.block_id = b.id where k.inbound_id = i.id and b.removed_at is null),
        exists (select 1 from vehicles v where v.id = i.vehicle_id and v.retired_at is null))
        from partner_crm_inbound i where i.remote_id = 'rec-g63'),
  '2 gone 0 t');
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', false, 'error', 'Their cars: x', 'inbound', null));
select test.eq('not read (null) is not "no cars": nothing goes', (select status from partner_crm_inbound where remote_id = 'rec-new'), 'created');
select test.eq('Admin: link a waiting car to one of theirs (the others stay as they are)',
  app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_inbound_item', jsonb_build_object('id', (select id from partner_crm_inbound where remote_id = 'rec-norate'), 'action', 'link',
    'vehicle_id', (select id from vehicles where partner_sheet_name = 'Audi S5' and partner_id = test.pc_partner()))) ->> 'status', 'linked');
select test.eq('linking one did not mark the others gone', (select status from partner_crm_inbound where remote_id = 'rec-new'), 'created');
select test.eq('Admin: set one aside', app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_inbound_item', jsonb_build_object('id', (select id from partner_crm_inbound where remote_id = 'rec-g63'), 'action', 'skip')) ->> 'status', 'skipped');
select test.throws('Admin: link to a car that is not theirs', $$select app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_inbound_item', jsonb_build_object('id', (select id from partner_crm_inbound where remote_id = 'rec-norate'), 'action', 'link', 'vehicle_id', test.id('vehicle:PC1')))$$, '%one of their cars%');
select test.throws('Admin: an assistant cannot', $$select app.door(test.id('pc_cs'), 'aal2', 'admin_do', 'partner_crm_inbound_item', jsonb_build_object('id', (select id from partner_crm_inbound where remote_id = 'rec-norate'), 'action', 'skip'))$$);

-- ================================================================ 8. leads both ways
select test.eq('leads off: nothing due', jsonb_array_length(app.partner_crm_leads_due(test.pc_link())), 0);
select test.ok('leads on (with their pipeline)', (app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_save', jsonb_build_object('partner_id', test.pc_partner(),
  'leads_enabled', true, 'pipeline_id', 'pipeRentals01', 'pipeline_stage_id', 'stageNew01', 'inbound_stage_id', 'stageSendCC')) ->> 'leads_enabled')::boolean);
select test.mk_booking('PC-B2', 'PC2', 'pc_rita', (app.today() + 20)::text || ' 10:00', (app.today() + 22)::text || ' 10:00', 'requested');
select test.eq('a request after their booking link: remembered', public.server_partner_referral(jsonb_build_object('booking_number', 'PC-B2', 'code', '01-MOTORS')) ->> 'ok', 'true');
select test.eq('an unknown code is not', public.server_partner_referral(jsonb_build_object('booking_number', 'PC-B2', 'code', 'nobody')) ->> 'ok', 'false');
select test.mk_booking('PC-B3', 'PC3', 'pc_rita', (app.today() + 30)::text || ' 10:00', (app.today() + 32)::text || ' 10:00', 'requested');
update bookings set vehicle_id = (select id from vehicles where partner_sheet_name = 'Audi S5' and partner_id = test.pc_partner()) where booking_number = 'PC-B3';
select test.eq('due: the referral and the request for their car (after leads were turned on)',
  (select string_agg(x ->> 'booking_number' || ':' || (x ->> 'reason'), ' ' order by x ->> 'booking_number') from jsonb_array_elements(app.partner_crm_leads_due(test.pc_link())) x),
  'PC-B2:referral PC-B3:partner_car');
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', true,
     'leads', jsonb_build_array(jsonb_build_object('booking_id', (select id from bookings where booking_number = 'PC-B2'), 'reason', 'referral', 'ok', true, 'contact_id', 'con1', 'opportunity_id', 'opp1')),
     'partner_leads', jsonb_build_array(jsonb_build_object('opportunity_id', 'oppFromPartner1', 'name', 'Sam Example', 'email', 'Sam.Example@example.test', 'car', 'Range Rover'),
                                        jsonb_build_object('opportunity_id', 'oppNoContact', 'name', 'Nobody'))));
select test.ok('sent and received: the lead recorded as sent, their opportunity a lead here (one with no email or phone skipped)',
  (select count(*) from leads where source = 'partner' and email = 'sam.example@example.test') = 1
  and (select count(*) from partner_crm_leads where remote_opportunity_id = 'oppNoContact') = 0
  and (select status from partner_crm_leads where booking_id = (select id from bookings where booking_number = 'PC-B2')) = 'sent'
  and not exists (select 1 from jsonb_array_elements(app.partner_crm_leads_due(test.pc_link())) x where x ->> 'booking_number' = 'PC-B2'));
select public.server_partner_crm_done(jsonb_build_object('connection_id', test.pc_link(), 'kind', 'sync', 'ok', true,
  'partner_leads', jsonb_build_array(jsonb_build_object('opportunity_id', 'oppFromPartner1', 'email', 'sam.example@example.test'))));
select test.eq('their same opportunity again adds nothing', (select count(*) from leads where source = 'partner' and email = 'sam.example@example.test'), 1::bigint);
select test.ok('the referral code check for the link cookie (visitors may ask)', public.partner_referral_code_ok('01-motors') and not public.partner_referral_code_ok('nope')
  and has_function_privilege('anon', 'public.partner_referral_code_ok(text)', 'execute'));

-- ================================================================ 9. disconnect
select test.eq('disconnect', app.door(test.id('pc_admin'), 'aal2', 'admin_do', 'partner_crm_disconnect', jsonb_build_object('partner_id', test.pc_partner())) ->> 'connected', 'false');
select test.ok('disconnected: the token gone from the store, nothing due',
  public.server_partner_crm_secret(test.pc_link()) is null and jsonb_array_length(public.server_partner_crm_due()) = 0
  and (case when app.crm_vault() then true else not exists (select 1 from app.crm_secrets) end));
select test.eq('not connected: a job is refused', public.server_partner_crm_job(test.pc_link(), null, 'sync') ->> 'ok', 'false');
