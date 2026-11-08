# Only insurance replacements are hidden from owners (0791); renter payments no longer fail on a changed name

Hotfix (owner, November 8). Bookings billed to the renter were hidden from their car's owner (the Program setting for
owner revenue visibility applied to every booking). Owners now see every booking that is not an insurance replacement.

- Every booking billed to the renter that was hidden is shown now, with a line in its history. Placeholder holds keep
  their own rule (the owner sees their dates only).
- A new booking billed to the renter is shown from the start. The Program setting still applies to insurance
  replacements (billed to an insurer, or split).
- Staff can no longer hide a booking billed to the renter. Settings > Program: "Hide only insurance replacements from
  owners", on by default.

## Renter payments

A renter with no card on file whose name or email changed after their first payment attempt (a licence approved, an
email changed) got an error on every Pay now and every pay link for a day: the card processor customer was made again
with the same request key and other details. The customer already made for the renter (or owner) is now found and used
again, and a new one gets a key that carries its name and email.

Checks: `web/src/integrations/payments/stripe.test.ts`, `supabase/tests/99_owner_visibility_insurance_only.sql`; `98_owner_hide.sql` runs with the rule off.

## Hiring, photo import, icon

- A sales hire's pay read "10.0000000000000000%": commission tiers now read 10%, 15% and 20% (`app.pct_text`).
- A Drive photo import stopped at 600 photos and skipped the rest ("More than 600 photos in one import"). The limits
  are now 5,000 photos, 2,000 folders and 40 GB a run; repeating the link adds only the photos not in yet.
- The site icon and the app icon use the red CarmaCars icon.

## Guides

No guide change: the setting is described in Settings itself; the Drive import chapter's numbers are updated in the next guide build.
