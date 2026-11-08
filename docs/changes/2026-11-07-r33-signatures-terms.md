# Signatures only by e-signature, updated terms to accept, Form D for the fleet supplier, Choose a portal (Release 33, part F: 0720 to 0722)

Branch `r33-f` (on `r33-e`). Migrations `supabase/migrations/0720_no_paper_signatures.sql` (the database refuses a new
paper signature; Form D on screen for every route, the fleet supplier's included; the second CarmaCars signer),
`0721_updated_terms_acceptance.sql` (versions to accept, acceptances, Admin's publish and list) and
`0722_r33f_signatures_terms_guides.sql` (guide text only, `supabase/seed/0722_gen_guides.mjs`). SCHEMA_MARKER 0722.
Tests: `supabase/tests/99_r33f_signatures_terms.sql` (40 assertions; the full suite 11154 passed). No applied migration is edited; the functions changed are wrapped
(suffix `_pre0720`, `_pre0721`).

## The owner's decisions (November 7, 2026)

| Item | How it works |
| --- | --- |
| 1. No paper signatures for anyone | Every agreement (rental agreements and changes, owner agreements of every route, Forms A to D, the debit agreement, investment, staff and contractor, partner, referral) is signed only through the e-signature flow. Removed: Record paper signature on the booking (Documents), the investor page, the partner page (and "Print the partner agreement" to sign on paper), Staff agreements, the owner checklist (agreements), the To do "paper" pop-up (now **Waiting to sign**, with the link to the owner), the field ready check's "Signed on paper instead? Scan it" (`src/server/actions/field-paper.ts` deleted), Record signed on paper on an updated Vehicle Schedule, "The owner signs on paper" in Add a car for an owner, "Already signed on paper" in Add a rental (and the assistant's `agreement: paper`), and the owner's photo upload of Forms C and D. The database refuses one too (`app.no_paper_guard`, triggers on `paper_signatures`, `signature_records` method paper, `signature_requests` provider paper, `vehicle_term_changes.signed_method`, `partners.agreement_method`, `bookings.agreement_on_paper`, Forms C and D uploaded on `owner_agreement_forms`; `app.staff_add_owner_car` refuses `signing: paper`); the server action refuses before it. Records already on file stay readable (and voidable): the booking's "Signed on paper (before November 2026)" card shows only when one exists. **Kept**: the official ServiceOntario forms the government requires in ink are printed as today and their scan is still recorded (`paper_signatures.doc_type = 'registry_form'`, "Record an official form signed in ink" on the owner checklist) |
| 2. Forced acceptance of updated terms | `terms_versions` (document, version, summary, text, its SHA-256, Requires acceptance) and `terms_acceptances` (who, when, IP address, device, the SHA-256 shown, the portal; never changed). Admin > Settings > **Updated terms** (`/admin/settings/terms`, `admin_do terms_publish`, `admin_read terms_versions`) publishes a version and lists who accepted. The terms of use and the privacy policy also replace the site's text (`legal.terms`, `legal.privacy`, `legal.meta` last updated); left empty, the site's current text is the version. Who is asked (`app.terms_binds`): terms and privacy, every account with a portal; the rental agreement, renters; the owner program agreements, owners of the standard routes; the fleet lease, fleet suppliers; the partner agreement, partners; the investment agreement, investors; the staff agreement, staff and field. Only accounts opened before the version; never an Admin. The renter, owner, investor and staff portal frames show **We've updated our terms** full screen (`TermsGate`) with the summary and the new text until each is accepted (Accept records it, `server_terms_accept`, which checks the version binds the person and the text is the one published). It voids no signed agreement and asks no renter to sign a past booking again. Not shown while an Admin views as someone |
| 3. Form D for the fleet supplier route | `app.owner_witnessed_forms` (wrapped) gives a supplier Form D (once; Form C stays out). Form D is signed on screen on every route now (`/owner/documents/form-d`, `app.owner_form_d_open`, `sign_requests.doc_type = 'form_d'`): the owner signs with the signing steps of every signature, the two witnesses type their names and the statement on the same device (`app.sign_request_sign`, wrapped, checks two different adults, neither the owner, each statement word for word). Part 2 is signed for CarmaCars from the stored signatures: the signing officer's automatic countersignature (Program settings `signing_officer_name`, as everywhere) and CarmaCars' witness, the new **second signing officer** (`program_settings.second_signing_officer_name` / `_title`, method `stored_signature`). The form is approved at once and the signed copy (both parts, the witnesses and the certificate) is filed in the owner's Documents. Form D's text is the Title Agreement's own form (`docs/source`, unchanged; there is no ServiceOntario Form D in the official forms): only its facts are filled. The Title-Holding and Lease Agreement stays in the supplier packet, the 30-day notice and forms 013-0169 / 013-1155 for an officer moving his own car are unchanged (r33-e) |
| 4. Choose a portal | Redesigned in the site's style (`src/features/access/PortalChooser.tsx`, `.cp` in `app.css`): the brand mark, then one card per portal (icon, name, one line of what is there, the person's role there), at least 88 px tall; the portal chosen last comes first (cookie `cc_last_portal`, set when a card is pressed; the portal key only) |
| 5. No renter portal for an Admin account | `portalsFor` leaves My rentals out for an Admin (the frame's "Also:", the chooser, the refusal pages); `/account` and its pages redirect an Admin to `/admin` (not while viewing as someone). The renter record and its bookings are not touched |

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/99_r33_fleet_supplier.sql` | no Forms C and D for a supplier (`7/0/0`, `...:0`) | Form D only (`7/1/0`, `...:1`) | item 3 |
| `supabase/tests/*.sql` that build records signed on paper (22 files) | | `set_config('app.paper_fixture', 'on', false)` first: a superuser session may still make those fixtures | item 1 |
| `web/src/features/assistant/assistant.test.ts` | add a rental "signed on paper" | sent to sign online | item 1 |
| `web/tests/e2e/signin.spec.ts` | the chooser's links read the portal names | cards (name, what, role), the last used first; an Admin who rents has no renter portal | items 4, 5 |
| `web/tests/e2e/guides-manual.spec.ts`, `guided-actions.spec.ts`, `ops.spec.ts`, `offers-and-rentals.spec.ts`, `long-rentals.spec.ts`, `long-rentals-2.spec.ts`, `insurer-rates.spec.ts`, `shared-pages.spec.ts` | paper signature flows | refused; Form D on screen; Waiting to sign | item 1 |
| `web/src/lib/schema-marker.ts` | 0711 | 0722 | the new migrations |

## Setup for the owner

- Program settings: **Second signing officer** (name and title). Until it is set, Part 2 of Form D carries the signing
  officer's signature only and its witness spot reads "to be set in Program settings".

## Not checked here

No local server: the pages were not opened in a browser (no end-to-end run); the updated end-to-end specs were not run.
Choose a portal was rendered statically (the same markup and the site's CSS) for the before and after screenshots. Type
check, lint, unit tests and the database suite ran.

## Guides

- `renter/start-here`, `owner/start-here`, `investor/start-here`, `va/start-here`, `field/start-here`: We've updated our terms.
- `owner/apply-and-get-your-car-listed`: Forms C and D on screen; the fleet supplier's Form D.
- `owner/documents-and-forms`: no paper copy; Form D on screen, with your two witnesses beside you.
- `owner/for-partner-rental-companies`: signed on screen only.
- `owner/quick-reference`: Sign Form D on screen.
- `admin/getting-around-admin`: Waiting to sign; Choose a portal; no renter portal for an Admin account.
- `admin/partners-company-cars-and-rentals-added-by-hand`: the partner agreement and rental agreements signed online only.
- `admin/owners-and-onboarding`: no paper signature; Record an official form signed in ink; Forms C and D on screen; the fleet supplier's Form D.
- `admin/settings`: investment and staff agreements by e-signature only; Updated terms to accept.
- `admin/assistant`: the rental agreement is always sent to sign online.
- `va/customer-service`: rental agreements signed online only; Owner forms.
- `va/add-a-rental-by-hand`: sent to sign online, Sign now on this device.
- `field/a-handover`: no paper copy.
- `investor/your-investments`: signed here only.

Exported to `docs/guides/content`; migration 0722 publishes the 18 changed chapters (`supabase/seed/0722_gen_guides.mjs`).
