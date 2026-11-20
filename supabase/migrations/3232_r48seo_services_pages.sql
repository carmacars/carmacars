-- 3232 (release 48, SEO): every service on every search page, and the landing pages for how people ask
-- (docs/changes/2026-11-20-r48-seo.md).
--
-- The owner, Nov 20: promote every service on the search pages (the tracker, the owner program, the chauffeur, the kinds of
-- renters, the coverage options, delivery and pickup, the add-ons), and add pages for how people search ("car with a
-- charger", "car and flowers").
--
-- - public.service_facts(): the numbers the services module prints, in one read: the tracker product, the lowest
--   chauffeur rate, the add-ons with their prices and the landing pages that exist. Read by the server only.
-- - Five landing pages under /car-rental (seo_pages, editable in Admin > Settings > Search like the others): rideshare,
--   g2-licence, with-a-charger, with-flowers, with-child-seat. Their prices are tokens or the add-on cards the page
--   reads from the add-ons table (facts.addons), never a number typed into the copy.

create or replace function public.service_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'tracker', public.tracker_product(),
    'chauffeur_from_cents', (select min((app.chauffeur_vehicle_row(c) ->> 'rate_3plus_cents')::bigint) from chauffeur_vehicles c where c.active),
    'addons', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'description', a.description, 'photo_path', a.photo_path, 'price_cents', a.price_cents,
                 'pricing_unit', a.pricing_unit, 'cap_cents', a.cap_cents, 'lead_time_hours', a.lead_time_hours, 'max_per_booking', a.max_per_booking) order by a.sort_order, a.name), '[]'::jsonb)
                 from addons a where a.active),
    'landing', (select coalesce(jsonb_agg(p.slug order by p.slug), '[]'::jsonb) from seo_pages p where p.is_active))
$$;
revoke all on function public.service_facts() from public, anon, authenticated;
grant execute on function public.service_facts() to service_role;

insert into seo_pages (slug, kind, name, sort_order, facts, match, copy, source, status) values
  ('rideshare', 'use', 'Car rental for rideshare drivers', 240, '{"topic": "driving for a rideshare or delivery platform", "nearby": ["weekly", "monthly", "economy"], "agreement_section": "10.3"}', '{}',
   jsonb_build_object('seo_title', 'Car Rental for Uber and Lyft Drivers in {{city}} | {{brand}}', 'meta_description', 'Rent a car in {{city}} to drive for Uber, Lyft or a delivery app. Rideshare is allowed in the rental agreement, with weekly and monthly rates.',
     'h1', 'Car rental for rideshare and delivery drivers in {{city}}',
     'intro', 'Yes: you can drive a {{brand}} rental for Uber, Lyft and delivery apps. The rental agreement allows it in writing, and once you are booked your booking page makes the documents the platforms ask for. Rent by the week or the month, from drivers {{minAge}} and older with an Ontario {{licence}} licence.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'Allowed in writing', 'body', 'Section 10.3 of the rental agreement welcomes rideshare and delivery driving. Tell us in your request which platform you drive for. Only you or an additional driver on the booking may drive the car for that work, and each platform''s own rules for drivers and vehicles are yours to meet.'),
       jsonb_build_object('heading', 'Weekly and monthly rates', 'body', 'From {{weekFrom}} days the weekly rate applies, and {{monthDays}} days is charged at the monthly rate. Extend from your account while the car is free. The kilometre allowance and the overage rate are on each car''s page and in your offer, so you can cost a week of driving before you book.'),
       jsonb_build_object('heading', 'The documents the platforms ask for', 'body', 'Once the booking is confirmed, its page gives you the documents rideshare and delivery platforms ask a renter for. Upload them to the platform yourself; approval is the platform''s decision.'),
       jsonb_build_object('heading', 'Tolls, tickets and the tracker', 'body', 'The car is tracked by GPS for the whole rental, as the agreement says. Tolls and tickets during your rental are yours, each matched to your booking with the invoice as proof.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Can I use a rental car for Uber in {{city}}?', 'answer', 'Yes. The {{brand}} rental agreement allows rideshare and delivery driving. Uber and the other platforms decide which cars and drivers they accept, so check their vehicle rules for the car you choose.'),
       jsonb_build_object('question', 'Is {{brand}} affiliated with Uber or Lyft?', 'answer', 'No. {{brand}} is not affiliated with or endorsed by Uber, Lyft or any delivery platform. They are named only to describe the work.'),
       jsonb_build_object('question', 'How long can I rent for?', 'answer', 'By the week or the month, and you can extend from your account while the car is free.'),
       jsonb_build_object('question', 'How old do I have to be?', 'answer', 'Drivers {{minAge}} and older with an Ontario {{licence}} licence can rent. Drivers under {{fullAge}} pay a young driver fee for each day. The platforms set their own minimum age for drivers.'))), 'seed', 'published'),
  ('g2-licence', 'use', 'Car rental with a G2 licence', 236, '{"topic": "renting with a G2 licence", "licence_classes": ["G", "G2"], "nearby": ["young-drivers", "under-25", "economy"]}', '{}',
   jsonb_build_object('seo_title', 'Rent a Car With a G2 Licence in {{city}} | {{brand}}', 'meta_description', 'Yes, you can rent a car in {{city}} with a G2. {{brand}} accepts an Ontario {{licence}} licence for every car, from age {{minAge}}. See the cars and the fees.',
     'h1', 'Rent a car with a G2 licence in {{city}}',
     'intro', 'Yes: {{brand}} rents to G2 drivers. We accept an Ontario {{licence}} licence for every car in the fleet, from age {{minAge}}. If you are under {{fullAge}} a young driver fee is added for each day, shown on each car''s page before you send a request.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'What you need', 'body', 'Your Ontario {{licence}} licence, valid for the whole rental, and a credit card in your own name for the payment and the deposit. Before pickup you upload photos of your licence and a selfie, and a person checks them.'),
       jsonb_build_object('heading', 'The young driver fee', 'body', 'Drivers aged {{youngA}} usually pay {{ydA}} a day and drivers aged {{youngB}} usually pay {{ydB}} a day. The licence class changes nothing: a G2 driver and a G driver of the same age pay the same.'),
       jsonb_build_object('heading', 'Your G2 conditions still apply', 'body', 'The conditions on your licence apply in a rental car as in any car, including zero blood alcohol. Follow them: a breach is yours, not the car''s.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Can you rent a car with a G2 in Ontario?', 'answer', 'Yes, at {{brand}}. We accept an Ontario {{licence}} licence for every car, from age {{minAge}}.'),
       jsonb_build_object('question', 'Does a G2 driver pay more than a G driver?', 'answer', 'No. The young driver fee depends on your age, not your licence class.'),
       jsonb_build_object('question', 'Can I rent with a G1?', 'answer', 'A G1 driver cannot drive alone, so we rent to {{licence}} drivers. A G1 holder can ride as a passenger.'),
       jsonb_build_object('question', 'Can a G2 driver be an additional driver?', 'answer', 'Yes. Additional drivers need the same documents and are checked the same way.'))), 'seed', 'published'),
  ('with-a-charger', 'use', 'Car rental with a phone charger', 620, '{"topic": "a phone charger ready in the car", "addons": ["phone_charger"], "nearby": ["with-child-seat", "with-flowers", "electric"]}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental With a Phone Charger in {{city}} | {{brand}}', 'meta_description', 'Add a phone charger to any {{brand}} rental: a cable with USB-C and Lightning ends, waiting in the car at pickup. Tick it when you send your request.',
     'h1', 'A rental car with a charger waiting in it',
     'intro', 'Tick the phone charger when you send your request and it is in the car at pickup: one cable with USB-C and Lightning ends, so it fits an iPhone or an Android phone. The price is below and in your offer before you pay.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'How to add it', 'body', 'Choose a car, pick your dates and tick the charger in the add-ons step of the request. It is listed as its own line in your offer.'),
       jsonb_build_object('heading', 'Renting an electric car?', 'body', 'Electric cars are handed over with their charging cable, and each car''s page says how it charges. A car returned with less charge than it left with pays the recharging fee in the fee schedule.'),
       jsonb_build_object('heading', 'Bring it back with the car', 'body', 'The charger is ours and comes back with the car. One that is not returned is charged as the fee schedule says.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Does the rental car have a phone charger?', 'answer', 'Add one in your request and it is in the car at pickup: a cable with USB-C and Lightning ends.'),
       jsonb_build_object('question', 'Can I add a charger after I booked?', 'answer', 'Yes, from your booking page before pickup, while there is time to put it in the car.'),
       jsonb_build_object('question', 'Do the cars have USB ports?', 'answer', 'Each car''s page lists its features. The cable plugs into a USB port.'))), 'seed', 'published'),
  ('with-flowers', 'use', 'Car rental with flowers', 622, '{"topic": "a bouquet waiting in the car", "addons": ["flowers"], "nearby": ["luxury", "convertible", "exotic", "with-a-charger"]}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental With Flowers in the Car, {{city}} | {{brand}}', 'meta_description', 'A rental car with a fresh bouquet on the passenger seat: for an anniversary, a proposal, a birthday or an airport pickup. Add flowers to any {{brand}} rental.',
     'h1', 'A rental car with flowers waiting inside',
     'intro', 'Add flowers to your request and a fresh bouquet is on the passenger seat when you pick the car up or when we deliver it. People book it for anniversaries, proposals, birthdays and airport pickups. The price is below and in your offer before you pay.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'How it works', 'body', 'Tick flowers in the add-ons step of your request, ahead of pickup so we can order the bouquet: the notice we need is shown with the add-on. Tell us the occasion in the note.'),
       jsonb_build_object('heading', 'Make it a surprise', 'body', 'Have the car delivered to a home, a hotel or the airport with the bouquet inside: delivery starts at {{delMin}}. For the full gesture, add a chauffeur by the hour.'),
       jsonb_build_object('heading', 'Pick the car to match', 'body', 'A convertible for a summer evening, a luxury sedan for a dinner, an SUV when the family is coming too.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Can I rent a car with flowers in it?', 'answer', 'Yes. Add flowers to any {{brand}} rental and the bouquet is in the car at pickup or delivery.'),
       jsonb_build_object('question', 'How much notice do you need?', 'answer', 'Enough to order a fresh bouquet: the notice is shown with the add-on when you send your request.'),
       jsonb_build_object('question', 'Can you deliver the car with the flowers?', 'answer', 'Yes, across {{deliveryArea}}. Delivery starts at {{delMin}}.'))), 'seed', 'published'),
  ('with-child-seat', 'use', 'Car rental with a child seat', 624, '{"topic": "a child, baby or booster seat ready in the car", "addons": ["baby_seat", "child_seat", "booster_seat"], "nearby": ["minivan", "suv", "with-a-charger"]}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental With a Child Seat or Baby Seat in {{city}} | {{brand}}', 'meta_description', 'Add a baby seat, a child seat or a booster to any {{brand}} rental in {{city}}. It is in the car at pickup; you install it and check it suits your child.',
     'h1', 'A rental car with a child seat ready',
     'intro', 'Add a rear-facing baby seat, a forward-facing child seat or a booster to your request and it is in the car at pickup. The seat is charged per day up to a maximum, shown below and in your offer. You install it and check that it suits your child.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'Which seat', 'body', 'A rear-facing baby seat for infants, a forward-facing child seat for toddlers and a booster for older children. Ontario law sets which one your child needs by weight, height and age: choose by your child, and ask us if you are unsure.'),
       jsonb_build_object('heading', 'You install it', 'body', 'We put the seat in the car; you fit it and check it, because only you know your child''s size and the fit you are used to. Take the time you need before you drive off.'),
       jsonb_build_object('heading', 'Room for the family', 'body', 'Two seats and luggage fit best in an SUV or a minivan. Up to {{maxSeats}} seats can be added to one booking.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Can I rent a car with a car seat in {{city}}?', 'answer', 'Yes. Add a baby seat, a child seat or a booster to any {{brand}} rental.'),
       jsonb_build_object('question', 'How much is a child seat?', 'answer', 'A baby seat is {{baby}} a day up to {{babyCap}} for the rental. Each seat''s price is on this page and in your offer.'),
       jsonb_build_object('question', 'Do you install the seat?', 'answer', 'We put it in the car. You install it and check that it suits your child.'),
       jsonb_build_object('question', 'Can I bring my own seat?', 'answer', 'Yes. Your own seat is welcome.'))), 'seed', 'published')
on conflict (slug) do nothing;

-- The search page templates changed (release 48: the kit, the services module, the folds): every programmatic page's
-- lastmod moves once, so the sitemaps ask search engines to read them again.
select app.seo_content_epoch_refresh('r48-1');

-- IndexNow: the new pages are announced once (the five landing pages above queue themselves through their trigger).
select app.indexnow_queue_path(p, 'r48 seo: new page')
  from unnest(array['/trackers', '/trackers/install', '/services', '/trackers/kill-switch-for-car', '/trackers/starter-interrupt-device', '/trackers/gps-tracker-for-rental-car',
                    '/trackers/anti-theft-tracker-toronto', '/trackers/fleet-tracking', '/trackers/turo-host-gps-tracker', '/trackers/toll-and-ticket-billing']) p;
select app.indexnow_queue_path('/trackers/install/' || (x ->> 'slug'), 'r48 seo: new page') from jsonb_array_elements(public.tracker_install_places(60)) x;
