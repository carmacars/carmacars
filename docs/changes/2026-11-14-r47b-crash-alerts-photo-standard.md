# Crash alerts that mean something, the photo standard on the connector, a shorter To do list (Release 47, part B: 2895 to 2899)

Migrations `2895_r47b_client_error_alerts.sql`, `2896_r47b_connector_photo_standard.sql`, `2897_r47b_staff_digest_todos.sql`,
`2898_r47b_insurer_open_end.sql`, `2899_r47b_capture_clash.sql`. Test: `supabase/tests/99_r47b_alerts_digests.sql`.

## Website crash alerts (2895)

- Every browser error report is still kept 30 days in `client_errors`, now with its kind: `network` (Failed to fetch, network error, Load failed, NetworkError), `transition` (Transition was aborted, skipTransition), `stale_build` (a server action or chunk of the previous deploy: the page reloads itself since r46), `translation` (NotFoundError, removeChild, insertBefore, WebKit's "The object can not be found here."), `foreign` (Script error., extensions, MetaMask, a "Maximum call stack size exceeded" with no frame of the site) or `crash`.
- Only a `crash` opens a To do: one per page and message a day, written again on each report with how many times, how many people (signed-in account, else the visitor id cookie) and which browsers. One person: high; three or more the same day: urgent. A To do closed today stays closed.
- Fixed at the cause:
  - React #441 on `/car-rental/<place>`, `/careers/<role>/apply`, `/staff/visitors` (and the other pages that showed it): Next 16 streams metadata to browsers after the page, and every route's metadata runs the root layout's, which read the settings with no fallback; the place and landing pages also read the page, the tokens and the settings again. A busy read failed the metadata, which reached the browser as #441. Root, landing and place metadata now fall back to plain metadata (`features/seo/meta-fallback.ts`, unit tested); not found and redirects still pass. Visitors' Live now, History and Chat reads (staff and Admin) had no fallback either, as r46's Game leads: the page now says which part did not load.
  - NotFoundError on `/account/documents`, `/account/rewards`, `/pay/...`: the browser's translation (Chrome on iPhone in these reports) replaced React's text. An inline guard in `<head>` (`lib/client-error/dom-guard.ts`, unit tested) makes removeChild and insertBefore forgiving for a node that moved, the fix React's issue 11538 gives.
  - "Maximum call stack size exceeded" on `/account/rewards`: no recursion of the site's code on that page; it came in the same minute as the translation errors from Chrome on iPhone. Classed `foreign` only when its stack has no frame of the site, so one of ours still opens a To do.
- Once: open "Website crash" To do's that are now noise, or whose cause is fixed above, are closed with a note; the others stay open.

## The connector: photo_standard (2896)

`photo_standard {vehicle?, limit?}` (admin:read, read only, logged in api_calls): per car the photos, public, at the r45 standard, flagged (each with the check's why and reasons, tries and when), queued, AI angles and the angles still missing, the first photo's shot type and whether the public cover is a real photo, a sample or none; fleet totals; Gemini today (used, daily limit, reserve, left, waiting). The vehicle filter takes the id, fleet number or plate. Unit test in `features/api-access/tools.test.ts`.

## The connector: Stripe (2896)

Read live from Stripe in the web layer with the server's key, after the database checked the key and the scope and logged the call (`features/api-access/stripe-inspect.ts`, unit tested with a faked Stripe). The reads only GET; only a card's brand and last 4 are returned.

- `stripe_booking {booking}` (admin:read): every PaymentIntent, charge and SetupIntent the booking references (payments, card forms opened, pay links) or that Stripe finds by its metadata, with status, amounts, capture method, when, the last error, refunds, disputes and the card; beside the site's payments, holds and pay links; and a verdict ("paid and recorded", "paid at Stripe but not recorded (pi_...)", "hold authorized until ...", "not paid").
- `stripe_account {}` (admin:read): the balance per currency, charges and payouts enabled, the schedule, the next and last payout, and the open requirements (currently_due, past_due, eventually_due, current_deadline, disabled_reason).
- `stripe_record_paid {booking, payment_intent}` (admin:write, previewed then confirmed): records a PaymentIntent Stripe shows succeeded for the booking's total through settleIntent, the webhook's path. Nothing is charged or captured: any other status, booking or purpose is refused.

## A shorter Admin To do list (2897, 2898, 2899)

- **New staff this week** (first_day_admin): one standing To do, one line per hire of the last 60 days with what their onboarding still waits on (signing in, the agreement, pay details or their check, the academy) and the hire's page; a line drops off once nothing waits; written again on each change and every hour. **Pay details to verify** (verify_staff_payout): one line per person with the Verify link, gone once verified. The per-hire and per-payout To do's are no longer opened; the open ones were folded in.
- **Insurer rental with no known end date** (billed to an insurer or with its claim on file, dates provisional or the note saying the end date is not known): reaching the return time sends no overdue notice and opens no late-return To do; one "Insurer rental reached its end date: extend or close" To do instead, the booking stays on rent, and the To do closes when the end date moves later or the car is back. Open late-return To do's of such bookings were closed with a note.
- **Capture clash**: Stripe's "another in-progress request using this Idempotent Key" is read again a few times before anything is recorded (`server/portal/capture-check.ts`, unit tested); only a real refusal marks the payment failed. When an intent shows captured, a payment marked failed by a capture is recorded as paid again and its capture_failed To do closed. Once: the open ones are closed only when Stripe's payment_intent.succeeded for that intent is on file.

## Guides

No guide change: the new To do's carry their own instructions, and no screen's steps change (the connector tools are described in the connector itself).
