-- 0115: SEO coverage (owner, October 23, 2026; docs/seo/coverage-2026-10-23.md). Data and two small schema changes.
-- 1. More search terms, the conventions of 0095 and 0098: a term with its own pages where the intent differs (a chauffeur
--    "car service", a loaner while your car is in the shop, rent-to-own, a car subscription), a synonym (canonical_slug)
--    where the intent is the same as an existing term ("car rentals", "auto financing", "window tinting"): a synonym's
--    page is served, points its canonical to the term's page and stays out of the sitemaps. A synonym takes its term's
--    vertical, rules, served, landing page, service, lead kind, note and questions, so it never says more than the
--    term does. The words stay within the booking rules: rentals as the rental terms say them; the chauffeur service by
--    request (served 'request', a person replies); buying, financing and leasing never offered (we are not a dealer,
--    a lender or a leasing company); body repair, never mechanical work; brand names (Uber, Uber Eats, Amazon Flex)
--    only to describe the work, with the not-affiliated sentence. Mechanical repair, oil changes, tires and towing get
--    no page: CarmaCars does not do them, and a page for each would promise beyond what we book.
-- 2. vehicle_catalog_years.year from 1900 (Wikidata's models before 1981, the import's --wikidata, names only).
-- 3. Program settings vpage_extra_sources: the further catalog sources the catalog workflow includes (vpicdb, nrcan,
--    wikidata). Empty by default: they wait until the database has moved off the 1 GB server, then stay on (every import
--    replaces the whole catalog, so a source switched off again takes its pages away).
-- No applied migration is edited.

-- ================================================================ 1. terms with their own pages
insert into place_terms (slug, vertical, phrase, title, match, served, landing_slug, lead_kind, intent_note, faq, sort_order) values
  -- pickup, and a car while yours is in the shop (the rental and insurance replacement rules)
  ('car-rental-pickup', 'rental', 'car rental pickup', 'Car Rental Pickup', '{}', 'yes', 'car-delivery', null,
   'Pick the car up at our location in Toronto at no charge, or have it delivered to your address for the delivery fee shown on each car''s page.',
   '[{"question": "Is pickup free?", "answer": "Yes. Picking the car up at our location costs nothing; delivery to your address is priced on each car''s page and in your offer."}]', 760),
  ('rental-car-while-car-is-in-the-shop', 'rental', 'rental car while your car is in the shop', 'Rental Car While Yours Is in the Shop', '{}', 'yes', 'insurance-replacement', null,
   'A car to drive while yours is being repaired, by the day, the week or up to {{maxDays}} days at a time. After a collision, your insurer may pay when your adjuster approves the rental, and we can bill them directly.',
   '[{"question": "Will my insurance pay for the rental?", "answer": "After a collision, often yes, when your adjuster approves it. We can bill your insurance company directly. Otherwise you pay the rate shown on each car''s page."}]', 770),
  ('loaner-car', 'rental', 'loaner car', 'Loaner Car', '{}', 'yes', 'insurance-replacement', null,
   'Need a car while yours is at the dealer or the shop? Rent one by the day or the week, delivered to you. After a collision, your insurer may pay when your adjuster approves the rental.',
   '[{"question": "Can you deliver the car to the shop?", "answer": "We deliver to an address within our delivery area for the fee shown on each car''s page, or you pick it up at our location at no charge."}]', 780),
  ('courtesy-car', 'rental', 'courtesy car', 'Courtesy Car', '{}', 'yes', 'insurance-replacement', null,
   'A car while yours is off the road, rented by the day or the week. After a collision, your insurer may pay when your adjuster approves the rental, and we can bill them directly.',
   '[{"question": "Is a courtesy car free?", "answer": "No. You pay the rental rate unless your insurer approves the rental after a collision, in which case we can bill them directly."}]', 790),
  ('replacement-car-rental', 'rental', 'replacement car rental', 'Replacement Car Rental', '{}', 'yes', 'insurance-replacement', null,
   'A replacement car while yours is repaired or stolen. When your adjuster approves a rental, we can bill your insurance company directly, and we deliver the car to you.',
   '[{"question": "Who pays for a replacement car?", "answer": "Your insurer, when your adjuster approves the rental; we can bill them directly. Otherwise you pay the rate shown on each car''s page."}]', 800),
  -- leasing and subscriptions answered with a rental we really offer
  ('car-subscription', 'rental', 'car subscription', 'Car Subscription', '{}', 'yes', 'monthly', null,
   'No subscription contract: rent month to month instead. One booking runs up to {{maxDays}} days and renews with a new agreement, and you can stop at the end of any booking.',
   '[{"question": "Is there a long contract?", "answer": "No. Each booking runs up to {{maxDays}} days. Renew it with a new agreement, or stop at the end of it."}]', 810),
  ('short-term-car-lease', 'rental', 'short term car lease', 'Short Term Car Lease', '{}', 'yes', 'monthly', null,
   'We do not lease cars. A monthly rental is the short-term alternative: one booking runs up to {{maxDays}} days, renews with a new agreement, and you can stop at the end of any booking.',
   '[{"question": "Is this a lease?", "answer": "No. It is a rental: each booking runs up to {{maxDays}} days and renews with a new agreement. There is no lease and no buyout."}]', 820),
  -- gig work beyond 0098's list
  ('amazon-flex-car-rental', 'rental', 'Amazon Flex car rental', 'Car Rental for Amazon Flex Drivers', '{}', 'yes', null, null,
   'Use your rental for Amazon Flex delivery work. Tell us when you book. Weekly and monthly rates first: trips of {{weekFrom}} days or more use the weekly rate, and one booking runs up to {{maxDays}} days and renews. Amazon Flex is named only to describe the work; CarmaCars is not affiliated with, approved or endorsed by Amazon.',
   '[{"question": "Is there a weekly or monthly rate?", "answer": "Yes. Trips of {{weekFrom}} days or more use the weekly rate, and a booking of up to {{maxDays}} days never costs more than the monthly rate. Each car shows its rates on its page."}, {"question": "Can I use the car for Amazon Flex work?", "answer": "Yes. Tell us when you book. CarmaCars is not affiliated with or approved by Amazon."}]', 830),
  ('uber-black-car-rental', 'rental', 'Uber Black car rental', 'Premium Car Rental for Uber Drivers', '{"classes": ["premium", "luxury", "exotic"]}', 'yes', null, null,
   'Premium and luxury cars by the week or the month. Uber decides which cars and model years qualify for Uber Black or Uber Comfort in your city: check with Uber before you book. Uber is named only to describe the work; CarmaCars is not affiliated with, approved or endorsed by Uber.',
   '[{"question": "Will this car qualify for Uber Black?", "answer": "Uber decides that for each city, car and model year. Check with Uber before you book; CarmaCars is not affiliated with or approved by Uber."}]', 840),
  -- the chauffeur service by request: "car service", "black car", the black SUVs ("black trucks"), limos, airport runs
  ('car-service', 'rental', 'car service', 'Car Service', '{}', 'request', null, 'place_request',
   'Car service with a professional driver, booked by the hour through our chauffeur service, two hours minimum: a luxury car, SUV or van. Send the date and the trip, and we reply with the vehicle and the price.', '[]', 850),
  ('black-car-service', 'rental', 'black car service', 'Black Car Service', '{}', 'request', null, 'place_request',
   'A professional driver with a luxury car or SUV, booked by the hour through our chauffeur service, two hours minimum. Send the date and the trip, and we reply with the vehicle and the price.', '[]', 860),
  ('black-suv-service', 'rental', 'black SUV service', 'Black SUV Service', '{}', 'request', null, 'place_request',
   'A full-size luxury SUV with a professional driver, booked by the hour through our chauffeur service, two hours minimum. Send the date, the trip and how many people, and we reply with the vehicle and the price.', '[]', 870),
  ('executive-car-service', 'rental', 'executive car service', 'Executive Car Service', '{}', 'request', null, 'place_request',
   'A luxury sedan or SUV with a professional driver for meetings, roadshows and visitors, booked by the hour through our chauffeur service, two hours minimum. Send the details and we reply with the vehicle and the price.', '[]', 880),
  ('limo-service', 'rental', 'limo service', 'Limo Service', '{}', 'request', null, 'place_request',
   'Our chauffeur service books a professional driver with a luxury car, SUV or van by the hour, two hours minimum, for weddings, nights out and events. Send the date and the trip, and we reply with the vehicles we can offer and the price.', '[]', 890),
  ('airport-car-service', 'rental', 'airport car service', 'Airport Car Service', '{}', 'request', null, 'place_request',
   'A driver to or from the airport with a luxury car, SUV or van, booked by the hour through our chauffeur service, two hours minimum. Send the flight, the address and how many people, and we reply with the vehicle and the price.', '[]', 900)
on conflict do nothing;

insert into place_terms (slug, vertical, phrase, title, served, lead_kind, intent_note, sort_order) values
  ('new-cars', 'sale', 'new cars', 'New Cars', 'request', 'buyer', 'We do not sell new cars. Rent the model you are considering for a few days first, then buy from a dealer with confidence.', 150),
  ('trucks-for-sale', 'sale', 'trucks for sale', 'Trucks for Sale', 'request', 'buyer', 'We do not sell trucks. Tell us the truck you are looking for and we will help where we can, and you can rent a pickup first when one is in our fleet.', 160),
  ('suvs-for-sale', 'sale', 'SUVs for sale', 'SUVs for Sale', 'request', 'buyer', 'We do not sell SUVs. Rent the SUV you are considering for a few days, with your family and your luggage, before you buy one.', 170),
  ('rent-to-own-cars', 'sale', 'rent to own cars', 'Rent to Own Cars', 'request', 'finance', 'We do not offer rent to own: a rental never becomes a purchase. A monthly rental, renewed with a new agreement up to {{maxDays}} days at a time, gives you a car while you save or rebuild your credit.', 180)
on conflict do nothing;

insert into place_terms (slug, vertical, phrase, title, served, service_code, lead_kind, intent_note, sort_order) values
  ('car-repair', 'bodyshop', 'car repair', 'Car Repair', 'yes', 'collision', 'bodyshop', 'Body repair: collisions, dents, scratches, bumpers, paint and windshield chips. We do not do mechanical work such as engines, brakes or oil changes.', 210),
  ('auto-repair', 'bodyshop', 'auto repair', 'Auto Repair', 'yes', 'collision', 'bodyshop', 'Auto body repair after a collision, dents, scratches, paint and windshield chips. We do not do mechanical repairs such as engines, brakes or oil changes.', 220)
on conflict do nothing;

-- ================================================================ synonyms: the term's pages, by another name
insert into place_terms (slug, vertical, phrase, title, canonical_slug, match, served, landing_slug, service_code, lead_kind, intent_note, faq, sort_order)
select x.slug, t.vertical, x.phrase, x.title, t.slug, t.match, t.served, t.landing_slug, t.service_code, t.lead_kind, t.intent_note, t.faq, t.sort_order + 1
  from (values
    -- rental
    ('car-rentals', 'car rentals', 'Car Rentals', 'car-rental'),
    ('car-rental-service', 'car rental service', 'Car Rental Service', 'car-rental'),
    ('car-rental-company', 'car rental company', 'Car Rental Company', 'car-rental'),
    ('car-rental-agency', 'car rental agency', 'Car Rental Agency', 'car-rental'),
    ('rent-a-car-near-me', 'rent a car near me', 'Rent a Car Near Me', 'car-rental-near-me'),
    ('vehicle-hire', 'vehicle hire', 'Vehicle Hire', 'vehicle-rental'),
    ('cheap-rental-cars', 'cheap rental cars', 'Cheap Rental Cars', 'cheap-car-rental'),
    ('cheap-car-hire', 'cheap car hire', 'Cheap Car Hire', 'cheap-car-rental'),
    ('luxury-car-hire', 'luxury car hire', 'Luxury Car Hire', 'luxury-car-rental'),
    ('luxury-rental-cars', 'luxury rental cars', 'Luxury Rental Cars', 'luxury-car-rental'),
    ('exotic-car-hire', 'exotic car hire', 'Exotic Car Hire', 'exotic-car-rental'),
    ('van-hire', 'van hire', 'Van Hire', 'van-rental'),
    ('pickup-truck-rental', 'pickup truck rental', 'Pickup Truck Rental', 'truck-rental'),
    ('black-truck-rental', 'black truck rental', 'Black Truck Rental', 'truck-rental'),
    ('black-suv-rental', 'black SUV rental', 'Black SUV Rental', 'suv-rental'),
    ('monthly-car-hire', 'monthly car hire', 'Monthly Car Hire', 'monthly-car-rental'),
    ('car-rental-by-the-month', 'car rental by the month', 'Car Rental by the Month', 'monthly-car-rental'),
    ('weekly-car-hire', 'weekly car hire', 'Weekly Car Hire', 'weekly-car-rental'),
    ('rental-car-delivery', 'rental car delivery', 'Rental Car Delivery', 'car-rental-delivery'),
    ('car-rental-delivered-to-you', 'car rental delivered to you', 'Car Rental Delivered to You', 'car-rental-delivery'),
    ('airport-rental-car', 'airport rental car', 'Airport Rental Car', 'airport-car-rental'),
    ('airport-pickup-car-rental', 'airport pickup car rental', 'Airport Pickup Car Rental', 'airport-car-rental'),
    ('insurance-rental-car', 'insurance rental car', 'Insurance Rental Car', 'insurance-replacement-rental'),
    ('insurance-replacement-car', 'insurance replacement car', 'Insurance Replacement Car', 'insurance-replacement-rental'),
    ('direct-billing-car-rental', 'direct billing car rental', 'Direct Billing Car Rental', 'insurance-replacement-rental'),
    ('accident-replacement-car', 'accident replacement car', 'Accident Replacement Car', 'collision-replacement-car'),
    ('rental-car-during-repairs', 'rental car during repairs', 'Rental Car During Repairs', 'rental-car-while-car-is-in-the-shop'),
    ('courtesy-vehicle', 'courtesy vehicle', 'Courtesy Vehicle', 'courtesy-car'),
    ('loaner-vehicle', 'loaner vehicle', 'Loaner Vehicle', 'loaner-car'),
    ('replacement-vehicle', 'replacement vehicle', 'Replacement Vehicle', 'replacement-car-rental'),
    ('mini-lease', 'mini lease', 'Mini Lease', 'short-term-car-lease'),
    ('uber-car-rental', 'Uber car rental', 'Uber Car Rental', 'uber-rental-car'),
    ('rent-a-car-for-uber', 'rent a car for Uber', 'Rent a Car for Uber', 'uber-rental-car'),
    ('lyft-car-rental', 'Lyft car rental', 'Lyft Car Rental', 'lyft-rental-car'),
    ('uber-eats-rental-car', 'Uber Eats rental car', 'Uber Eats Rental Car', 'uber-eats-car-rental'),
    ('doordash-rental-car', 'DoorDash rental car', 'DoorDash Rental Car', 'doordash-car-rental'),
    ('rideshare-rental', 'rideshare rental', 'Rideshare Rental', 'rideshare-car-rental'),
    ('courier-car-rental', 'courier car rental', 'Courier Car Rental', 'delivery-driver-car-rental'),
    ('chauffeur', 'chauffeur', 'Chauffeur', 'chauffeur-service'),
    ('chauffeured-car-service', 'chauffeured car service', 'Chauffeured Car Service', 'chauffeur-service'),
    ('private-driver', 'private driver', 'Private Driver', 'car-with-driver'),
    ('hire-a-driver', 'hire a driver', 'Hire a Driver', 'car-with-driver'),
    ('luxury-car-service', 'luxury car service', 'Luxury Car Service', 'black-car-service'),
    ('black-truck-service', 'black truck service', 'Black Truck Service', 'black-suv-service'),
    ('limousine-service', 'limousine service', 'Limousine Service', 'limo-service'),
    ('airport-transfer', 'airport transfer', 'Airport Transfer', 'airport-car-service'),
    -- buying, financing, leasing (never offered)
    ('cars-for-sale-near-me', 'cars for sale near me', 'Cars for Sale Near Me', 'cars-for-sale'),
    ('car-dealer', 'car dealer', 'Car Dealer', 'car-dealership'),
    ('used-car-dealership', 'used car dealership', 'Used Car Dealership', 'car-dealership'),
    ('pre-owned-cars', 'pre-owned cars', 'Pre-Owned Cars', 'used-cars'),
    ('second-hand-cars', 'second hand cars', 'Second Hand Cars', 'used-cars'),
    ('new-cars-for-sale', 'new cars for sale', 'New Cars for Sale', 'new-cars'),
    ('auto-financing', 'auto financing', 'Auto Financing', 'car-financing'),
    ('car-finance', 'car finance', 'Car Finance', 'car-financing'),
    ('vehicle-financing', 'vehicle financing', 'Vehicle Financing', 'car-financing'),
    ('car-loan', 'car loan', 'Car Loan', 'auto-loans'),
    ('car-loans', 'car loans', 'Car Loans', 'auto-loans'),
    ('auto-loan', 'auto loan', 'Auto Loan', 'auto-loans'),
    ('bad-credit-car-financing', 'bad credit car financing', 'Bad Credit Car Financing', 'bad-credit-car-loans'),
    ('bad-credit-auto-loans', 'bad credit auto loans', 'Bad Credit Auto Loans', 'bad-credit-car-loans'),
    ('car-lease', 'car lease', 'Car Lease', 'car-leasing'),
    ('auto-lease', 'auto lease', 'Auto Lease', 'car-leasing'),
    ('auto-leasing', 'auto leasing', 'Auto Leasing', 'car-leasing'),
    ('vehicle-leasing', 'vehicle leasing', 'Vehicle Leasing', 'car-leasing'),
    ('lease-transfer', 'lease transfer', 'Lease Transfer', 'lease-takeover'),
    ('sell-your-car', 'sell your car', 'Sell Your Car', 'sell-my-car'),
    ('we-buy-cars', 'we buy cars', 'We Buy Cars', 'sell-my-car'),
    ('cash-for-cars', 'cash for cars', 'Cash for Cars', 'sell-my-car'),
    ('car-trade-in', 'car trade in', 'Car Trade In', 'trade-in'),
    -- body shop
    ('auto-repair-shop', 'auto repair shop', 'Auto Repair Shop', 'auto-repair'),
    ('car-body-shop', 'car body shop', 'Car Body Shop', 'auto-body-shop'),
    ('fender-bender-repair', 'fender bender repair', 'Fender Bender Repair', 'collision-repair'),
    ('car-accident-repair', 'car accident repair', 'Car Accident Repair', 'accident-repair'),
    ('car-dent-repair', 'car dent repair', 'Car Dent Repair', 'dent-repair'),
    ('dent-removal', 'dent removal', 'Dent Removal', 'dent-repair'),
    ('pdr', 'PDR', 'PDR', 'paintless-dent-repair'),
    ('car-scratch-repair', 'car scratch repair', 'Car Scratch Repair', 'scratch-repair'),
    ('bumper-replacement', 'bumper replacement', 'Bumper Replacement', 'bumper-repair'),
    ('car-paint-shop', 'car paint shop', 'Car Paint Shop', 'car-painting'),
    ('auto-paint-shop', 'auto paint shop', 'Auto Paint Shop', 'car-painting'),
    ('auto-glass-repair', 'auto glass repair', 'Auto Glass Repair', 'windshield-repair'),
    ('windshield-chip-repair', 'windshield chip repair', 'Windshield Chip Repair', 'windshield-repair'),
    -- detailing
    ('auto-detail', 'auto detail', 'Auto Detail', 'auto-detailing'),
    ('car-detail', 'car detail', 'Car Detail', 'car-detailing'),
    ('mobile-car-detailing', 'mobile car detailing', 'Mobile Car Detailing', 'mobile-detailing'),
    ('mobile-car-wash', 'mobile car wash', 'Mobile Car Wash', 'mobile-detailing'),
    ('interior-car-cleaning', 'interior car cleaning', 'Interior Car Cleaning', 'interior-detailing'),
    ('car-interior-cleaning', 'car interior cleaning', 'Car Interior Cleaning', 'interior-detailing'),
    ('car-shampoo', 'car shampoo', 'Car Shampoo', 'upholstery-cleaning'),
    ('window-tinting', 'window tinting', 'Window Tinting', 'window-tint'),
    ('car-window-tinting', 'car window tinting', 'Car Window Tinting', 'window-tint'),
    ('car-wrapping', 'car wrapping', 'Car Wrapping', 'car-wrap'),
    ('paint-protection', 'paint protection', 'Paint Protection', 'paint-protection-film'),
    ('ceramic-car-coating', 'ceramic car coating', 'Ceramic Car Coating', 'ceramic-coating'),
    ('nano-coating', 'nano coating', 'Nano Coating', 'ceramic-coating'),
    ('car-polishing', 'car polishing', 'Car Polishing', 'polishing'),
    ('car-waxing', 'car waxing', 'Car Waxing', 'wax')
  ) x(slug, phrase, title, target)
  join place_terms t on t.slug = x.target and t.canonical_slug is null
on conflict do nothing;

-- ================================================================ 2. catalog years from 1900
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'vehicle_catalog_years'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'year' and pg_get_constraintdef(oid) ~ '1980' loop
    execute format('alter table vehicle_catalog_years drop constraint %I', c);
  end loop;
end $$;
alter table vehicle_catalog_years add constraint vehicle_catalog_years_year_check check (year between 1900 and 2100);

-- ================================================================ 3. the further catalog sources
alter table program_settings
  add column if not exists vpage_extra_sources text[] not null default '{}'
    check (vpage_extra_sources <@ array['vpicdb', 'nrcan', 'wikidata']::text[]);
comment on column program_settings.vpage_extra_sources is 'Further sources the catalog workflow adds to the vehicle catalog (0115): vpicdb (the vPIC database export: heavy trucks, buses, low-volume makes, trims from the VIN patterns), nrcan (Natural Resources Canada Fuel Consumption Ratings: Canadian-market models and figures), wikidata (models before 1981). Empty until the database has moved off the 1 GB server; once on, keep them on (each import replaces the whole catalog). docs/seo/coverage-2026-10-23.md';

-- ================================================================ 4. crawl priority and click depth (owner, October 23:
-- "speed up the crawl and get as many pages indexed as possible")
-- 4a. The priority sitemap (/sitemap-priority.xml, first in /sitemap.xml, at most 50,000 addresses): the make pages and
-- the popular models (vehicle_catalog_popular) with their years and trims from vpage_popular_from_year, as the stored
-- vehicle sitemap lists them (indexed pages only); then the Ontario cities and neighbourhoods nearest our location
-- (the delivery reach first) for the first rental, buying, detailing and body shop terms. The fleet's car pages and the
-- landing pages are added by the app from sitemap_all. Stored by a job (every 30 minutes) so the file is one read;
-- lastmod: the vehicle page's stored date, the place's own date (as the place sitemaps).
create table if not exists app.sitemap_priority_cache (
  path text primary key,
  lastmod timestamptz,
  sort integer not null
);
alter table app.sitemap_priority_cache enable row level security;
revoke all on app.sitemap_priority_cache from public, anon, authenticated;

create or replace function app.sitemap_priority_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  o jsonb := app.place_origin();
  v_vehicles integer;
  v_terms integer;
  v_per integer;
  n integer;
begin
  perform set_config('statement_timeout', '120s', true);
  create temp table if not exists _spc (path text primary key, lastmod timestamptz, sort integer) on commit drop;
  truncate _spc;
  -- the vehicles: every make, then the popular models in their order, model page first, newest years first
  insert into _spc (path, lastmod, sort)
    select c.path, c.lastmod, row_number() over (order by c.path)::integer from app.vehicle_sitemap_paths_cache c where c.base = 'makes'
    on conflict do nothing;
  insert into _spc (path, lastmod, sort)
    select x.path, x.lastmod, 10000 + row_number() over (order by x.psort, x.yr desc nulls first, x.path)::integer
      from (select c.path, c.lastmod, p.sort psort, nullif(split_part(c.path, '/', 5), '')::integer yr
              from vehicle_catalog_popular p
              join app.vehicle_sitemap_paths_cache c on c.base in (p.make_slug || '-models', p.make_slug || '-years', p.make_slug || '-trims')
               and (c.path = app.vpage_path(p.make_slug, p.model_slug) or c.path like app.vpage_path(p.make_slug, p.model_slug) || '/%')) x
     where x.yr is null or x.yr >= s.vpage_popular_from_year
     order by x.psort, x.yr desc nulls first, x.path
     limit 15000
    on conflict do nothing;
  select count(*) into v_vehicles from _spc;
  -- the place pages: the first terms of each family whose pages are in search, for the Ontario places nearest us
  create temp table if not exists _spt on commit drop as select vertical, slug, sort_order, landing_slug from place_terms limit 0;
  truncate _spt;
  insert into _spt
    select t.vertical, t.slug, t.sort_order, t.landing_slug from (
      select t.*, row_number() over (partition by t.vertical order by t.sort_order, t.slug) rn from place_terms t
       where t.is_active and t.canonical_slug is null
         and case t.vertical when 'rental' then s.place_hubs_index when 'sale' then s.sale_hubs_index when 'bodyshop' then s.bodyshop_hubs_index else s.detailing_hubs_index end
         and (not s.place_quality_gate or t.vertical <> 'rental' or t.served = 'request' or app.seo_real_count(t.match) >= 1)) t
     where t.rn <= case t.vertical when 'rental' then 12 when 'sale' then 3 else 4 end;
  select count(*) into v_terms from _spt;
  v_per := case when v_terms > 0 then greatest(0, (49000 - v_vehicles - 500) / v_terms) else 0 end;
  insert into _spc (path, lastmod, sort)
    select app.place_hub_path(t.vertical, t.slug, p.slug), p.updated_on::timestamptz,
           100000 + (row_number() over (order by p.rk, t.vertical <> 'rental', t.sort_order, t.slug))::integer
      from (select p.*, row_number() over (order by (p.lat - (o ->> 'lat')::real) ^ 2 + ((p.lng - (o ->> 'lng')::real) * cos(radians((o ->> 'lat')::numeric)::real)) ^ 2, p.id) rk
              from places p join place_regions r on r.id = p.region_id and r.is_enabled and r.code = 'CA-ON'
             where p.is_active and p.kind in (4, 5, 6) and p.lat is not null
               and (not s.place_quality_gate or app.distance_km((o ->> 'lat')::numeric, (o ->> 'lng')::numeric, p.lat::numeric, p.lng::numeric) <= s.place_delivery_reach_km)) p
      cross join _spt t
     where p.rk <= v_per
       and not (t.vertical = 'rental' and t.slug = 'car-rental' and p.landing_slug is not null)
       and not (t.vertical = 'rental' and p.slug = 'toronto' and t.landing_slug is not null)
    on conflict do nothing;
  delete from app.sitemap_priority_cache c where not exists (select 1 from _spc x where x.path = c.path);
  insert into app.sitemap_priority_cache (path, lastmod, sort) select path, lastmod, sort from _spc
    on conflict (path) do update set lastmod = excluded.lastmod, sort = excluded.sort
    where (app.sitemap_priority_cache.lastmod, app.sitemap_priority_cache.sort) is distinct from (excluded.lastmod, excluded.sort);
  select count(*) into n from app.sitemap_priority_cache;
  return n;
end $$;

create or replace function public.sitemap_priority() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', c.path, 'lastmod', c.lastmod) order by c.sort, c.path), '[]'::jsonb)
    from (select * from app.sitemap_priority_cache order by sort, path limit 49500) c
$$;

-- 4b. The place directory (/places and /places/<n>): every place with pages, a thousand a page by id (a primary key
-- range, like the place sitemaps), so any place page is three clicks from the home page (footer Browse, the directory,
-- a page of it) and any term page four. The index of pages (which regions each page holds) is stored by the same job.
create table if not exists app.place_directory_cache (
  page integer primary key,
  places integer not null,
  regions text[] not null default '{}',
  first_name text,
  last_name text
);
alter table app.place_directory_cache enable row level security;
revoke all on app.place_directory_cache from public, anon, authenticated;

create or replace function app.place_directory_listable(p places) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p.is_active and p.kind <> 8 and app.place_enabled(p)
$$;

create or replace function app.place_directory_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  perform set_config('statement_timeout', '120s', true);
  create temp table if not exists _pdc (page integer primary key, places integer, regions text[], first_name text, last_name text) on commit drop;
  truncate _pdc;
  insert into _pdc
    select (p.id - 1) / 1000 + 1, count(*), array_agg(distinct coalesce(r.name, case p.country when 'CA' then 'Canada' when 'US' then 'United States' else 'Mexico' end)),
           (array_agg(p.name order by p.id))[1], (array_agg(p.name order by p.id desc))[1]
      from places p left join place_regions r on r.id = p.region_id
     where p.is_active and p.kind <> 8 and (r.is_enabled or (p.kind = 1 and exists (select 1 from place_regions x where x.country = p.country and x.is_enabled)))
     group by 1;
  delete from app.place_directory_cache c where not exists (select 1 from _pdc x where x.page = c.page);
  insert into app.place_directory_cache (page, places, regions, first_name, last_name) select page, places, regions, first_name, last_name from _pdc
    on conflict (page) do update set places = excluded.places, regions = excluded.regions, first_name = excluded.first_name, last_name = excluded.last_name
    where (app.place_directory_cache.places, app.place_directory_cache.regions, app.place_directory_cache.first_name, app.place_directory_cache.last_name)
          is distinct from (excluded.places, excluded.regions, excluded.first_name, excluded.last_name);
  select count(*) into n from app.place_directory_cache;
  return n;
end $$;

-- the stored index; before the first refresh (a new database, a first load) the live grouping
create or replace function public.place_directory_index() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not exists (select 1 from app.place_directory_cache) then
    return (select coalesce(jsonb_agg(jsonb_build_object('page', x.page, 'places', x.n, 'regions', x.regions, 'first', x.first_name, 'last', x.last_name) order by x.page), '[]'::jsonb)
              from (select (p.id - 1) / 1000 + 1 page, count(*) n, array_agg(distinct coalesce(r.name, p.country)) regions,
                           (array_agg(p.name order by p.id))[1] first_name, (array_agg(p.name order by p.id desc))[1] last_name
                      from places p left join place_regions r on r.id = p.region_id
                     where app.place_directory_listable(p) group by 1) x);
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('page', c.page, 'places', c.places, 'regions', c.regions, 'first', c.first_name, 'last', c.last_name) order by c.page), '[]'::jsonb)
            from app.place_directory_cache c);
end $$;

-- one page: its places with their parent's name, by id range (the primary key); null past the last page
create or replace function public.place_directory_page(p_page integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when p_page between 1 and 100000 then
    (select coalesce(jsonb_agg(jsonb_build_object('slug', p.slug, 'name', p.name, 'kind', app.place_kind(p.kind), 'country', p.country,
                                                  'region', (select r.code from place_regions r where r.id = p.region_id),
                                                  'region_name', (select r.name from place_regions r where r.id = p.region_id),
                                                  'parent', (select q.name from places q where q.id = p.parent_id)) order by p.id), '[]'::jsonb)
       from places p where p.id > (p_page - 1) * 1000 and p.id <= p_page * 1000 and app.place_directory_listable(p)) end
$$;

-- 4c. Every make with its models, for /makes (two clicks to any model page, three to a year, four to a trim)
create or replace function public.vehicle_make_index() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', mk.slug, 'name', mk.name,
           'models', (select coalesce(jsonb_agg(jsonb_build_object('slug', m.slug, 'name', m.name) order by m.name), '[]'::jsonb) from vehicle_catalog_models m where m.make_slug = mk.slug))
         order by mk.name), '[]'::jsonb)
    from vehicle_catalog_makes mk
$$;

revoke all on function app.sitemap_priority_refresh(), app.place_directory_refresh() from public, anon, authenticated;
grant execute on function app.sitemap_priority_refresh(), app.place_directory_refresh() to service_role;
revoke all on function public.sitemap_priority() from public, anon, authenticated;
grant execute on function public.sitemap_priority() to service_role;
grant execute on function public.place_directory_index(), public.place_directory_page(integer), public.vehicle_make_index() to anon, authenticated, service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-sitemap-priority', '12,42 * * * *', 'select app.sitemap_priority_refresh()');
    perform cron.schedule('carmacars-place-directory', '17 * * * *', 'select app.place_directory_refresh()');
  end if;
end $$;
select app.sitemap_priority_refresh();
select app.place_directory_refresh();
