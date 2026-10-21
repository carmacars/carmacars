# Listing with no roadblocks, proof of coverage, motion (October 21, 2026; migrations 0070 and 0071)

The owner, October 20 and 21, 2026: "Listing a car must have no roadblocks"; "Renters must upload their insurance policy
for OPCF 27, and credit card coverage must be on a credit card that actually has rental coverage"; "Make the site feel
interactive and appealing."

## 1. Every gate between Add a car and the public site (0070)

Entry points: Admin > Add a car (company, partner, program owner), staff adding a car for an owner (customer service,
fleet), an owner's own application, the application approved by an Admin, the listing intake and its review.

| Gate | Before (0022 to 0069) | After (0070) |
| --- | --- | --- |
| Year, make, model | Refused | Refused (the basics) |
| VIN | Required on every Add a car | Plate or VIN; staff may add by plate (an owner's own application still gives the VIN); "No VIN yet" on the checklist |
| Rates | Refused ("no rates are set") | Pre-filled from similar cars, else Program settings by class; Publish now sets them when missing |
| Car status onboarding (paperwork open) | Refused ("not enrolled yet") | Listed; the open steps are a checklist |
| Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate | Refused (through the status) | Checklist, "Paperwork" |
| Insurer confirmation (car on the fleet policy) | Refused (through the status) | Listed and bookable; HANDOVER refused until the car is on the policy; staff warned on the request and offer |
| Owner terms (Revenue Share) | Refused at Add a rental; a request failed with a database error | Checklist; a request uses the owner's terms or the standard grid |
| Owner's own application not decided | n/a | Not published automatically until decided (Publish now still works) |
| Details (colour, body, seats, gearbox) | Refused ("details missing") | Checklist; the page leaves them out |
| Photos (required shots, minimum count) | Refused | Sample photos stand in; any shot is optional |
| Plate check | Refused the listing while any public photo was unchecked | Holds back only that photo (it shows once checked); never on sample photos or an example car |
| Copy rules (AI draft missing or failing) | Refused | A clean template text stands in; the AI text replaces it by itself |
| Possible duplicate (open flag) | Refused | Checklist; only a duplicate confirmed by staff keeps the car off |
| Twin listing not live | Refused | The twin link is cleared |
| Owner or field staff submitting a listing | Staff review first | Unchanged (staff publish at once) |
| Retired, left the program, out of service, Turo only | Refused | Refused (true states) |
| Bookings turned off, Self-Managed owner in arrears, listing paused | Off the site | Unchanged |
| Publishing | Staff press Publish after every check | Publish now on every car page (Admin, customer service, fleet); Program setting "Publish new cars automatically", on by default: added with rates, rates saved, a car added for an owner, an application approved, enrollment |

The owner hears "your car is live" at enrollment, when it can be handed over. Enrollment of a published car makes it
Available. A car deleted before its events are sent no longer stops the notification batch.

## 2. Proof of coverage (0071)

| Option | What the renter does | What staff do | Gate |
| --- | --- | --- | --- |
| 1, OPCF 27 | Insurer, policy number, expiry strictly after the return date, the policy or endorsement as a PDF or photos (up to 6 pages, one proof) | Approve, or reject with a reason the renter sees | Handover until approved |
| 2, credit card | Pays with the card (Stripe funding must be credit; debit, prepaid and unknown are refused with OPCF 27 and the Protection Plan offered), cardholder name matches, ticks that the card covers this class for this length; benefit document optional | See brand, last four, funding, name match, still the Card on File; approve or reject | Handover until approved |
| 3, Protection Plan | Asks for it (a task) | Confirm it is active (needs a Protection Plan line) | Handover until confirmed (was impossible before) |

Changing the option lapses the earlier proof. Reminders 48 and 24 hours before pickup while the proof is missing or
declined, without doubling the identity reminder. Proofs are private (one-minute links) and kept 7 years; licence images
and selfies are deleted 90 days after the rental by the hourly purge job (/api/jobs/purge), never under a legal hold, an
open claim or a dispute.

## 3. Motion

Page transitions (View Transitions API, CSS fallback), steps of the request, scroll reveals only below the fold, press
and hover feedback, skeleton lines, image fade-in, under prefers-reduced-motion: no-preference only. Tests run with
reduced motion (playwright.config.ts); tests/e2e/motion.spec.ts turns it on.

## Tests

`supabase/tests/49_listing_no_roadblocks.sql`, `supabase/tests/50_coverage_proof.sql`; earlier suites updated where the
rules changed (11, 12, 15, 19, 25, 26, 34, 44); `web/tests/e2e/listing-coverage.spec.ts`, `web/tests/e2e/motion.spec.ts`.
