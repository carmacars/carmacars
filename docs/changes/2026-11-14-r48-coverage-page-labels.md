# One name for each OPCF 27 page, and the hire email without a spaced dash (Release 48: 3012)

Migration `3012_r48_coverage_page_labels.sql`.

The endorsement page of an OPCF 27 proof was "OPCF 27 endorsement" (what is missing, the document's title, the staff Verify page), "the endorsement page" (the renter's checklist button) or "OPCF 27 endorsement page" (the review and the upload), depending on the screen.

- Every screen now says **pink slip** and **OPCF 27 endorsement page**: `app.opcf27_page_label` (what is missing, for the renter, staff and Admins), the document's title (existing titles renamed), the renter's checklist button (`app.renter_still_needed`), the staff Verify page and the renter's coverage card.
- The hire email (`applicant_hired`) gives the WhatsApp member tag in the owner's format, "Name - Position" (for example "Maria - Sales"), matching the first-day To do and the guides; `emails/check.mjs` allows that exact quoted pattern and still flags any other spaced hyphen.
- Tests: `supabase/tests/99_r35b_card_fuel_delivery.sql`, `supabase/tests/99_r48_plan_edit_licence.sql`.

## Guides

- `va/customer-service`: each page of an OPCF 27 proof is the **pink slip** or the **OPCF 27 endorsement page**.
