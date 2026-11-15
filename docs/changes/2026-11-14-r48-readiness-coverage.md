# The get-ready tracker and Approve all agree, and renters see what to send (Release 48: 2920)

Migration `2920_r48_coverage_truth.sql`.

A renter on OPCF 27 sent one page of his policy. Documents said **Approve all (1)** with nothing to approve, and his checklist said **Under review**, so he did not know where to upload the rest.

Root causes:

- The review counted the proof of coverage as soon as it was sent, but approving it is refused until both the pink slip and the OPCF 27 endorsement page are in, the policy details are complete and the policy runs past the return. Approve all then approved nothing.
- The Protection Plan was counted on a booking not paid yet, which Approve all cannot confirm.
- The renter's checklist read the newest coverage upload ("Under review") and never which page was missing.

What changed:

- One rule, `app.coverage_state(booking)`: whether the proof (or the plan) can be approved now, and what the renter still has to send. The count on Documents (Admin, customer service, the staff Verify page), what Approve all approves, the booking's get-ready line and the renter's checklist all read it.
- Staff see **Waiting for the renter: their pink slip** under Coverage, each page labelled (pink slip, OPCF 27 endorsement page), and the get-ready line says the same.
- The renter's step says exactly what is missing ("We have your OPCF 27 endorsement page. Still needed: your pink slip") and its button opens that upload with the page chosen (`verify?need=pink_slip`). A licence or selfie step opens its own upload too.
- Next to each upload, and after a refusal, drawn examples of a pink slip and an OPCF 27 endorsement page (made up: Example Insurance Co., fake numbers, EXAMPLE watermark) with the parts that must show circled and numbered, and short steps: where to find it (insurer app, email, glovebox), how to photograph it (flat, four corners, no glare), why one is sent back (`web/src/features/portal/CoverageExamples.tsx`).
- Tests: `supabase/tests/99_r48_readiness.sql`, `web/tests/e2e/coverage-examples.spec.ts`, `readiness.test.ts`.

## Guides

- `renter/before-pickup`: each checklist line says which insurance page is missing, its button opens that upload, the example pictures and how to take the photo
- `va/customer-service`: Approve all (n) counts only what it can approve; Waiting for the renter names the missing page
