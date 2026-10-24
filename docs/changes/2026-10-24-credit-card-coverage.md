# Which credit cards include rental car coverage (October 24, 2026)

Migration 0131. The owner, October 23, 2026: renters keep asking which credit cards include rental car coverage (coverage option 2: a G2 or full G licence plus OPCF 27, credit card rental coverage, or the CarmaCars Protection Plan).

## What renters see

- **`/credit-card-rental-coverage`** (in the pages sitemap, `/llms.txt` and `/llms-full.txt`): the car value limits first ("Most cards stop at $65,000 or $85,000": MSRP for the model year and trim, before taxes; many luxury cars, including many Mercedes-Benz models, are priced above them; over the limit, choose OPCF 27 or the Protection Plan), with the count of Canadian cards at $65,000, $85,000 and $100,000 from the list. Then "Confirm with your card issuer before you rent" (a summary, not a promise; CarmaCars does not decide claims and is not an insurer), the searchable list, the checklist (pay the whole rental with that card; decline other damage waivers only if your card's terms say so; check the car and the dates; bring proof of coverage; keep the paperwork), a note on peer-to-peer exclusions (you rent from CarmaCars under its rental agreement; still ask the issuer) and five questions answered from the list (the page's FAQPage data: real questions only).
- **The list**: search (issuer, card, exclusions), issued in (Canada, US), "Covers cars priced up to" ($65,000, $85,000, $100,000 or more: a card with no stated MSRP limit never counts), primary only. Columns: card, who pays first (Primary, Secondary, or "Not stated: ask the issuer"), car value limit, longest rental, key exclusions and conditions (car sharing and notes), the official guide (new tab), last checked, and "In the issuer's document" or "Unverified" with the summary it came from. Rendered on the server; the filters only narrow it. Scrolls sideways on a phone.
- **Links**: Requirements and coverage (option 2's row, and a line under the table on the $65,000 and $85,000 limits), the request form's option 2 ("Which cards include it", new tab), the renter portal's coverage section when option 2 is chosen, and the FAQ's coverage group ("Which credit cards include rental car coverage?", in the live block by the migration when the question is not there yet, and in `web/scripts/content/site-content.json`).
- Copy rules: no dashes, CarmaCars spelled so, the numbered company never shown, the Protection Plan never called insurance or coverage and its provider never named (unit test and the DB suite check the list and the page).

## What staff see

- **Admin > Settings > Card coverage** (`/admin/settings/card-coverage`): the table of every card (hidden ones too), "Change a card" for each (issued in, issuer, card, pays, MSRP limit, the limit in the guide's words, longest rental, exclusions, conditions, car sharing, note, official guide, where the numbers came from, read in the issuer's own document, last checked, order, shown) and "Add a card". Changing a card's facts without a date marks it checked today; a link must start with https://; the same card twice is refused; Admins only (the door: `admin_read 'card_coverage'`, `admin_save 'card_rental_coverage'`). A save refreshes the public pages at once. Every change is in the audit log.
- **Admin > Today**: "Check the credit card coverage list" while an active card was last checked more than 180 days ago.
- **`/va/card-coverage`** ("Card coverage" for every function: Renters for customer service, Bookings for Sales, Rentals for Finance and Fleet): what to say (send the page, ask which car, never say they are covered, offer OPCF 27 or the Protection Plan), what to check on a booking with option 2, and the same list.

## The database

- `card_rental_coverage` (row-level security, the admin policy; granted to no visitor), `public.card_coverage_public()` (the active cards, anonymous visitors too), `app.card_coverage_list`, `app.card_coverage_save`, the door wrapped (`door_pre0131`) and `app.site_setup_problems` wrapped (`site_setup_problems_pre0131`). `SCHEMA_MARKER` 0131. Suite 84 (`supabase/tests/84_card_coverage.sql`).

## The list as seeded (checked October 23, 2026)

48 cards: 41 Canadian, 7 US. 14 read in the issuer's own document that day; the rest marked Unverified with their source. The MSRP limits the list carries:

| Limit | Cards |
| --- | --- |
| $100,000 | CIBC Aventura Visa Infinite Privilege, CIBC Aeroplan Visa Infinite Privilege (both unverified) |
| $85,000 | American Express Cobalt, Gold Rewards, Aeroplan (issuer pages), Platinum, Aeroplan Reserve, Marriott Bonvoy (unverified); RBC Avion Visa Infinite Privilege; TD Aeroplan Visa Infinite Privilege (issuer); CIBC Aventura Visa Infinite (issuer, primary), Aeroplan Visa Infinite, Dividend Visa Infinite, Dividend Platinum Visa (issuer, primary); BMO eclipse Visa Infinite Privilege; Desjardins Odyssey World Elite (issuer, primary; names Mercedes-Benz as covered within the limit), Cash Back World Elite; Tangerine Rewards World Elite; Brim World Elite (issuer summary) |
| $65,000 | RBC Avion Visa Infinite, WestJet RBC World Elite; TD Aeroplan Visa Infinite, First Class Travel (issuer), Cash Back Visa Infinite; CIBC Gold, Platinum and Vacationgold (issuer, primary); Scotiabank Passport Visa Infinite (primary), Gold American Express, Momentum Visa Infinite (issuer, primary; excludes Porsche, Maserati and other exotic makes); BMO eclipse Visa Infinite (issuer, **secondary**), CashBack, Ascend and Blue Rewards World Elite; National Bank World Elite; PC Financial World Elite and Rogers Red World Elite (31 days); Neo World Elite |
| Value, not MSRP | Tangerine World Mastercard (actual cash value over $65,000 excluded, 31 days); MBNA Rewards World Elite (no price limit, expensive or exotic cars excluded, $65,000 per account for life, 31 days) |
| None | RBC ION+ Visa, Simplii Financial Cash Back Visa (unverified: not in any list of cards with the benefit); HSBC Canada cards are now RBC cards |
| US cards | Chase Sapphire Preferred (primary, up to $125,000 MSRP, excludes Maybach, Bentley, Rolls-Royce and other makes), Sapphire Reserve (primary, $75,000), Capital One Venture X (primary, $75,000 MSRP), Citi Strata Premier, Strata Elite (secondary in the US, primary outside it), Costco Anywhere Visa ($50,000), American Express US Platinum and Gold (secondary): all unverified |

What could not be read in the issuer's own document that day (marked Unverified on the page): American Express Platinum, Aeroplan Reserve and Marriott Bonvoy (their certificates could not be fetched); RBC Avion Visa Infinite's dollar limit (RBC's summary gives none); RBC Avion Visa Infinite Privilege, WestJet RBC World Elite and ION+; TD Aeroplan Visa Infinite (the certificate's rental car section was cut off) and Cash Back Visa Infinite; CIBC Aeroplan, Dividend Visa Infinite and the two Privilege cards; Scotiabank Passport Visa Infinite (read in the Passport Visa Infinite+ certificate of 2021) and Gold American Express; BMO eclipse Visa Infinite Privilege, CashBack, Ascend and Blue Rewards World Elite; National Bank; Desjardins Cash Back World Elite; Tangerine Rewards World Elite; PC Financial's limit; Rogers; Neo; HSBC; Simplii; every US card. Whether the American Express Canada cards pay first is not on their coverage pages ("Not stated: ask the issuer").

## Sources (read October 23, 2026)

Issuer documents:
- American Express Canada, Cobalt Card coverage: https://americanexpress.com/en-ca/insurance/coverage/cobalt-card
- American Express Canada, Aeroplan Card coverage: https://americanexpress.com/en-ca/insurance/coverage/aeroplan-card
- American Express Canada, Gold Rewards Card travel coverage: https://americanexpress.com/ca/en/benefits/gold-rewards-card/travel-coverage.html
- American Express Canada, Platinum Card insurance: https://www.americanexpress.com/en-ca/benefits/insurance/the-platinum-card/
- RBC Avion Visa Infinite summary: https://www.rbcinsurance.com/en-ca/wp-content/uploads/sites/2/2021/06/rbc-avion-visa-infinite-quebecforms.pdf
- RBC business cards' insurance: https://www.rbcroyalbank.com/business/credit-cards/_assets-custom/pdf/full-suite-of-insurance-coverages-EN.pdf
- TD Aeroplan Visa Infinite Privilege: https://www.td.com/content/dam/tdct/document/pdf/personal-banking/apinp-en.pdf
- TD First Class Travel Visa Infinite: https://www.td.com/content/dam/tdct/document/pdf/personal-banking/fct-en.pdf
- TD Aeroplan Visa Infinite certificate (partly read): https://www.td.com/content/dam/tdct/document/pdf/12281-2b-ap-infinite-roc-single-f-01-a2-final-en.pdf
- CIBC Aventura Visa Infinite: https://www.cibc.com/content/dam/personal_banking/credit_cards/agreements_and_insurance/aventura-infinite-certificate-en.pdf
- CIBC Dividend Platinum Visa: https://www.cibc.com/content/dam/personal_banking/credit_cards/agreements_and_insurance/dividend-platinum-ins-en.pdf
- CIBC Gold, Platinum and Vacationgold Visa: https://www.cibc.com/content/dam/personal_banking/credit_cards/agreements_and_insurance/auto-rental-ins-en.pdf
- Scotiabank Passport Visa Infinite+: https://www.scotiabank.com/content/dam/scotiabank/canada/common/documents/pdf/Passport-Infinite-plus-COI-EN.pdf
- Scotia Momentum Visa Infinite: https://www.scotiabank.com/ca/common/pdf/credit_card/MINF_rental_car_collision.pdf
- BMO eclipse Visa Infinite: https://www.bmo.com/pdf/bmo-eclipse-visa-infinite-certificate-of-insurance-en.pdf
- Desjardins auto rental certificate: https://www.desjardins.com/content/dam/pdf/en/business/credit-cards/auto-rental-insurance-certificate.pdf
- Tangerine World Mastercard: https://www.tangerine.ca/content/dam/tangerine/en/pdfs/credit-card-cardholder-agreement/6-Final_Tangerine_world_ecci-sm_en_10-25-2025.pdf
- PC Financial World Elite benefits guide: https://www.pcfinancial.ca/static/b3aa233e287755dba96d8c768c2ca0e0/50414271_PCF_Benefit_Guide_WE_EN.pdf
- Brim World Elite certificates (May 22, 2026): https://static.brimfinancial.com/afklm/pdf_files/Insurance%20Certificates%20-%20Brim%20World%20Elite%20(as%20of%20May%2022,%202026).pdf
- MBNA Rewards World Elite (TD Insurance): https://www.tdinsurance.com/content/dam/tdinsurance/document/pdf/product-summary-mbna-rewards-world-elite-cc-en.pdf
- American Express US car rental loss and damage guides: https://www.americanexpress.com/us/credit-cards/features-benefits/policies/car-rental-loss-and-damage-insurance-terms.html

Published summaries (the Unverified rows):
- Rewards Canada, credit card car rental insurance: https://www.rewardscanada.ca/credit-card-car-rental-insurance.html
- Milesopedia, National Bank World Elite insurance: https://milesopedia.com/en/personal-finance/insurance/nbc-world-elite-mastercard-insurance-guide/
- Your Mileage May Vary, primary rental car coverage (July 2026): https://yourmileagemayvary.com/2026/07/28/credit-cards-primary-rental-car-coverage/
- NerdWallet, Citi travel insurance: https://www.nerdwallet.com/article/travel/the-guide-to-citi-credit-card-travel-insurance
- NerdWallet, Chase Sapphire Reserve car rental insurance: https://www.nerdwallet.com/article/travel/chase-sapphire-reserve-car-rental-insurance-guide
- Chase Sapphire Reserve guide to benefits (copy on WalletHub): https://cdn.wallethub.com/wallethub/posts/100280/bgc10981_sapphire_reserve_cf57027.pdf
- Prince of Travel, RBC completes the HSBC Bank Canada acquisition: https://princeoftravel.com/?p=169128

## Checks

Typecheck, lint, unit tests (`src/features/coverage/cards.test.ts`: limits, filters, the questions, the page's required lines and links), the text check, `check-change-guides`, `scripts/test.sh` with suite 84, and end to end (`tests/e2e/card-coverage.spec.ts`, one worker, 375 and 1440): the page, its filters and axe; the Admin edit reaching the page; customer service's quick reference.

## Guides

- `renter/before-pickup`: option 2, which cards include it and their limits, and that only the issuer decides a claim.
- `va/your-workday`: Card coverage in every function's menu.
- `va/customer-service`: "Which credit cards include rental car coverage?": what to send, ask, never say, and offer.
- `admin/settings`: Settings > Card coverage: checking and correcting a card, Unverified, Today's reminder.

Published by migration 0131 (generated by `supabase/seed/0131_gen_guides.mjs`).
