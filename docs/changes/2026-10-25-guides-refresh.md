# Guides, investor deck and investor video after Release 9, October 25, 2026

The owner: "make sure all of the guides are updated and accurate as well as the investor pitch deck, and investor video".

Migration `supabase/migrations/0168_guides_refresh.sql` (SCHEMA_MARKER `0168`) carries only the guides block, generated
by `supabase/seed/0168_gen_guides.mjs` (base `origin/main`, so every chapter changed here republishes its final text,
including the Admin chapters 0167 changed).

## Guides

Chapters whose text, screenshots or pins changed: `renter/find-a-car-and-send-a-request`, `renter/your-offer`, `renter/sign-and-pay`, `renter/before-pickup`, `renter/during-your-trip`, `renter/after-your-trip`, `owner/home-and-your-vehicles`, `owner/fees-payments-and-payouts`, `owner/documents-and-forms`, `admin/getting-around-admin`, `admin/requests-offers-and-bookings`, `admin/calendars`, `admin/fleet-and-listings`, `admin/the-investor-deck`, `admin/quick-reference`, `va/your-workday`, `va/customer-service`, `va/finance`, `va/fleet`, `va/sales`, `field/start-here`, `field/my-jobs`, `field/a-handover`, `field/photo-shoots`, `field/report-rentals-referrals-and-profile`, `investor/your-investments`, `investor/the-investor-deck`, `investor/statements`, `investor/profile-and-notices`.

- Text audited against the code, chapter by chapter, in `docs/guides/src/guides/*.py`; `docs/guides/content/*.json`,
  `images.json` and `docs/guides/src/img` regenerated from retaken screens (`export.py`).
- Redesigned screens (Admin To do, Owner home and vehicle, assistant queue and Finance, the field job list) re-cropped
  and re-pinned. The field handover steps are cropped to the step, below the job card.
- Investor: a "Watch the deck" step. Admin: the investor deck chapter lists the newest features.
- `portal-facts.md`: email links last 24 hours (an owner invitation 14 days).
- Field app: the header wrapped over the wordmark at 390 px (`.fd__top`, `field.css`).
- `guides.yml` has two inputs for this kind of run: `keep` (push the screens, converted to WebP, to a branch
  `guide-shots-<run>`, with the deck's own screens) and `records` (skip the sample-records e2e step).
- `web/scripts/guide-shots.mjs`: the stories follow today's flow (licence photos before approving an offer, the strong
  signature with code, initials and consents, the home address gate, a model year on the cars they use).

## Investor deck

- `features.ts`: slides rewritten for what shipped (offers without a request, signature with code and certificate,
  the trip page, the owner portal and terms car by car, the investor portal, the assistant queue, jobs from bookings,
  deposits settled after the bills, the field app with licence review, the Admin To do, the staff assistant, promo
  code end dates, referral partners). Rules kept: no insurance premium, fleet size, car count, utilization or
  internal costs; 3.2x with its footnote unchanged; investor offer percentage from settings; no numbered company
  name; no long dashes.
- New and refreshed screenshots in `web/public/deck`.

## After the deploy

- Re-run `guides-pdf.yml` (all portals) so the stored PDFs carry the new text.
- Re-run `investor-video.yml` once the deck is deployed: the narration (`docs/investor-video/script.md`) follows the
  new slide titles.
