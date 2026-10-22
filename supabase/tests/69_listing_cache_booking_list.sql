-- 69: the public listing row cache, the /book car list and the real car for a sample car request (migration 0102).
-- Fixtures start with "lc".
select test.suite('69 listing cache and booking list');

-- ---------------------------------------------------------------- 1. the cache returns exactly the old rows
select test.eq('every car has a cache row', (select count(*) from vehicles v where not exists (select 1 from app.listing_row_cache c where c.vehicle_id = v.id)), 0::bigint);
select test.eq('every car: the cached row is the live row',
  (select count(*) from vehicles v where app.public_listing_row(v.id) is distinct from app.public_listing_row_live(v.id)), 0::bigint);
select test.eq('the fleet is the same rows as computed live',
  (select jsonb_agg(f order by f ->> 'slug') from public.fleet() f),
  (select jsonb_agg(r order by r ->> 'slug') from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     cross join lateral (select app.public_listing_row_live(l.vehicle_id) r) x
    where l.status = 'published' and v.management_mode <> 'turo_only' and x.r is not null));
select test.ok('anon reads the fleet and a car page', exists (select 1 from vehicle_listings where status = 'published'));
set role anon;
select test.ok('anon: fleet', (select count(*) from public.fleet()) > 0);
select test.ok('anon: the cache table is not readable', test.visible('select * from app.listing_row_cache') = -1);
reset role;

-- ---------------------------------------------------------------- 2. the rows follow every change
select test.mk_owner('lc_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type, vin)
values (test.id('vehicle:LC1'), test.id('owner:lc_own'), 2021, 'Kia', 'Forte', 'LX', 'Black', 'LC1AAA', 'economy', 'available', 'managed', 'transfer', 'Sedan', 'LCVIN0000000000A1'),
       (test.id('vehicle:LC2'), test.id('owner:lc_own'), 2019, 'Zedmobile', 'Twin', 'Base', 'Teal', 'LC2AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'LCVIN0000000000A2'),
       (test.id('vehicle:LC3'), test.id('owner:lc_own'), 2019, 'Zedmobile', 'Twin', 'Base', 'Teal', 'LC3AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'LCVIN0000000000A3'),
       (test.id('vehicle:LC4'), test.id('owner:lc_own'), 2018, 'Zedmobile', 'Solo', null, null, 'LC4AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'LCVIN0000000000A4');
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select v.id, p, p, p * 6, p * 20, 200, 35, 50000, 5000, 5000, now() - interval '1 day'
  from (values (test.id('vehicle:LC1'), 5500), (test.id('vehicle:LC2'), 4150), (test.id('vehicle:LC3'), 4150), (test.id('vehicle:LC4'), 4150)) x(id, p) join vehicles v on v.id = x.id;
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, 'lc-' || lower(v.plate), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from vehicles v
 where v.id in (test.id('vehicle:LC1'), test.id('vehicle:LC2'), test.id('vehicle:LC3'), test.id('vehicle:LC4'))
on conflict (vehicle_id) do update set status = 'published', published_at = now();
update vehicle_listings set status = 'published' where vehicle_id in (test.id('vehicle:LC1'), test.id('vehicle:LC2'), test.id('vehicle:LC3'), test.id('vehicle:LC4'));

create or replace function test.lc_same(p_label text) returns boolean language sql as $$
  select app.public_listing_row(test.id('vehicle:' || p_label)) is not distinct from app.public_listing_row_live(test.id('vehicle:' || p_label))
     and (select c.row from app.listing_row_cache c where c.vehicle_id = test.id('vehicle:' || p_label)) is not distinct from app.public_listing_row_live(test.id('vehicle:' || p_label))
$$;
select test.ok('a new car: cached and on the fleet', test.lc_same('LC1') and exists (select 1 from public.fleet() f where (f ->> 'vehicle_id')::uuid = test.id('vehicle:LC1')));
update rate_cards set daily_rate_cents = 5600 where vehicle_id = test.id('vehicle:LC1');
select test.ok('a rate changed: the row follows', test.lc_same('LC1') and (app.public_listing_row(test.id('vehicle:LC1')) ->> 'daily_rate_cents')::int = 5600);
update vehicles set colour = 'Blue' where id = test.id('vehicle:LC1');
select test.ok('the car changed: the row follows', test.lc_same('LC1') and app.public_listing_row(test.id('vehicle:LC1')) ->> 'colour' = 'Blue');
update vehicle_listings set headline = 'A blue Forte' where vehicle_id = test.id('vehicle:LC1');
select test.ok('the listing changed: the row follows', test.lc_same('LC1') and app.public_listing_row(test.id('vehicle:LC1')) ->> 'headline' = 'A blue Forte');
insert into vehicle_class_links (vehicle_id, class_code) select test.id('vehicle:LC1'), code from vehicle_classes where code <> 'economy' and is_active order by code limit 1 on conflict do nothing;
select test.ok('a class added: the row follows', test.lc_same('LC1'));
update vehicle_classes set sort_order = sort_order where code = 'economy';
select test.ok('the classes table (every row): still the same', test.lc_same('LC1') and test.lc_same('LC2'));
update vehicle_listings set status = 'unpublished' where vehicle_id = test.id('vehicle:LC4');
select test.ok('taken off the site: the row is null, as live', test.lc_same('LC4') and app.public_listing_row(test.id('vehicle:LC4')) is null);
update vehicle_listings set status = 'published' where vehicle_id = test.id('vehicle:LC4');
select test.ok('back on the site', test.lc_same('LC4') and app.public_listing_row(test.id('vehicle:LC4')) is not null);
-- a rate card that starts later: the row says until when it holds; past that it is computed live
update rate_cards set effective_to = date_trunc('day', now()) + interval '5 days' where vehicle_id = test.id('vehicle:LC4') and effective_to is null;
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select test.id('vehicle:LC4'), 9900, 9900, 59400, 198000, 200, 35, 50000, 5000, 5000, date_trunc('day', now()) + interval '5 days';
select test.ok('a later rate card: valid until it starts',
  (select valid_until from app.listing_row_cache where vehicle_id = test.id('vehicle:LC4')) = date_trunc('day', now()) + interval '5 days' and test.lc_same('LC4'));
update app.listing_row_cache set valid_until = now() - interval '1 second', row = '{"stale": true}' where vehicle_id = test.id('vehicle:LC4');
select test.ok('an expired row is never served', app.public_listing_row(test.id('vehicle:LC4')) is not distinct from app.public_listing_row_live(test.id('vehicle:LC4')));
select test.ok('the job refreshes expired rows', app.listing_cache_refresh_due() >= 1 and test.lc_same('LC4'));
delete from rate_cards where vehicle_id = test.id('vehicle:LC4') and effective_from > now();
update rate_cards set effective_to = null where vehicle_id = test.id('vehicle:LC4');
select test.ok('the later card removed: no end', (select valid_until from app.listing_row_cache where vehicle_id = test.id('vehicle:LC4')) is null);
select test.eq('after all of it, every car still matches',
  (select count(*) from vehicles v where app.public_listing_row(v.id) is distinct from app.public_listing_row_live(v.id)), 0::bigint);

-- ---------------------------------------------------------------- 3. the /book car list
select test.eq('money as the site writes it', concat_ws(' ', app.money_text(6000), app.money_text(125000), app.money_text(5950)), '$60 $1,250 $59.50');
create temp table lc_list as select x from jsonb_array_elements(public.booking_cars()) x;
select test.eq('the list is the fleet', (select count(*) from lc_list), (select count(*) from public.fleet()));
select test.eq('label: year, make, model, trim, colour, from price',
  (select x ->> 'label' from lc_list where (x ->> 'vehicle_id')::uuid = test.id('vehicle:LC1')), '2021 Kia Forte LX, blue, from $56 a day');
select test.ok('two identical cars get their car code',
  (select bool_and(x ->> 'label' = format('2019 Zedmobile Twin Base, teal (%s), from $41.50 a day', v.car_code)) and count(*) = 2
     from lc_list join vehicles v on v.id = (x ->> 'vehicle_id')::uuid where v.id in (test.id('vehicle:LC2'), test.id('vehicle:LC3'))));
select test.eq('a car without trim and colour, not a duplicate: no code',
  (select x ->> 'label' from lc_list where (x ->> 'vehicle_id')::uuid = test.id('vehicle:LC4')), '2018 Zedmobile Solo, from $41.50 a day');
update vehicles set year_approximate = true where id = test.id('vehicle:LC4');
select test.eq('a year not confirmed: no year',
  (select x ->> 'label' from jsonb_array_elements(public.booking_cars()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:LC4')), 'Zedmobile Solo, from $41.50 a day');
select test.eq('and it says so', (select x ->> 'year_confirmed' from jsonb_array_elements(public.booking_cars()) x where (x ->> 'vehicle_id')::uuid = test.id('vehicle:LC4')), 'false');
update vehicles set year_approximate = false where id = test.id('vehicle:LC4');
select test.ok('sorted by price, then name', (select bool_and(ok) from (
  select (lag(x ->> 'from_cents') over w)::bigint < (x ->> 'from_cents')::bigint
      or ((lag(x ->> 'from_cents') over w)::bigint = (x ->> 'from_cents')::bigint
          and regexp_replace(lag(x ->> 'label') over w, '( \([^)]*\))?, from \$[0-9,.]+ a day$', '') <= regexp_replace(x ->> 'label', '( \([^)]*\))?, from \$[0-9,.]+ a day$', ''))
      or lag(x ->> 'label') over w is null ok
    from jsonb_array_elements(public.booking_cars()) with ordinality t(x, i) window w as (order by i)) s));
select test.ok('only id, slug, label and price (no full rows)', (select bool_and(not (x ? 'photos') and not (x ? 'headline') and x ? 'label' and x ? 'slug' and x ? 'vehicle_id' and x ? 'from_cents')
  from jsonb_array_elements(public.booking_cars()) x));
select slug as lc1_slug from vehicle_listings where vehicle_id = test.id('vehicle:LC1') \gset
set role anon;
select test.eq('anon: one car of the form, with its handover places', public.booking_car(:'lc1_slug') ->> 'owner_location', 'false');
select test.ok('anon: not a car of the site: null', public.booking_car('no-such-car') is null);
reset role;

-- ---------------------------------------------------------------- 4. a request on a sample car: a real car free for the dates
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type, is_sample, vin)
values (test.id('vehicle:LCS'), test.id('owner:lc_own'), 2023, 'Kia', 'Forte', 'EX', 'White', 'LCSAAA', 'economy', 'available', 'managed', 'transfer', 'Sedan', true, 'LCVIN0000000000S1'),
       (test.id('vehicle:LCT'), test.id('owner:lc_own'), 2023, 'Zedmobile', 'Alone', null, 'White', 'LCTAAA', 'exotic', 'available', 'managed', 'transfer', 'Coupe', true, 'LCVIN0000000000S2');
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select v, 6400, 6400, 38400, 128000, 200, 35, 50000, 5000, 5000, now() - interval '1 day' from unnest(array[test.id('vehicle:LCS'), test.id('vehicle:LCT')]) v;
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v, 'lc-sample-' || substr(v::text, 1, 8), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from unnest(array[test.id('vehicle:LCS'), test.id('vehicle:LCT')]) v
on conflict (vehicle_id) do update set status = 'published';
select test.eq('the same make and model, free: offered first',
  app.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') ->> 'vehicle_id', test.id('vehicle:LC1')::text);
select test.eq('named with its year', app.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') ->> 'name', '2021 Kia Forte');
select test.eq('and its kind of match', app.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') ->> 'match', 'same_model');
insert into vehicle_calendar_blocks (vehicle_id, starts_at, ends_at, source, reason)
values (test.id('vehicle:LC1'), now() + interval '19 days', now() + interval '25 days', 'staff', 'service');
select test.ok('the Forte is busy: another real car of the same class and body, or none',
  coalesce(app.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') ->> 'vehicle_id', '') <> test.id('vehicle:LC1')::text);
select test.ok('a similar car is the same class and body near the price', coalesce((select v.class = 'economy' and abs(app.listing_from_cents(app.public_listing_row(v.id)) - 6400) <= 2560
  from vehicles v where v.id = (app.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') ->> 'vehicle_id')::uuid), true));
select test.ok('no real car of the kind: none', app.sample_car_match(test.id('vehicle:LCT'), now() + interval '20 days', now() + interval '23 days') is null);
select test.ok('no dates: none', app.sample_car_match(test.id('vehicle:LCS'), null, null) is null);
select test.ok('a real car asked about: none', app.sample_car_match(test.id('vehicle:LC1'), now() + interval '30 days', now() + interval '33 days') is null);
delete from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:LC1') and reason = 'service' and source = 'staff';
set role anon;
select test.ok('anon may ask', public.sample_car_match(test.id('vehicle:LCS'), now() + interval '20 days', now() + interval '23 days') is not null);
reset role;

-- the enquiry keeps the match and the task names it
update vehicles set sample_bookable = false where id = test.id('vehicle:LCS');
create temp table lc_enq as select public.submit_booking_request(jsonb_build_object('vehicle_id', test.id('vehicle:LCS'), 'request_key', 'lc-enquiry-1',
  'pickup_at', now() + interval '20 days', 'return_at', now() + interval '23 days', 'renter', jsonb_build_object('full_name', 'Lc Person', 'email', 'lc@example.com'))) r;
select test.ok('an enquiry, with the real car', (select (r ->> 'enquiry')::boolean and r -> 'suggested' ->> 'vehicle_id' = test.id('vehicle:LC1')::text from lc_enq));
select test.ok('kept on the lead', exists (select 1 from leads where kind = 'sample_car' and payload ->> 'request_key' = 'lc-enquiry-1' and payload -> 'suggested' ->> 'slug' is not null));
select test.ok('the customer service task names it', exists (select 1 from tasks t join leads l on t.dedupe_key = 'sample-enquiry:' || l.id
  where l.payload ->> 'request_key' = 'lc-enquiry-1' and t.title like '%Free: 2021 Kia Forte LX%' and t.detail like '%A real car free for these dates%'));
select r ->> 'booking_number' as lc_eq1 from lc_enq \gset
set role anon;
select test.ok('the received page knows a real car is waiting', public.enquiry_has_match(:'lc_eq1'));
select test.ok('an unknown enquiry: no', not public.enquiry_has_match('EQ-0'));
reset role;
create temp table lc_enq2 as select public.submit_booking_request(jsonb_build_object('vehicle_id', test.id('vehicle:LCT'), 'request_key', 'lc-enquiry-2',
  'pickup_at', now() + interval '20 days', 'return_at', now() + interval '23 days', 'renter', jsonb_build_object('full_name', 'Lc Person', 'email', 'lc@example.com'))) r;
select test.ok('no match: the enquiry as before', (select (r ->> 'enquiry')::boolean and not (r ? 'suggested') from lc_enq2)
  and not public.enquiry_has_match((select r ->> 'booking_number' from lc_enq2)));
