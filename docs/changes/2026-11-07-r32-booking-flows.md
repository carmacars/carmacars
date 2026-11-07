# Release 32, part B: booking flows (0680 to 0682)

Branch `r32-b` from `r32`. Migrations 0680 (one card charge), 0681 (the licence link in the request and offer emails),
0682 (the guide chapters). SCHEMA_MARKER 0682.

## 1. "Returned" in one tap

A return was recorded only on the booking page (the Check-out, check-in and signing card), so overdue cars sat stuck.

- Every booking on rent that is overdue or due back today has **Returned**: Admin To do (Check-outs and check-ins today),
  Bookings > Now (Out now and Coming back), the top of the booking page (also the page the late return alert opens),
  staff Today and Bookings for Fleet and customer service, and field staff's Cars now. The database decides who may
  (Admin, Fleet, Sales, Customer service, field staff); Finance is refused.
- A small form: the return time (now by default, may be earlier; never in the future), km and fuel if known. It records
  through the existing record-now path (`handover_record_now`, 0195): the booking is returned at that time, the late
  return charge follows it, Fleet gets the task to add the photos and readings.
- Late alerts stop: verified in the test (the overdue notices in the outbox are skipped, the late return To do closes,
  the reminder jobs emit no new late alert once returned). No database change was needed.
- Code: `web/src/features/handover/ReturnedButton.tsx`, `returned.ts` (which bookings show it, unit-tested).

## 2. One card charge for the rental and fees (0680)

The Money tab's "The rental and fees" charged the card on file once per part (two Stripe charges, two receipts).

- Now one charge (`card_charge_begin` with covers `balance`) for what is open, split in the database across the rental
  and the fees, the rental first (the same order `booking_part_open` already uses for a whole-booking card payment).
  What is open already leaves out the insurer's part and money received another way, so neither is charged. More than
  is open is refused.
- Commissions and owner payouts follow the rental part as before (one booking-total card payment, as a rental charge).
- The split is kept (`payment_part_allocations`); the Money tab lists the one payment as "Rental and fees (rental $x,
  fees $y)"; Stripe's one receipt says "Rental $x and fees $y".
- The rental or the fees alone with no amount charges what that part has open.
- Checked the same way: pay links of the balance (`payment_requests.covers = 'balance'`) were already one charge (0139);
  "Charge the saved card" after a change (BalanceActions) was one charge already and now uses the balance split; deposit
  holds and their capture are one Stripe call each. No other double charge.

## 3. Uploads: the camera or the photo library

A forced camera (`capture=`) hides the photo library on an iPhone.

- Staff uploads never force the camera: the Renter documents card (`StaffDocUpload`) and the licence photos of Sign now on
  this device (the selfie stays camera only).
- Renter and owner licence and document uploads show two choices, **Take a photo** (the camera) and **Choose from my
  photos** (no capture): the verify page cards (licence front and back, the coverage proof too), the additional driver's
  licence page, the owner's witnessed forms.
- Unchanged: selfies (camera only), the field checklist and job photos, the listing shots, the field fix-at-the-car
  screen (taken on the spot). The licence reader still checks every image (the upload path is the same).

## 4. Renter quick links (0681)

- The renter home (Your trips) shows, for the next booking while it needs them: **Upload your licence** (from the
  request on), **Upload proof of insurance** (after approval; the verify page) and **Check if your credit card covers
  rentals** (`/credit-card-rental-coverage`). `web/src/features/portal/quick-links.ts` decides (unit-tested).
- The request received, offer ready and offer reminder emails link straight to the licence upload while the renter's
  licence is missing (`licence_missing` in `app.ntf_booking`, the same check as the offer's acceptance). Their main link
  is unchanged.

Checks: `supabase/tests/99_r32_booking_flows.sql`, `returned.test.ts`, `quick-links.test.ts`.

## Guides

- `admin/requests-offers-and-bookings`: Returned; one card charge for the rental and fees.
- `va/fleet`: Returned.
- `renter/before-pickup`: Take a photo or Choose from my photos; the quick links and the email link.
