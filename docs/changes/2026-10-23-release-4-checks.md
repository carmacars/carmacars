# Release 4 of October 23: the full suite

The full suite of release 4 (0115 to 0127) failed on the end-to-end tests, the emails with database values, the SEO audit and the crawl. Each cause, and what changed. Migration 0128, schema marker `0128`.

## What changed

### End to end

- **Changes, staff propose a longer trip (both widths).** The renter's Documents page crashed once the booking had a rental agreement document without a title: 0127 named Blind Spot's agreement by its title (`d.title.startsWith('Blind Spot')`), and a document's title may be empty. The page reads it safely now (`d.title?.startsWith`), and the portal's document type says the title may be empty.
- **Mechanical work on the per car pages, in the vehicle sitemaps.** The test looked for `/sitemap-vehicles/t-oil-change-...`; since 0124 the files are at the root, `/sitemap-vehicles-t-oil-change-...xml`. The test reads the new names.
- **Flaky: field handover ("the database refused the completion").** The test's free car could be one another test had taken off the fleet insurance policy, and such a car is refused at handover (0078). Its free car is now one on the policy (`app.vehicle_on_policy`).
- **Flaky: the renter reviews a closed booking ("This car is not available to book").** The test took any published car on random dates; it now takes a car that takes requests and is free those days (no booking, block or cleaning time of another test).

### Emails with database values (9 problems)

Every owner billing email (owner_debit_notice, owner_invoice_issued, owner_invoice_voided, owner_pad_confirmed, owner_payment_failed, owner_payment_received, owner_payment_recorded, owner_payment_reversed, owner_upfront_invoice) showed "18122211 Canada Inc." on its own. 0122 made `app.owner_payee_name()` the legal name alone, for the agreements ("Agreements need to just say the numbered corp, no operating as"), and the emails' `payee_name` (the Payee row and the sender line above the mailing address) and the debit agreement copied into the confirmation took it too.

Migration 0128: `app.owner_email_payee_name()` names the payee in the emails as the legal review approved it (0053): "18122211 Canada Inc., operating as CarmaCars", never the bare business name (the lawyer's rule for the PAD payee, `web/src/features/legal-review.test.ts`) and never the numbered company alone (the brand rule; the email check accepts only the "operating as" form). `app.notification_payload` sets it as `payee_name` of every owner email (the Payee row, the sender line above the mailing address, the confirmation's subject) and in the first paragraph of the debit agreement copied into owner_pad_confirmed ("You authorize 18122211 Canada Inc., operating as CarmaCars, to debit..."). The agreements, their PDFs, the countersignature and the Banking page keep the legal name alone, as 0122 decided. Suites 07, 32 and 33 check the emails' payee and that no payload names the numbered company alone.

### SEO audit (26 problems)

- **Duplicate entries.** The priority sitemap (0115) repeated every car of the fleet and every landing page, which are in `/sitemap-cars.xml` and `/sitemap-landing.xml`, and the hubs file repeated three model pages of the vehicle sitemaps (`/cars/ford/mustang`, `/cars/mercedes-benz/c-class`, `/cars/porsche/macan`). Each address is now in one sitemap file: the priority list leaves out the addresses of the site's own files (cars, landing pages, fixed pages, guides, hubs), which are listed right after it at the top of the index, and keeps its own selection (makes, popular models, the place pages nearest us). The hubs file leaves out the model pages its make's vehicle models file lists (while the vehicle sitemaps are on).
- **Duplicate titles.** `/body-shop` and `/detailing` had the titles of the place pages of their first term in Toronto (`/body-shop/auto-body-shop/toronto`, `/detailing/car-detailing/toronto`). The hubs are now "Auto Body Shop in Toronto: Collision, Dents, Paint | CarmaCars" and "Car Detailing in Toronto: Ceramic, Tint, PPF | CarmaCars".
- **"/cars/<make> is linked but missing" (23).** The model pages of the fleet's cars (the hubs file) link up to their make, and the make pages of makes the vehicle catalog does not cover (Audi, Bentley, BMW, Ferrari, Infiniti, Lamborghini, Land Rover, Maserati, McLaren, Rolls-Royce: 0097, they list our cars of that make) were in no sitemap. `public.sitemap_hubs()` (0128) adds them to the hubs file when they are in search, and /cars links them under "Browse by make" (`public.vehicle_fleet_makes()`). The audit counts the hubs file's `/cars/<make>` addresses as make pages, like those of the vehicle makes file.

### Crawl (5 problems)

- **Admin > Settings > Forms, "Review and check" answered 404.** 0122 gave the official forms their mapping, so the button shows, but the local stack had none of the template PDFs the database names. The local stack (`web/scripts/local-db.sh`) now stores the publisher's downloads of the five forms (`web/tests/fixtures/official-forms`) where the forms-fetch workflow stores them in production and makes them the current templates (`app.official_templates_use_originals(true)`), as that workflow does.
- **/auth/oauth did not hydrate.** It is the start of "Continue with Google": a redirect to the provider's page (the local stand-in here), never a page of the site. The crawl skips it like /auth/callback.

### Live signals: the request form started (live-signals.spec.ts:58)

Failed in every full run since the tax label, Maps cap and Google sign-in release: the visitor focused the request form's first field and "Started the request form" never showed. Two real gaps, not timing:

- /book streamed the form in a Suspense boundary (`fallback={null}`), and React reveals a streamed boundary up to about 300 ms after the page loads. Until then the form sits in a hidden container: a field "touched" there is not focused and no `request_started` is sent (seen in the browser: the form's container replaced 185 to 394 ms after load). The form is now in the page's first HTML (no Suspense around `RequestWizard`, which reads the address itself).
- The beacon loads once the page is idle (up to 3 s after load), and lost what happened before: a field already in use and the price already shown (`quote_seen`, so "Saw the full price" missed now and then too). Components now hand their events to `emitTrack` (`web/src/lib/track/emit.ts`), which keeps them until the beacon starts; the beacon takes them, and counts the request as started if a field of the form already has the focus. It also starts the request on the first `input` or `change` in the form (autofill, a radio tapped without focus), besides `focusin`.

### Database suite

- Suite 56 (live visitor signals), "twice is below the threshold": the two searches were 40 to 43 days out, a weekend trip on the days where that is a Thursday or a Friday (it failed on October 24). The searches are now a Monday to Thursday trip.

## Checks

The specs above at 375 and 1440 (live-chat, live-heartbeat, live-signals 10 times in a row, request and visitor-history after the 0128 follow-ups), with sitemap-index, form-fillers, second-agreement, debit, owner-terms, tolls-plates-forms and audit-fixes: passed. The SEO audit: 0 problems. The emails with database values: 0 problems (the owner billing emails from the app's own rows). The crawl as admin and anon: 0 problems. Typecheck, lint, unit tests, the text check and the database suite.

## Guides

No guide change: the screens and steps of the guides are the same; /cars lists more makes under "Browse by make", the owner emails name the payee "<legal name>, operating as CarmaCars" again, and the rest are sitemaps, tests and the local stack.
