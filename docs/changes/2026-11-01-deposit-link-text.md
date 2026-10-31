# The deposit link texted before pickup, and texts by default (0213)

Owner requests, Release 21b. Migration `supabase/migrations/0213_deposit_link_text.sql`. Code: `web/src/server/deposit-guard.ts`
(`sendDepositLinks`), `web/src/server/paylink.ts`, `web/src/app/pay/[token]/page.tsx`, `web/src/features/money/BookingMoney.tsx`,
`web/src/features/field/Checklist.tsx`, `web/src/features/offers/model.ts`, `web/src/features/offers/OfferComposer.tsx`,
`web/src/features/admin/BookingReview.tsx`, `web/src/features/money/BalanceActions.tsx`, `web/src/features/handover/SendSigningLink.tsx`,
`web/src/features/signing/EsignFlow.tsx`. Tests: `supabase/tests/99_deposit_link_text.sql`, `web/src/features/offers/model.test.ts`,
`web/tests/e2e/release-21b.spec.ts`.

## 1. The deposit hold link by text before every pickup

- A confirmed booking whose deposit is a card hold (`deposit_pay_method` card, a deposit, not waived, not taken another way,
  no hold placed, a rental the hold covers): `site_settings.deposit_link_hours` (24) before pickup, or at once when the
  pickup is sooner, the deposit job (the Worker's five-minute tick: `public.server_jobs_due` says "deposits" while one is
  due) makes the same payment request as Money > Collect a card > The deposit hold (kind hold, covers deposit,
  `payment_requests.auto`), its Stripe hold intent, and texts the /pay link from the CarmaCars number (Quo).
- One live request per booking and deposit amount: nothing is made while a live hold request exists (staff's or the
  job's); an expired one, or one for an older amount, is replaced (the old one cancelled). The link stays open until a
  day after pickup.
- No mobile number, or the text not sent (refused when queued, or failed at Quo): a task **Deposit link not sent** (queue
  cs, high, due two hours before pickup) and an in-app notice to the Admins and the booking's staff
  (`staff_deposit_link_not_sent`, no email).
- The Money tab: "Deposit link texted <time>, opened <time>" (or not opened yet, or not sent with the reason). The pay
  page records the first opening (`payment_requests.opened_at`). The ready check shows the same under Deposit; the hold
  is still required before the keys, as before.
- Admin > Settings > Site settings, **Deposit link by text**: on by default, and the hours.

## 2. Text by default

- The offer composer and a sent offer's changes (the review screen): Text is ticked first, Email not. With no mobile
  number the link goes by email, and the screen says so (`offerChannels`).
- Money > Collect a card: by text when the renter has a mobile number, else on this device; a note when Text is chosen
  without one. A balance's pay link and the signing link: Text first.
- The signing code: by text first (`app.esign_view` `default_channel`, 0212); with no mobile, a note that it goes by email.
- No agreement wording changed.

## Guides

- `admin/requests-offers-and-bookings`: the deposit link before pickup, and Text first.
