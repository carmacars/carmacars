# CarmaCars website: what is not confirmed yet

Every value on the prototype that you have not confirmed, or that is sample data. Nothing here is typed into a page: each item is a field in `tools/src/site.mjs`, `tools/src/data.mjs` or `assets/photos.json`, and will be a field in the admin portal. Tell us the real value and it changes everywhere.

Status key: **Blank** = shown on the site as a hatched "to be added" marker or left out. **Sample** = invented so the layout can be judged. **Assumed** = our best reading of your documents or notes; confirm or correct. **Draft** = from your draft documents, waiting on the lawyer or accountant.

## 1. Brand

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 1 | Logo | Text wordmark "CarmaCars" (Inter Display 800, "Cars" in red) | Header, footer, every page | Assumed | Approve the wordmark, or send a logo file (SVG, plus a version for black backgrounds). The slot takes it with no redesign |
| 2 | Brand red | `#D0111B` | Buttons, links, selection, wordmark | Assumed | Confirm this is the brand red, or give the exact value |
| 3 | Tagline | "What goes around, drives around." | Home hero, footer | Assumed | Approve or replace |
| 4 | Other karma lines | "Good cars come back around." (owner band), "Word gets around." (reviews), "Not every road comes back around." (404), "Bring it back the way you got it, and so does your deposit." (footer) | Home, footer, 404 | Assumed | Approve each or strike it |
| 5 | Typeface | Inter Display for headings, Inter for text | Every page | Assumed | Approve the look |
| 6 | Favicon | Black square with a red mark | Browser tab | Sample | Supply one, or we draw it from the logo |
| 7 | Web address | `https://carmacars.ca/` | Canonical links, structured data | Assumed | Confirm the live domain and whether `www` is used |

## 2. Contact details

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 8 | Public email | `info@carmacars.ca` | Contact, confirmation page, request form opt-in | Assumed (from planning notes) | Confirm it exists and is the address for renters. Say if owners, billing or privacy requests need their own addresses |
| 9 | Phone number | Blank | Contact | Blank | The public number |
| 10 | WhatsApp | Blank (shares the phone row) | Contact | Blank | Whether WhatsApp is offered publicly, and the number |
| 11 | 24-hour incident and roadside line | Mentioned, no number ("in your rental agreement and your pickup message") | Contact, requirements, FAQ | Blank | The number, and whether it should be printed on the site |
| 12 | Street or mailing address | Blank | Contact | Blank | The address to show, or confirm none is shown |
| 13 | Pickup and return location | "We confirm the place with your booking" | Car pages, delivery, request form | Blank | Where renters collect and return cars |
| 14 | Opening hours | Blank | Contact | Blank | Days and hours |
| 15 | Pickup and return time slots | 8:00 a.m. to 8:00 p.m., every 30 minutes, default 10:00 a.m. | Search, car pages, request form | Sample | The real handover hours |
| 16 | Social accounts | None shown | Footer (appears when set) | Blank | Instagram, TikTok, Facebook links, if any |
| 17 | Response-time wording | "We reply as fast as we can during opening hours" and "Requests sent outside opening hours are answered when we reopen" | Contact, confirmation, FAQ | Assumed | Approve, or give the promise you want to make |
| 18 | Owner reply time | "within one business day", then a call | Owner page | Assumed (operating procedures) | Confirm |

## 3. Where you operate

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 19 | City named in headings and titles | "Toronto" | Titles, headings, descriptions | Assumed | Confirm Toronto is the right word (or GTA, or another city) |
| 20 | Service area | "Toronto, Ontario" | Contact, footer, structured data | Assumed | The area you want to be found in |
| 21 | Delivery area | Not stated. "Tell us the address and we confirm it with your booking" | Home, delivery, car pages, FAQ | Blank | Which cities or postal areas you deliver to |
| 22 | Airport delivery (Pearson, Billy Bishop) | Not mentioned | Nowhere yet | Blank | Whether you deliver to airports, and any extra fee |
| 23 | Delivery fee by area | Not used. The fee is per car only | Delivery, car pages | Assumed | Whether distance or area should change the fee |
| 24 | Travel outside Ontario | "Only with our written consent. Ask in your request" | Requirements, FAQ, car pages | Draft (rental agreement) | Confirm |

## 4. The fleet (all sample)

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 25 | Every car | 12 invented cars: Mercedes-Benz A220, CLA250, C300, GLC300, GLE350; Toyota Corolla, RAV4; Hyundai Elantra; Honda Civic; Tesla Model 3; Chrysler Pacifica; Mazda MX-5 | Fleet, car pages, home, footer | Sample | The real fleet register: year, make, model, trim, colour, plate or fleet number |
| 26 | Car details | Seats, doors, transmission, drive, fuel, consumption or range, luggage, six features each | Car pages | Sample | Per car, from the register |
| 27 | Car descriptions | One or two lines per car, written by us | Car pages | Sample | Approve the style; we rewrite for the real cars |
| 28 | Daily, weekend, weekly, monthly rates | $59 to $189 a day and matching weekly and monthly rates | Fleet, car pages, estimates | Sample | The rate sheet per car |
| 29 | "From $59 a day" | Computed from the cheapest car in the data | Home, fleet title and description | Sample | Nothing; it follows the real rates |
| 30 | Deposit per car | $500, $1,000 or $2,500 by class | Car pages, requirements, FAQ | Draft (billing spec) | Confirm the three amounts and which class each car is in |
| 31 | Class of each car | Economy, Standard, Premium, SUV, Luxury | Fleet filter, car pages | Sample | Class per car |
| 32 | Kilometre allowance | 200 km a day (150 for the GLE350) | Car pages, estimates | Sample | Allowance per car |
| 33 | Overage rate | $0.35 per km ($0.75 for the GLE350; "$0.75 to $1.50 luxury" in the fee list) | Car pages, requirements, FAQ | Sample per car, Draft for the range | Rate per car |
| 34 | Delivery and pickup fee per car | $75, $100, $125 or $175 | Car pages, delivery page, estimates | Sample | Fee per car (your range is $75 to $200) |
| 35 | Cars open to drivers aged 18 to 20 | Corolla, Elantra, Civic | Fleet filter, car pages, requirements | Sample | Which real cars are flagged |
| 36 | Fleet numbers | "CC 01" to "CC 12" on plate labels | Cards, car pages | Sample | Whether to show a fleet number, and its format |
| 37 | Booked dates | Invented bookings from October 15, 2026 | Calendars, fleet availability | Sample | Nothing; comes from live bookings |
| 38 | Featured cars on the home page | Seven chosen by us | Home rail | Sample | Which cars to feature |
| 39 | Winter tires | Offered as an extra, "subject to availability for the car" | Request form | Assumed | Which cars have them, and whether it is an extra or standard in winter |
| 40 | Baby seats | Up to 3 per booking | Request form | Assumed | Whether you stock them, and how many |

## 5. Photos

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 41 | Every car photo | Drawn stand-ins, 8 per car | Fleet, car pages | Sample | Real photos per `PHOTOS.md` |
| 42 | Scene photos | Drawn stand-ins for 9 slots | Home, delivery, owner, how it works, fleet, contact | Sample | Six scenes per `PHOTOS.md` |
| 43 | Photo descriptions (alt text) | Written for the stand-ins | Every image | Sample | We rewrite once real photos arrive |

## 6. Prices, fees and policy numbers

These come from your billing spec and rental agreement, which are drafts. Each is one field; confirm the list is current.

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 44 | Minimum age and licence | 18 or older; G2 or G; any car from 21 | Home, requirements, car pages, FAQ, request form | Draft | Confirm |
| 45 | Licences from outside Ontario | "Reviewed by a person before we confirm" | Requirements, FAQ, request form | Assumed | Your actual policy (other provinces, international) |
| 46 | Young driver fees | $35 a day up to $350 (18 to 20); $20 a day up to $200 (21 to 25) | Requirements, car pages, FAQ, estimates | Draft | Confirm |
| 47 | Additional driver fee and limit | $10 a day up to $70; form allows up to 3 | Requirements, car pages, request form | Draft; the limit of 3 is assumed | Confirm fee and the maximum number |
| 48 | Winter tire and baby seat fees | $15 a day up to $150; $12 a day up to $70 | Requirements, request form | Draft | Confirm |
| 49 | HST | 13%, added to estimates; "before HST unless stated" | Estimates, footer, fee tables | Draft | Confirm you are HST registered at launch, and whether the HST number must appear on the site or only on receipts |
| 50 | Rate rule | Weekend rate for days starting Friday or Saturday; 1 to 6 days capped at weekly; 7 to 29 days at one-seventh of weekly, capped at monthly; 30 days monthly | Car pages, FAQ, estimates | Draft | Confirm |
| 51 | Longest booking | 30 days, then renew | Home, car pages, FAQ, request form | Draft | Confirm |
| 52 | Deposit method and timing | At pickup; card hold up to 7 days, charged and refunded for longer; released within 7 business days; up to 30 days held back for open items | Requirements, car pages, FAQ | Draft | Confirm |
| 53 | Cancellation tiers | 95% within 24 hours of booking and 48 or more before pickup; 75% at 48 hours or more; 50% at 24 to 48; none inside 24; refunds within 10 business days | Home FAQ, car pages, cancellation page, request form | Draft (lawyer to confirm tiers are defensible) | Confirm |
| 54 | Non-refundable booking | 10% off the rental charge | Car pages, request form, FAQ | Draft | Confirm it is offered online |
| 55 | Offer validity | Open 24 hours; does not hold the car; if someone else pays first we offer another car or dates | Home, how it works, car pages, request form, confirmation, FAQ | Confirmed by you this week | Nothing, unless it changes |
| 56 | Damage | Under $2,500 at cost plus $50; $2,500 or more, the $2,500 deductible plus $75 | Home, requirements, car pages, FAQ | Draft | Confirm |
| 57 | Late return | 30 minute grace; $25 an hour plus the extra day | Requirements, FAQ, how it works | Draft | Confirm |
| 58 | Fuel and charging | Pump price plus 25%, or $10 per 10% of battery, plus $25 | Requirements, car FAQ, FAQ | Draft | Confirm |
| 59 | Cleaning, pet, smoking | $75; $250 heavy; $150 pet; $300 smoking | Requirements, FAQ | Draft | Confirm |
| 60 | Lost key, tolls, tickets, declined payment | Cost plus $50; $15 per toll invoice; $40 per ticket; $40 per declined charge | Requirements, FAQ | Draft | Confirm |
| 61 | Verification deadline and method | Licence front and back plus a selfie holding it, at least 24 hours before pickup | Home, how it works, requirements, confirmation, FAQ | Draft (operating procedures) | Confirm, and say if an identity-check service replaces the selfie |
| 62 | Pets | "With our approval" | Requirements, FAQ, request form | Draft | Confirm |

## 7. Coverage

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 63 | Price of coverage sold through CarmaCars | No price. "Priced for your car and dates" and "In your quote" | Estimates, requirements, request form | Blank | The price or price table |
| 64 | Coverage provider | Not named ("a third-party provider") | Requirements, home, car pages | By your instruction | Nothing |
| 65 | "Liability coverage included" | "Third-party liability coverage at the minimum limits Ontario law requires" | Home, requirements, car pages, FAQ | Draft (rental agreement 8.1) | Broker to confirm the wording |
| 66 | Roadside assistance | "Basic 24-hour roadside assistance for mechanical breakdown is included" | Requirements, FAQ | Draft | Confirm a provider is in place at launch |
| 67 | Whether selling coverage needs a licence | Not addressed on the site | | Draft (open point for the lawyer) | Lawyer's answer before option 3 is offered |

## 8. Reviews

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 68 | Reviews | Empty: "No reviews yet." | Home | Blank | Nothing until real reviews exist |
| 69 | Review source | Not decided | Home | Blank | Google reviews, your own post-trip reviews, or both |
| 70 | Review policy | "Renters can leave a review after a completed trip" | Home | Assumed | Who can review, whether you moderate, whether you reply |
| 71 | Populated-state content | Three items labelled "Sample, not a real review", behind a prototype switch | Home | Sample | Nothing; removed for launch |

## 9. Booking flow and accounts

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 72 | Sign-in method | Email and password, with a create-account tab | Sign in | Assumed | Password, emailed link, or Google sign-in |
| 73 | Account not required to request | "You do not need an account to request a car" | Sign in | Assumed | Confirm, or require an account |
| 74 | Password reset | "Forgot your password? Contact us" | Sign in | Assumed | Normal reset by email is expected in the real build |
| 75 | Fields asked in a request | Car, dates, times, delivery addresses, name, email, mobile, date of birth, additional drivers, referrer, licence class and expiry, coverage choice, booking type, extras, notes | Request form | Assumed | Add or remove fields |
| 76 | How the offer reaches the renter | "By email", then "reply yes" for the agreement and payment link | Confirmation, how it works | Assumed (operating procedures) | Email, text, WhatsApp or the portal |
| 77 | Request number format | "R-" and six digits | Confirmation | Sample | Your numbering |
| 78 | Payment method | Credit card in the renter's own name, through your checkout | How it works, requirements, FAQ | Draft | Confirm debit and prepaid cards are refused |
| 79 | Marketing opt-in text | "Sent by CarmaCars, info@carmacars.ca" | Request form | Draft | Anti-spam law expects the sender's mailing address in this line. Lawyer to confirm the wording now that the company name is not shown |

## 10. Owner program page

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 80 | Fees and revenue share | No numbers. "Depend on how many cars you have with us. We confirm them on a call" | Owner page | Confirmed by you this week | Nothing |
| 81 | Program facts | Paid on the 10th; billed on the 15th; no minimum term; 30 days' notice; no security deposit; free own use when not booked | Owner page, home | Draft (enrolment agreement) | Confirm these may be public |
| 82 | Up-front costs | "First and last month's insurance fee and a tracker install fee", no amounts | Owner page | Draft | Confirm |
| 83 | Referral reward | "Earn 20% of the rental charge on their first rental. Not on your own car" | Owner page | Draft | Confirm it may be public, or remove |
| 84 | Three ways to enrol | Managed, self-managed and Turo only, compared in a table | Owner page | Draft | Confirm all three are offered publicly, especially Turo only |
| 85 | "It comes back the way it left" | "Every handover is photographed, so it comes back the way it left" | Owner page | Assumed (a marketing claim) | Approve or soften |
| 86 | Listing time | "usually within two business days" | Owner page | Assumed (operating procedures) | Confirm |
| 87 | Cars you decline | "Rebuilt, salvage or irreparable" | Owner page | Draft | Confirm |
| 88 | Application questions | Name, mobile, email, year, make, model, ownership, registration, option | Owner page | Assumed | Add or remove |

## 11. Legal pages

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 89 | Terms of use | Your October 6 draft, with a "Draft for legal review" notice | Terms | Draft | Lawyer's final text |
| 90 | Privacy policy | Same draft | Privacy | Draft | Lawyer's final text |
| 91 | Cancellation policy | Same draft, plus worked examples computed from the tiers | Cancellation | Draft | Lawyer's final text |
| 92 | Legal entity name | Not displayed anywhere. "CarmaCars" is used, with a hidden note for the lawyer where the name would sit | Terms, privacy, footer, request form | By your instruction | Ask the lawyer whether Ontario consumer law requires the supplier's legal name and address on a site that takes bookings |
| 93 | Blanks in the legal text | Hatched "to be added": last-updated date, contact for notices, Privacy Officer name, email and address, countries where data is stored, cancellation email | Terms, privacy, cancellation | Blank | Each value |
| 94 | Tracking disclosure | Every car has a GPS tracker; the owner can see location; no sound or video; a moving car is never disabled | Requirements, how it works, FAQ, privacy | Draft | Lawyer to confirm the public wording |
| 95 | Cookie banner | None in the prototype | | Blank | The privacy draft says analytics cookies need consent; a banner is needed if analytics is used |

## 12. Other things we chose

| # | Item | Shown now | Where | Status | Needed from you |
| --- | --- | --- | --- | --- | --- |
| 96 | Structured data for search | Business type "AutoRental", price range "$$", each car "in stock" with its rates | Hidden in page code | Assumed | Nothing, unless you object |
| 97 | Page titles and descriptions | Written by us around "Toronto car rental" and "rent a [car] in Toronto" | Browser tab, search results | Assumed | Approve, or name the search terms you care about |
| 98 | "Photos are representative" line | "Colour, trim and features may differ" | Car pages | Draft (terms) | Confirm |
| 99 | Prototype clock | Fixed at October 15, 2026 | Calendars | Sample | Nothing; live date in production |
| 100 | Admin sample screen | Bookings table and fleet calendar with placeholder renters and totals | Style guide page | Sample | Nothing |
| 101 | Style guide link in the footer | Shown | Footer | Sample | Removed for launch |
| 102 | Language | English only, Canadian spelling | Every page | Assumed | Whether French or other languages are wanted |
