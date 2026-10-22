# More rental search terms (migration 0098)

The owner, October 22, 2026: more rental search terms, for search only. No other copy or rule on the site changes
(requirements, FAQs, booking checks and Program settings stay as they are). Migration 0098 is data only: 36 rows in
place_terms (vertical rental), so every place gets a page per term (`/car-rental/<term>/<place>`), with its sitemap
files, and the car page variants pick them up later. 0096 and 0097 are reserved by other branches.

## 1. The terms

| Group | Terms | Cars listed |
| --- | --- | --- |
| Driving record | DUI, impaired driving conviction, bad driving record, high risk driver, demerit points, licence reinstatement | every car |
| Rideshare and delivery | Uber, Lyft, rideshare, Uber Eats, DoorDash, SkipTheDishes, Instacart, Hopp, delivery driver, gig driver | every car |
| New drivers | G2, new driver, newcomer to Canada, international student, international licence, no credit check | every car |
| | Debit card | cars with vehicles.no_credit_card (Toronto: /car-rental/no-credit-card) |
| Occasions | wedding, prom, photoshoot or film | premium, luxury and exotic |
| | ski trip | SUVs |
| | moving day | vans, minivans, SUVs, pickups |
| | 7 seater | 7 seats or more (Toronto: /car-rental/minivan) |
| | hybrid, electric | the fuel |
| | road trip, corporate, cross border, pet friendly, winter tires | every car |

"One way car rental" was already in 0095. A term's Toronto page is its own place page, except the two with a landing
page of the same intent (debit card, 7 seater).

## 2. Wording that stays true whatever the booking rules say

- Driving record: "Drivers with a DUI or a bad driving record can rent with us. Your eligibility and any deposit are
  confirmed when you book." Licence reinstatement: only once the licence is valid again; a valid licence is required.
- Rideshare and delivery: "Use your rental for Uber work. Tell us when you book." Weekly and monthly rates come first in
  the text and the first question. Brand names describe the work only, and every one of these pages says CarmaCars is
  not affiliated with, approved or endorsed by Uber, Lyft, Uber Eats, DoorDash, SkipTheDishes, Instacart or Hopp.
- Cross border: the site's rule (trips out of Ontario only with our written consent); there is no Program setting for US
  trips, so the page says a cross-border trip is not allowed without that consent.
- New drivers: Ontario G2 and G accepted; licences from outside Ontario are reviewed by a person before we confirm.
- Debit card: only the cars marked no credit card needed. Pets: with our approval, the pet cleaning fee only if needed.
- No long dashes, no numbered company, "CarmaCars" everywhere (DB test 61).

## 3. Tests

DB test 61: rental terms 31 + 36; the rideshare and delivery pages carry the not-affiliated line; the driving record
pages say eligibility is confirmed when you book; the debit card page lists the no credit card cars; every landing page
a term names exists. SCHEMA_MARKER 0098.

## Guides

No guide change: the terms are rows in Admin > Settings > Search, places and terms, which the admin guide already covers.
