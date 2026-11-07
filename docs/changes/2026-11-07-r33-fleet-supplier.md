# The fleet supplier route (Release 33, part E: 0710 and 0711)

Branch `r33-e`. Migrations `supabase/migrations/0710_fleet_supplier_route.sql` (the route, the default terms, the tier
lock, approval, portal signing only, the portal lease) and `0711_r33_fleet_supplier_guides.sql` (guide text only).
SCHEMA_MARKER 0711. Tests: `supabase/tests/99_r33_fleet_supplier.sql` (67 assertions), `web/src/features/owner/fleet-route.test.ts`. Text:
`docs/source/v2_fleet_lease.md` (status final, the lawyer markers removed; the articles are word for word the same).
No applied migration is edited.

## The owner's decisions (November 7, 2026)

| Item | How it works |
| --- | --- |
| 1. The lawyer approved the Fleet Supplier Lease Agreement | Program settings `fleet_lease_agreements_awaiting_lawyer` off (default off, as the flat-rate set since 0205): Admin no longer shows "Agreement awaiting lawyer OK". The source text says final; `FLEET_LAWYER_NOTES` is empty, so `FLEET_TEMPLATE_VERSION` is new (`owner-fleet-v1-190c27acf7`); agreements signed before keep their version |
| 2. A supplier opens his own account | The application (`/list-your-car/apply`, or `?route=fleet` from the new link on List your car): a corporation chooses **Fleet supplier: lease your cars to CarmaCars** (`owners.onboarding_route = 'fleet_supplier'`). It asks the corporation's legal name and number, the registered address, the signing officer's name and title, and per car the VIN (year, make and model from it), the plate, the tier and who it is registered to now (his corporation; an officer personally, moving it in; or a seller), with the name and address on the ownership and the transfer or sale date when it is not his corporation (`vehicle_onboardings.fleet_transfer`); the ownership copy is uploaded in the portal (Cars > the car; only that upload shows). "How it will work" is skipped. The database (`app.submit_owner_application`, wrapped) checks the same, makes each car Managed, held by the corporation, owned outright, leased to CarmaCars as an existing corporation (`lease_existing_corporation`), and runs `app.fleet_supplier_setup`: the default lease terms of Program settings (new `fleet_lease_default_*`: Regular $580, Troubled $200, claim profit 20%, write-off 100% under 18 months and 50% after, notice 30 days) from the first of the month, and the default Upkeep Table (engine, transmission, shocks, rustproofing, refurbishment: the supplier; tires, brakes, oil changes, ball joints: CarmaCars). Admin changes them on the Fleet lease card as before. **The forms are made at once** for each car (`app.vehicle_registry_forms` and `app.registry_context`, wrapped; 0042's official forms, only the empty boxes): the lease, as the existing-corporation lease (SR-LV-006, his corporation the registrant signed by the signing officer; SR-LV-012, CarmaCars holding the plates as the lessee; Form B on screen after approval), and, for a car not registered to his corporation, the transfer into it: ON00453 when the corporation has no RIN, and 013-0169 with 013-1155 when an officer moves his own car in (the officer as the transferor). A car bought from a seller is transferred on the back of the ownership permit (no fillable form); the seller and the sale date are kept. Filled again at approval. A form missing a value (a RIN, the odometer) stays a draft listing it, as on every route. No Forms C and D (paper, witnessed) and no upfront payment on the checklist. The Title-Holding and Lease Agreement stays in his packet: the approved agreement relies on it (its Title Agreement, 9.4) |
| 3. He marks each car Regular or Troubled | `vehicle_onboardings.lease_tier`, locked by a trigger. Before approval only an Admin corrects it (`fleet_onboarding_tier_correct`, the Fleet lease card's **Correct the tier**, with the reason, audited); Approve (`app.application_approve`, wrapped) sets each car's terms with no fees and no invoice and puts it on the lease at that tier from **Delivered on** (`fleet_lease_car_set`); after that 0640's `fleet_lease_tier_correct` |
| 4. Portal signing only | `app.record_paper_signature` refuses any owner agreement or form of a supplier; staff cannot choose "signs on paper" (`app.staff_add_owner_car`); the owner page hides Record paper signature for him |
| 5. The portal shows his lease | `owner_portal_home.fleet_lease` (`app.owner_fleet_lease_view`): each car, tier, lease a month, on the lease since, next payment date (`app.fleet_next_payment`: the first Payout Date one full month after delivery, then each 10th). Home (Your fleet lease, Next lease payment instead of Fees due), Money > Statements (the card above the statements, no Invoices tab), each car's page (Fleet lease instead of Terms and Invoices). No fee invoice or debit: 0640's guards |
| Staff | Owners > **Add an owner** (Admin, customer service, fleet) and **Add a car for an owner** (also Sales' Start an application): Route **Fleet supplier** for a corporation. Tier required, only the ownership copy, no terms or invoices, email signing only. A staff entry waits for an Admin's approval before the car goes on the lease (an Admin's own entry is approved at once) |

## Every route makes its forms by itself

Checked in `99_r33_fleet_supplier.sql` (section 10): an application on each route, approved, has every form its method needs filled with no other staff step: S1 (corporation, lease) 2, S2 (new Owner Corporation) 5, S3 (Co-Registrant) 2, S4 and S5 (Transfer) none (the back of the permit). Turo-Only needs none. Approval is the one staff step on the standard routes (the terms are set then); the fleet supplier's forms are filled when he adds the car. No route needed a fix.

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/99_r31_owner_agreements.sql` | the supplier's agreement "signed:true" (flagged for the lawyer) | "signed:false" | item 1 |
| `web/src/features/owner-agreement/fleet-lease.test.ts` | at least 6 fleet lawyer notes | none | item 1 |
| `web/src/features/portal-nav/tabs.test.ts` | Money tabs flag `partner` | flag `nofees` (a partner or a fleet supplier) | item 5 |
| `web/src/lib/schema-marker.ts` | 0682 | 0711 | the new migrations |

## Not checked here

No local server: the pages were not opened in a browser (no end-to-end run). Type check, lint, unit tests and the
database suite ran.

## Guides

- `owner/apply-and-get-your-car-listed`: A fleet supplier: lease your cars to CarmaCars.
- `admin/owners-and-onboarding`: A fleet supplier: the fleet lease (the route's defaults); Approve a fleet supplier's cars.
- `va/customer-service`: Add a car for an owner (a fleet supplier).
- `va/sales`: Owners you bring in (a fleet supplier).

Exported to `docs/guides/content`; migration 0711 publishes the 4 changed chapters (`supabase/seed/0711_gen_guides.mjs`).
