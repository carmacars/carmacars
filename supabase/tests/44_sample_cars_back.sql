-- 44: the sample cars back (migration 0065). The catalogue of the 20 sample cars, "Show sample cars" (recreates the
-- missing ones with photos, rates and listings, restores and publishes the others, still noindex and out of the
-- sitemap), "Hide sample cars" (one click, never refused: not by an enquiry, an old request or a booking), a request on
-- a sample car becoming an enquiry with a customer service task (never a booking, from anywhere), the chat's facts, why
-- a real car is not on the site (app.vehicle_public_gates), and the sample photos of a real car without photos on its
-- public page. Fixtures start with "sx".
select test.suite('44 sample cars back');

select test.mk_user('sx_admin', 'admin');
select test.mk_user('sx_cs', 'va', 'cs');
select test.mk_owner('sx_owner');
select test.mk_renter('sx_rita');
create temp table sc (k text primary key, v jsonb);
grant all on sc to public;
create or replace function test.sc(p text) returns jsonb language sql stable as $$ select v from sc where k = p $$;
create or replace function test.scdo(p_name text, p_user text default 'sx_admin') returns jsonb language sql as $$
  select app.door(test.id(p_user), '', 'ops_do', p_name, '{}') $$;

-- ---------------------------------------------------------------- 1. the catalogue
select test.eq('catalogue: the 20 sample cars of the original seed', (select count(*) from sample_car_catalogue), 20::bigint);
select test.ok('catalogue: each with rates, photos and a listing text',
  not exists (select 1 from sample_car_catalogue where (data #>> '{rates,daily}') is null or jsonb_array_length(data -> 'photos') < 1 or data ->> 'blurb' is null));
select test.ok('catalogue: the photos are files of the site (never the photo bucket)',
  not exists (select 1 from sample_car_catalogue, jsonb_array_elements(data -> 'photos') p where p ->> 'path' not like '/sample-photos/cars/%'));
select test.ok('a fresh database gets no sample car from the migration', not exists (select 1 from vehicle_listings l join sample_car_catalogue c on c.slug = l.slug));

-- ---------------------------------------------------------------- 2. show
select test.throws('show: only an Admin', $$select test.scdo('sample_cars_show', 'sx_cs')$$, 'Admin');
insert into sc select 'show', test.scdo('sample_cars_show');
select test.eq('show: the 20 sample cars added', (test.sc('show') ->> 'added')::int, 20);
select test.ok('show: all on the site', (test.sc('show') #>> '{state,public}')::int >= 20
  and (select count(*) from vehicle_listings l join sample_car_catalogue c on c.slug = l.slug where l.status = 'published') = 20);
select test.eq('show: each with its 8 photos, rates and classes',
  (select count(*) from vehicles v join vehicle_listings l on l.vehicle_id = v.id join sample_car_catalogue c on c.slug = l.slug where v.is_sample
      and (select count(*) from vehicle_photos p where p.vehicle_id = v.id and p.is_public and p.status = 'approved') = 8
      and exists (select 1 from rate_cards r where r.vehicle_id = v.id)
      and exists (select 1 from vehicle_class_links k where k.vehicle_id = v.id)), 20::bigint);
select test.eq('show: the young driver fees of the seed (Porsche 911)',
  (select amount_cents from vehicle_fee_overrides o join vehicle_listings l on l.vehicle_id = o.vehicle_id where l.slug = 'porsche-911' and o.fee_type_code = 'young_driver_18_20'),
  (select (data #>> '{young,a}')::bigint from sample_car_catalogue where slug = 'porsche-911'));
set role anon;
select test.ok('show: on the fleet page, marked as a sample', exists (select 1 from public.fleet() f where f ->> 'slug' = 'toyota-corolla' and f ->> 'is_sample' = 'true'));
select test.eq('show: the car page is not indexable', public.car_page('toyota-corolla') ->> 'indexable', 'false');
select test.eq('show: its photos are the sample car photos (not "Sample photo" placeholders)',
  public.car_page('toyota-corolla') #>> '{photos,0,path}', '/sample-photos/cars/toyota-corolla-lead.svg');
create temp table sx_map as select path from public.sitemap_rows();
reset role;
select test.ok('show: no sample car in the sitemap',
  not exists (select 1 from sx_map s join vehicle_listings l on '/cars/' || l.slug = s.path join vehicles v on v.id = l.vehicle_id where v.is_sample));
select test.ok('show: the sample addresses are suppressed', (select count(*) from email_suppressions where email in ('sample.owner@example.test', 'sample.renter@example.test') and lifted_at is null) = 2);
select test.ok('show: in the audit log', exists (select 1 from audit_log where action = 'sample_cars_show' and actor_user_id = test.id('sx_admin')));
insert into sc select 'again', test.scdo('sample_cars_show');
select test.eq('show again: nothing added, nothing changed', (test.sc('again') ->> 'added')::int || '/' || (test.sc('again') ->> 'shown')::int, '0/0');

-- ---------------------------------------------------------------- 3. a request on a sample car is an enquiry
create or replace function test.screq(p_slug text, p_key text) returns jsonb language sql as $$
  select public.submit_booking_request(jsonb_build_object('request_key', p_key, 'vehicle_id', (select vehicle_id from vehicle_listings where slug = p_slug),
    'pickup_at', '2026-11-20 10:00-05', 'return_at', '2026-11-23 10:00-05', 'booking_type', 'standard', 'note', 'Need it for a wedding',
    'renter', jsonb_build_object('email', 'Eve.Enquirer@example.test', 'full_name', 'Eve Enquirer', 'mobile', '647-555-0123', 'date_of_birth', '1990-01-01'),
    'consents', jsonb_build_object('marketing', jsonb_build_object('opted_in', false))), null, 'test', null) $$;
set role service_role;
insert into sc select 'enq', test.screq('toyota-corolla', 'sc-request-key-1');
reset role;
select test.eq('enquiry: the request answers ok, as an enquiry with a reference', (test.sc('enq') ->> 'ok') || '/' || (test.sc('enq') ->> 'enquiry') || '/' || left(test.sc('enq') ->> 'booking_number', 3), 'true/true/EQ-');
select test.ok('enquiry: no booking is created', not exists (select 1 from bookings b join vehicle_listings l on l.vehicle_id = b.vehicle_id where l.slug = 'toyota-corolla'));
select test.ok('enquiry: a lead of kind sample_car with the car, the dates and the contact',
  exists (select 1 from leads where kind = 'sample_car' and email = 'eve.enquirer@example.test' and payload ->> 'reference' = test.sc('enq') ->> 'booking_number'
            and payload ->> 'car' like '%Toyota Corolla%' and payload ->> 'dates' is not null and message = 'Need it for a wedding'));
select test.ok('enquiry: a customer service task "Suggest a similar real car", due at the first reply target',
  exists (select 1 from tasks t where t.task_type = 'sample_car_enquiry' and t.queue = 'cs' and t.title like 'Suggest a similar real car:%Toyota Corolla%' and t.status = 'open'
            and t.related_id = (test.sc('enq') ->> 'lead_id')::uuid and t.due_at is not null));
set role service_role;
insert into sc select 'enq2', test.screq('toyota-corolla', 'sc-request-key-1');
reset role;
select test.eq('enquiry: the same request sent twice is one enquiry', (test.sc('enq2') ->> 'booking_number') || '/' || (test.sc('enq2') ->> 'created') || '/' ||
  (select count(*) from leads where kind = 'sample_car'), (test.sc('enq') ->> 'booking_number') || '/false/1');
select test.throws('enquiry: no booking on a sample car from anywhere (Add a rental, an import): refused with the reason',
  $$insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents,
      km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
    select 'SC-2', 'standard', 'requested', l.vehicle_id, test.id('renter:sc_rita'), now(), now() + interval '3 days', now() + interval '4 days', now() + interval '4 days', 1,
      5900, 5900, 30000, 100000, 'daily', 1, 0, 5900, 0, 200, 200, 35, 50000, 5900, 767, 6667 from vehicle_listings l where l.slug = 'hyundai-elantra'$$, 'example car');
select test.mk_vehicle('sxreal', 'sx_owner');
select test.ok('enquiry: a real car still books normally (the guard is only for sample cars)',
  test.mk_booking('SC-REAL', 'sxreal', 'sx_rita', '2026-11-01 10:00', '2026-11-02 10:00', 'requested') is not null);
select test.eq('chat: the assistant''s facts mark the sample cars, not the real ones',
  (select string_agg(c ->> 'slug' || '=' || (c ->> 'sample'), ',' order by c ->> 'slug') from jsonb_array_elements(app.server_chat_facts() -> 'fleet') c
    where c ->> 'slug' in ('toyota-corolla', 'mercedes-c300-sxpub0')), 'toyota-corolla=true');

-- ---------------------------------------------------------------- 4. hide: one click, never refused
-- an old request on a sample car (the seed's calendar is the only way one is written now)
select set_config('app.request_id', 'seed', false);
insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
    daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents,
    km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
  select 'SC-OLD', 'standard', 'requested', l.vehicle_id, test.id('renter:sc_rita'), now(), now() + interval '3 days', now() + interval '4 days', now() + interval '4 days', 1,
    5900, 5900, 30000, 100000, 'daily', 1, 0, 5900, 0, 200, 200, 35, 50000, 5900, 767, 6667 from vehicle_listings l where l.slug = 'hyundai-elantra';
select set_config('app.request_id', '', false);
select test.throws('hide: only an Admin', $$select test.scdo('sample_cars_hide', 'sx_cs')$$, 'Admin');
insert into sc select 'hide', test.scdo('sample_cars_hide');
select test.ok('hide: all off the site at once, with an open enquiry and an old request', (test.sc('hide') ->> 'hidden')::int >= 20 and (test.sc('hide') #>> '{state,public}')::int = 0);
set role anon;
select test.ok('hide: none on the fleet page', not exists (select 1 from public.fleet() f where f ->> 'is_sample' = 'true'));
reset role;
select test.ok('hide: the cars, their photos and the enquiry stay (Show brings them back)',
  (select count(*) from vehicles v join vehicle_listings l on l.vehicle_id = v.id join sample_car_catalogue c on c.slug = l.slug where v.is_sample) = 20 and exists (select 1 from leads where kind = 'sample_car'));
select test.eq('hide twice: nothing to hide, still no error', (test.scdo('sample_cars_hide') ->> 'hidden')::int, 0);
insert into sc select 'show2', test.scdo('sample_cars_show');
select test.eq('show after hide: the same 20 back, none added', (test.sc('show2') ->> 'added')::int || '/' || (test.sc('show2') ->> 'shown')::int, '0/20');
-- a sample car deleted (Delete all sample cars) and one retired come back with Show
select app.vehicle_delete(test.id('sx_admin'), jsonb_build_object('vehicle_id', (select vehicle_id from vehicle_listings where slug = 'porsche-911'), 'bulk', true));
update vehicles set retired_at = now(), retired_reason = 'test' where id = (select vehicle_id from vehicle_listings where slug = 'honda-civic');
update vehicle_listings set status = 'unpublished' where slug = 'honda-civic';
insert into sc select 'show3', test.scdo('sample_cars_show');
select test.eq('show: a deleted sample car is recreated, a retired one restored', (test.sc('show3') ->> 'added')::int || '/' || (test.sc('show3') ->> 'shown')::int, '1/1');
select test.ok('show: the restored car is no longer retired', (select retired_at is null from vehicles where id = (select vehicle_id from vehicle_listings where slug = 'honda-civic')));

-- ---------------------------------------------------------------- 5. why a real car is not on the site
-- a car in onboarding (agreements not signed), a car ready to list without a listing, a car on the site
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:sxonb'), test.id('owner:sx_owner'), 2017, 'Volkswagen', 'Jetta', 'SXONB000000000001', 'SXONB01', 'standard', 'onboarding', 'managed', 'transfer', 'Sedan'),
       (test.id('vehicle:sxready'), test.id('owner:sx_owner'), 2022, 'Chevrolet', 'Malibu', 'SXRDY000000000001', 'SXRDY01', 'standard', 'ready_to_list', 'managed', 'transfer', 'Sedan'),
       (test.id('vehicle:sxnorates'), test.id('owner:sx_owner'), 2021, 'Kia', 'Forte', 'SXNRT000000000001', 'SXNRT01', 'standard', 'ready_to_list', 'managed', 'transfer', 'Sedan');
insert into vehicle_onboardings (vehicle_id, status) values (test.id('vehicle:sxonb'), 'intake');
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
values (test.id('vehicle:sxready'), 6000, 7000, 36000, 120000, 200, 25, 50000, 0, 0, '2026-09-01');
select test.mk_vehicle('sxpub', 'sx_owner');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
values (test.id('vehicle:sxpub'), 'mercedes-c300-scpub', 'Mercedes-Benz C 300', 'published', now(), 5, 'Automatic', 'Sedan');
select test.ok('gates: a car on the site has none, and is not listed as not public',
  jsonb_array_length(app.vehicle_public_gates(test.id('vehicle:sxpub'))) = 0
  and not exists (select 1 from jsonb_array_elements(app.cars_not_public()) c where c ->> 'vehicle_id' = test.id('vehicle:sxpub')::text));
select test.ok('gates: a car in onboarding has its open steps on the checklist (0070); the listing is its only gate',
  exists (select 1 from jsonb_array_elements(app.listing_checklist(test.id('vehicle:sxonb'))) g where g ->> 'code' = 'signatures')
  and not exists (select 1 from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:sxonb'))) g where g ->> 'code' = 'signatures')
  and exists (select 1 from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:sxonb'))) g where g ->> 'code' = 'listing'));
select test.eq('gates: a car ready to list waits on Publish now only (0070: details and photos are checklist items)', (select string_agg(g ->> 'code' || ': ' || (g ->> 'action'), ',') from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:sxready'))) g),
  'listing: Press Publish now on the car');
select test.ok('gates: no rates is named with its action',
  exists (select 1 from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:sxnorates'))) g where g ->> 'code' = 'rates' and g ->> 'action' like 'Set the rates%'));
select test.ok('gates: the plate check never applies to a car on sample photos',
  not exists (select 1 from jsonb_array_elements(app.vehicle_public_gates(test.id('vehicle:sxready'))) g where g ->> 'code' = 'plates'));
select test.ok('not public: each real car with its next action and whether it shows sample photos; no sample car',
  exists (select 1 from jsonb_array_elements(app.cars_not_public()) c where c ->> 'vehicle_id' = test.id('vehicle:sxready')::text and c ->> 'next' like 'Press Publish now%'
            and (c ->> 'sample_photos')::boolean)
  and not exists (select 1 from jsonb_array_elements(app.cars_not_public()) c join vehicles v on v.id = (c ->> 'vehicle_id')::uuid where v.is_sample));
select test.throws('not public: only an Admin reads it', $$select app.door(test.id('sx_cs'), '', 'ops_read', 'cars_not_public', '{}')$$, 'Admin');
select test.ok('not public: an Admin reads it through the door', jsonb_typeof(app.door(test.id('sx_admin'), '', 'ops_read', 'cars_not_public', '{}')) = 'array');

-- ---------------------------------------------------------------- 6. a real car without photos shows sample photos (0054)
set role anon;
select test.eq('sample photo: the car page of a real car without photos shows a sample photo, marked',
  (public.car_page('mercedes-c300-scpub') #>> '{photos,0,sample}') || '/' || (public.car_page('mercedes-c300-scpub') #>> '{photos,0,label}'), 'true/Front left');  -- 0073: the studio set, labelled by shot
select test.eq('sample photo: the fleet card''s cover too', (select f #>> '{cover,sample}' from public.fleet() f where f ->> 'slug' = 'mercedes-c300-scpub'), 'true');
reset role;

select test.ok('privileges: a browser cannot show or hide the sample cars',
  not has_function_privilege('anon', 'app.sample_cars_show(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.sample_cars_hide(uuid)', 'execute')
  and not has_function_privilege('anon', 'app.sample_car_enquiry(jsonb, inet, text, uuid)', 'execute'));
