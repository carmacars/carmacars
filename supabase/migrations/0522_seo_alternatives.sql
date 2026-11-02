-- 0522: "alternative" search terms for the place pages (docs/changes/2026-11-07-r27-leftovers.md, section 4). Data only.
--
-- The owner: people search "Turo alternative", "RideAlike alternative" and "Luup alternative"; add them to the page
-- multiplier (0095: one page per enabled place and term, /car-rental/<term>/<place>, in the sitemaps through
-- place_hub and the sitemap files). The conventions of 0098 and 0115 hold: brand names only to say what the searcher
-- compared, the not-affiliated sentence on every page and in its questions, nothing said about the other companies'
-- prices, rules or service, and nothing CarmaCars does not do. Each term has its own words (no synonym: the intents
-- differ), and the quality gate (place_quality_gate) and the canonical rules apply to them like every rental term.
-- Titles: "Turo Alternative in <place>", "RideAlike Alternative in <place>", "Luup Alternative for Rideshare Drivers in
-- <place>" (web/src/features/places/copy.ts writes "<title> in <place>").
-- No applied migration is edited.

insert into place_terms (slug, vertical, phrase, title, match, served, landing_slug, intent_note, faq, sort_order) values
  ('turo-alternative', 'rental', 'Turo alternative', 'Turo Alternative', '{}', 'yes', null,
   'Rent from CarmaCars directly: one company handles the car, the rental agreement, the deposit and support from the request to the return. Send a request with no payment, and pay only once we confirm the car and the full price. Turo is named only to describe what you compared; CarmaCars is not affiliated with, approved or endorsed by Turo.',
   '[{"question": "Is CarmaCars part of Turo?", "answer": "No. CarmaCars is not affiliated with, approved or endorsed by Turo. You book with CarmaCars directly, on this site."}, {"question": "Who do I deal with when I rent?", "answer": "CarmaCars, from the request to the return: the car, the rental agreement, the deposit and support."}]', 900),
  ('ridealike-alternative', 'rental', 'RideAlike alternative', 'RideAlike Alternative', '{}', 'yes', null,
   'Every car shows its own photos, calendar, rates, deposit and kilometres included, and you book with CarmaCars directly. Send a request with no payment and see the full price before you pay. RideAlike is named only to describe what you compared; CarmaCars is not affiliated with, approved or endorsed by RideAlike.',
   '[{"question": "Is CarmaCars part of RideAlike?", "answer": "No. CarmaCars is not affiliated with, approved or endorsed by RideAlike. You book with CarmaCars directly, on this site."}, {"question": "Do I pay when I send a request?", "answer": "No. You pay only after we confirm the car and the price and you approve the offer."}]', 910),
  ('luup-alternative', 'rental', 'Luup alternative', 'Luup Alternative for Rideshare Drivers', '{}', 'yes', null,
   'A car for Uber, Lyft or delivery work, rented from CarmaCars directly. Tell us when you book. Weekly and monthly rates first: trips of {{weekFrom}} days or more use the weekly rate, and one booking runs up to {{maxDays}} days and renews. Luup, Uber and Lyft are named only to describe what you compared and the work; CarmaCars is not affiliated with, approved or endorsed by any of them.',
   '[{"question": "Is CarmaCars part of Luup?", "answer": "No. CarmaCars is not affiliated with, approved or endorsed by Luup, Uber or Lyft. You book with CarmaCars directly, on this site."}, {"question": "Can I use the car for rideshare work?", "answer": "Yes. Tell us when you book. Trips of {{weekFrom}} days or more use the weekly rate."}]', 920)
on conflict (slug) do update set phrase = excluded.phrase, title = excluded.title, intent_note = excluded.intent_note, faq = excluded.faq,
  served = excluded.served, sort_order = excluded.sort_order, is_active = true;
