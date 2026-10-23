# The investor video: script

The owner, October 23, 2026: "generate a video using claude for the investor page, not to replace the deck but in
addition to the deck (goes over the entire deck with animations and sound and voiceover and transitions) throw it on the
investor page right above the deck".

This file is the video's script and its source: `web/scripts/investor-video/build.mjs` reads it, one scene per `##`
heading, in the deck's order. The rules are the deck's own (docs/changes/2026-10-21-investor-deck.md):

- **Every number is the deck's number.** A `{{name}}` is filled from `app.deck_figures()` with the deck's own formulas
  (`web/scripts/investor-video/deck-entry.tsx`), and the build stops if a filled value does not appear on the deck as
  rendered. No internal costs, fleet size or car count, ever.
- **The deck's words.** The narration retells the slide on screen in the deck's wording: CarmaCars, coverage "under our
  fleet policy", the multiplier always as "CarmaCars' figure" with its footnote, the Return as the fixed Yearly
  Percentage in the agreement, never a numbered company name, no long dashes.
- **The heading is the deck slide's title**, exactly (the build checks it against the slide). A heading marked
  `group` is a feature group: the group's opening slide and every feature slide after it, shown one after another
  while the narration plays.
- The narration is spoken by Cloudflare Workers AI text to speech; the captions are this text, as written.

Tokens: `brand`, `area`, `tagline`, `mult` (3.2x), `yearly` (30%), `min`, `lockup`, `payDay`, `monthly`,
`monthsToFirst`, `y1months`, `exampleAmounts`, `shareRange`, `feeRange`, `partner`, `days`, `total`, `phone`, `email`.
With the published defaults they read: 3.2x, 30%, $20,000, 6 months, the 15th, $500.00 a month, about 7.5 months,
$20,000 and $50,000, 25% to 35%, $370 to $475, 20%.

## CarmaCars

This is {{brand}}: car rental in {{area}}, built on cars owners bring to us and a platform we built ourselves.

## CarmaCars at a glance

A rental company that grows without buying every car. Investors back the growth and earn a fixed yearly percentage.

## The problem for renters

Renting a car is still harder than it should be. Counters, paperwork, surprise charges and uneven hosts.

## The problem for car owners

For owners, cars sit idle. Renting one out alone is a job.

## The solution

{{brand}} runs the rental. Owners earn, and renters get the whole price before booking and delivery to the door.

## How a rental works

Every rental follows the same checked path, from the request to the owner's statement, each step with its record.

## How CarmaCars adds cars

Three ways to add cars, two of them without capital. Owner cars pay a management fee of {{shareRange}}, and partner cars earn us a {{partner}} commission.

## How we make money

Seven lines of revenue: our own cars, managed owner cars, coverage under our fleet policy, Turo management, partner fleets and chauffeurs, detailing, and body shop work.

## The owner program fees

Each owner car pays {{feeRange}} a month in fixed fees, by tier, whether or not it is booked.

## Many revenue lines per rental

One rental, many lines of revenue. Delivery, add-ons and renter fees are never shared with the owner.

## A sample 3-day rental

From public prices, a sample {{days}}-day rental comes to {{total}} before HST. {{brand}} keeps its share, plus every fee line.

## Why the model scales

Each new car makes the business stronger: fixed fees, one fleet policy spread wider, and automation, not headcount.

## Profitability: {{mult}}

{{brand}}' figure: a {{mult}} multiplier on the money we invest in the fleet. Internal, not audited; your return is the fixed Yearly Percentage in your agreement.

## The platform at a glance

One platform for everyone in the business: seven portals, and the automation behind them.

## For renters (group)

For renters, it all happens on the phone: the whole price, request, sign, pay, upload ID and manage the trip.

## For car owners (group)

Owners apply in minutes, see every booking, get a statement with every line, and are paid to their bank.

## For investors (group)

Investors have their own portal, with every statement.

## For our team (group)

A small team runs a large fleet: queues with targets, tolls matched to the renter, and handovers guided on a phone.

## Admin and automation (group)

The platform does the busywork: one calendar, AI listings, Turo sync, automated emails and self-updating guides.

## Growth and marketing (group)

Search pages for every car, place and need: trillions of combinations, rendered on demand. Live visitor signals and unfinished forms become leads, with an account opened at once. Partner fleets add exotic cars and chauffeurs.

## Safety and risk controls

Built to protect every car and every dollar: reviewed requests, verified renters, deposits and a deductible.

## Team and operations

A lean, founder-led team, supported by the platform, with a 24/7 incident line.

## Roadmap

Next: native apps, GPS trackers, more partner fleets and marketplaces. Plans, not promises.

## The investment offer

The offer: {{yearly}} a year, set in your agreement, from {{min}}. No Return for the {{lockup}}-month lockup, then monthly, or reinvested.

## How your return builds

{{min}} at {{yearly}} a year pays {{monthly}} a month. The first payment comes about {{monthsToFirst}} months after you invest.

## Worked examples

What {{exampleAmounts}} can earn after one, two, three and five years, paid or reinvested.

## Return calculator

In the deck, the calculator lets you try your own numbers.

## Key risks

Read the key risks before you invest. You could lose all of the money you invest, and you cannot demand your money back.

## How to invest

Invest from {{min}}, all online: talk to us, sign, send the funds, and follow it here.

## Contact

Let's talk. Call {{phone}} or email {{email}}. Thank you for watching.
