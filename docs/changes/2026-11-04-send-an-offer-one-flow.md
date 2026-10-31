# Send an offer as one flow; choices drive charges (0250)

The owner, Release 24: "the send offer page isn't cohesive. There's a bunch of rate cards that should probably be inside
dropdowns, and if the delivery is removed in one spot, the charge for it has to be manually removed in another spot."

- **One flow.** Send an offer (Admin and staff) is seven numbered steps: Renter and dates, Car, Pickup and return,
  Coverage, Add-ons, Price, Message and send. The price summary sits beside it on a desktop (sticky) and at the bottom of
  the screen on a phone (the total always in view; **Price details** opens every line). "The offer as the renter sees
  it" is folded under the price instead of a third column.
- **Reference tables folded.** The car's rates, deposit and rate sheet for the dates are under **Show rate card**
  (closed by default); "Type the total the renter pays", the add-on list and the internal note are disclosures too. On a
  booking's review screen the daily, weekend, weekly and monthly rate boxes are under **Show rate card**, open by
  themselves when one is changed.
- **Choices drive charges.** A fee set by hand is kept only while the choice that makes its line is chosen: the delivery
  fee with a delivery or an airport for the pickup, the collection fee with one for the return, the Protection Plan
  with option 3, an add-on's price with the add-on, a young driver fee with a driver of that age band, the additional
  driver fee with an additional driver. Taking the choice off drops the fee everywhere at once; choosing it again
  starts from the automatic amount.
  - The screens: `liveFees` and `lineLive` (`web/src/features/offers/model.ts`) prune the fees typed when a place, the
    coverage or the add-ons change, and the payload never carries a fee whose choice is gone. A fee the database
    priced away (a young driver fee once the date of birth is not young) is dropped from the boxes too
    (`droppedByPrice`).
  - **Charges** on Send an offer lists every fee with Automatic or **Set by hand**; **Change** opens its box, **Reset to
    automatic** removes the amount typed. The same badge and Reset are on each line of the price summary and under the
    choice that makes the fee (the delivery fee under Pickup, the Protection Plan under Coverage).
  - The review screen (`BookingReview`): a place changed away from a delivery or collection hides that fee box and puts
    it back to the booking's amount; a fee line the change makes (a delivery chosen now) gets its box; a fee box
    changed says Set by hand with Reset. Add a rental (`ManualRentalForm`): the same pruning, and "Add a line" offers a
    fee only when its choice is chosen (no delivery fee without a delivery, no young driver fee for a renter of 30).
  - The database (migration 0250): `app.line_overrides_live(spec)` keeps the fees set by hand whose choice is chosen,
    and `app.price_lines` takes only those, so no quote, offer, rental entered or booking repriced can carry a charge
    without its choice. A winter tire or baby seat set by hand changes its line and never makes one. The booking's price
    spec says how the car is handed over (`pickup_delivered`, `return_collected`), so a delivery with no distance yet
    still takes a fee typed by hand. A fee set by hand stored on a booking (`booking_line_overrides`) is deleted when its
    choice goes (the place, the coverage, the add-on cancelled), by triggers on `bookings` and `booking_addons`.
  - Pricing is otherwise unchanged: a fee whose choice is chosen is priced exactly as before; custom rates, the staff
    discount, insurer charges (VLF, LDW and the rest), card coverage, amounts typed before or after HST and drafts work
    as they did.
- Migration numbered 0250 (not 0242) to stay clear of a parallel branch at 0242 and up; `SCHEMA_MARKER` is 0250.
- Code: `web/src/features/offers/OfferComposer.tsx`, `web/src/features/offers/model.ts`,
  `web/src/features/admin/BookingReview.tsx`, `web/src/features/supply/ManualRentalForm.tsx`, `web/src/styles/admin.css`
  (`.oc-*`).
- Tests: `web/src/features/offers/model.test.ts` (the dependent lines), `supabase/tests/99_choices_drive_charges.sql`,
  `web/tests/e2e/send-offer-flow.spec.ts` (delivery removed takes its fee; the rate card closed; no horizontal overflow
  at 375 and 1440).

- **Simplicity pass** (the owner: "make it as easy to follow and understand as possible"): plain step titles, each with
  one line of what to do (Who is renting and when, Which car, Where they pick up and return, How damage is covered,
  Extras, The price, Send it); each step shows only what the current choices need, the rest under a labelled **More
  options** that opens by itself while something in it is used (another price, fees, deposit, discount, payment, how
  long the offer is open, the owner's view, the internal note, car filters); the price step says the rate sheet price
  in a sentence; what is missing is said beside its field once Send is pressed (`missingFields`, model.ts) and in one
  checklist above Send ("Ready to send" / "Missing: dates, car"); one primary button, "Send the offer to Nora", with
  Save without sending quiet; summary lines in plain words ("Car rental, 3 days", "Delivery to 78 Main St"), the
  total big; an (i) on the date of birth, coverage, kilometres, deposit and discount. On the review screen the
  discount and extra kilometre price are under More options.

## Guides

- `admin/requests-offers-and-bookings`: Send an offer without a request (the seven steps, Charges, Set by hand, choices
  drive charges); Answer a request with an offer (Show rate card, a place changed takes its fee).
