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
